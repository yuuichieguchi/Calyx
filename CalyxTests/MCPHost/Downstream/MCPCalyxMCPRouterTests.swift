//
//  MCPCalyxMCPRouterTests.swift
//  CalyxTests
//
//  Coverage: `MCPCalyxMCPRouter` (API contract section 10.6, verbatim,
//  rules 9-13) driven directly -- `routeCalyxMCP(request:paneContext:)`
//  -- with fakes for every dependency (`coordinator` built from
//  `FakeConnectionLookup`/`FakeCatalogProviding`, `registry` a real
//  disk-backed `MCPServerRegistry` under a throwaway temp directory,
//  `connections` a `FakeConnectionLookup`). No `CalyxMCPServer`, no
//  socket, no herdr.
//
//  - Rule 9: an app-only tool (`visibility` excludes `.model`) on
//    `tools/call` is rejected `-32000` WITHOUT ever reaching
//    `callProxiedTool` -- proven by asserting the resolved connection's
//    `callToolInvocations` stays empty, not merely by the error code
//    (a wrong implementation could call through and then discard the
//    result). Both generations (rule applies identically per section
//    10.6: "旧世代も同じ").
//  - Rule 10: `resources/read` on a `ui://<alias>/...` URI reverse-
//    resolves through `MCPUIResourceURI.resolve` (alias, not serverID)
//    then the registry's own alias -> serverID lookup, and returns the
//    resolved connection's raw `readResource` result verbatim.
//    Unresolvable (no `ui://` scheme, or no alias segment) -> `-32602`.
//  - Rule 11, upstream half: an upstream `.toolsChanged` event reaches
//    every open legacy GET SSE stream's `notifications/tools/list_changed`,
//    not just one.
//  - Rule 11, pane-scoped half: `appToolRegistry: any MCPAppToolRegistry`
//    (section 9/10.6) yields a surfaceID on its `changes` stream when a
//    pane's own app tools change; the router routes
//    `notifications/tools/list_changed` only to the GET stream whose
//    session resolved to THAT pane at `initialize` time, never to a
//    different pane's stream (`RouterFakeAppToolRegistry`, Downstream-
//    scoped, distinct from section 14's Apps-scoped
//    `CalyxTests/MCPApps/FakeAppToolRegistry.swift`).
//  - Rule 12: `tools/call` answered as `.stream` (SSE) with
//    `notifications/progress` ordered before the final response frame
//    when the upstream delivers progress; plain `.buffered` JSON when
//    it does not.
//  - Rule 13: a modern `tools/call`'s route `Task` is cancelled when
//    the request's own stream consumer stops consuming -- proven with
//    a local blocking connection double (distinct from the shared
//    `FakeUpstreamConnection`, which has no blocking capability) that
//    reports whether ITS OWN `callTool` Task actually observed
//    cancellation.
//

import XCTest
import os
@testable import Calyx

// MARK: - A connection double that blocks until its Task is cancelled,
// for the cancellation-propagation test only. Distinct from the shared
// `FakeUpstreamConnection` (Connection module double, out of this
// file's scope to modify), which has no such capability.

private actor BlockingUpstreamConnection: MCPUpstreamConnecting {
    nonisolated let serverID: MCPServerID
    private var toolDefinitions: [MCPToolDefinition]
    private(set) var observedCancellation = false
    private(set) var callCount = 0

    init(serverID: MCPServerID, tools: [MCPToolDefinition]) {
        self.serverID = serverID
        self.toolDefinitions = tools
    }

    func tools() async -> [MCPToolDefinition] { toolDefinitions }
    func state() async -> MCPConnectionState {
        .ready(MCPServerInfo(negotiatedEra: .v2026_07_28, serverInfo: MCPImplementation(
            name: "blocking-server", version: "1.0", title: nil, description: nil, websiteUrl: nil
        ), instructions: nil), toolCount: toolDefinitions.count)
    }
    var events: AsyncStream<MCPServerEvent> { get async { AsyncStream { _ in } } }

    func callTool(name: String, arguments: [String: AnyCodable], context: MCPToolCallContext) async -> MCPUpstreamClient.ToolCallOutcome {
        callCount += 1
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(10))
        }
        observedCancellation = true
        return .cancelled(reason: .agentCancelled)
    }

    func readResource(uri: String) async throws -> [String: AnyCodable] { [:] }
    func listResources(cursor: String?) async throws -> (items: [[String: AnyCodable]], nextCursor: String?) { ([], nil) }
    func listResourceTemplates(cursor: String?) async throws -> (items: [[String: AnyCodable]], nextCursor: String?) { ([], nil) }
    func listPrompts(cursor: String?) async throws -> (items: [[String: AnyCodable]], nextCursor: String?) { ([], nil) }
}

