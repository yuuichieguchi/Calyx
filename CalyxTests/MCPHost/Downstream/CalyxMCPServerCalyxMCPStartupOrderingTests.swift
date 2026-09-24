//
//  CalyxMCPServerCalyxMCPStartupOrderingTests.swift
//  CalyxTests
//
//  Coverage: K53. `MCPHostComposition` installs the `/calyx-mcp` router
//  before `CalyxMCPServer.start` binds its listener, and the router reads
//  its session bearer through the server's own `sessionBearerToken`
//  holder, which `start` updates before it binds. A `/calyx-mcp` request
//  that arrives the moment the listener accepts connections is therefore
//  served (not 503, the no-router case covered by
//  `CalyxMCPServerCalyxMCPNoRouterTests`), and the session id it mints
//  is keyed by the token the server started with.
//

import XCTest
@testable import Calyx

@MainActor
final class CalyxMCPServerCalyxMCPStartupOrderingTests: XCTestCase {

    private var server: CalyxMCPServer!
    private var agentEndpointDir: String!

    override func setUp() async throws {
        try await super.setUp()
        agentEndpointDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).path
        server = CalyxMCPServer(agentEndpointDirectory: agentEndpointDir)
        server.agentRegistry = AgentRegistry()
        server.sessionSurfaceMap = SessionSurfaceMap()
    }

    override func tearDown() async throws {
        await server.stopAndWait()
        server = nil
        if let agentEndpointDir {
            try? FileManager.default.removeItem(atPath: agentEndpointDir)
        }
        agentEndpointDir = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

    /// The router the composition builds: installed before `start`, its
    /// bearer read through the server's holder.
    private func installRouterAsTheCompositionDoes() {
        let bearer = server.sessionBearerToken
        server.setCalyxMCPRouter(MCPCalyxMCPRouterTestSupport.makeMinimalRouter(bearerToken: { bearer.value }))
    }

    private func legacyRequest(method: String, params: [String: Any]?, token: String, sessionID: String? = nil) -> HTTPRequest {
        var dict: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": method]
        if let params { dict["params"] = params }
        var headers = ["Content-Type": "application/json", "Authorization": "Bearer \(token)"]
        if let sessionID { headers["Mcp-Session-Id"] = sessionID }
        return HTTPRequest(
            method: "POST", path: "/calyx-mcp", headers: headers,
            body: try! JSONSerialization.data(withJSONObject: dict)
        )
    }

    private func initializeRequest(token: String) -> HTTPRequest {
        legacyRequest(method: "initialize", params: [
            "protocolVersion": "2025-11-25",
            "capabilities": [:] as [String: Any],
            "clientInfo": ["name": "claude-code", "version": "1.0"],
        ], token: token)
    }

    private func sessionID(in response: HTTPResponse) -> String? {
        response.headers.first { $0.key.caseInsensitiveCompare("Mcp-Session-Id") == .orderedSame }?.value
    }

    private func startOnFreePort(token: String) async throws {
        try await server.start(token: token, preferredPort: Int.random(in: 49_152...65_000))
    }

    // MARK: - Tests

    func test_postCalyxMCP_immediatelyAfterStart_isServedNot503() async throws {
        installRouterAsTheCompositionDoes()
        try await startOnFreePort(token: "startup-ordering-token")

        let resp = await server.route(request: initializeRequest(token: "startup-ordering-token"))

        XCTAssertEqual(resp.statusCode, 200,
                       "a /calyx-mcp request the listener accepts right after start must reach the router, not 503")
    }

    func test_sessionMintedImmediatelyAfterStart_isKeyedByTheStartedToken() async throws {
        installRouterAsTheCompositionDoes()
        let token = "startup-ordering-token"
        try await startOnFreePort(token: token)

        let initialize = await server.route(request: initializeRequest(token: token))
        let minted = try XCTUnwrap(sessionID(in: initialize), "initialize must mint an Mcp-Session-Id")

        XCTAssertNotNil(MCPDownstreamSessionID.validate(minted, bearerToken: token),
                        "the session id minted right after start must be signed with the token the server started with")
        let followUp = await server.route(request: legacyRequest(method: "tools/list", params: nil, token: token, sessionID: minted))
        XCTAssertEqual(followUp.statusCode, 200, "the minted session id must be accepted by the next request")
    }

    func test_sessionBearerToken_followsTheTokenEachStartUses() async throws {
        try await startOnFreePort(token: "first-token")
        XCTAssertEqual(server.sessionBearerToken.value, "first-token")

        try await startOnFreePort(token: "second-token")
        XCTAssertEqual(server.sessionBearerToken.value, "second-token",
                       "a restart issues a new token, and the holder must carry it before the new listener serves")
    }
}
