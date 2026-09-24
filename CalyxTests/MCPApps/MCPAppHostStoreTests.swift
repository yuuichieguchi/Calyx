//
//  MCPAppHostStoreTests.swift
//  CalyxTests
//
//  MCPAppHostStore is the surface-UUID-keyed store that owns every MCP
//  Apps view (contract v2 §11.17). It implements MCPAppViewHosting and
//  MCPAppModelContextProviding, and additionally exposes MCPAppViewStatus
//  observation (snapshots/standaloneSnapshots/hasBackgroundActivity),
//  execution-layer notifications (viewDidLoadDocument/viewDidInitialize/
//  viewProcessDidTerminate/viewRequestedTeardown), app-tool registration
//  forwarding to MCPAppToolRegistry, and user actions (reload/close).
//
//  `CoupledRuntime` follows `.calyxMCPAppViewsChanged` the way the real
//  runtime does, so removal, retirement, server teardown and a destroyed
//  surface are checked against that coupling.
//
//  FakeMCPAppServerSession and FakeAppToolRegistry are shared doubles
//  (§14); FakePaneResolver and FakeTeardownRequester stay local since
//  §14 assigns them their own dedicated file names
//  (FakePaneResolving.swift / FakeViewTeardownRequesting.swift) that
//  this file does not need to duplicate to exercise the store.
//

import XCTest
@testable import Calyx

// MARK: - Fakes local to this file

@MainActor
private final class FakePaneResolver: MCPPaneResolving {
    var hosts: [UUID: MCPPaneHost] = [:]
    func paneHost(owningSurface surfaceID: UUID) -> MCPPaneHost? { hosts[surfaceID] }
}

/// Records every runtime call. mount does nothing else; send returns the
/// scripted reply.
@MainActor
private final class FakeTeardownRequester: MCPAppViewRuntime {
    private(set) var requestedViewIDs: [UUID] = []
    private(set) var mountedViewIDs: [UUID] = []
    private(set) var unmountedViewIDs: [UUID] = []
    private(set) var sentMessages: [(message: JSONRPCMessage, viewID: UUID)] = []
    var replyToRequests: (JSONRPCMessage) -> JSONRPCMessage? = { _ in nil }

    func requestTeardown(viewID: UUID) async {
        requestedViewIDs.append(viewID)
    }

    func mount(viewID: UUID, document: MCPAppViewDocument) async throws {
        mountedViewIDs.append(viewID)
    }

    func send(_ message: JSONRPCMessage, to viewID: UUID) async throws -> JSONRPCMessage? {
        sentMessages.append((message, viewID))
        return replyToRequests(message)
    }

    func unmount(viewID: UUID) {
        unmountedViewIDs.append(viewID)
    }
}

/// Mirrors how `MCPAppWebViewRuntime` is coupled to the store: it follows
/// `.calyxMCPAppViewsChanged` synchronously (the real observer runs on the
/// posting main thread) and drops the web view of any view the store no
/// longer lists, without closing its bridge. `requestTeardown` and
/// `unmount` act, and are recorded, only for a view still mounted; the
/// teardown request suspends once, as the real one waits for the reply.
/// A request sent to a view waits until `unmount` fails it (the real
/// bridge's `close()`).
@MainActor
private final class CoupledRuntime: NSObject, MCPAppViewRuntime {
    weak var store: MCPAppHostStore?
    private(set) var mounted: Set<UUID> = []
    private(set) var teardownRequestedViewIDs: [UUID] = []
    private(set) var unmountedViewIDs: [UUID] = []
    private(set) var sentMessages: [(message: JSONRPCMessage, viewID: UUID)] = []
    private var pendingRequests: [UUID: [CheckedContinuation<JSONRPCMessage?, Error>]] = [:]

    override init() {
        super.init()
        // Delivered on the posting thread, before `post` returns.
        NotificationCenter.default.addObserver(self, selector: #selector(viewsChanged(_:)), name: .calyxMCPAppViewsChanged, object: nil)
    }

    @objc private func viewsChanged(_ notification: Notification) {
        guard let store, notification.object as AnyObject? === store else { return }
        let listed = Set(store.allSnapshots().map(\.viewID))
        mounted = mounted.filter { listed.contains($0) }
    }

    var pendingRequestCount: Int { pendingRequests.values.reduce(0) { $0 + $1.count } }

    func requestTeardown(viewID: UUID) async {
        guard mounted.contains(viewID) else { return }
        teardownRequestedViewIDs.append(viewID)
        await Task.yield()
    }

    func mount(viewID: UUID, document: MCPAppViewDocument) async throws {
        mounted.insert(viewID)
    }

    func send(_ message: JSONRPCMessage, to viewID: UUID) async throws -> JSONRPCMessage? {
        sentMessages.append((message, viewID))
        guard case .request = message else { return nil }
        guard mounted.contains(viewID) else { throw MCPAppBridgeError.viewUnavailable }
        return try await withCheckedThrowingContinuation { continuation in
            pendingRequests[viewID, default: []].append(continuation)
        }
    }

    func unmount(viewID: UUID) {
        guard mounted.remove(viewID) != nil else { return }
        unmountedViewIDs.append(viewID)
        for continuation in pendingRequests.removeValue(forKey: viewID) ?? [] {
            continuation.resume(throwing: MCPAppBridgeError.closed)
        }
    }
}

/// A session whose `resources/read` waits until `release()`.
private final class BlockingReadSession: MCPAppServerSession, @unchecked Sendable {
    let serverID = MCPServerID(rawValue: UUID())
    let serverDisplayName = "Weather"
    private let lock = NSLock()
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var isReleased = false
    private let result: [String: AnyCodable]

    init(result: [String: AnyCodable]) {
        self.result = result
    }

    func release() {
        let released = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            isReleased = true
            defer { waiters.removeAll() }
            return waiters
        }
        released.forEach { $0.resume() }
    }

