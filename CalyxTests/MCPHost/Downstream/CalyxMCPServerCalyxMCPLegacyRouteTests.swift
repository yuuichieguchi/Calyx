//
//  CalyxMCPServerCalyxMCPLegacyRouteTests.swift
//  CalyxTests
//
//  Coverage: POST /calyx-mcp's legacy-generation behavior (plan §4):
//  a request carrying no modern-generation signal (no
//  `MCP-Protocol-Version` header) is served as ordinary JSON-RPC over
//  HTTP, the same envelope shape as /mcp, but on its own path/session
//  track: `initialize` echoes a supported requested version or falls
//  back to 2025-11-25, `Mcp-Session-Id` is minted and
//  returned, sessionless requests are still served (pi has no session
//  concept), a notification gets 202 (not 204 -- the TS SDK only opens
//  its GET SSE stream after a 202), batches are accepted, an unknown
//  method is 200/-32601 (NOT 404 -- 404 is reserved for the modern
//  generation's own unknown-method contract), and `ping` answers `{}`.
//
//  This exercises `route(request:)` directly (buffered path), the same
//  seam `CalyxMCPServerTests` uses for /mcp -- no real socket needed for
//  any of these.
//
//  Assumed request/response shape (not fully specified by the plan, so
//  fixed here): legacy /calyx-mcp accepts the identical JSON-RPC 2.0
//  envelope /mcp does (jsonrpc/id/method/params), and responds with
//  `Mcp-Session-Id` as an ordinary HTTP response header (not a body
//  field) once a session has been minted -- either on the first
//  `initialize` or lazily on first contact for a client that skips
//  straight to a tool call (pi's own flow, since pi never calls
//  `initialize` on this endpoint).
//

import XCTest
@testable import Calyx

@MainActor
final class CalyxMCPServerCalyxMCPLegacyRouteTests: XCTestCase {

    private var server: CalyxMCPServer!
    private let testToken = "legacy-calyx-mcp-token"
    private var agentEndpointDir: String!

    override func setUp() {
        super.setUp()
        agentEndpointDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).path
        server = CalyxMCPServer(agentEndpointDirectory: agentEndpointDir)
        server.agentRegistry = AgentRegistry()
        server._testSetToken(testToken)
        server.setCalyxMCPRouter(MCPCalyxMCPRouterTestSupport.makeMinimalRouter(bearerToken: { [testToken] in testToken }))
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

    private func legacyRequest(
        id: Int? = 1,
        method: String,
        params: [String: Any]? = nil,
        sessionID: String? = nil
    ) -> HTTPRequest {
        var dict: [String: Any] = ["jsonrpc": "2.0", "method": method]
        if let id { dict["id"] = id }
        if let params { dict["params"] = params }
        let body = try! JSONSerialization.data(withJSONObject: dict)
        var headers: [String: String] = [
            "Content-Type": "application/json",
            "Authorization": "Bearer \(testToken)",
        ]
        if let sessionID {
            headers["Mcp-Session-Id"] = sessionID
        }
        return HTTPRequest(method: "POST", path: "/calyx-mcp", headers: headers, body: body)
    }

    private func batchRequest(methods: [String], sessionID: String? = nil) -> HTTPRequest {
        let items: [[String: Any]] = methods.enumerated().map { i, m in
            ["jsonrpc": "2.0", "id": i, "method": m]
        }
        let body = try! JSONSerialization.data(withJSONObject: items)
        var headers: [String: String] = [
            "Content-Type": "application/json",
            "Authorization": "Bearer \(testToken)",
        ]
        if let sessionID { headers["Mcp-Session-Id"] = sessionID }
        return HTTPRequest(method: "POST", path: "/calyx-mcp", headers: headers, body: body)
    }

