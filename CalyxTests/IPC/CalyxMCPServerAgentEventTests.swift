//
//  CalyxMCPServerAgentEventTests.swift
//  CalyxTests
//
//  TDD Red Phase for CalyxMCPServer.route(request:): the extracted HTTP
//  path dispatcher, and the new POST /agent-event endpoint.
//
//  Coverage:
//  - POST /agent-event with a valid token, surface ID header, and body
//    returns 204 and updates the injected AgentRegistry
//  - Wrong bearer token → 401
//  - Missing / malformed X-Calyx-Surface-ID header → 400
//  - Malformed JSON body → 400
//  - POST /mcp behavior is unchanged (initialize still returns 200)
//  - GET / unknown paths → 404, and this is distinguished from a
//    would-be-404 /agent-event miss
//

import XCTest
@testable import Calyx

@MainActor
final class CalyxMCPServerAgentEventTests: XCTestCase {

    // MARK: - Properties

    private var server: CalyxMCPServer!
    private let testToken = "test-token-12345"

    /// Test-isolated `agent-endpoint.json` directory. This suite never
    /// calls `start()`, but `tearDown`'s `server.stop()` still calls
    /// `AgentEndpointFile.remove(directory:)` — redirect it so that
    /// never touches the real
    /// ~/Library/Application Support/Calyx/agent-endpoint.json.
    private var agentEndpointDir: String!

    // MARK: - Lifecycle

