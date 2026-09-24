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
        await store.uiToolInvocationDidStart(inv, session: session)

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
        await store.uiToolInvocationDidStart(inv, session: session)

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
        await store.uiToolInvocationDidStart(inv, session: session)
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
        await store.uiToolInvocationDidStart(inv, session: session)
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
        await store.uiToolInvocationDidStart(inv, session: session)
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
        await store.uiToolInvocationDidStart(inv, session: session)
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
        await store.uiToolInvocationDidStart(inv, session: session)
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
        await store.uiToolInvocationDidStart(inv, session: session)
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

        await store.uiToolInvocationDidStart(inv, session: session)

        let snapshot = try XCTUnwrap(store.standaloneSnapshots().first)
        XCTAssertEqual(snapshot.title, "dashboard · Weather · Claude Code")
    }

    func test_standalonePanel_title_toolServerOnly_whenClientNameNil() async throws {
        let store = makeStore()
        let session = FakeMCPAppServerSession(readResourceResult: .success(validReadResourceResult()))
        let inv = try invocation(serverID: session.serverID, surfaceID: nil, toolName: "dashboard", serverDisplayName: "Weather", clientName: nil)

        await store.uiToolInvocationDidStart(inv, session: session)

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
        await store.uiToolInvocationDidStart(inv, session: session)
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
        await store.uiToolInvocationDidStart(inv, session: session)

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
        await store.uiToolInvocationDidStart(inv, session: session)
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
        await store.uiToolInvocationDidStart(inv, session: session)
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
        await store.uiToolInvocationDidStart(inv, session: session)
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
        await store.uiToolInvocationDidStart(inv, session: session)
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
        await store.uiToolInvocationDidStart(inv, session: session)
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
        await store.uiToolInvocationDidStart(inv, session: session)

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
        await store.uiToolInvocationDidStart(inv, session: session)

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
        await store.uiToolInvocationDidStart(invA, session: sessionA)
        await store.uiToolInvocationDidStart(invB, session: sessionB)

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
        await store.uiToolInvocationDidStart(inv, session: session)
        let viewID = try XCTUnwrap(store.snapshots(forSurface: surfaceID).first?.viewID)
        store.viewDidLoadDocument(viewID: viewID)
        store.viewDidInitialize(viewID: viewID)
        store.registerAppTools([try MCPToolDefinition(raw: ["name": AnyCodable("record_event")])], viewID: viewID)

        let result = await store.callAppTool(surfaceID: surfaceID, name: "record_event", arguments: ["text": AnyCodable("hi")])

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

        let result = await store.callAppTool(surfaceID: surfaceID, name: "record_event", arguments: [:])

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
        await store.uiToolInvocationDidStart(inv, session: session)

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
        await store.uiToolInvocationDidStart(inv, session: session)

        let snapshot = try XCTUnwrap(store.snapshots(forSurface: surfaceID).first)
        if case .readFailed = snapshot.status {
            XCTFail("a failed metadata fallback must not fail a view whose resources/read succeeded")
        }
        XCTAssertEqual(runtime.mountedViewIDs, [inv.id.rawValue], "the view mounts with the undeclared defaults")
    }
}
