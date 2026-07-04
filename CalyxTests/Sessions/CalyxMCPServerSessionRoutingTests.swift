//
//  CalyxMCPServerSessionRoutingTests.swift
//  CalyxTests
//
//  TDD Red Phase for CalyxMCPServer's session -> surface resolution: a
//  persistent-session pane's calyx-agent-hook sends its stable
//  calyx-session ID (see AgentHookScriptSessionIDTests) in the same
//  X-Calyx-Surface-ID header a legacy pane sends its raw surface UUID
//  in. `route(request:)` must resolve a value that isn't a UUID via
//  the injected SessionSurfaceMap before giving up with 400.
//
//  Direct route(request:) style, matching CalyxMCPServerAgentEventTests
//  — no real NWConnection involved.
//
//  Coverage:
//  - A registered calyx-session ID in the header resolves to its
//    mapped surface UUID; the registry entry is keyed by that UUID
//  - An unresolvable (unregistered, non-UUID) value still 400s, same
//    as today's malformed-header behavior
//  - A plain surface UUID header keeps working unchanged (non-regression)
//  - Fix round (review, item 7): /mcp must get the same session-ID
//    fallback /agent-event already has — today routeMCP intentionally
//    keeps using parseSurfaceID directly and does NOT fall back to
//    SessionSurfaceMap, so an MCP client running inside a
//    persistent-session pane (e.g. Claude Code's own MCP connection,
//    which reads the same CALYX_SESSION_ID/CALYX_SURFACE_ID
//    precedence) loses its surface binding across a reconnect even
//    though the /agent-event hook path already survives one
//

import XCTest
@testable import Calyx

@MainActor
final class CalyxMCPServerSessionRoutingTests: XCTestCase {

    private var server: CalyxMCPServer!
    private let testToken = "test-token-session-routing"
    private var agentEndpointDir: String!

    override func setUp() {
        super.setUp()
        agentEndpointDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).path
        server = CalyxMCPServer()
        server.agentEndpointDirectory = agentEndpointDir
        server.agentRegistry = AgentRegistry()
        // Isolated instance — never touch .shared, which other suites read.
        server.sessionSurfaceMap = SessionSurfaceMap()
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

    private func validAgentEventBody(sessionID: String = "claude-session-1", cwd: String = "/Users/dev/repo") -> Data {
        Data("""
        {"hook_event_name":"SessionStart","session_id":"\(sessionID)","cwd":"\(cwd)"}
        """.utf8)
    }

    private func agentEventRequest(token: String?, surfaceIDHeader: String?, body: Data?) -> HTTPRequest {
        var headers: [String: String] = [:]
        if let token { headers["Authorization"] = "Bearer \(token)" }
        if let surfaceIDHeader { headers["X-Calyx-Surface-ID"] = surfaceIDHeader }
        return HTTPRequest(method: "POST", path: "/agent-event", headers: headers, body: body)
    }

    // MARK: - calyx-session ID resolution

    func test_agentEvent_headerCarriesRegisteredCalyxSessionID_resolvesToMappedSurface() async {
        let calyxSessionID = "01ARZ3NDEKTSV4RRFFQ69G5FAV"
        let surfaceID = UUID()
        server.sessionSurfaceMap.register(sessionID: calyxSessionID, surfaceID: surfaceID)

        let request = agentEventRequest(token: testToken, surfaceIDHeader: calyxSessionID, body: validAgentEventBody())

        let response = await server.route(request: request)

        XCTAssertEqual(response.statusCode, 204,
                       "A calyx-session ID registered in SessionSurfaceMap must resolve and succeed, not 400")
        XCTAssertEqual(server.agentRegistry.entries.count, 1)
        XCTAssertNotNil(server.agentRegistry.entries[surfaceID],
                        "The registry entry must be keyed by the RESOLVED surface UUID, not the raw " +
                        "calyx-session ID string")
    }

    func test_agentEvent_unregisteredCalyxSessionID_returns400() async {
        let unregisteredSessionID = "01UNKNOWNZZZZZZZZZZZZZZZZZ"

        let request = agentEventRequest(token: testToken, surfaceIDHeader: unregisteredSessionID, body: validAgentEventBody())

        let response = await server.route(request: request)

        XCTAssertEqual(response.statusCode, 400,
                       "A session ID SessionSurfaceMap cannot resolve must still 400, exactly like any " +
                       "other unresolvable X-Calyx-Surface-ID value")
    }

    // MARK: - Non-regression: plain surface UUID unaffected

    func test_agentEvent_plainSurfaceUUIDHeader_stillWorksUnchanged() async {
        let surfaceID = UUID()

        let request = agentEventRequest(token: testToken, surfaceIDHeader: surfaceID.uuidString, body: validAgentEventBody())

        let response = await server.route(request: request)

        XCTAssertEqual(response.statusCode, 204)
        XCTAssertNotNil(server.agentRegistry.entries[surfaceID],
                        "An ordinary (non-persistent-session) pane's raw surface UUID must keep working " +
                        "exactly as before")
    }

    // MARK: - routeMCP session-ID fallback (fix round, item 7)

    private func mcpRequest(token: String?, surfaceIDHeader: String?, body: Data) -> HTTPRequest {
        var headers: [String: String] = [:]
        if let token { headers["Authorization"] = "Bearer \(token)" }
        if let surfaceIDHeader { headers["X-Calyx-Surface-ID"] = surfaceIDHeader }
        return HTTPRequest(method: "POST", path: "/mcp", headers: headers, body: body)
    }

    private func initializeRequestBody(id: Int) -> Data {
        let dict: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": "initialize",
            "params": [
                "protocolVersion": "2024-11-05",
                "capabilities": [:] as [String: Any],
                "clientInfo": ["name": "test", "version": "1.0"],
            ],
        ]
        return try! JSONSerialization.data(withJSONObject: dict)
    }

    func test_routeMCP_headerCarriesRegisteredCalyxSessionID_resolvesToMappedSurfaceForPeerBinding() async throws {
        let calyxSessionID = "01ARZ3NDEKTSV4RRFFQ69G5FAV"
        let surfaceID = UUID()
        server.sessionSurfaceMap.register(sessionID: calyxSessionID, surfaceID: surfaceID)

        let initResponse = await server.route(request: mcpRequest(
            token: testToken, surfaceIDHeader: calyxSessionID, body: initializeRequestBody(id: 1)
        ))

        XCTAssertEqual(initResponse.statusCode, 200, "initialize must still succeed regardless of header resolution")
        let data = try XCTUnwrap(initResponse.body)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let result = try XCTUnwrap(json["result"] as? [String: Any])
        let instructions = try XCTUnwrap(result["instructions"] as? String)

        XCTAssertTrue(
            instructions.contains("Your peer_id is:"),
            "/mcp must resolve a calyx-session ID via SessionSurfaceMap the same way /agent-event does, " +
            "so initialize auto-registers and binds a peer for the resolved surface — today routeMCP only " +
            "calls parseSurfaceID directly, which fails on a non-UUID session ID, so no peer is registered at all"
        )
    }
}
