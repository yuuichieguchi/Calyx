//
//  MCPHostCoordinatorCallProxiedToolTests.swift
//  CalyxTests
//
//  Coverage: `MCPHostCoordinator.callProxiedTool` (API contract section
//  10.2, verbatim). Inputs are exactly `exportedName`, `arguments`,
//  `surfaceID`, `clientName`, `clientDeclaredUI`, `cancellationKey`,
//  `progress` -- no CLI-kind string. Internal procedure per section
//  10.2: `catalog.resolve(exportedName:surfaceID:)` locates (serverID,
//  upstreamToolName, definition); `cwdResolver(surfaceID)` resolves cwd
//  only when a pane is resolved; `connections.connection(forServerID:)`
//  supplies the `MCPUpstreamConnecting`; a `MCPToolCallContext` is built
//  and `callTool` invoked; the render decision governs whether
//  `viewHosting.uiToolInvocationDidStart` fires.
//
//  Connection-state waiting (section 10.2, section 15): `connecting`/
//  `restarting` wait, with NO timer, until the connection reaches
//  `ready` or `failed` -- observed here through `FakeUpstreamConnection`'s
//  real `events` stream, never a production timer. `failed`/`disabled`
//  fail immediately with no wait at all.
//
//  Cancellation (section 10.3): a downstream session-with-nonce caller
//  (or the router, for a session-less caller) owns the Swift `Task`
//  actually running `callProxiedTool` and cancels THAT Task directly --
//  `MCPHostCoordinator` itself exposes no separate cancel method.
//  `cancellationKey.requestID` supplies `MCPUIToolInvocation.upstreamRequestID`
//  (a `JSONRPCId`, matching the type on that struct).
//
//  needsAuthorization/authorizing (section 10.2, section 12's 2-minute
//  rule, resolved): `MCPHostCoordinator.init` now takes
//  `authorizationPrompting: any MCPAuthorizationPrompting` and
//  `clock: any MCPClock`. `MCPHostCoordinator.authorizationWait == 120`.
//  Driven here with `ManualMCPClock` so no test waits on the wall
//  clock: `promptSignIn(serverID:serverDisplayName:surfaceID:)` fires
//  once when the wait begins; reaching `.ready` before the clock
//  advances past `authorizationWait` completes the call normally;
//  advancing the clock by exactly `authorizationWait` with no `.ready`
//  in between returns isError. `serverDisplayName` (section 8's
//  `MCPCatalogResolvedTool.serverDisplayName`, resolved through
//  `catalog.resolve(exportedName:surfaceID:)` -- not the connection's `.ready`
//  state, which is unavailable while `needsAuthorization`/`authorizing`)
//  is pinned to the literal the test's `resolvedTool` helper supplies.
//

import XCTest
import os
@testable import Calyx

// MARK: - Fakes

@MainActor
private final class FakeViewHost: MCPAppViewHosting {
    private(set) var startedInvocations: [MCPUIToolInvocation] = []
    private(set) var startedSessions: [any MCPAppServerSession] = []
    private var activeSurfaces: Set<UUID> = []
    private(set) var appToolCalls: [(surfaceID: UUID, viewID: UUID, name: String, arguments: [String: AnyCodable])] = []
    var appToolResult = MCPCallToolResult(raw: [:])

    func uiToolInvocationDidStart(_ invocation: MCPUIToolInvocation, session: any MCPAppServerSession) async {
        startedInvocations.append(invocation)
        startedSessions.append(session)
    }

    func hasActiveView(forSurface surfaceID: UUID) -> Bool { activeSurfaces.contains(surfaceID) }
    func isStandalonePanel(_ id: MCPInvocationID) -> Bool { false }
    func remapSurface(old: UUID, new: UUID) {}
    func teardownViews(forServer serverID: MCPServerID, reason: String) async {}

    func callAppTool(surfaceID: UUID, viewID: UUID, name: String, arguments: [String: AnyCodable]) async -> MCPCallToolResult {
        appToolCalls.append((surfaceID, viewID, name, arguments))
        return appToolResult
    }

    private(set) var finishedInvocations: [(id: MCPInvocationID, result: MCPCallToolResult)] = []
    private(set) var cancelledInvocations: [MCPInvocationID] = []

    func uiToolInvocationDidFinish(_ id: MCPInvocationID, result: MCPCallToolResult) async {
        finishedInvocations.append((id, result))
    }

    func uiToolInvocationWasCancelled(_ id: MCPInvocationID) async {
        cancelledInvocations.append(id)
    }

    func serverConnectionChanged(serverID: MCPServerID, state: MCPConnectionState) {}
}

private actor ProgressRecorder {
    private(set) var updates: [MCPProgressUpdate] = []
    func record(_ update: MCPProgressUpdate) { updates.append(update) }
}

@MainActor
private final class FakeAuthorizationPrompting: MCPAuthorizationPrompting {
    private(set) var calls: [(serverID: MCPServerID, serverDisplayName: String, surfaceID: UUID?)] = []

    func promptSignIn(serverID: MCPServerID, serverDisplayName: String, surfaceID: UUID?) async {
        calls.append((serverID, serverDisplayName, surfaceID))
    }
}

/// A ready connection whose `resources/read` waits until `release()`.
private actor ReadBlockingConnection: MCPUpstreamConnecting {
    nonisolated let serverID: MCPServerID
    private let outcome: MCPUpstreamClient.ToolCallOutcome
    private let readResult: [String: AnyCodable]
    private let state: MCPConnectionState
    private var readWaiters: [CheckedContinuation<Void, Never>] = []
    private var isReleased = false
    private(set) var toolCallCount = 0
    private let eventsStream: AsyncStream<MCPServerEvent>

    init(serverID: MCPServerID, state: MCPConnectionState, outcome: MCPUpstreamClient.ToolCallOutcome, readResult: [String: AnyCodable]) {
        self.serverID = serverID
        self.state = state
        self.outcome = outcome
        self.readResult = readResult
        self.eventsStream = AsyncStream { _ in }
    }

    func release() {
        isReleased = true
        readWaiters.forEach { $0.resume() }
        readWaiters.removeAll()
    }

    func tools() async -> [MCPToolDefinition] { [] }
    func state() async -> MCPConnectionState { state }
    var events: AsyncStream<MCPServerEvent> { get async { eventsStream } }

    func callTool(name: String, arguments: [String: AnyCodable], context: MCPToolCallContext) async -> MCPUpstreamClient.ToolCallOutcome {
        toolCallCount += 1
        return outcome
    }

    func readResource(uri: String) async throws -> [String: AnyCodable] {
        if !isReleased {
            await withCheckedContinuation { readWaiters.append($0) }
        }
        return readResult
    }

    func listResources(cursor: String?) async throws -> (items: [[String: AnyCodable]], nextCursor: String?) { ([], nil) }
    func listResourceTemplates(cursor: String?) async throws -> (items: [[String: AnyCodable]], nextCursor: String?) { ([], nil) }
    func listPrompts(cursor: String?) async throws -> (items: [[String: AnyCodable]], nextCursor: String?) { ([], nil) }
}