    func readResource(uri: String) async throws -> [String: AnyCodable] {
        await withCheckedContinuation { continuation in
            let resumeNow = lock.withLock { () -> Bool in
                if isReleased { return true }
                waiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
        return result
    }

    func callTool(name: String, arguments: [String: AnyCodable]) async throws -> MCPCallToolResult { MCPCallToolResult(raw: [:]) }
    func listTools() async -> [MCPToolDefinition] { [] }
    func listResources(cursor: String?) async throws -> (items: [[String: AnyCodable]], nextCursor: String?) { ([], nil) }
    func listResourceTemplates(cursor: String?) async throws -> (items: [[String: AnyCodable]], nextCursor: String?) { ([], nil) }
    func listPrompts(cursor: String?) async throws -> (items: [[String: AnyCodable]], nextCursor: String?) { ([], nil) }
    func events() -> AsyncStream<MCPServerEvent> { AsyncStream { _ in } }
}

/// Holds a value a test Task produced, for bounded polling.
@MainActor
private final class Box<Value> {
    var value: Value?
}

private struct WaitTimedOut: Error, CustomStringConvertible {
    let description: String
}

@MainActor
final class MCPAppHostStoreTests: XCTestCase {

    private func tool(name: String = "dashboard", resourceURI: String = "ui://server/view") throws -> MCPToolDefinition {
        try MCPToolDefinition(raw: [
            "name": AnyCodable(name),
            "_meta": AnyCodable(["ui": AnyCodable(["resourceUri": AnyCodable(resourceURI)])]),
        ])
    }

    private func invocation(
        serverID: MCPServerID = MCPServerID(rawValue: UUID()),
        surfaceID: UUID?,
        toolName: String = "dashboard",
        serverDisplayName: String = "Weather",
        clientName: String? = nil
    ) throws -> MCPUIToolInvocation {
        MCPUIToolInvocation(
            id: MCPInvocationID(rawValue: UUID()),
            serverID: serverID,
            serverDisplayName: serverDisplayName,
            tool: try tool(name: toolName),
            upstreamRequestID: .int(1),
            arguments: [:],
            surfaceID: surfaceID,
            clientName: clientName,
            clientDeclaredUI: false,
            requestedAt: Date()
        )
    }

    /// A resources/read result the validator accepts: one text/html
    /// content item under a `ui://` uri matching the tool's declared
    /// resourceUri, mimeType text/html;profile=mcp-app.
    private func validReadResourceResult(uri: String = "ui://server/view") -> [String: AnyCodable] {
        [
            "contents": AnyCodable([AnyCodable([
                "uri": AnyCodable(uri),
                "mimeType": AnyCodable("text/html;profile=mcp-app"),
                "text": AnyCodable("<!DOCTYPE html><html></html>"),
            ])])
        ]
    }

    /// A resources/read result the validator rejects: zero content items.
    private func invalidReadResourceResult() -> [String: AnyCodable] {
        ["contents": AnyCodable([AnyCodable]())]
    }

    /// Starts the invocation and waits for the store's load of its
    /// resource (read, validation, mount) to finish.
    private func startAndLoad(_ store: MCPAppHostStore, _ invocation: MCPUIToolInvocation, session: any MCPAppServerSession) async {
        await store.uiToolInvocationDidStart(invocation, session: session)
        await store.resourceLoad(forView: invocation.id.rawValue)?.value
    }

    private func makeStore(
        resolver: FakePaneResolver = FakePaneResolver(),
        teardownRequester: FakeTeardownRequester = FakeTeardownRequester(),
        appToolRegistry: FakeAppToolRegistry = FakeAppToolRegistry()
    ) -> MCPAppHostStore {
        MCPAppHostStore(paneResolver: resolver, runtime: teardownRequester, appToolRegistry: appToolRegistry)
    }

    // MARK: - Resource error card (validator rejects the content)

    func test_invalidResourceContent_producesResourceErrorStatus() async throws {
        let resolver = FakePaneResolver()
        let surfaceID = UUID()
        resolver.hosts[surfaceID] = .window(windowID: UUID(), tabID: UUID())
        let store = makeStore(resolver: resolver)

        let session = FakeMCPAppServerSession(readResourceResult: .success(invalidReadResourceResult()))
        let inv = try invocation(serverID: session.serverID, surfaceID: surfaceID)
        await startAndLoad(store, inv, session: session)

        let snapshot = try XCTUnwrap(store.snapshots(forSurface: surfaceID).first)
        guard case .resourceError = snapshot.status else {
            return XCTFail("expected .resourceError, got \(snapshot.status)")
        }
    }

    // MARK: - readFailed (resources/read itself throws), with Retry -> reload

    func test_readResourceThrows_producesReadFailedStatus() async throws {
        let resolver = FakePaneResolver()
        let surfaceID = UUID()
        resolver.hosts[surfaceID] = .window(windowID: UUID(), tabID: UUID())
        let store = makeStore(resolver: resolver)

        let session = FakeMCPAppServerSession(readResourceResult: .failure(FakeSessionError(message: "upstream timeout")))
        let inv = try invocation(serverID: session.serverID, surfaceID: surfaceID)
        await startAndLoad(store, inv, session: session)

        let snapshot = try XCTUnwrap(store.snapshots(forSurface: surfaceID).first)
        guard case .readFailed = snapshot.status else {
            return XCTFail("expected .readFailed, got \(snapshot.status)")
        }
    }

    func test_reload_fromReadFailed_reissuesReadResource_growingCallCount() async throws {
        let resolver = FakePaneResolver()
        let surfaceID = UUID()
        resolver.hosts[surfaceID] = .window(windowID: UUID(), tabID: UUID())
        let store = makeStore(resolver: resolver)

        let session = FakeMCPAppServerSession(readResourceResult: .failure(FakeSessionError(message: "boom")))
        let inv = try invocation(serverID: session.serverID, surfaceID: surfaceID)
        await startAndLoad(store, inv, session: session)
        XCTAssertEqual(session.readResourceCallCount, 1)

        let viewID = try XCTUnwrap(store.snapshots(forSurface: surfaceID).first?.viewID)
        await store.reload(viewID: viewID)

        XCTAssertGreaterThan(session.readResourceCallCount, 1, "reload must re-issue resources/read against the session")
    }

    // MARK: - waitingForApp after viewDidLoadDocument, no timer

    func test_viewDidLoadDocument_afterSuccessfulRead_transitionsToWaitingForApp() async throws {
        let resolver = FakePaneResolver()
        let surfaceID = UUID()
        resolver.hosts[surfaceID] = .window(windowID: UUID(), tabID: UUID())
        let store = makeStore(resolver: resolver)

        let session = FakeMCPAppServerSession(readResourceResult: .success(validReadResourceResult()))
        let inv = try invocation(serverID: session.serverID, surfaceID: surfaceID)
        await startAndLoad(store, inv, session: session)
        let viewID = try XCTUnwrap(store.snapshots(forSurface: surfaceID).first?.viewID)

        store.viewDidLoadDocument(viewID: viewID)

        let snapshot = try XCTUnwrap(store.snapshots(forSurface: surfaceID).first)
        guard case .waitingForApp = snapshot.status else {
            return XCTFail("expected .waitingForApp, got \(snapshot.status)")
        }
    }

    // MARK: - live after viewDidInitialize

    func test_viewDidInitialize_afterWaitingForApp_transitionsToLive() async throws {
        let resolver = FakePaneResolver()
        let surfaceID = UUID()
        resolver.hosts[surfaceID] = .window(windowID: UUID(), tabID: UUID())
        let store = makeStore(resolver: resolver)

        let session = FakeMCPAppServerSession(readResourceResult: .success(validReadResourceResult()))
        let inv = try invocation(serverID: session.serverID, surfaceID: surfaceID)
        await startAndLoad(store, inv, session: session)
        let viewID = try XCTUnwrap(store.snapshots(forSurface: surfaceID).first?.viewID)
        store.viewDidLoadDocument(viewID: viewID)

        store.viewDidInitialize(viewID: viewID)

        let snapshot = try XCTUnwrap(store.snapshots(forSurface: surfaceID).first)
        guard case .live = snapshot.status else {
            return XCTFail("expected .live, got \(snapshot.status)")
        }
    }

    // MARK: - stopped after viewProcessDidTerminate

    func test_viewProcessDidTerminate_transitionsToStopped() async throws {
        let resolver = FakePaneResolver()
        let surfaceID = UUID()
        resolver.hosts[surfaceID] = .window(windowID: UUID(), tabID: UUID())
        let store = makeStore(resolver: resolver)

        let session = FakeMCPAppServerSession(readResourceResult: .success(validReadResourceResult()))
        let inv = try invocation(serverID: session.serverID, surfaceID: surfaceID)
        await startAndLoad(store, inv, session: session)
        let viewID = try XCTUnwrap(store.snapshots(forSurface: surfaceID).first?.viewID)
        store.viewDidLoadDocument(viewID: viewID)
        store.viewDidInitialize(viewID: viewID)

        store.viewProcessDidTerminate(viewID: viewID)

        let snapshot = try XCTUnwrap(store.snapshots(forSurface: surfaceID).first)
        guard case .stopped = snapshot.status else {
            return XCTFail("expected .stopped, got \(snapshot.status)")
        }
    }

    // MARK: - upstreamDisconnected on non-ready state, cleared on ready

    func test_serverConnectionChanged_nonReady_marksViewsUpstreamDisconnected() async throws {
        let resolver = FakePaneResolver()
        let surfaceID = UUID()
        resolver.hosts[surfaceID] = .window(windowID: UUID(), tabID: UUID())
        let store = makeStore(resolver: resolver)

        let session = FakeMCPAppServerSession(readResourceResult: .success(validReadResourceResult()))
        let inv = try invocation(serverID: session.serverID, surfaceID: surfaceID)
        await startAndLoad(store, inv, session: session)
        let viewID = try XCTUnwrap(store.snapshots(forSurface: surfaceID).first?.viewID)
        store.viewDidLoadDocument(viewID: viewID)
        store.viewDidInitialize(viewID: viewID)

        store.serverConnectionChanged(serverID: session.serverID, state: .connecting)

        let snapshot = try XCTUnwrap(store.snapshots(forSurface: surfaceID).first)
        guard case .upstreamDisconnected = snapshot.status else {
            return XCTFail("expected .upstreamDisconnected, got \(snapshot.status)")
        }
    }

    func test_serverConnectionChanged_ready_clearsUpstreamDisconnected() async throws {
        let resolver = FakePaneResolver()
        let surfaceID = UUID()
        resolver.hosts[surfaceID] = .window(windowID: UUID(), tabID: UUID())
        let store = makeStore(resolver: resolver)

        let session = FakeMCPAppServerSession(readResourceResult: .success(validReadResourceResult()))
        let inv = try invocation(serverID: session.serverID, surfaceID: surfaceID)
        await startAndLoad(store, inv, session: session)
        let viewID = try XCTUnwrap(store.snapshots(forSurface: surfaceID).first?.viewID)
        store.viewDidLoadDocument(viewID: viewID)
        store.viewDidInitialize(viewID: viewID)
        store.serverConnectionChanged(serverID: session.serverID, state: .connecting)

        let readyInfo = MCPServerInfo(
            negotiatedEra: .v2025_11_25,
            serverInfo: MCPImplementation(name: "fixture", version: "1.0", title: nil, description: nil, websiteUrl: nil),
            instructions: nil
        )
        store.serverConnectionChanged(serverID: session.serverID, state: .ready(readyInfo, toolCount: 3))

        let snapshot = try XCTUnwrap(store.snapshots(forSurface: surfaceID).first)
        if case .upstreamDisconnected = snapshot.status {
            XCTFail(".upstreamDisconnected must be cleared once the server is ready again")
        }
    }

    // MARK: - Standalone panel title format

    func test_standalonePanel_title_toolServerClient_whenClientNamePresent() async throws {
        let store = makeStore()
        let session = FakeMCPAppServerSession(readResourceResult: .success(validReadResourceResult()))
        let inv = try invocation(serverID: session.serverID, surfaceID: nil, toolName: "dashboard", serverDisplayName: "Weather", clientName: "Claude Code")

        await startAndLoad(store, inv, session: session)

        let snapshot = try XCTUnwrap(store.standaloneSnapshots().first)
        XCTAssertEqual(snapshot.title, "dashboard · Weather · Claude Code")
    }

    func test_standalonePanel_title_toolServerOnly_whenClientNameNil() async throws {
        let store = makeStore()
        let session = FakeMCPAppServerSession(readResourceResult: .success(validReadResourceResult()))
        let inv = try invocation(serverID: session.serverID, surfaceID: nil, toolName: "dashboard", serverDisplayName: "Weather", clientName: nil)

        await startAndLoad(store, inv, session: session)

        let snapshot = try XCTUnwrap(store.standaloneSnapshots().first)
        XCTAssertEqual(snapshot.title, "dashboard · Weather")
    }

    // MARK: - hasBackgroundActivity(in:)

    func test_hasBackgroundActivity_trueForPaneHostWithLiveView() async throws {
        let resolver = FakePaneResolver()
        let surfaceID = UUID()
        let paneHost = MCPPaneHost.window(windowID: UUID(), tabID: UUID())
        resolver.hosts[surfaceID] = paneHost
        let store = makeStore(resolver: resolver)

        let session = FakeMCPAppServerSession(readResourceResult: .success(validReadResourceResult()))
        let inv = try invocation(serverID: session.serverID, surfaceID: surfaceID)
        await startAndLoad(store, inv, session: session)
        let viewID = try XCTUnwrap(store.snapshots(forSurface: surfaceID).first?.viewID)
        store.viewDidLoadDocument(viewID: viewID)
        store.viewDidInitialize(viewID: viewID)

        XCTAssertTrue(store.hasBackgroundActivity(in: paneHost))
    }

    func test_hasBackgroundActivity_falseForUnrelatedPaneHost() async throws {
        let resolver = FakePaneResolver()
        let surfaceID = UUID()
        resolver.hosts[surfaceID] = .window(windowID: UUID(), tabID: UUID())
        let unrelated = MCPPaneHost.window(windowID: UUID(), tabID: UUID())
        let store = makeStore(resolver: resolver)

        let session = FakeMCPAppServerSession(readResourceResult: .success(validReadResourceResult()))
        let inv = try invocation(serverID: session.serverID, surfaceID: surfaceID)
        await startAndLoad(store, inv, session: session)

        XCTAssertFalse(store.hasBackgroundActivity(in: unrelated))
    }

    // MARK: - App tools forwarded to MCPAppToolRegistry, unregistered on close

    func test_registerAppTools_forwardsToRegistry_withOwningSurfaceAndServerID() async throws {
        let resolver = FakePaneResolver()
        let surfaceID = UUID()
        resolver.hosts[surfaceID] = .window(windowID: UUID(), tabID: UUID())
        let appToolRegistry = FakeAppToolRegistry()
        let store = makeStore(resolver: resolver, appToolRegistry: appToolRegistry)

        let session = FakeMCPAppServerSession(readResourceResult: .success(validReadResourceResult()))
        let inv = try invocation(serverID: session.serverID, surfaceID: surfaceID)
        await startAndLoad(store, inv, session: session)
        let viewID = try XCTUnwrap(store.snapshots(forSurface: surfaceID).first?.viewID)

        let appTool = try MCPToolDefinition(raw: ["name": AnyCodable("record_event")])
        store.registerAppTools([appTool], viewID: viewID)

        XCTAssertEqual(appToolRegistry.registerCalls.count, 1)
        let call = try XCTUnwrap(appToolRegistry.registerCalls.first)
        XCTAssertEqual(call.tools, ["record_event"])
        XCTAssertEqual(call.surfaceID, surfaceID)
        XCTAssertEqual(call.viewID, viewID)
        XCTAssertEqual(call.serverID, session.serverID)
    }

    func test_close_unregistersAppToolsForThatView() async throws {
        let resolver = FakePaneResolver()
        let surfaceID = UUID()
        resolver.hosts[surfaceID] = .window(windowID: UUID(), tabID: UUID())
        let appToolRegistry = FakeAppToolRegistry()
        let store = makeStore(resolver: resolver, appToolRegistry: appToolRegistry)

        let session = FakeMCPAppServerSession(readResourceResult: .success(validReadResourceResult()))
        let inv = try invocation(serverID: session.serverID, surfaceID: surfaceID)
        await startAndLoad(store, inv, session: session)
        let viewID = try XCTUnwrap(store.snapshots(forSurface: surfaceID).first?.viewID)
        let appTool = try MCPToolDefinition(raw: ["name": AnyCodable("record_event")])
        store.registerAppTools([appTool], viewID: viewID)

        await store.close(viewID: viewID)

        XCTAssertEqual(appToolRegistry.unregisteredViewIDs, [viewID])
    }

    // MARK: - Model context: latest-only per view

    func test_modelContexts_returnsLatestEntryPerView() async throws {
        let resolver = FakePaneResolver()
        let surfaceID = UUID()
        resolver.hosts[surfaceID] = .window(windowID: UUID(), tabID: UUID())
        let store = makeStore(resolver: resolver)

        let session = FakeMCPAppServerSession(readResourceResult: .success(validReadResourceResult()))
        let inv = try invocation(serverID: session.serverID, surfaceID: surfaceID)
        await startAndLoad(store, inv, session: session)
        let viewID = try XCTUnwrap(store.snapshots(forSurface: surfaceID).first?.viewID)

        store.updateModelContext(viewID: viewID, entry: MCPAppModelContextEntry(
            viewID: viewID, serverDisplayName: "Weather", toolName: "dashboard", content: nil, structuredContent: AnyCodable("v1")
        ))
        store.updateModelContext(viewID: viewID, entry: MCPAppModelContextEntry(
            viewID: viewID, serverDisplayName: "Weather", toolName: "dashboard", content: nil, structuredContent: AnyCodable("v2")
        ))

        let contexts = store.modelContexts(forSurface: surfaceID)
        XCTAssertEqual(contexts.count, 1)
        XCTAssertEqual(contexts.first?.structuredContent?.stringValue, "v2")
    }

    // MARK: - close on a live view requests teardown first

    func test_close_onLiveView_requestsTeardownFirst() async throws {
        let resolver = FakePaneResolver()
        let surfaceID = UUID()
        resolver.hosts[surfaceID] = .window(windowID: UUID(), tabID: UUID())
        let teardownRequester = FakeTeardownRequester()
        let store = makeStore(resolver: resolver, teardownRequester: teardownRequester)

        let session = FakeMCPAppServerSession(readResourceResult: .success(validReadResourceResult()))
        let inv = try invocation(serverID: session.serverID, surfaceID: surfaceID)
        await startAndLoad(store, inv, session: session)
        let viewID = try XCTUnwrap(store.snapshots(forSurface: surfaceID).first?.viewID)
        store.viewDidLoadDocument(viewID: viewID)
        store.viewDidInitialize(viewID: viewID)

        await store.close(viewID: viewID)

        XCTAssertEqual(teardownRequester.requestedViewIDs, [viewID])
        XCTAssertFalse(store.hasActiveView(forSurface: surfaceID))
    }

    // MARK: - .calyxSurfaceDestroyed tears down the surface's views

    func test_surfaceDestroyedNotification_tearsDownViewsForThatSurface() async throws {
        let resolver = FakePaneResolver()
        let surfaceID = UUID()
        resolver.hosts[surfaceID] = .window(windowID: UUID(), tabID: UUID())
        let teardownRequester = FakeTeardownRequester()
        let store = makeStore(resolver: resolver, teardownRequester: teardownRequester)

        let session = FakeMCPAppServerSession(readResourceResult: .success(validReadResourceResult()))
        let inv = try invocation(serverID: session.serverID, surfaceID: surfaceID)
        await startAndLoad(store, inv, session: session)
        XCTAssertTrue(store.hasActiveView(forSurface: surfaceID))

        NotificationCenter.default.post(name: .calyxSurfaceDestroyed, object: nil, userInfo: ["surfaceID": surfaceID])

        XCTAssertFalse(store.hasActiveView(forSurface: surfaceID))
        XCTAssertEqual(teardownRequester.requestedViewIDs, [inv.id.rawValue])
    }

    func test_surfaceDestroyedNotification_forUnrelatedSurface_leavesViewsUntouched() async throws {
        let resolver = FakePaneResolver()
        let surfaceID = UUID()
        let otherSurfaceID = UUID()
        resolver.hosts[surfaceID] = .window(windowID: UUID(), tabID: UUID())
        let store = makeStore(resolver: resolver)

        let session = FakeMCPAppServerSession(readResourceResult: .success(validReadResourceResult()))
        let inv = try invocation(serverID: session.serverID, surfaceID: surfaceID)
        await startAndLoad(store, inv, session: session)

        NotificationCenter.default.post(name: .calyxSurfaceDestroyed, object: nil, userInfo: ["surfaceID": otherSurfaceID])

        XCTAssertTrue(store.hasActiveView(forSurface: surfaceID))
    }

    // MARK: - remapSurface(old:new:) moves views without a teardown

    func test_remapSurface_movesViewsToNewSurface_withoutTeardown() async throws {
        let resolver = FakePaneResolver()
        let oldSurfaceID = UUID()
        let newSurfaceID = UUID()
        resolver.hosts[oldSurfaceID] = .window(windowID: UUID(), tabID: UUID())
        resolver.hosts[newSurfaceID] = .window(windowID: UUID(), tabID: UUID())
        let teardownRequester = FakeTeardownRequester()
        let store = makeStore(resolver: resolver, teardownRequester: teardownRequester)

        let session = FakeMCPAppServerSession(readResourceResult: .success(validReadResourceResult()))
        let inv = try invocation(serverID: session.serverID, surfaceID: oldSurfaceID)
        await startAndLoad(store, inv, session: session)

        store.remapSurface(old: oldSurfaceID, new: newSurfaceID)

        XCTAssertFalse(store.hasActiveView(forSurface: oldSurfaceID))
        XCTAssertTrue(store.hasActiveView(forSurface: newSurfaceID))
        XCTAssertTrue(teardownRequester.requestedViewIDs.isEmpty, "a reconnect remap must not tear the WKWebView down and rebuild it")
    }

    // MARK: - Server removed/disabled tears down every view on that server

    func test_teardownViewsForServer_tearsDownEveryViewOnThatServer() async throws {
        let resolver = FakePaneResolver()
        let surfaceA = UUID()
        let surfaceB = UUID()
        resolver.hosts[surfaceA] = .window(windowID: UUID(), tabID: UUID())
        resolver.hosts[surfaceB] = .window(windowID: UUID(), tabID: UUID())
        let teardownRequester = FakeTeardownRequester()
        let store = makeStore(resolver: resolver, teardownRequester: teardownRequester)

        let serverID = MCPServerID(rawValue: UUID())
        let sessionA = FakeMCPAppServerSession(serverID: serverID, readResourceResult: .success(validReadResourceResult()))
        let sessionB = FakeMCPAppServerSession(serverID: serverID, readResourceResult: .success(validReadResourceResult()))
        let invA = try invocation(serverID: serverID, surfaceID: surfaceA)
        let invB = try invocation(serverID: serverID, surfaceID: surfaceB)
        await startAndLoad(store, invA, session: sessionA)
        await startAndLoad(store, invB, session: sessionB)

        await store.teardownViews(forServer: serverID, reason: "server disabled")

        XCTAssertFalse(store.hasActiveView(forSurface: surfaceA))
        XCTAssertFalse(store.hasActiveView(forSurface: surfaceB))
        XCTAssertEqual(Set(teardownRequester.requestedViewIDs), Set([invA.id.rawValue, invB.id.rawValue]))
    }

    // MARK: - callAppTool forwards tools/call to the live view that registered the tool

    func test_callAppTool_forwardsToOwningLiveView_andReturnsItsResult() async throws {
        let resolver = FakePaneResolver()
        let surfaceID = UUID()
        resolver.hosts[surfaceID] = .window(windowID: UUID(), tabID: UUID())
        let runtime = FakeTeardownRequester()
        let viewResult: [String: AnyCodable] = [
            "content": AnyCodable([AnyCodable(["type": AnyCodable("text"), "text": AnyCodable("recorded")])]),
        ]
        runtime.replyToRequests = { message in
            guard case .request(let id, _, _) = message else { return nil }
            return .response(id: id, result: AnyCodable(viewResult), error: nil)
        }
        let store = makeStore(resolver: resolver, teardownRequester: runtime)

        let session = FakeMCPAppServerSession(readResourceResult: .success(validReadResourceResult()))
        let inv = try invocation(serverID: session.serverID, surfaceID: surfaceID)
        await startAndLoad(store, inv, session: session)
        let viewID = try XCTUnwrap(store.snapshots(forSurface: surfaceID).first?.viewID)
        store.viewDidLoadDocument(viewID: viewID)
        store.viewDidInitialize(viewID: viewID)
        store.registerAppTools([try MCPToolDefinition(raw: ["name": AnyCodable("record_event")])], viewID: viewID)

        let result = await store.callAppTool(surfaceID: surfaceID, viewID: viewID, name: "record_event", arguments: ["text": AnyCodable("hi")])

        XCTAssertEqual(result.raw, viewResult, "the view's own tools/call result is returned verbatim")
        let request = try XCTUnwrap(runtime.sentMessages.last { entry in
            if case .request = entry.message { return true }
            return false
        })
        XCTAssertEqual(request.viewID, viewID)
        guard case .request(_, let method, let params) = request.message else { return XCTFail("expected a request") }
        XCTAssertEqual(method, "tools/call")
        XCTAssertEqual(params?["name"]?.stringValue, "record_event")
        XCTAssertEqual(params?["arguments"]?["text"]?.stringValue, "hi")
    }

    func test_callAppTool_withoutAnOwningLiveView_returnsIsError() async throws {
        let resolver = FakePaneResolver()
        let surfaceID = UUID()
        resolver.hosts[surfaceID] = .window(windowID: UUID(), tabID: UUID())
        let runtime = FakeTeardownRequester()
        let store = makeStore(resolver: resolver, teardownRequester: runtime)

        let result = await store.callAppTool(surfaceID: surfaceID, viewID: UUID(), name: "record_event", arguments: [:])

        XCTAssertEqual(result.raw["isError"]?.boolValue, true)
        XCTAssertTrue(runtime.sentMessages.isEmpty, "with no owning view nothing is sent to any view")
    }

    // MARK: - The CSP reported to the app is the builder's normalized list

    func test_appliedCSP_schemelessDeclaration_isReportedAsHTTPSOrigin() async throws {
        let resolver = FakePaneResolver()
        let surfaceID = UUID()
        resolver.hosts[surfaceID] = .window(windowID: UUID(), tabID: UUID())
        let store = makeStore(resolver: resolver)

        let result: [String: AnyCodable] = [
            "contents": AnyCodable([AnyCodable([
                "uri": AnyCodable("ui://server/view"),
                "mimeType": AnyCodable("text/html;profile=mcp-app"),
                "text": AnyCodable("<!DOCTYPE html><html></html>"),
                "_meta": AnyCodable(["ui": AnyCodable(["csp": AnyCodable([
                    "connectDomains": AnyCodable([AnyCodable("api.example.com"), AnyCodable("http://evil.example.com")]),
                ])])]),
            ])])
        ]
        let session = FakeMCPAppServerSession(readResourceResult: .success(result))
        let inv = try invocation(serverID: session.serverID, surfaceID: surfaceID)
        await startAndLoad(store, inv, session: session)

        let applied = try XCTUnwrap(store.appliedCSP(forView: inv.id.rawValue))
        XCTAssertEqual(applied.connectDomains, ["https://api.example.com"])
        let capabilities = MCPAppHostCapabilities.build(appliedCSP: applied).raw
        let reported = capabilities["sandbox"]?["csp"]?["connectDomains"]?.arrayValue?.compactMap(\.stringValue)
        XCTAssertEqual(reported, ["https://api.example.com"])
    }

    // MARK: - A failed resources/list fallback lookup does not fail the view

    func test_listResourcesFailure_forMetaFallback_stillMountsTheView() async throws {
        let resolver = FakePaneResolver()
        let surfaceID = UUID()
        resolver.hosts[surfaceID] = .window(windowID: UUID(), tabID: UUID())
        let runtime = FakeTeardownRequester()
        let store = makeStore(resolver: resolver, teardownRequester: runtime)

        // The content item has no _meta.ui, so the store looks for the list entry's.
        let session = FakeMCPAppServerSession(readResourceResult: .success(validReadResourceResult()))
        session.listResourcesResult = .failure(FakeSessionError(message: "resources/list unsupported"))
        let inv = try invocation(serverID: session.serverID, surfaceID: surfaceID)
        await startAndLoad(store, inv, session: session)

        let snapshot = try XCTUnwrap(store.snapshots(forSurface: surfaceID).first)
        if case .readFailed = snapshot.status {
            XCTFail("a failed metadata fallback must not fail a view whose resources/read succeeded")
        }
        XCTAssertEqual(runtime.mountedViewIDs, [inv.id.rawValue], "the view mounts with the undeclared defaults")
    }

    // MARK: - Second review fixes

    /// Polls `condition` on the main actor; throws when it stays false.
    private func waitUntil(timeout: TimeInterval = 2, _ description: String, _ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { throw WaitTimedOut(description: description) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func makeCoupled(resolver: FakePaneResolver = FakePaneResolver(), appToolRegistry: FakeAppToolRegistry = FakeAppToolRegistry())
        -> (store: MCPAppHostStore, runtime: CoupledRuntime) {
        let runtime = CoupledRuntime()
        let store = MCPAppHostStore(paneResolver: resolver, runtime: runtime, appToolRegistry: appToolRegistry)
        runtime.store = store
        return (store, runtime)
    }

    /// Starts a view in `surfaceID` and brings it to live.
    private func startLiveView(
        _ store: MCPAppHostStore, surfaceID: UUID?, serverID: MCPServerID = MCPServerID(rawValue: UUID())
    ) async throws -> UUID {
        let session = FakeMCPAppServerSession(serverID: serverID, readResourceResult: .success(validReadResourceResult()))
        let inv = try invocation(serverID: serverID, surfaceID: surfaceID)
        await startAndLoad(store, inv, session: session)
        let viewID = inv.id.rawValue
        store.viewDidLoadDocument(viewID: viewID)
        store.viewDidInitialize(viewID: viewID)
        return viewID
    }

    /// `callAppTool` with a bound: a request the coupled runtime parks is
    /// answered only by `unmount`, so a misrouted call would never return.
    private func callAppTool(
        _ store: MCPAppHostStore, surfaceID: UUID, viewID: UUID, name: String
    ) async throws -> MCPCallToolResult {
        let box = Box<MCPCallToolResult>()
        Task { @MainActor in
            box.value = await store.callAppTool(surfaceID: surfaceID, viewID: viewID, name: name, arguments: [:])
        }
        try await waitUntil("callAppTool returns") { box.value != nil }
        return try XCTUnwrap(box.value)
    }

    private func methods(sentTo viewID: UUID, by runtime: CoupledRuntime) -> [String] {
        runtime.sentMessages.filter { $0.viewID == viewID }.compactMap { entry in
            switch entry.message {
            case .notification(let method, _), .request(_, let method, _): return method
            default: return nil
            }
        }
    }

    // Finding 1: teardown and unmount reach the runtime on every removal path.

    func test_close_sendsTeardownAndUnmounts_withACoupledRuntime() async throws {
        let surfaceID = UUID()
        let (store, runtime) = makeCoupled()
        let viewID = try await startLiveView(store, surfaceID: surfaceID)

        await store.close(viewID: viewID)

        XCTAssertEqual(runtime.teardownRequestedViewIDs, [viewID], "ui/resource-teardown must reach the still-mounted view")
        XCTAssertEqual(runtime.unmountedViewIDs, [viewID], "the web view must be released")
        XCTAssertFalse(store.hasActiveView(forSurface: surfaceID))
    }

    func test_retirement_sendsTeardownAndUnmounts_withACoupledRuntime() async throws {
        let surfaceID = UUID()
        let (store, runtime) = makeCoupled()
        let first = try await startLiveView(store, surfaceID: surfaceID)
        await store.uiToolInvocationDidFinish(MCPInvocationID(rawValue: first), result: MCPCallToolResult(raw: [:]))
        XCTAssertEqual(store.snapshot(viewID: first)?.status, .completed)

        let session = FakeMCPAppServerSession(readResourceResult: .success(validReadResourceResult()))
        let next = try invocation(serverID: session.serverID, surfaceID: surfaceID)
        await startAndLoad(store, next, session: session)

        XCTAssertEqual(runtime.teardownRequestedViewIDs, [first], "the retired view gets ui/resource-teardown")
        XCTAssertEqual(runtime.unmountedViewIDs, [first])
        XCTAssertNil(store.snapshot(viewID: first))
    }

    func test_serverTeardown_sendsTeardownAndUnmounts_withACoupledRuntime() async throws {
        let (store, runtime) = makeCoupled()
        let serverID = MCPServerID(rawValue: UUID())
        let viewID = try await startLiveView(store, surfaceID: UUID(), serverID: serverID)

        await store.teardownViews(forServer: serverID, reason: "server removed")

        XCTAssertEqual(runtime.teardownRequestedViewIDs, [viewID])
        XCTAssertEqual(runtime.unmountedViewIDs, [viewID])
    }

    func test_surfaceDestroyed_sendsTeardownAndUnmounts_withACoupledRuntime() async throws {
        let surfaceID = UUID()
        let (store, runtime) = makeCoupled()
        let viewID = try await startLiveView(store, surfaceID: surfaceID)

        NotificationCenter.default.post(name: .calyxSurfaceDestroyed, object: nil, userInfo: ["surfaceID": surfaceID])

        XCTAssertFalse(store.hasActiveView(forSurface: surfaceID), "the table drops the view before the post returns")
        XCTAssertEqual(runtime.teardownRequestedViewIDs, [viewID], "the teardown request starts before the post returns")
        try await waitUntil("the destroyed pane's view is unmounted") { runtime.unmountedViewIDs == [viewID] }
    }

    // MARK: - K52: a view ends with the conversation that called it

    private func postConversationEnded(_ surfaceID: UUID) {
        NotificationCenter.default.post(name: .calyxAgentConversationEnded, object: nil, userInfo: ["surfaceID": surfaceID])
    }

    func test_conversationEnded_tearsDownAndRemovesEveryViewOfThatPane() async throws {
        let surfaceID = UUID()
        let (store, runtime) = makeCoupled()
        let first = try await startLiveView(store, surfaceID: surfaceID)
        let session = FakeMCPAppServerSession(readResourceResult: .failure(FakeSessionError(message: "unreadable")))
        let unmountedCard = try invocation(serverID: session.serverID, surfaceID: surfaceID)
        await startAndLoad(store, unmountedCard, session: session)
        let second = try await startLiveView(store, surfaceID: surfaceID)
        XCTAssertEqual(store.snapshots(forSurface: surfaceID).map(\.viewID), [first, unmountedCard.id.rawValue, second],
                       "precondition: two live views and a card without a web view")

        postConversationEnded(surfaceID)

        try await waitUntil("the pane's views are removed") { !store.hasActiveView(forSurface: surfaceID) }
        XCTAssertEqual(runtime.teardownRequestedViewIDs, [first, second], "each mounted view gets ui/resource-teardown")
        XCTAssertEqual(runtime.unmountedViewIDs, [first, second])
        XCTAssertNil(store.snapshot(viewID: unmountedCard.id.rawValue))
    }

    func test_conversationEnded_leavesOtherPanesAndStandaloneViewsUntouched() async throws {
        let surfaceID = UUID()
        let otherSurfaceID = UUID()
        let (store, runtime) = makeCoupled()
        let ended = try await startLiveView(store, surfaceID: surfaceID)
        let other = try await startLiveView(store, surfaceID: otherSurfaceID)
        let standalone = try await startLiveView(store, surfaceID: nil)

        postConversationEnded(surfaceID)

        try await waitUntil("the ended pane's view is removed") { store.snapshot(viewID: ended) == nil }
        XCTAssertEqual(store.snapshot(viewID: other)?.status, .live)
        XCTAssertEqual(store.snapshot(viewID: standalone)?.status, .live)
        XCTAssertEqual(runtime.teardownRequestedViewIDs, [ended])
        XCTAssertEqual(runtime.unmountedViewIDs, [ended])
    }

    func test_conversationEnded_unregistersTheViewsAppTools() async throws {
        let surfaceID = UUID()
        let appToolRegistry = FakeAppToolRegistry()
        let (store, _) = makeCoupled(appToolRegistry: appToolRegistry)
        let viewID = try await startLiveView(store, surfaceID: surfaceID)
        store.registerAppTools([try MCPToolDefinition(raw: ["name": AnyCodable("pick")])], viewID: viewID)
        XCTAssertFalse(appToolRegistry.appTools(forSurface: surfaceID).isEmpty, "precondition: the pane's agent sees the tool")

        postConversationEnded(surfaceID)

        try await waitUntil("the view is removed") { store.snapshot(viewID: viewID) == nil }
        XCTAssertTrue(appToolRegistry.appTools(forSurface: surfaceID).isEmpty)
    }

    func test_callAppTool_awaitingAViewThatIsClosed_returnsIsError() async throws {
        let surfaceID = UUID()
        let (store, runtime) = makeCoupled()
        let viewID = try await startLiveView(store, surfaceID: surfaceID)
        store.registerAppTools([try MCPToolDefinition(raw: ["name": AnyCodable("record_event")])], viewID: viewID)

        let box = Box<MCPCallToolResult>()
        Task { @MainActor in
            box.value = await store.callAppTool(surfaceID: surfaceID, viewID: viewID, name: "record_event", arguments: [:])
        }
        try await waitUntil("the tools/call request reaches the view") { runtime.pendingRequestCount == 1 }
        await store.close(viewID: viewID)

        try await waitUntil("the pending call returns once the view is closed") { box.value != nil }
        XCTAssertEqual(box.value?.raw["isError"]?.boolValue, true)
    }

    // Finding 2: an app tool call goes to exactly the view the catalog named.

    func test_callAppTool_toAViewThatNoLongerExists_isError_evenWhenAnotherViewOffersTheName() async throws {
        let surfaceID = UUID()
        let (store, runtime) = makeCoupled()
        let closed = try await startLiveView(store, surfaceID: surfaceID)
        store.registerAppTools([try MCPToolDefinition(raw: ["name": AnyCodable("pick")])], viewID: closed)
        let other = try await startLiveView(store, surfaceID: surfaceID)
        store.registerAppTools([try MCPToolDefinition(raw: ["name": AnyCodable("pick")])], viewID: other)
        await store.close(viewID: closed)

        let result = try await callAppTool(store, surfaceID: surfaceID, viewID: closed, name: "pick")

        XCTAssertEqual(result.raw["isError"]?.boolValue, true)
        XCTAssertFalse(methods(sentTo: other, by: runtime).contains("tools/call"), "the call is not rerouted to another view")
    }

    func test_callAppTool_twoViewsInOnePaneWithTheSameToolName_routeSeparately() async throws {
        let surfaceID = UUID()
        let (store, runtime) = makeCoupled()
        let viewA = try await startLiveView(store, surfaceID: surfaceID)
        let viewB = try await startLiveView(store, surfaceID: surfaceID)
        for viewID in [viewA, viewB] {
            store.registerAppTools([try MCPToolDefinition(raw: ["name": AnyCodable("pick")])], viewID: viewID)
        }

        Task { @MainActor in _ = await store.callAppTool(surfaceID: surfaceID, viewID: viewA, name: "pick", arguments: [:]) }
        try await waitUntil("the call reaches view A") { self.methods(sentTo: viewA, by: runtime).contains("tools/call") }
        Task { @MainActor in _ = await store.callAppTool(surfaceID: surfaceID, viewID: viewB, name: "pick", arguments: [:]) }
        try await waitUntil("the call reaches view B") { self.methods(sentTo: viewB, by: runtime).contains("tools/call") }

        XCTAssertEqual(methods(sentTo: viewA, by: runtime).filter { $0 == "tools/call" }.count, 1)
        XCTAssertEqual(methods(sentTo: viewB, by: runtime).filter { $0 == "tools/call" }.count, 1)
        await store.close(viewID: viewA)
        await store.close(viewID: viewB)
    }

    func test_callAppTool_withASurfaceTheViewIsNotIn_isError() async throws {
        let surfaceID = UUID()
        let (store, runtime) = makeCoupled()
        let viewID = try await startLiveView(store, surfaceID: surfaceID)
        store.registerAppTools([try MCPToolDefinition(raw: ["name": AnyCodable("pick")])], viewID: viewID)

        let result = try await callAppTool(store, surfaceID: UUID(), viewID: viewID, name: "pick")

        XCTAssertEqual(result.raw["isError"]?.boolValue, true)
        XCTAssertFalse(methods(sentTo: viewID, by: runtime).contains("tools/call"))
    }

    // Finding 5: the phase never moves back.

    func test_viewDidLoadDocument_afterLive_keepsTheViewLive() async throws {
        let surfaceID = UUID()
        let (store, _) = makeCoupled()
        let viewID = try await startLiveView(store, surfaceID: surfaceID)

        store.viewDidLoadDocument(viewID: viewID)

        XCTAssertEqual(store.snapshot(viewID: viewID)?.status, .live)
    }

    func test_secondInitialized_isIgnored() async throws {
        let surfaceID = UUID()
        let (store, runtime) = makeCoupled()
        let viewID = try await startLiveView(store, surfaceID: surfaceID)
        await store.uiToolInvocationDidFinish(MCPInvocationID(rawValue: viewID), result: MCPCallToolResult(raw: [:]))
        try await waitUntil("tool-result reaches the view") {
            self.methods(sentTo: viewID, by: runtime).contains("ui/notifications/tool-result")
        }

        store.viewDidInitialize(viewID: viewID)

        XCTAssertEqual(store.snapshot(viewID: viewID)?.status, .completed, "a second initialized does not move a completed view back to live")
        XCTAssertEqual(methods(sentTo: viewID, by: runtime).filter { $0 == "ui/notifications/tool-input" }.count, 1)
    }

    func test_initializedAfterReload_isHandledAgain() async throws {
        let surfaceID = UUID()
        let (store, runtime) = makeCoupled()
        let viewID = try await startLiveView(store, surfaceID: surfaceID)
        try await waitUntil("tool-input reaches the view") {
            self.methods(sentTo: viewID, by: runtime).contains("ui/notifications/tool-input")
        }
        store.viewProcessDidTerminate(viewID: viewID)

        await store.reload(viewID: viewID)
        store.viewDidLoadDocument(viewID: viewID)
        XCTAssertEqual(store.snapshot(viewID: viewID)?.status, .waitingForApp, "a reload starts the phases again")
        store.viewDidInitialize(viewID: viewID)

        XCTAssertEqual(store.snapshot(viewID: viewID)?.status, .live)
        try await waitUntil("the reloaded view gets tool-input again") {
            self.methods(sentTo: viewID, by: runtime).filter { $0 == "ui/notifications/tool-input" }.count == 2
        }
    }

    // Finding 6: the upstream call does not wait for the view's resource.

    func test_uiToolInvocationDidStart_returnsBeforeTheResourceReadCompletes() async throws {
        let surfaceID = UUID()
        let (store, runtime) = makeCoupled()
        let session = BlockingReadSession(result: validReadResourceResult())
        let inv = try invocation(serverID: session.serverID, surfaceID: surfaceID)
        defer { session.release() }

        let returned = Box<Bool>()
        Task { @MainActor in
            await store.uiToolInvocationDidStart(inv, session: session)
            returned.value = true
        }
        try await waitUntil("uiToolInvocationDidStart returns while resources/read is blocked") { returned.value == true }

        XCTAssertEqual(store.snapshot(viewID: inv.id.rawValue)?.status, .loadingResource, "the view is registered at once")
        session.release()
        await store.resourceLoad(forView: inv.id.rawValue)?.value
        XCTAssertEqual(runtime.mounted, [inv.id.rawValue], "the load finishes in the store's own task")
    }

    // Finding 12: a view's tool set is replaced, not merged.

    func test_registerAppTools_replacesTheViewsPreviousTools() async throws {
        let surfaceID = UUID()
        let appToolRegistry = FakeAppToolRegistry()
        let (store, runtime) = makeCoupled(appToolRegistry: appToolRegistry)
        let viewID = try await startLiveView(store, surfaceID: surfaceID)

        store.registerAppTools([try MCPToolDefinition(raw: ["name": AnyCodable("a")]), try MCPToolDefinition(raw: ["name": AnyCodable("b")])], viewID: viewID)
        store.registerAppTools([try MCPToolDefinition(raw: ["name": AnyCodable("b")])], viewID: viewID)

        XCTAssertEqual(appToolRegistry.registerCalls.last?.tools, ["b"], "the registry gets only the view's current tools")
        let result = try await callAppTool(store, surfaceID: surfaceID, viewID: viewID, name: "a")
        XCTAssertEqual(result.raw["isError"]?.boolValue, true, "a tool the view no longer lists is not callable")
        XCTAssertFalse(methods(sentTo: viewID, by: runtime).contains("tools/call"))
    }
}
