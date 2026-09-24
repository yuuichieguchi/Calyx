//
//  CalyxMCPServerCalyxMCPNoRouterTests.swift
//  CalyxTests
//
//  Coverage: `CalyxMCPServer.setCalyxMCPRouter(_:)` (API contract
//  section 10.9, verbatim) -- while no router has been installed (the
//  real production wiring happens once `MCPUpstreamSupervisor` finishes
//  building one at IPC startup), every `/calyx-mcp` route must answer
//  503, not crash and not silently fall through to some other route's
//  behavior. `/mcp` (calyx-ipc) must be completely unaffected, since it
//  never depends on the router at all.
//

import XCTest
@testable import Calyx

@MainActor
final class CalyxMCPServerCalyxMCPNoRouterTests: XCTestCase {

    private var server: CalyxMCPServer!
    private let testToken = "no-router-test-token"
    private var agentEndpointDir: String!

    override func setUp() {
        super.setUp()
        agentEndpointDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).path
        server = CalyxMCPServer(agentEndpointDirectory: agentEndpointDir)
        server.agentRegistry = AgentRegistry()
        server._testSetToken(testToken)
        // Deliberately no setCalyxMCPRouter(_:) call.
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

    private func toolsListRequest() -> HTTPRequest {
        let body = try! JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "method": "tools/list"])
        return HTTPRequest(
            method: "POST", path: "/calyx-mcp",
            headers: ["Content-Type": "application/json", "Authorization": "Bearer \(testToken)"],
            body: body
        )
    }

    func test_postCalyxMCP_noRouterInstalled_returns503() async throws {
        let resp = await server.route(request: toolsListRequest())
        XCTAssertEqual(resp.statusCode, 503)
    }

    func test_deleteCalyxMCP_noRouterInstalled_returns503() async throws {
        let req = HTTPRequest(
            method: "DELETE", path: "/calyx-mcp",
            headers: ["Authorization": "Bearer \(testToken)", "Mcp-Session-Id": "v1.x.y"],
            body: nil
        )
        let resp = await server.route(request: req)
        XCTAssertEqual(resp.statusCode, 503)
    }

    func test_postMCP_unaffectedByMissingCalyxMCPRouter() async throws {
        // /mcp (calyx-ipc, 85 tools) must never depend on the /calyx-mcp
        // router's presence at all.
        let body = try! JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "method": "tools/list"])
        let req = HTTPRequest(
            method: "POST", path: "/mcp",
            headers: ["Content-Type": "application/json", "Authorization": "Bearer \(testToken)"],
            body: body
        )
        let resp = await server.route(request: req)
        XCTAssertEqual(resp.statusCode, 200, "/mcp must keep working with no /calyx-mcp router installed at all")
    }
}