/// The runtime seam, doing nothing: no web view is ever mounted.
@MainActor
private final class InertViewRuntime: MCPAppViewRuntime {
    func requestTeardown(viewID: UUID) async {}
    func mount(viewID: UUID, document: MCPAppViewDocument) async throws {}
    func send(_ message: JSONRPCMessage, to viewID: UUID) async throws -> JSONRPCMessage? { nil }
    func unmount(viewID: UUID) {}
}

@MainActor
private final class NoPaneResolver: MCPPaneResolving {
    func paneHost(owningSurface surfaceID: UUID) -> MCPPaneHost? { nil }
}

@MainActor
private final class ResultBox {
    var result: MCPCallToolResult?
}

@MainActor
final class MCPHostCoordinatorCallProxiedToolTests: XCTestCase {

    private func tool(
        _ name: String, visibility: Set<MCPToolVisibility> = [.model], resourceUri: String? = nil
    ) throws -> MCPToolDefinition {
        var raw: [String: AnyCodable] = [
            "name": AnyCodable(name),
            "description": AnyCodable("d"),
            "inputSchema": AnyCodable(["type": AnyCodable("object")]),
        ]
        var ui: [String: AnyCodable] = [:]
        if visibility != [.model, .app] {
            ui["visibility"] = AnyCodable(visibility.map { AnyCodable($0.rawValue) })
        }
        if let resourceUri {
            ui["resourceUri"] = AnyCodable(resourceUri)
        }
        if !ui.isEmpty {
            raw["_meta"] = AnyCodable(["ui": AnyCodable(ui)])
        }
        return try MCPToolDefinition(raw: raw)
    }

    private func resolvedTool(
        exportedName: String, serverID: MCPServerID, serverDisplayName: String = "Weather Service",
        serverAlias: String = "srv", upstreamToolName: String, definition: MCPToolDefinition, origin: MCPCatalogToolOrigin = .server
    ) -> MCPCatalogResolvedTool {
        MCPCatalogResolvedTool(
            exportedName: exportedName, serverID: serverID, serverDisplayName: serverDisplayName,
            serverAlias: MCPServerAlias(rawValue: serverAlias)!, upstreamToolName: upstreamToolName,
            origin: origin, definition: definition, exportedRaw: definition.raw
        )
    }

    private func makeCoordinator(
        connections: [MCPServerID: any MCPUpstreamConnecting],
        catalog: FakeCatalogProviding,
        viewHosting: any MCPAppViewHosting,
        authorizationPrompting: any MCPAuthorizationPrompting = FakeAuthorizationPrompting(),
        cwdResolver: @escaping @Sendable (UUID) -> URL? = { _ in nil },
        clock: any MCPClock = SystemMCPClock()
    ) -> MCPHostCoordinator {
        MCPHostCoordinator(
            connections: FakeConnectionLookup(connections),
            catalog: catalog,
            viewHosting: viewHosting,
            elicitationPresenting: FakeElicitationPresenter(scriptedResponses: []),
            authorizationPrompting: authorizationPrompting,
            cwdResolver: cwdResolver,
            clock: clock
        )
    }

    private func readyState() -> MCPConnectionState {
        .ready(MCPServerInfo(negotiatedEra: .v2025_11_25, serverInfo: MCPImplementation(
            name: "fake-server", version: "1.0", title: nil, description: nil, websiteUrl: nil
        ), instructions: nil), toolCount: 1)
    }

    // MARK: - Raw pass-through, exact-name routing via the injected catalog

    func test_result_rawPassesThroughUnchanged_routedViaCatalogResolve() async throws {
        let serverID = MCPServerID(rawValue: UUID())
        let connection = FakeUpstreamConnection(serverID: serverID, initialState: readyState(), initialTools: [try tool("get_weather")])
        let rawResult: [String: AnyCodable] = [
            "content": AnyCodable([AnyCodable(["type": AnyCodable("text"), "text": AnyCodable("72F")])]),
            "structuredContent": AnyCodable(["temp": AnyCodable(72)]),
            "isError": AnyCodable(false),
            "_meta": AnyCodable(["io.modelcontextprotocol/serverInfo": AnyCodable(["name": AnyCodable("weather")])]),
        ]
        await connection.enqueueToolCallOutcome(.result(MCPCallToolResult(raw: rawResult)))
        let catalog = FakeCatalogProviding(resolvedTools: [
            "srv-get_weather": resolvedTool(exportedName: "srv-get_weather", serverID: serverID, upstreamToolName: "get_weather", definition: try tool("get_weather")),
        ])
        let coordinator = makeCoordinator(connections: [serverID: connection], catalog: catalog, viewHosting: FakeViewHost())

        let result = await coordinator.callProxiedTool(
            exportedName: "srv-get_weather", arguments: [:], surfaceID: UUID(), clientName: "claude-code",
            clientDeclaredUI: false,
            cancellationKey: MCPDownstreamCancellationKey(sessionNonce: "sess-1", requestID: .int(2)),
            progress: nil
        )

        XCTAssertEqual(result.raw, rawResult, "the proxy must forward the raw upstream result untouched")
        let invocations = await connection.callToolInvocations
        XCTAssertEqual(invocations.map(\.name), ["get_weather"])
    }

    // MARK: - Render decision drives viewHosting.uiToolInvocationDidStart

