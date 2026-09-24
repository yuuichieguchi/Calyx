//
//  CalyxMCPServerLegacyMCPEndpointRegressionTests.swift
//  CalyxTests
//
//  Regression pin for §4 of the MCP Apps plan: "既存 calyx-ipc
//  （/mcp、85 ツール）には手を付けません" -- introducing the new
//  /calyx-mcp endpoint (and the routeStreaming(request:lifetime:) split)
//  must leave POST /mcp's own behavior byte-for-byte identical: the
//  85-tool tools/list surface, protocolVersion 2024-11-05, listChanged:
//  false, and 204 for a notification. Lives under MCPHost/Downstream/
//  rather than editing CalyxMCPServerTests.swift directly, per the
//  test-writer split for this feature.
//

import XCTest
@testable import Calyx

@MainActor
final class CalyxMCPServerLegacyMCPEndpointRegressionTests: XCTestCase {

    private var server: CalyxMCPServer!
    private let testToken = "regression-test-token"
    private var agentEndpointDir: String!

    override func setUp() {
        super.setUp()
        agentEndpointDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).path
        server = CalyxMCPServer(agentEndpointDirectory: agentEndpointDir)
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

    private func request(method: String = "POST", path: String, body: Data?, token: String? = nil) -> HTTPRequest {
        var headers: [String: String] = ["Content-Type": "application/json"]
        if let token {
            headers["Authorization"] = "Bearer \(token)"
        }
        return HTTPRequest(method: method, path: path, headers: headers, body: body)
    }

    private func jsonRPC(id: Int? = 1, method: String, params: [String: Any]? = nil) -> Data {
        var dict: [String: Any] = ["jsonrpc": "2.0", "method": method]
        if let id { dict["id"] = id }
        if let params { dict["params"] = params }
        return try! JSONSerialization.data(withJSONObject: dict)
    }

    // MARK: - tools/list: still exactly 85, unaffected by the new catalog

    func test_postMCP_toolsList_stillReturnsExactly85Tools() async throws {
        let req = request(path: "/mcp", body: jsonRPC(method: "tools/list"), token: testToken)
        let resp = await server.route(request: req)
        XCTAssertEqual(resp.statusCode, 200)

        let json = try JSONSerialization.jsonObject(with: try XCTUnwrap(resp.body)) as? [String: Any]
        let result = try XCTUnwrap(json?["result"] as? [String: Any])
        let tools = try XCTUnwrap(result["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.count, 85, "POST /mcp must remain unaffected by the new /calyx-mcp catalog")
    }

    // MARK: - initialize: protocolVersion and listChanged unchanged

    func test_postMCP_initialize_stillReports20241105AndListChangedFalse() async throws {
        let req = request(path: "/mcp", body: jsonRPC(method: "initialize", params: [
            "protocolVersion": "2024-11-05",
            "capabilities": [:] as [String: Any],
            "clientInfo": ["name": "regression", "version": "1.0"],
        ]), token: testToken)
        let resp = await server.route(request: req)
        XCTAssertEqual(resp.statusCode, 200)

        let json = try JSONSerialization.jsonObject(with: try XCTUnwrap(resp.body)) as? [String: Any]
        let result = try XCTUnwrap(json?["result"] as? [String: Any])
        XCTAssertEqual(result["protocolVersion"] as? String, "2024-11-05")

        let capabilities = try XCTUnwrap(result["capabilities"] as? [String: Any])
        let toolsCapability = try XCTUnwrap(capabilities["tools"] as? [String: Any])
        XCTAssertEqual(toolsCapability["listChanged"] as? Bool, false,
                       "POST /mcp must keep advertising listChanged: false -- the new dynamic-catalog " +
                       "list_changed notification belongs to /calyx-mcp only")
    }

    // MARK: - notification: still 204

    func test_postMCP_notification_stillReturns204() async throws {
        let req = request(path: "/mcp", body: jsonRPC(id: nil, method: "notifications/initialized"), token: testToken)
        let resp = await server.route(request: req)
        XCTAssertEqual(resp.statusCode, 204)
        XCTAssertNil(resp.body)
    }

    // MARK: - /mcp and /calyx-mcp are independently routed

    func test_getMCP_stillReturns404_notRepurposedForStreaming() async throws {
        // The new streaming behavior belongs to GET /calyx-mcp; GET /mcp
        // must remain unrouted, exactly as before this feature.
        let req = request(method: "GET", path: "/mcp", body: nil, token: testToken)
        let resp = await server.route(request: req)
        XCTAssertEqual(resp.statusCode, 404)
    }
}