    override func setUp() {
        super.setUp()
        agentEndpointDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).path
        server = CalyxMCPServer()
        server.agentEndpointDirectory = agentEndpointDir
        // stop() (called from tearDown) now also resets agentRegistry;
        // individual tests that assert on agent-event handling override
        // this with their own instance below.
        server.agentRegistry = AgentRegistry()
        server._testSetToken(testToken)
    }

    override func tearDown() {
        server.stop()
        server = nil
        if let agentEndpointDir {
            try? FileManager.default.removeItem(atPath: agentEndpointDir)
        }
        agentEndpointDir = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func validAgentEventBody(sessionID: String = "session-1", cwd: String = "/Users/dev/repo") -> Data {
        Data("""
        {"hook_event_name":"SessionStart","session_id":"\(sessionID)","cwd":"\(cwd)"}
        """.utf8)
    }

    private func agentEventRequest(
        token: String?,
        surfaceIDHeader: String?,
        body: Data?,
        kindHeader: String? = nil
    ) -> HTTPRequest {
        var headers: [String: String] = [:]
        if let token { headers["Authorization"] = "Bearer \(token)" }
        if let surfaceIDHeader { headers["X-Calyx-Surface-ID"] = surfaceIDHeader }
        if let kindHeader { headers["X-Calyx-Agent-Kind"] = kindHeader }
        return HTTPRequest(method: "POST", path: "/agent-event", headers: headers, body: body)
    }

    // MARK: - POST /agent-event success

    func test_route_agentEvent_validRequest_returns204AndUpdatesInjectedRegistry() async {
        let registry = AgentRegistry()
        server.agentRegistry = registry
        let surfaceID = UUID()

        let request = agentEventRequest(
            token: testToken,
            surfaceIDHeader: surfaceID.uuidString,
            body: validAgentEventBody(sessionID: "session-1", cwd: "/Users/dev/repo")
        )

        let response = await server.route(request: request)

        XCTAssertEqual(response.statusCode, 204)
        XCTAssertEqual(registry.entries.count, 1)
        XCTAssertEqual(registry.entries[surfaceID]?.sessionID, "session-1")
        XCTAssertEqual(registry.entries[surfaceID]?.cwd, "/Users/dev/repo")
        XCTAssertEqual(registry.entries[surfaceID]?.state, .idle)
    }

    // MARK: - X-Calyx-Agent-Kind propagation (Phase 2)

    func test_route_agentEvent_agentKindHeader_propagatesToRegistryEntryKind() async {
        // Case A: X-Calyx-Agent-Kind: codex must propagate to the entry's kind.
        let registryWithKindHeader = AgentRegistry()
        server.agentRegistry = registryWithKindHeader
        let surfaceWithKindHeader = UUID()
        let requestWithKindHeader = agentEventRequest(
            token: testToken,
            surfaceIDHeader: surfaceWithKindHeader.uuidString,
            body: validAgentEventBody(sessionID: "session-1", cwd: "/Users/dev/repo"),
            kindHeader: "codex"
        )

        let responseWithKindHeader = await server.route(request: requestWithKindHeader)

        XCTAssertEqual(responseWithKindHeader.statusCode, 204)
        XCTAssertEqual(registryWithKindHeader.entries[surfaceWithKindHeader]?.kind, "codex",
                       "X-Calyx-Agent-Kind: codex must propagate to the registry entry's kind")

        // Case B: a missing header must default to claude-code.
        let registryWithoutKindHeader = AgentRegistry()
        server.agentRegistry = registryWithoutKindHeader
        let surfaceWithoutKindHeader = UUID()
        let requestWithoutKindHeader = agentEventRequest(
            token: testToken,
            surfaceIDHeader: surfaceWithoutKindHeader.uuidString,
            body: validAgentEventBody(sessionID: "session-2", cwd: "/Users/dev/repo2")
        )

        let responseWithoutKindHeader = await server.route(request: requestWithoutKindHeader)

        XCTAssertEqual(responseWithoutKindHeader.statusCode, 204)
        XCTAssertEqual(registryWithoutKindHeader.entries[surfaceWithoutKindHeader]?.kind, "claude-code",
                       "A missing X-Calyx-Agent-Kind header must default to claude-code")
    }

    func test_route_agentEvent_emptyStringKindHeader_defaultsToClaudeCode() async {
        let registry = AgentRegistry()
        server.agentRegistry = registry
        let surfaceID = UUID()
        let request = agentEventRequest(
            token: testToken,
            surfaceIDHeader: surfaceID.uuidString,
            body: validAgentEventBody(sessionID: "session-1", cwd: "/Users/dev/repo"),
            kindHeader: ""
        )

        let response = await server.route(request: request)

        XCTAssertEqual(response.statusCode, 204)
        XCTAssertEqual(registry.entries[surfaceID]?.kind, "claude-code",
                       "An empty-string X-Calyx-Agent-Kind header must default to claude-code")
    }

    func test_route_agentEvent_whitespaceOnlyKindHeader_defaultsToClaudeCode() async {
        let registry = AgentRegistry()
        server.agentRegistry = registry
        let surfaceID = UUID()
        let request = agentEventRequest(
            token: testToken,
            surfaceIDHeader: surfaceID.uuidString,
            body: validAgentEventBody(sessionID: "session-1", cwd: "/Users/dev/repo"),
            kindHeader: "   "
        )

        let response = await server.route(request: request)

        XCTAssertEqual(response.statusCode, 204)
        XCTAssertEqual(registry.entries[surfaceID]?.kind, "claude-code",
                       "A whitespace-only X-Calyx-Agent-Kind header must default to claude-code")
    }

    // MARK: - Authentication

    func test_route_agentEvent_wrongToken_returns401() async {
        let request = agentEventRequest(
            token: "wrong-token",
            surfaceIDHeader: UUID().uuidString,
            body: validAgentEventBody()
        )

        let response = await server.route(request: request)

        XCTAssertEqual(response.statusCode, 401)
    }

    func test_route_agentEvent_missingToken_returns401() async {
        let request = agentEventRequest(
            token: nil,
            surfaceIDHeader: UUID().uuidString,
            body: validAgentEventBody()
        )

        let response = await server.route(request: request)

        XCTAssertEqual(response.statusCode, 401)
    }

    // MARK: - Surface ID header validation

    func test_route_agentEvent_missingSurfaceIDHeader_returns400() async {
        let request = agentEventRequest(token: testToken, surfaceIDHeader: nil, body: validAgentEventBody())

        let response = await server.route(request: request)

        XCTAssertEqual(response.statusCode, 400)
    }

    func test_route_agentEvent_malformedSurfaceIDHeader_returns400() async {
        let request = agentEventRequest(
            token: testToken,
            surfaceIDHeader: "not-a-uuid",
            body: validAgentEventBody()
        )

        let response = await server.route(request: request)

        XCTAssertEqual(response.statusCode, 400)
    }

    // MARK: - Body validation

    func test_route_agentEvent_malformedJSONBody_returns400() async {
        let request = agentEventRequest(
            token: testToken,
            surfaceIDHeader: UUID().uuidString,
            body: Data("not json {{{".utf8)
        )

        let response = await server.route(request: request)

        XCTAssertEqual(response.statusCode, 400)
    }

    func test_route_agentEvent_missingBody_returns400() async {
        let request = agentEventRequest(
            token: testToken,
            surfaceIDHeader: UUID().uuidString,
            body: nil
        )

        let response = await server.route(request: request)

        XCTAssertEqual(response.statusCode, 400)
    }

    // MARK: - POST /mcp unchanged

    func test_route_mcpInitialize_behaviorUnchanged_returns200() async throws {
        let bodyDict: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": [
                "protocolVersion": "2024-11-05",
                "capabilities": [:] as [String: Any],
                "clientInfo": ["name": "test", "version": "1.0"],
            ],
        ]
        let body = try JSONSerialization.data(withJSONObject: bodyDict)

        let request = HTTPRequest(
            method: "POST",
            path: "/mcp",
            headers: ["Authorization": "Bearer \(testToken)"],
            body: body
        )

        let response = await server.route(request: request)

        XCTAssertEqual(response.statusCode, 200)
        let responseData = try XCTUnwrap(response.body)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: responseData) as? [String: Any])
        let result = try XCTUnwrap(json["result"] as? [String: Any])
        XCTAssertEqual(result["protocolVersion"] as? String, "2024-11-05")
    }

    // MARK: - Unknown routes

    func test_route_otherPath_returns404() async {
        // Sanity: POST /agent-event must be routed on its own path (not
        // fall through to the generic 404 branch), so the assertions below
        // actually exercise path dispatch rather than a blanket 404.
        let agentEventResponse = await server.route(request: agentEventRequest(
            token: testToken,
            surfaceIDHeader: UUID().uuidString,
            body: validAgentEventBody()
        ))
        XCTAssertNotEqual(agentEventResponse.statusCode, 404,
                          "Precondition: /agent-event must be dispatched, not fall through to 404")

        let getResponse = await server.route(request: HTTPRequest(
            method: "GET", path: "/agent-event", headers: [:], body: nil
        ))
        XCTAssertEqual(getResponse.statusCode, 404)

        let unknownPathResponse = await server.route(request: HTTPRequest(
            method: "POST", path: "/unknown", headers: [:], body: nil
        ))
        XCTAssertEqual(unknownPathResponse.statusCode, 404)
    }
}