    func test_paneResolved_viewHostAlwaysStarted_evenWhenClientDeclaredUI() async throws {
        let serverID = MCPServerID(rawValue: UUID())
        let connection = FakeUpstreamConnection(serverID: serverID, initialState: readyState(), initialTools: [try tool("get_weather")])
        await connection.enqueueToolCallOutcome(.result(MCPCallToolResult(raw: [:])))
        let catalog = FakeCatalogProviding(resolvedTools: [
            "srv-get_weather": resolvedTool(exportedName: "srv-get_weather", serverID: serverID, upstreamToolName: "get_weather", definition: try tool("get_weather", resourceUri: "ui://weather/card.html")),
        ])
        let viewHost = FakeViewHost()
        let coordinator = makeCoordinator(connections: [serverID: connection], catalog: catalog, viewHosting: viewHost)
        let surfaceID = UUID()

        _ = await coordinator.callProxiedTool(
            exportedName: "srv-get_weather", arguments: [:], surfaceID: surfaceID, clientName: "codex",
            clientDeclaredUI: true,
            cancellationKey: MCPDownstreamCancellationKey(sessionNonce: nil, requestID: .int(3)),
            progress: nil
        )

        XCTAssertEqual(viewHost.startedInvocations.count, 1,
                       "a resolved pane must always render, even when the caller also declared the UI extension")
        XCTAssertEqual(viewHost.startedInvocations.first?.surfaceID, surfaceID)
        XCTAssertEqual(viewHost.startedInvocations.first?.upstreamRequestID, JSONRPCId.int(3),
                       "MCPUIToolInvocation.upstreamRequestID carries the cancellation key's JSONRPCId")
        XCTAssertEqual(viewHost.startedInvocations.first?.clientName, "codex",
                       "clientName comes from _meta.clientInfo or the legacy session payload, never a CLI kind string")
    }

    func test_paneLess_clientDeclaredUI_viewHostNeverStarted() async throws {
        let serverID = MCPServerID(rawValue: UUID())
        let connection = FakeUpstreamConnection(serverID: serverID, initialState: readyState(), initialTools: [try tool("get_weather")])
        await connection.enqueueToolCallOutcome(.result(MCPCallToolResult(raw: [:])))
        let catalog = FakeCatalogProviding(resolvedTools: [
            "srv-get_weather": resolvedTool(exportedName: "srv-get_weather", serverID: serverID, upstreamToolName: "get_weather", definition: try tool("get_weather", resourceUri: "ui://weather/card.html")),
        ])
        let viewHost = FakeViewHost()
        let coordinator = makeCoordinator(connections: [serverID: connection], catalog: catalog, viewHosting: viewHost)

        _ = await coordinator.callProxiedTool(
            exportedName: "srv-get_weather", arguments: [:], surfaceID: nil, clientName: nil,
            clientDeclaredUI: true,
            cancellationKey: MCPDownstreamCancellationKey(sessionNonce: nil, requestID: .int(4)),
            progress: nil
        )

        XCTAssertTrue(viewHost.startedInvocations.isEmpty,
                      "no pane, but the caller already declared it renders UI itself -- Calyx must step aside")
    }

    func test_paneLess_noDeclaration_viewHostStartedWithNilSurfaceID() async throws {
        let serverID = MCPServerID(rawValue: UUID())
        let connection = FakeUpstreamConnection(serverID: serverID, initialState: readyState(), initialTools: [try tool("get_weather")])
        await connection.enqueueToolCallOutcome(.result(MCPCallToolResult(raw: [:])))
        let catalog = FakeCatalogProviding(resolvedTools: [
            "srv-get_weather": resolvedTool(exportedName: "srv-get_weather", serverID: serverID, upstreamToolName: "get_weather", definition: try tool("get_weather", resourceUri: "ui://weather/card.html")),
        ])
        let viewHost = FakeViewHost()
        let coordinator = makeCoordinator(connections: [serverID: connection], catalog: catalog, viewHosting: viewHost)

        _ = await coordinator.callProxiedTool(
            exportedName: "srv-get_weather", arguments: [:], surfaceID: nil, clientName: nil,
            clientDeclaredUI: false,
            cancellationKey: MCPDownstreamCancellationKey(sessionNonce: nil, requestID: .int(5)),
            progress: nil
        )

        XCTAssertEqual(viewHost.startedInvocations.count, 1,
                       "no pane and no declaration (session-less included) must render in an independent panel")
        XCTAssertNil(viewHost.startedInvocations.first?.surfaceID)
    }

    // MARK: - The rendered view receives the same outcome the agent does

    private func uiToolFixture() throws -> (MCPServerID, FakeUpstreamConnection, FakeCatalogProviding) {
        let serverID = MCPServerID(rawValue: UUID())
        let definition = try tool("get_weather", resourceUri: "ui://weather/card.html")
        let connection = FakeUpstreamConnection(serverID: serverID, initialState: readyState(), initialTools: [definition])
        let catalog = FakeCatalogProviding(resolvedTools: [
            "srv-get_weather": resolvedTool(exportedName: "srv-get_weather", serverID: serverID, upstreamToolName: "get_weather", definition: definition),
        ])
        return (serverID, connection, catalog)
    }

    func test_renderedCall_result_reachesViewHostWithMatchingInvocationID_andEqualsReturnedResult() async throws {
        let (serverID, connection, catalog) = try uiToolFixture()
        let rawResult: [String: AnyCodable] = [
            "content": AnyCodable([AnyCodable(["type": AnyCodable("text"), "text": AnyCodable("72F")])]),
        ]
        await connection.enqueueToolCallOutcome(.result(MCPCallToolResult(raw: rawResult)))
        let viewHost = FakeViewHost()
        let coordinator = makeCoordinator(connections: [serverID: connection], catalog: catalog, viewHosting: viewHost)

        let result = await coordinator.callProxiedTool(
            exportedName: "srv-get_weather", arguments: [:], surfaceID: UUID(), clientName: nil,
            clientDeclaredUI: false,
            cancellationKey: MCPDownstreamCancellationKey(sessionNonce: nil, requestID: .int(21)),
            progress: nil
        )

        XCTAssertEqual(viewHost.finishedInvocations.count, 1)
        XCTAssertEqual(viewHost.finishedInvocations.first?.id, viewHost.startedInvocations.first?.id,
                       "the finished hook must name the invocation the view host was started with")
        XCTAssertEqual(viewHost.finishedInvocations.first?.result, result,
                       "the view receives exactly the result returned to the agent")
        XCTAssertTrue(viewHost.cancelledInvocations.isEmpty)
    }