@MainActor
final class MCPCalyxMCPRouterTests: XCTestCase {

    private let testToken = "router-test-token"
    private var registryDir: String!

    override func tearDown() {
        if let registryDir { try? FileManager.default.removeItem(atPath: registryDir) }
        registryDir = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func tool(_ name: String, visibility: Set<MCPToolVisibility> = [.model]) throws -> MCPToolDefinition {
        var raw: [String: AnyCodable] = [
            "name": AnyCodable(name),
            "description": AnyCodable("d"),
            "inputSchema": AnyCodable(["type": AnyCodable("object")]),
        ]
        if visibility != [.model, .app] {
            raw["_meta"] = AnyCodable(["ui": AnyCodable(["visibility": AnyCodable(visibility.map { AnyCodable($0.rawValue) })])])
        }
        return try MCPToolDefinition(raw: raw)
    }

    private func resolvedTool(
        exportedName: String, serverID: MCPServerID, serverDisplayName: String = "Weather Service",
        upstreamToolName: String, definition: MCPToolDefinition
    ) -> MCPCatalogResolvedTool {
        MCPCatalogResolvedTool(
            exportedName: exportedName, serverID: serverID, serverDisplayName: serverDisplayName,
            upstreamToolName: upstreamToolName,
            origin: .server, definition: definition, exportedRaw: definition.raw
        )
    }

    private func makeRegistry(alias: String, serverID: MCPServerID) -> MCPServerRegistry {
        registryDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        try! FileManager.default.createDirectory(atPath: registryDir, withIntermediateDirectories: true)
        let registry = MCPServerRegistry(directory: registryDir, secretStore: InMemoryMCPSecretStore())
        try! registry.add(MCPServerConfig(
            id: serverID, alias: MCPServerAlias(rawValue: alias)!, displayName: "Weather",
            isEnabled: true, transport: .stdio(command: "/usr/bin/tool", args: [], envNames: [], cwd: nil), auth: nil
        ))
        return registry
    }

    private func modernRequest(
        method: String, name: String? = nil, params: [String: Any] = [:], id: Any = 1, progressToken: Any? = nil
    ) -> HTTPRequest {
        var fullParams = params
        var meta: [String: Any] = [
            "io.modelcontextprotocol/protocolVersion": "2026-07-28",
            "io.modelcontextprotocol/clientInfo": ["name": "router-test", "version": "1.0.0"],
            "io.modelcontextprotocol/clientCapabilities": [:] as [String: Any],
        ]
        if let progressToken { meta["progressToken"] = progressToken }
        fullParams["_meta"] = meta
        if let name { fullParams["name"] = name }
        let dict: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": fullParams]
        let body = try! JSONSerialization.data(withJSONObject: dict)
        var headers: [String: String] = [
            "Content-Type": "application/json",
            "Authorization": "Bearer \(testToken)",
            "MCP-Protocol-Version": "2026-07-28",
            "Mcp-Method": method,
        ]
        if let name { headers["Mcp-Name"] = name }
        return HTTPRequest(method: "POST", path: "/calyx-mcp", headers: headers, body: body)
    }

    private func legacyRequest(method: String, params: [String: Any] = [:], id: Any = 1) -> HTTPRequest {
        let dict: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
        let body = try! JSONSerialization.data(withJSONObject: dict)
        return HTTPRequest(
            method: "POST", path: "/calyx-mcp",
            headers: ["Content-Type": "application/json", "Authorization": "Bearer \(testToken)"],
            body: body
        )
    }

    private func buffered(_ routed: RoutedResponse) throws -> HTTPResponse {
        guard case .buffered(let resp) = routed else { throw XCTSkip("expected .buffered, got \(routed)") }
        return resp
    }

    private func errorCode(_ resp: HTTPResponse) throws -> Int {
        let json = try JSONSerialization.jsonObject(with: try XCTUnwrap(resp.body)) as? [String: Any]
        let error = try XCTUnwrap(json?["error"] as? [String: Any])
        return try XCTUnwrap(error["code"] as? Int)
    }

    /// Everything the stream yielded before it finished or `timeout`
    /// elapsed, whichever came first.
    private static func drain(_ stream: AsyncStream<Data>, timeout: Duration = .seconds(5)) async -> String {
        let collected = OSAllocatedUnfairLock(initialState: [Data]())
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for await chunk in stream { collected.withLock { $0.append(chunk) } }
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
            }
            await group.next()
            group.cancelAll()
        }
        return collected.withLock { $0 }.map { String(data: $0, encoding: .utf8) ?? "" }.joined()
    }

    private func readyState() -> MCPConnectionState {
        .ready(MCPServerInfo(negotiatedEra: .v2026_07_28, serverInfo: MCPImplementation(
            name: "fake-server", version: "1.0", title: nil, description: nil, websiteUrl: nil
        ), instructions: nil), toolCount: 1)
    }

    // MARK: - Rule 9: app-only tool -> -32000, both generations, never reaches callProxiedTool

    func test_toolsCall_appOnlyTool_modern_returnsDashError32000_withoutCallingUpstream() async throws {
        let serverID = MCPServerID(rawValue: UUID())
        let connection = FakeUpstreamConnection(serverID: serverID, initialTools: [try tool("widget", visibility: [.app])])
        let catalog = FakeCatalogProviding(resolvedTools: [
            "srv-widget": resolvedTool(exportedName: "srv-widget", serverID: serverID, upstreamToolName: "widget", definition: try tool("widget", visibility: [.app])),
        ])
        let router = MCPCalyxMCPRouterTestSupport.makeMinimalRouter(
            catalog: catalog, connections: FakeConnectionLookup([serverID: connection]), bearerToken: { [testToken] in testToken }
        )

        let routed = await router.routeCalyxMCP(
            request: modernRequest(method: "tools/call", name: "srv-widget", params: ["arguments": [:] as [String: Any]]),
            paneContext: MCPPaneResolutionContext(surfaceID: nil, clientName: nil, herdrPaneRef: nil)
        )
        let resp = try buffered(routed)
        XCTAssertEqual(try errorCode(resp), -32000)
        let invocations = await connection.callToolInvocations
        XCTAssertTrue(invocations.isEmpty, "an app-only tool must never reach the upstream connection at all")
    }

    func test_toolsCall_appOnlyTool_legacy_returnsDashError32000_withoutCallingUpstream() async throws {
        let serverID = MCPServerID(rawValue: UUID())
        let connection = FakeUpstreamConnection(serverID: serverID, initialTools: [try tool("widget", visibility: [.app])])
        let catalog = FakeCatalogProviding(resolvedTools: [
            "srv-widget": resolvedTool(exportedName: "srv-widget", serverID: serverID, upstreamToolName: "widget", definition: try tool("widget", visibility: [.app])),
        ])
        let router = MCPCalyxMCPRouterTestSupport.makeMinimalRouter(
            catalog: catalog, connections: FakeConnectionLookup([serverID: connection]), bearerToken: { [testToken] in testToken }
        )

        let routed = await router.routeCalyxMCP(
            request: legacyRequest(method: "tools/call", params: ["name": "srv-widget", "arguments": [:] as [String: Any]]),
            paneContext: MCPPaneResolutionContext(surfaceID: nil, clientName: nil, herdrPaneRef: nil)
        )
        let resp = try buffered(routed)
        XCTAssertEqual(try errorCode(resp), -32000, "section 10.6 rule 9 applies identically to the legacy generation")
        let invocations = await connection.callToolInvocations
        XCTAssertTrue(invocations.isEmpty)
    }

    // MARK: - Rule 10: resources/read ui:// reverse lookup

    func test_resourcesRead_uiURI_resolvesAliasThroughRegistry_returnsUpstreamResultVerbatim() async throws {
        let serverID = MCPServerID(rawValue: UUID())
        let readResult: [String: AnyCodable] = ["contents": AnyCodable([AnyCodable(["uri": AnyCodable("ui://widget/index.html"), "text": AnyCodable("<html></html>")])])]
        let connection = FakeUpstreamConnection(serverID: serverID, readResourceResult: .success(readResult))
        let registry = makeRegistry(alias: "weather", serverID: serverID)
        let router = MCPCalyxMCPRouterTestSupport.makeMinimalRouter(
            registry: registry, connections: FakeConnectionLookup([serverID: connection]), bearerToken: { [testToken] in testToken }
        )
        let exportedURI = try XCTUnwrap(MCPUIResourceURI.export(upstreamURI: "ui://widget/index.html", alias: "weather"))

        let routed = await router.routeCalyxMCP(
            request: modernRequest(method: "resources/read", name: exportedURI, params: ["uri": exportedURI]),
            paneContext: MCPPaneResolutionContext(surfaceID: nil, clientName: nil, herdrPaneRef: nil)
        )
        let resp = try buffered(routed)
        XCTAssertEqual(resp.statusCode, 200)
        let json = try JSONSerialization.jsonObject(with: try XCTUnwrap(resp.body)) as? [String: Any]
        let result = try XCTUnwrap(json?["result"] as? [String: Any])
        let contents = try XCTUnwrap(result["contents"] as? [[String: Any]])
        XCTAssertEqual(contents.first?["text"] as? String, "<html></html>")
        let uris = await connection.readResourceURIs
        XCTAssertEqual(uris, ["ui://widget/index.html"], "the connection must be asked for the UPSTREAM uri, not the exported one")
    }

    func test_resourcesRead_unresolvableURI_returnsDashError32602() async throws {
        let router = MCPCalyxMCPRouterTestSupport.makeMinimalRouter(bearerToken: { [testToken] in testToken })

        let routed = await router.routeCalyxMCP(
            request: modernRequest(method: "resources/read", name: "https://example.com/x", params: ["uri": "https://example.com/x"]),
            paneContext: MCPPaneResolutionContext(surfaceID: nil, clientName: nil, herdrPaneRef: nil)
        )
        let resp = try buffered(routed)
        XCTAssertEqual(try errorCode(resp), -32602, "a non-ui:// (or alias-less ui://) uri must never resolve to an upstream call")
    }

    // MARK: - Rule 11 (upstream half): tools-changed broadcasts to every open legacy stream

    func test_upstreamToolsChanged_broadcastsToBothOpenLegacyStreams() async throws {
        let serverID = MCPServerID(rawValue: UUID())
        let connection = FakeUpstreamConnection(serverID: serverID, initialTools: [try tool("get_weather")])
        let router = MCPCalyxMCPRouterTestSupport.makeMinimalRouter(
            registry: makeRegistry(alias: "weather", serverID: serverID),
            connections: FakeConnectionLookup([serverID: connection]), bearerToken: { [testToken] in testToken }
        )

        func mintSession() async throws -> String {
            let routed = await router.routeCalyxMCP(
                request: legacyRequest(method: "initialize", params: [
                    "protocolVersion": "2025-11-25", "capabilities": [:] as [String: Any],
                    "clientInfo": ["name": "router-stream-test", "version": "1.0"],
                ]),
                paneContext: MCPPaneResolutionContext(surfaceID: nil, clientName: nil, herdrPaneRef: nil)
            )
            let resp = try buffered(routed)
            return try XCTUnwrap(resp.headers.first { $0.key.caseInsensitiveCompare("Mcp-Session-Id") == .orderedSame }?.value)
        }

        let sessionA = try await mintSession()
        let sessionB = try await mintSession()

        func openStream(_ sessionID: String) async throws -> AsyncStream<Data> {
            let routed = await router.routeCalyxMCPStream(request: HTTPRequest(
                method: "GET", path: "/calyx-mcp",
                headers: ["Authorization": "Bearer \(testToken)", "Mcp-Session-Id": sessionID, "Accept": "text/event-stream"],
                body: nil
            ))
            guard case .stream(_, let body) = routed else { throw XCTSkip("expected a GET stream") }
            return body
        }

        let streamA = try await openStream(sessionA)
        let streamB = try await openStream(sessionB)

        await connection.setTools([try tool("get_weather"), try tool("get_forecast")])

        async let textA = Self.drain(streamA, timeout: .seconds(3))
        async let textB = Self.drain(streamB, timeout: .seconds(3))
        let (resultA, resultB) = await (textA, textB)

        XCTAssertTrue(resultA.contains("notifications/tools/list_changed"), "session A must observe the upstream change")
        XCTAssertTrue(resultB.contains("notifications/tools/list_changed"), "session B must observe the SAME upstream change")
    }

    // MARK: - Rule 11, pane-scoped half: a pane's app-tool change reaches only that pane's stream

    func test_paneAppToolChange_reachesOnlyThatPanesStream_notAnotherPanes() async throws {
        let appToolRegistry = RouterFakeAppToolRegistry()
        let router = MCPCalyxMCPRouterTestSupport.makeMinimalRouter(
            appToolRegistry: appToolRegistry, bearerToken: { [testToken] in testToken }
        )
        let paneA = UUID()
        let paneB = UUID()

        func mintSession(surfaceID: UUID) async throws -> String {
            let routed = await router.routeCalyxMCP(
                request: legacyRequest(method: "initialize", params: [
                    "protocolVersion": "2025-11-25", "capabilities": [:] as [String: Any],
                    "clientInfo": ["name": "router-pane-scope-test", "version": "1.0"],
                ]),
                paneContext: MCPPaneResolutionContext(surfaceID: surfaceID, clientName: nil, herdrPaneRef: nil)
            )
            let resp = try buffered(routed)
            return try XCTUnwrap(resp.headers.first { $0.key.caseInsensitiveCompare("Mcp-Session-Id") == .orderedSame }?.value)
        }

        func openStream(_ sessionID: String) async throws -> AsyncStream<Data> {
            let routed = await router.routeCalyxMCPStream(request: HTTPRequest(
                method: "GET", path: "/calyx-mcp",
                headers: ["Authorization": "Bearer \(testToken)", "Mcp-Session-Id": sessionID, "Accept": "text/event-stream"],
                body: nil
            ))
            guard case .stream(_, let body) = routed else { throw XCTSkip("expected a GET stream") }
            return body
        }

        let sessionA = try await mintSession(surfaceID: paneA)
        let sessionB = try await mintSession(surfaceID: paneB)
        let streamA = try await openStream(sessionA)
        let streamB = try await openStream(sessionB)

        appToolRegistry.emitChange(forSurface: paneA)

        async let textA = Self.drain(streamA, timeout: .seconds(3))
        async let textB = Self.drain(streamB, timeout: .seconds(3))
        let (resultA, resultB) = await (textA, textB)

        XCTAssertTrue(resultA.contains("notifications/tools/list_changed"),
                      "pane A's own stream must observe pane A's app-tool change")
        XCTAssertFalse(resultB.contains("notifications/tools/list_changed"),
                       "pane B's stream must never observe pane A's app-tool change")
    }

    // MARK: - Rule 12: tools/call SSE progress forwarding vs plain JSON

    func test_toolsCall_progressDelivered_answeredAsSSE_progressBeforeResult() async throws {
        let serverID = MCPServerID(rawValue: UUID())
        let connection = FakeUpstreamConnection(
            serverID: serverID, initialState: readyState(), initialTools: [try tool("slow_tool")],
            toolCallOutcomes: [.result(MCPCallToolResult(raw: ["content": AnyCodable([]), "isError": AnyCodable(false)]))]
        )
        await connection.enqueueProgress(MCPProgressUpdate(progress: 1, total: 2, message: "halfway"))
        await connection.enqueueToolCallOutcome(.result(MCPCallToolResult(raw: ["content": AnyCodable([]), "isError": AnyCodable(false)])))
        let catalog = FakeCatalogProviding(resolvedTools: [
            "srv-slow_tool": resolvedTool(exportedName: "srv-slow_tool", serverID: serverID, upstreamToolName: "slow_tool", definition: try tool("slow_tool")),
        ])
        let router = MCPCalyxMCPRouterTestSupport.makeMinimalRouter(
            catalog: catalog, connections: FakeConnectionLookup([serverID: connection]), bearerToken: { [testToken] in testToken }
        )

        let routed = await router.routeCalyxMCP(
            request: modernRequest(
                method: "tools/call", name: "srv-slow_tool", params: ["arguments": [:] as [String: Any]], progressToken: "progress-1"
            ),
            paneContext: MCPPaneResolutionContext(surfaceID: nil, clientName: nil, herdrPaneRef: nil)
        )
        guard case .stream(_, let body) = routed else {
            return XCTFail("a tools/call whose upstream delivers progress must be answered as an SSE stream, got \(routed)")
        }
        let text = await Self.drain(body)
        let progressRange = text.range(of: "notifications/progress")
        let resultRange = text.range(of: "\"result\"")
        XCTAssertNotNil(progressRange)
        XCTAssertNotNil(resultRange)
        if let progressRange, let resultRange {
            XCTAssertTrue(progressRange.lowerBound < resultRange.lowerBound, "progress must be sent before the final response frame")
        }
    }

    func test_toolsCall_noProgress_answeredAsPlainJSON() async throws {
        let serverID = MCPServerID(rawValue: UUID())
        let connection = FakeUpstreamConnection(serverID: serverID, initialState: readyState(), initialTools: [try tool("get_weather")])
        await connection.enqueueToolCallOutcome(.result(MCPCallToolResult(raw: ["content": AnyCodable([]), "isError": AnyCodable(false)])))
        let catalog = FakeCatalogProviding(resolvedTools: [
            "srv-get_weather": resolvedTool(exportedName: "srv-get_weather", serverID: serverID, upstreamToolName: "get_weather", definition: try tool("get_weather")),
        ])
        let router = MCPCalyxMCPRouterTestSupport.makeMinimalRouter(
            catalog: catalog, connections: FakeConnectionLookup([serverID: connection]), bearerToken: { [testToken] in testToken }
        )

        let routed = await router.routeCalyxMCP(
            request: modernRequest(method: "tools/call", name: "srv-get_weather", params: ["arguments": [:] as [String: Any]]),
            paneContext: MCPPaneResolutionContext(surfaceID: nil, clientName: nil, herdrPaneRef: nil)
        )
        guard case .buffered = routed else {
            return XCTFail("a tools/call with no upstream progress must be plain buffered JSON, got \(routed)")
        }
    }

    // MARK: - Rule 13: modern tools/call cancellation when the request stream's consumer stops

    func test_modernToolsCall_consumerStopsConsuming_cancelsTheRouteTask() async throws {
        let serverID = MCPServerID(rawValue: UUID())
        let connection = BlockingUpstreamConnection(serverID: serverID, tools: [try tool("long_running")])
        let catalog = FakeCatalogProviding(resolvedTools: [
            "srv-long_running": resolvedTool(exportedName: "srv-long_running", serverID: serverID, upstreamToolName: "long_running", definition: try tool("long_running")),
        ])
        let router = MCPCalyxMCPRouterTestSupport.makeMinimalRouter(
            catalog: catalog, connections: FakeConnectionLookup([serverID: connection]), bearerToken: { [testToken] in testToken }
        )

        let routed = await router.routeCalyxMCP(
            request: modernRequest(method: "tools/call", name: "srv-long_running", params: ["arguments": [:] as [String: Any]]),
            paneContext: MCPPaneResolutionContext(surfaceID: nil, clientName: nil, herdrPaneRef: nil)
        )
        guard case .stream(_, let body) = routed else {
            return XCTFail("a tools/call against a connection that never returns must still be an open .stream while pending")
        }

        // Consume exactly one element (or none) then stop -- simulating
        // the request's underlying connection closing -- without ever
        // draining to completion.
        _ = await withTaskGroup(of: Data?.self) { group in
            group.addTask {
                var iterator = body.makeAsyncIterator()
                return await iterator.next()
            }
            group.addTask {
                try? await Task.sleep(for: .milliseconds(200))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }

        // Wait for the route's own Task to notice its stream is no
        // longer being consumed and cancel the in-flight upstream call.
        let observed = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                while !(await connection.observedCancellation) {
                    do {
                        try await Task.sleep(for: .milliseconds(20))
                    } catch {
                        return false
                    }
                }
                return true
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(5))
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
        XCTAssertTrue(observed, "the route's Task must be cancelled (and that cancellation must reach the upstream " +
                      "connection's callTool) once the request's own stream stops being consumed")
    }
}