    private func responseHeader(_ name: String, in response: HTTPResponse) -> String? {
        response.headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    // MARK: - initialize: version negotiation

    func test_initialize_requestedSupportedVersion_isEchoedBack() async throws {
        let req = legacyRequest(method: "initialize", params: [
            "protocolVersion": "2025-06-18",
            "capabilities": [:] as [String: Any],
            "clientInfo": ["name": "test", "version": "1.0"],
        ])
        let resp = await server.route(request: req)
        XCTAssertEqual(resp.statusCode, 200)
        let json = try JSONSerialization.jsonObject(with: try XCTUnwrap(resp.body)) as? [String: Any]
        let result = try XCTUnwrap(json?["result"] as? [String: Any])
        XCTAssertEqual(result["protocolVersion"] as? String, "2025-06-18",
                       "a requested version legacy /calyx-mcp supports must be echoed back verbatim")
    }

    func test_initialize_unsupportedRequestedVersion_fallsBackTo20251125() async throws {
        let req = legacyRequest(method: "initialize", params: [
            "protocolVersion": "1999-01-01",
            "capabilities": [:] as [String: Any],
            "clientInfo": ["name": "test", "version": "1.0"],
        ])
        let resp = await server.route(request: req)
        let json = try JSONSerialization.jsonObject(with: try XCTUnwrap(resp.body)) as? [String: Any]
        let result = try XCTUnwrap(json?["result"] as? [String: Any])
        XCTAssertEqual(result["protocolVersion"] as? String, "2025-11-25")
    }

    func test_initialize_piStyleEmptyParams_fallsBackTo20251125() async throws {
        // pi sends {} for params on its "initialize" handshake -- see
        // PiExtensionManager.scriptBody's callCalyx("initialize", {}, ...).
        let req = legacyRequest(method: "initialize", params: [:])
        let resp = await server.route(request: req)
        let json = try JSONSerialization.jsonObject(with: try XCTUnwrap(resp.body)) as? [String: Any]
        let result = try XCTUnwrap(json?["result"] as? [String: Any])
        XCTAssertEqual(result["protocolVersion"] as? String, "2025-11-25")
    }

    // MARK: - Mcp-Session-Id minted and returned

    func test_initialize_mintsAndReturnsMcpSessionIdHeader() async throws {
        let req = legacyRequest(method: "initialize", params: [
            "protocolVersion": "2025-11-25",
            "capabilities": [:] as [String: Any],
            "clientInfo": ["name": "test", "version": "1.0"],
        ])
        let resp = await server.route(request: req)
        let sessionID = responseHeader("Mcp-Session-Id", in: resp)
        XCTAssertNotNil(sessionID, "legacy /calyx-mcp must mint and return an Mcp-Session-Id on initialize")
        XCTAssertFalse(sessionID?.isEmpty ?? true)
    }

    // MARK: - Sessionless requests still served (pi has no session)

    func test_toolsListWithNoSessionHeaderAtAll_stillServed() async throws {
        let req = legacyRequest(method: "tools/list", sessionID: nil)
        let resp = await server.route(request: req)
        XCTAssertEqual(resp.statusCode, 200,
                       "a client with no session concept at all (pi) must still be served, not rejected " +
                       "for lacking Mcp-Session-Id")
    }

    // MARK: - Notifications get 202, not 204

    func test_notification_returns202_not204() async throws {
        let req = legacyRequest(id: nil, method: "notifications/initialized")
        let resp = await server.route(request: req)
        XCTAssertEqual(resp.statusCode, 202,
                       "legacy /calyx-mcp must answer a notification with 202 (not /mcp's 204) -- the TS " +
                       "SDK only opens its GET SSE stream once it has seen a 202 response")
    }

    // MARK: - Batches accepted

    func test_batchRequest_isAccepted() async throws {
        let req = batchRequest(methods: ["ping", "tools/list"])
        let resp = await server.route(request: req)
        XCTAssertEqual(resp.statusCode, 200, "legacy /calyx-mcp must accept a JSON-RPC batch array body")
        let json = try JSONSerialization.jsonObject(with: try XCTUnwrap(resp.body))
        XCTAssertTrue(json is [Any], "a batch request must receive a batch (array) response")
    }

    // MARK: - Unknown method: 200/-32601 (not 404)

    func test_unknownMethod_returns200WithDashError32601() async throws {
        let req = legacyRequest(method: "totally/unknown")
        let resp = await server.route(request: req)
        XCTAssertEqual(resp.statusCode, 200,
                       "legacy /calyx-mcp's unknown-method contract is 200/-32601, matching /mcp -- 404 is " +
                       "reserved for the modern generation")
        let json = try JSONSerialization.jsonObject(with: try XCTUnwrap(resp.body)) as? [String: Any]
        let error = try XCTUnwrap(json?["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, -32601)
    }

    // MARK: - ping

    func test_ping_returnsEmptyObjectResult() async throws {
        let req = legacyRequest(method: "ping")
        let resp = await server.route(request: req)
        XCTAssertEqual(resp.statusCode, 200)
        let json = try JSONSerialization.jsonObject(with: try XCTUnwrap(resp.body)) as? [String: Any]
        let result = try XCTUnwrap(json?["result"] as? [String: Any])
        XCTAssertTrue(result.isEmpty, "ping must answer with an empty object result")
    }

    // MARK: - Auth still required

    func test_missingAuth_returns401() async throws {
        let body = try! JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "method": "ping"])
        let req = HTTPRequest(method: "POST", path: "/calyx-mcp", headers: [:], body: body)
        let resp = await server.route(request: req)
        XCTAssertEqual(resp.statusCode, 401)
    }
}