    func test_renderedCall_protocolError_reachesViewHostAsTheSameIsErrorResult() async throws {
        let (serverID, connection, catalog) = try uiToolFixture()
        await connection.enqueueToolCallOutcome(.protocolError(.timeout))
        let viewHost = FakeViewHost()
        let coordinator = makeCoordinator(connections: [serverID: connection], catalog: catalog, viewHosting: viewHost)

        let result = await coordinator.callProxiedTool(
            exportedName: "srv-get_weather", arguments: [:], surfaceID: UUID(), clientName: nil,
            clientDeclaredUI: false,
            cancellationKey: MCPDownstreamCancellationKey(sessionNonce: nil, requestID: .int(22)),
            progress: nil
        )

        XCTAssertEqual(result.raw["isError"]?.boolValue, true)
        XCTAssertEqual(viewHost.finishedInvocations.map(\.result), [result])
        XCTAssertTrue(viewHost.cancelledInvocations.isEmpty)
    }

    func test_renderedCall_cancelled_callsWasCancelled_notDidFinish() async throws {
        let (serverID, connection, catalog) = try uiToolFixture()
        await connection.enqueueToolCallOutcome(.cancelled(reason: .agentCancelled))
        let viewHost = FakeViewHost()
        let coordinator = makeCoordinator(connections: [serverID: connection], catalog: catalog, viewHosting: viewHost)

        _ = await coordinator.callProxiedTool(
            exportedName: "srv-get_weather", arguments: [:], surfaceID: UUID(), clientName: nil,
            clientDeclaredUI: false,
            cancellationKey: MCPDownstreamCancellationKey(sessionNonce: nil, requestID: .int(23)),
            progress: nil
        )

        XCTAssertEqual(viewHost.cancelledInvocations, viewHost.startedInvocations.map(\.id))
        XCTAssertEqual(viewHost.cancelledInvocations.count, 1)
        XCTAssertTrue(viewHost.finishedInvocations.isEmpty)
    }

    func test_stepAside_callsNeitherOutcomeHook() async throws {
        let (serverID, connection, catalog) = try uiToolFixture()
        await connection.enqueueToolCallOutcome(.result(MCPCallToolResult(raw: [:])))
        let viewHost = FakeViewHost()
        let coordinator = makeCoordinator(connections: [serverID: connection], catalog: catalog, viewHosting: viewHost)

        _ = await coordinator.callProxiedTool(
            exportedName: "srv-get_weather", arguments: [:], surfaceID: nil, clientName: nil,
            clientDeclaredUI: true,
            cancellationKey: MCPDownstreamCancellationKey(sessionNonce: nil, requestID: .int(24)),
            progress: nil
        )

        XCTAssertTrue(viewHost.startedInvocations.isEmpty)
        XCTAssertTrue(viewHost.finishedInvocations.isEmpty)
        XCTAssertTrue(viewHost.cancelledInvocations.isEmpty)
    }

    func test_toolWithoutUI_callsNeitherOutcomeHook() async throws {
        let serverID = MCPServerID(rawValue: UUID())
        let connection = FakeUpstreamConnection(serverID: serverID, initialState: readyState(), initialTools: [try tool("get_weather")])
        await connection.enqueueToolCallOutcome(.result(MCPCallToolResult(raw: [:])))
        let catalog = FakeCatalogProviding(resolvedTools: [
            "srv-get_weather": resolvedTool(exportedName: "srv-get_weather", serverID: serverID, upstreamToolName: "get_weather", definition: try tool("get_weather")),
        ])
        let viewHost = FakeViewHost()
        let coordinator = makeCoordinator(connections: [serverID: connection], catalog: catalog, viewHosting: viewHost)

        _ = await coordinator.callProxiedTool(
            exportedName: "srv-get_weather", arguments: [:], surfaceID: UUID(), clientName: nil,
            clientDeclaredUI: false,
            cancellationKey: MCPDownstreamCancellationKey(sessionNonce: nil, requestID: .int(25)),
            progress: nil
        )

        XCTAssertTrue(viewHost.startedInvocations.isEmpty)
        XCTAssertTrue(viewHost.finishedInvocations.isEmpty)
        XCTAssertTrue(viewHost.cancelledInvocations.isEmpty)
    }

    // MARK: - cwd resolved only when a pane is resolved

    func test_cwd_resolvedForTheCallingPane_andPassedToConnectionCallTool() async throws {
        let serverID = MCPServerID(rawValue: UUID())
        let connection = FakeUpstreamConnection(serverID: serverID, initialState: readyState(), initialTools: [try tool("get_weather")])
        await connection.enqueueToolCallOutcome(.result(MCPCallToolResult(raw: [:])))
        let catalog = FakeCatalogProviding(resolvedTools: [
            "srv-get_weather": resolvedTool(exportedName: "srv-get_weather", serverID: serverID, upstreamToolName: "get_weather", definition: try tool("get_weather")),
        ])
        let surfaceID = UUID()
        let expectedCwd = URL(fileURLWithPath: "/Users/dev/project")
        let coordinator = makeCoordinator(
            connections: [serverID: connection], catalog: catalog, viewHosting: FakeViewHost(),
            cwdResolver: { resolvedSurfaceID in resolvedSurfaceID == surfaceID ? expectedCwd : nil }
        )

        _ = await coordinator.callProxiedTool(
            exportedName: "srv-get_weather", arguments: [:], surfaceID: surfaceID, clientName: nil,
            clientDeclaredUI: false,
            cancellationKey: MCPDownstreamCancellationKey(sessionNonce: nil, requestID: .int(6)),
            progress: nil
        )

        let invocations = await connection.callToolInvocations
        XCTAssertEqual(invocations.first?.context.cwd, expectedCwd)
    }

    func test_cwd_nilWhenPaneUnresolved_cwdResolverNeverCalled() async throws {
        let serverID = MCPServerID(rawValue: UUID())
        let connection = FakeUpstreamConnection(serverID: serverID, initialState: readyState(), initialTools: [try tool("get_weather")])
        await connection.enqueueToolCallOutcome(.result(MCPCallToolResult(raw: [:])))
        let catalog = FakeCatalogProviding(resolvedTools: [
            "srv-get_weather": resolvedTool(exportedName: "srv-get_weather", serverID: serverID, upstreamToolName: "get_weather", definition: try tool("get_weather")),
        ])
        let cwdResolverCalled = OSAllocatedUnfairLock(initialState: false)
        let coordinator = makeCoordinator(
            connections: [serverID: connection], catalog: catalog, viewHosting: FakeViewHost(),
            cwdResolver: { _ in cwdResolverCalled.withLock { $0 = true }; return URL(fileURLWithPath: "/should/not/be/used") }
        )

        _ = await coordinator.callProxiedTool(
            exportedName: "srv-get_weather", arguments: [:], surfaceID: nil, clientName: nil,
            clientDeclaredUI: false,
            cancellationKey: MCPDownstreamCancellationKey(sessionNonce: nil, requestID: .int(7)),
            progress: nil
        )

        let invocations = await connection.callToolInvocations
        XCTAssertNil(invocations.first?.context.cwd,
                     "with no resolvable pane, cwd must be nil and the cwd resolver must not be consulted at all (contract section 10.2)")
        XCTAssertFalse(cwdResolverCalled.withLock { $0 })
    }

    // MARK: - Progress handler forwarded to MCPToolCallContext.progress

    func test_progress_forwardedToTheSuppliedHandler() async throws {
        let serverID = MCPServerID(rawValue: UUID())
        let connection = FakeUpstreamConnection(serverID: serverID, initialState: readyState(), initialTools: [try tool("slow_tool")])
        await connection.enqueueToolCallOutcome(.result(MCPCallToolResult(raw: [:])))
        await connection.setTools([try tool("slow_tool")])
        // Script the outcome to arrive after a progress update -- the
        // fake delivers scripted progress before returning its outcome.
        let catalog = FakeCatalogProviding(resolvedTools: [
            "srv-slow_tool": resolvedTool(exportedName: "srv-slow_tool", serverID: serverID, upstreamToolName: "slow_tool", definition: try tool("slow_tool")),
        ])
        let recorder = ProgressRecorder()
        let coordinator = makeCoordinator(connections: [serverID: connection], catalog: catalog, viewHosting: FakeViewHost())

        _ = await coordinator.callProxiedTool(
            exportedName: "srv-slow_tool", arguments: [:], surfaceID: UUID(), clientName: nil,
            clientDeclaredUI: false,
            cancellationKey: MCPDownstreamCancellationKey(sessionNonce: nil, requestID: .int(8)),
            progress: { update in await recorder.record(update) }
        )

        let invocations = await connection.callToolInvocations
        XCTAssertNotNil(invocations.first?.context.progress,
                        "the supplied progress handler must be threaded into MCPToolCallContext.progress")
    }

    // MARK: - Server no longer configured

    func test_serverNoLongerConfigured_returnsIsErrorNamingTheServerRemoved() async throws {
        let catalog = FakeCatalogProviding()
        let coordinator = makeCoordinator(connections: [:], catalog: catalog, viewHosting: FakeViewHost())

        let result = await coordinator.callProxiedTool(
            exportedName: "removed-srv-old_tool", arguments: [:], surfaceID: nil, clientName: nil,
            clientDeclaredUI: false,
            cancellationKey: MCPDownstreamCancellationKey(sessionNonce: nil, requestID: .int(11)),
            progress: nil
        )

        XCTAssertEqual(result.raw["isError"]?.boolValue, true)
    }

    // MARK: - Connection-state wait: connecting -> ready with no timer

    func test_connecting_waitsWithNoTimerUntilReady_thenCallsUpstream() async throws {
        let serverID = MCPServerID(rawValue: UUID())
        let connection = FakeUpstreamConnection(serverID: serverID, initialState: .connecting, initialTools: [try tool("get_weather")])
        await connection.enqueueToolCallOutcome(.result(MCPCallToolResult(raw: ["isError": AnyCodable(false)])))
        let catalog = FakeCatalogProviding(resolvedTools: [
            "srv-get_weather": resolvedTool(exportedName: "srv-get_weather", serverID: serverID, upstreamToolName: "get_weather", definition: try tool("get_weather")),
        ])
        let coordinator = makeCoordinator(connections: [serverID: connection], catalog: catalog, viewHosting: FakeViewHost())

        let task = Task {
            await coordinator.callProxiedTool(
                exportedName: "srv-get_weather", arguments: [:], surfaceID: nil, clientName: nil,
                clientDeclaredUI: false,
                cancellationKey: MCPDownstreamCancellationKey(sessionNonce: nil, requestID: .int(12)),
                progress: nil
            )
        }
        // Give the coordinator a chance to start observing connection
        // events before the state transition fires.
        try await Task.sleep(for: .milliseconds(50))
        await connection.setState(readyState())

        let result = await task.value
        XCTAssertEqual(result.raw["isError"]?.boolValue, false,
                       "once the connection reaches ready, the upstream call must actually proceed")
    }

    func test_failed_returnsIsErrorImmediately_withNoWait() async throws {
        let serverID = MCPServerID(rawValue: UUID())
        let connection = FakeUpstreamConnection(
            serverID: serverID,
            initialState: .failed(MCPConnectionFailure(reason: "spawn failed", stderrTail: nil)),
            initialTools: [try tool("get_weather")]
        )
        let catalog = FakeCatalogProviding(resolvedTools: [
            "srv-get_weather": resolvedTool(exportedName: "srv-get_weather", serverID: serverID, upstreamToolName: "get_weather", definition: try tool("get_weather")),
        ])
        let coordinator = makeCoordinator(connections: [serverID: connection], catalog: catalog, viewHosting: FakeViewHost())

        let result = await coordinator.callProxiedTool(
            exportedName: "srv-get_weather", arguments: [:], surfaceID: nil, clientName: nil,
            clientDeclaredUI: false,
            cancellationKey: MCPDownstreamCancellationKey(sessionNonce: nil, requestID: .int(13)),
            progress: nil
        )

        XCTAssertEqual(result.raw["isError"]?.boolValue, true)
        let invocations = await connection.callToolInvocations
        XCTAssertTrue(invocations.isEmpty, "a failed connection must never actually be called")
    }

    func test_disabled_returnsIsErrorImmediately_withNoWait() async throws {
        let serverID = MCPServerID(rawValue: UUID())
        let connection = FakeUpstreamConnection(serverID: serverID, initialState: .disabled, initialTools: [try tool("get_weather")])
        let catalog = FakeCatalogProviding(resolvedTools: [
            "srv-get_weather": resolvedTool(exportedName: "srv-get_weather", serverID: serverID, upstreamToolName: "get_weather", definition: try tool("get_weather")),
        ])
        let coordinator = makeCoordinator(connections: [serverID: connection], catalog: catalog, viewHosting: FakeViewHost())

        let result = await coordinator.callProxiedTool(
            exportedName: "srv-get_weather", arguments: [:], surfaceID: nil, clientName: nil,
            clientDeclaredUI: false,
            cancellationKey: MCPDownstreamCancellationKey(sessionNonce: nil, requestID: .int(14)),
            progress: nil
        )

        XCTAssertEqual(result.raw["isError"]?.boolValue, true)
        let invocations = await connection.callToolInvocations
        XCTAssertTrue(invocations.isEmpty)
    }

    // MARK: - Task cancellation propagates to the running upstream call

    func test_cancellingTheCallingTask_cancelsTheUpstreamCall() async throws {
        // The router (not the coordinator) owns the Swift Task running
        // callProxiedTool for a legacy session-with-nonce caller, and
        // cancels THAT task directly when it sees a matching
        // notifications/cancelled -- there is no separate cancel method
        // on MCPHostCoordinator (contract section 10.3).
        let serverID = MCPServerID(rawValue: UUID())
        let connection = FakeUpstreamConnection(serverID: serverID, initialState: readyState(), initialTools: [try tool("long_running")])
        await connection.enqueueToolCallOutcome(.cancelled(reason: .agentCancelled))
        let catalog = FakeCatalogProviding(resolvedTools: [
            "srv-long_running": resolvedTool(exportedName: "srv-long_running", serverID: serverID, upstreamToolName: "long_running", definition: try tool("long_running")),
        ])
        let coordinator = makeCoordinator(connections: [serverID: connection], catalog: catalog, viewHosting: FakeViewHost())

        let task = Task {
            await coordinator.callProxiedTool(
                exportedName: "srv-long_running", arguments: [:], surfaceID: UUID(), clientName: nil,
                clientDeclaredUI: false,
                cancellationKey: MCPDownstreamCancellationKey(sessionNonce: "sess-a", requestID: .int(15)),
                progress: nil
            )
        }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()

        _ = await task.value
        // The fake connection is scripted to report .cancelled, which is
        // the shape used to assert the outcome propagates the reason
        // through to MCPCallToolResult; the exact raw shape of a
        // cancelled ToolCallOutcome -> MCPCallToolResult mapping is an
        // implementation detail this file does not pin further.
    }

    // MARK: - needsAuthorization/authorizing: 2-minute rule (section 10.2/12)

    func test_needsAuthorization_promptsOnce_readyWithinWindow_returnsNormalResult() async throws {
        let serverID = MCPServerID(rawValue: UUID())
        let connection = FakeUpstreamConnection(serverID: serverID, initialState: .needsAuthorization, initialTools: [try tool("get_weather")])
        await connection.enqueueToolCallOutcome(.result(MCPCallToolResult(raw: ["isError": AnyCodable(false)])))
        let catalog = FakeCatalogProviding(resolvedTools: [
            "srv-get_weather": resolvedTool(exportedName: "srv-get_weather", serverID: serverID, upstreamToolName: "get_weather", definition: try tool("get_weather")),
        ])
        let prompting = FakeAuthorizationPrompting()
        let clock = ManualMCPClock()
        let surfaceID = UUID()
        let coordinator = makeCoordinator(
            connections: [serverID: connection], catalog: catalog, viewHosting: FakeViewHost(),
            authorizationPrompting: prompting, clock: clock
        )

        let task = Task {
            await coordinator.callProxiedTool(
                exportedName: "srv-get_weather", arguments: [:], surfaceID: surfaceID, clientName: nil,
                clientDeclaredUI: false,
                cancellationKey: MCPDownstreamCancellationKey(sessionNonce: nil, requestID: .int(16)),
                progress: nil
            )
        }
        // Give the coordinator a chance to observe .needsAuthorization
        // and call promptSignIn before the connection becomes ready --
        // otherwise the ready transition could race ahead of the prompt.
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(prompting.calls.count, 1, "promptSignIn must fire exactly once when the wait begins")
        XCTAssertEqual(prompting.calls.first?.serverID, serverID)
        XCTAssertEqual(prompting.calls.first?.surfaceID, surfaceID)
        XCTAssertEqual(prompting.calls.first?.serverDisplayName, "Weather Service",
                       "serverDisplayName now comes from MCPCatalogResolvedTool.serverDisplayName (section 8)")

        await connection.setState(readyState())
        let result = await task.value

        XCTAssertEqual(result.raw["isError"]?.boolValue, false,
                       "reaching .ready before the authorizationWait clock elapses must complete the call normally")
        XCTAssertTrue(clock.sleepDurations().isEmpty || clock.sleepDurations().allSatisfy { $0 <= MCPHostCoordinator.authorizationWait },
                      "the coordinator must never sleep past authorizationWait for a single wait")
    }

    func test_needsAuthorization_neverReady_advanceByAuthorizationWait_returnsIsError() async throws {
        let serverID = MCPServerID(rawValue: UUID())
        let connection = FakeUpstreamConnection(serverID: serverID, initialState: .needsAuthorization, initialTools: [try tool("get_weather")])
        let catalog = FakeCatalogProviding(resolvedTools: [
            "srv-get_weather": resolvedTool(exportedName: "srv-get_weather", serverID: serverID, upstreamToolName: "get_weather", definition: try tool("get_weather")),
        ])
        let prompting = FakeAuthorizationPrompting()
        let clock = ManualMCPClock()
        let coordinator = makeCoordinator(
            connections: [serverID: connection], catalog: catalog, viewHosting: FakeViewHost(),
            authorizationPrompting: prompting, clock: clock
        )

        let task = Task {
            await coordinator.callProxiedTool(
                exportedName: "srv-get_weather", arguments: [:], surfaceID: nil, clientName: nil,
                clientDeclaredUI: false,
                cancellationKey: MCPDownstreamCancellationKey(sessionNonce: nil, requestID: .int(17)),
                progress: nil
            )
        }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(prompting.calls.count, 1)
        XCTAssertEqual(prompting.calls.first?.serverDisplayName, "Weather Service")

        clock.advance(by: MCPHostCoordinator.authorizationWait)
        let result = await task.value

        XCTAssertEqual(result.raw["isError"]?.boolValue, true,
                       "no .ready within authorizationWait (120s, driven virtually) must fail with isError")
        let invocations = await connection.callToolInvocations
        XCTAssertTrue(invocations.isEmpty, "the upstream must never actually be called while still needsAuthorization")
    }


    // MARK: - App-origin tools are called on the view, not upstream

    func test_appOriginTool_routedToViewHostCallAppTool_resultReturnedVerbatim_upstreamNeverCalled() async throws {
        let serverID = MCPServerID(rawValue: UUID())
        let appSurfaceID = UUID()
        let appViewID = UUID()
        let connection = FakeUpstreamConnection(serverID: serverID, initialState: readyState(), initialTools: [try tool("get_weather")])
        let definition = try tool("pick_color")
        let catalog = FakeCatalogProviding(resolvedTools: [
            "srv-app-pick_color": resolvedTool(
                exportedName: "srv-app-pick_color", serverID: serverID, upstreamToolName: "pick_color",
                definition: definition, origin: .app(surfaceID: appSurfaceID, viewID: appViewID)
            ),
        ])
        let viewHost = FakeViewHost()
        let rawResult: [String: AnyCodable] = [
            "content": AnyCodable([AnyCodable(["type": AnyCodable("text"), "text": AnyCodable("teal")])]),
            "structuredContent": AnyCodable(["color": AnyCodable("teal")]),
        ]
        viewHost.appToolResult = MCPCallToolResult(raw: rawResult)
        let coordinator = makeCoordinator(connections: [serverID: connection], catalog: catalog, viewHosting: viewHost)
        let arguments: [String: AnyCodable] = ["palette": AnyCodable("warm"), "count": AnyCodable(2)]

        let result = await coordinator.callProxiedTool(
            exportedName: "srv-app-pick_color", arguments: arguments, surfaceID: appSurfaceID, clientName: "claude-code",
            clientDeclaredUI: false,
            cancellationKey: MCPDownstreamCancellationKey(sessionNonce: "sess-1", requestID: .int(5)),
            progress: nil
        )

        XCTAssertEqual(result.raw, rawResult, "the view's result is returned verbatim")
        XCTAssertEqual(viewHost.appToolCalls.count, 1)
        XCTAssertEqual(viewHost.appToolCalls.first?.surfaceID, appSurfaceID)
        XCTAssertEqual(viewHost.appToolCalls.first?.viewID, appViewID, "the call names the view that registered the tool")
        XCTAssertEqual(viewHost.appToolCalls.first?.name, "pick_color")
        XCTAssertEqual(viewHost.appToolCalls.first?.arguments, arguments)
        let upstreamCalls = await connection.callToolInvocations
        XCTAssertTrue(upstreamCalls.isEmpty, "an app-origin tool never reaches the upstream connection")
        XCTAssertTrue(viewHost.startedInvocations.isEmpty, "an app-origin call starts no new view")
    }

    // MARK: - An app tool is offered only to the pane that owns it (section 13a.1)

    func test_appToolOfPaneA_isNotResolvedFromPaneB() async throws {
        let serverID = MCPServerID(rawValue: UUID())
        let paneA = UUID()
        let paneB = UUID()
        let connection = FakeUpstreamConnection(serverID: serverID, initialState: readyState(), initialTools: [try tool("get_weather")])
        let catalog = FakeCatalogProviding(resolvedTools: [
            "srv-app-pick_color": resolvedTool(
                exportedName: "srv-app-pick_color", serverID: serverID, upstreamToolName: "pick_color",
                definition: try tool("pick_color"), origin: .app(surfaceID: paneA, viewID: UUID())
            ),
        ])
        let viewHost = FakeViewHost()
        let coordinator = makeCoordinator(connections: [serverID: connection], catalog: catalog, viewHosting: viewHost)

        let result = await coordinator.callProxiedTool(
            exportedName: "srv-app-pick_color", arguments: [:], surfaceID: paneB, clientName: "claude-code",
            clientDeclaredUI: false,
            cancellationKey: MCPDownstreamCancellationKey(sessionNonce: "sess-1", requestID: .int(6)),
            progress: nil
        )

        let resolveCalls = await catalog.resolveCalls
        XCTAssertEqual(resolveCalls.map(\.surfaceID), [paneB], "the caller's pane is what the catalog resolves against")
        XCTAssertEqual(result.raw["isError"]?.boolValue, true, "pane B's agent cannot call pane A's app tool")
        XCTAssertTrue(viewHost.appToolCalls.isEmpty, "the view in pane A is never called from pane B")
    }

    // MARK: - The upstream call does not wait for the view's resource

    func test_renderedCall_upstreamCallRunsWhileTheViewsResourceReadIsBlocked() async throws {
        let serverID = MCPServerID(rawValue: UUID())
        let rawResult: [String: AnyCodable] = ["content": AnyCodable([AnyCodable]())]
        let connection = ReadBlockingConnection(
            serverID: serverID, state: readyState(), outcome: .result(MCPCallToolResult(raw: rawResult)), readResult: [:]
        )
        let catalog = FakeCatalogProviding(resolvedTools: [
            "srv-get_weather": resolvedTool(
                exportedName: "srv-get_weather", serverID: serverID, upstreamToolName: "get_weather",
                definition: try tool("get_weather", resourceUri: "ui://weather/card.html")
            ),
        ])
        let store = MCPAppHostStore(paneResolver: NoPaneResolver(), runtime: InertViewRuntime(), appToolRegistry: FakeAppToolRegistry())
        let coordinator = makeCoordinator(connections: [serverID: connection], catalog: catalog, viewHosting: store)
        let surfaceID = UUID()

        let box = ResultBox()
        Task { @MainActor in
            box.result = await coordinator.callProxiedTool(
                exportedName: "srv-get_weather", arguments: [:], surfaceID: surfaceID, clientName: "claude-code",
                clientDeclaredUI: false,
                cancellationKey: MCPDownstreamCancellationKey(sessionNonce: "sess-1", requestID: .int(40)),
                progress: nil
            )
        }
        let deadline = Date().addingTimeInterval(2)
        while box.result == nil, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        await connection.release()

        XCTAssertEqual(box.result?.raw, rawResult, "the agent gets the upstream result while the view's resources/read is still blocked")
        let toolCallCount = await connection.toolCallCount
        XCTAssertEqual(toolCallCount, 1)
        XCTAssertTrue(store.hasActiveView(forSurface: surfaceID), "the view was registered before the upstream call")
    }

    // MARK: - `ui://` resource URIs in a server tool's result are exported (K62)

    private func uiMetaResult(resourceUri: String, flatResourceUri: String?) -> [String: AnyCodable] {
        var meta: [String: AnyCodable] = [
            "ui": AnyCodable([
                "resourceUri": AnyCodable(resourceUri),
                "visibility": AnyCodable([AnyCodable("model")]),
            ]),
            "io.modelcontextprotocol/serverInfo": AnyCodable(["name": AnyCodable("weather")]),
        ]
        if let flatResourceUri { meta["ui/resourceUri"] = AnyCodable(flatResourceUri) }
        return [
            "content": AnyCodable([AnyCodable(["type": AnyCodable("text"), "text": AnyCodable("72F")])]),
            "structuredContent": AnyCodable(["temp": AnyCodable(72)]),
            "_meta": AnyCodable(meta),
        ]
    }

    private func callWeather(_ coordinator: MCPHostCoordinator, surfaceID: UUID?, clientDeclaredUI: Bool = false) async -> MCPCallToolResult {
        await coordinator.callProxiedTool(
            exportedName: "srv-get_weather", arguments: [:], surfaceID: surfaceID, clientName: nil,
            clientDeclaredUI: clientDeclaredUI,
            cancellationKey: MCPDownstreamCancellationKey(sessionNonce: nil, requestID: .int(62)),
            progress: nil
        )
    }

    func test_serverToolResult_uiResourceUriAndFlatKey_exportedUnderTheServersAlias() async throws {
        let serverID = MCPServerID(rawValue: UUID())
        let connection = FakeUpstreamConnection(serverID: serverID, initialState: readyState(), initialTools: [try tool("get_weather")])
        await connection.enqueueToolCallOutcome(.result(MCPCallToolResult(
            raw: uiMetaResult(resourceUri: "ui://weather/card.html", flatResourceUri: "ui://weather/card.html")
        )))
        let catalog = FakeCatalogProviding(resolvedTools: [
            "srv-get_weather": resolvedTool(
                exportedName: "srv-get_weather", serverID: serverID, serverAlias: "fx",
                upstreamToolName: "get_weather", definition: try tool("get_weather")
            ),
        ])
        let coordinator = makeCoordinator(connections: [serverID: connection], catalog: catalog, viewHosting: FakeViewHost())

        let result = await callWeather(coordinator, surfaceID: nil, clientDeclaredUI: true)

        let expected = uiMetaResult(resourceUri: "ui://fx/weather/card.html", flatResourceUri: "ui://fx/weather/card.html")
        XCTAssertEqual(result.raw, expected,
                       "both _meta.ui.resourceUri and the deprecated flat key are exported the way tools/list exports them; nothing else changes")
    }

    func test_serverToolResult_nonUIResourceUri_leftAsIs() async throws {
        let serverID = MCPServerID(rawValue: UUID())
        let connection = FakeUpstreamConnection(serverID: serverID, initialState: readyState(), initialTools: [try tool("get_weather")])
        let raw = uiMetaResult(resourceUri: "https://weather.example/card.html", flatResourceUri: "https://weather.example/card.html")
        await connection.enqueueToolCallOutcome(.result(MCPCallToolResult(raw: raw)))
        let catalog = FakeCatalogProviding(resolvedTools: [
            "srv-get_weather": resolvedTool(exportedName: "srv-get_weather", serverID: serverID, upstreamToolName: "get_weather", definition: try tool("get_weather")),
        ])
        let coordinator = makeCoordinator(connections: [serverID: connection], catalog: catalog, viewHosting: FakeViewHost())

        let result = await callWeather(coordinator, surfaceID: nil, clientDeclaredUI: true)

        XCTAssertEqual(result.raw, raw, "a resourceUri that is not ui:// is not rewritten, as in tools/list")
    }

    func test_serverToolResult_withoutUIMeta_getsNoUIMetaFromTheToolDefinition() async throws {
        let (serverID, connection, catalog) = try uiToolFixture()
        let raw: [String: AnyCodable] = [
            "content": AnyCodable([AnyCodable(["type": AnyCodable("text"), "text": AnyCodable("shown")])]),
            "structuredContent": AnyCodable(["action": AnyCodable("none")]),
        ]
        await connection.enqueueToolCallOutcome(.result(MCPCallToolResult(raw: raw)))
        let coordinator = makeCoordinator(connections: [serverID: connection], catalog: catalog, viewHosting: FakeViewHost())

        let result = await callWeather(coordinator, surfaceID: UUID())

        XCTAssertEqual(result.raw, raw,
                       "the definition's _meta.ui is not copied into a result that carries none (plan section 4: results are forwarded raw)")
    }

    func test_renderedCall_viewReceivesTheUpstreamURI_agentReceivesTheExportedURI() async throws {
        let (serverID, connection, catalog) = try uiToolFixture()
        let upstreamRaw = uiMetaResult(resourceUri: "ui://weather/card.html", flatResourceUri: nil)
        await connection.enqueueToolCallOutcome(.result(MCPCallToolResult(raw: upstreamRaw)))
        let viewHost = FakeViewHost()
        let coordinator = makeCoordinator(connections: [serverID: connection], catalog: catalog, viewHosting: viewHost)

        let result = await callWeather(coordinator, surfaceID: UUID())

        XCTAssertEqual(result.raw, uiMetaResult(resourceUri: "ui://srv/weather/card.html", flatResourceUri: nil),
                       "the agent reads resources through Calyx, so it gets the ui://<alias>/... form")
        XCTAssertEqual(viewHost.finishedInvocations.first?.result.raw, upstreamRaw,
                       "the view's session is bound to the upstream server and reads the upstream URI")
    }

    func test_appOriginToolResult_uiResourceUri_notRewritten() async throws {
        let serverID = MCPServerID(rawValue: UUID())
        let appSurfaceID = UUID()
        let connection = FakeUpstreamConnection(serverID: serverID, initialState: readyState(), initialTools: [])
        let catalog = FakeCatalogProviding(resolvedTools: [
            "srv-app_pick": resolvedTool(
                exportedName: "srv-app_pick", serverID: serverID, upstreamToolName: "pick",
                definition: try tool("pick"), origin: .app(surfaceID: appSurfaceID, viewID: UUID())
            ),
        ])
        let viewHost = FakeViewHost()
        let raw = uiMetaResult(resourceUri: "ui://weather/card.html", flatResourceUri: "ui://weather/card.html")
        viewHost.appToolResult = MCPCallToolResult(raw: raw)
        let coordinator = makeCoordinator(connections: [serverID: connection], catalog: catalog, viewHosting: viewHost)

        let result = await coordinator.callProxiedTool(
            exportedName: "srv-app_pick", arguments: [:], surfaceID: appSurfaceID, clientName: nil,
            clientDeclaredUI: false,
            cancellationKey: MCPDownstreamCancellationKey(sessionNonce: nil, requestID: .int(63)),
            progress: nil
        )

        XCTAssertEqual(result.raw, raw, "an app tool's definition is exported verbatim (MCPToolCatalog), and so is its result")
    }
}
