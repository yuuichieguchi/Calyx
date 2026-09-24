//
//  CalyxMCPServerCalyxMCPDeleteTests.swift
//  CalyxTests
//
//  Coverage: `DELETE /calyx-mcp` (API contract section 10.4/10.9/10.10,
//  verbatim). Replaces the earlier `...SessionRevocationTests.swift`,
//  whose subject (a server-side revoked-nonce set) does not exist in
//  this contract: `MCPDownstreamSessionID` is stateless (see
//  `MCPDownstreamSessionIDTests.swift`), so DELETE closes the session's
//  live GET SSE stream and returns 200 WITHOUT revoking the signed
//  session id itself -- the same id continues to validate afterward,
//  and a fresh POST carrying it must still be served normally. This is
//  the contract's own explicit decision, not a deviation ("採用済みの
//  決定である" -- section 10.4).
//

import XCTest
@testable import Calyx

@MainActor
final class CalyxMCPServerCalyxMCPDeleteTests: XCTestCase {

    private var server: CalyxMCPServer!
    private let testToken = "delete-test-token"
    private var agentEndpointDir: String!
    private var lifetimeTasks: [Task<Void, Never>] = []

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
        for task in lifetimeTasks { task.cancel() }
        lifetimeTasks.removeAll()
        server.stop()
        server = nil
        if let agentEndpointDir {
            try? FileManager.default.removeItem(atPath: agentEndpointDir)
        }
        agentEndpointDir = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func openLifetime() -> Task<Void, Never> {
        let task = Task<Void, Never> {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
            }
        }
        lifetimeTasks.append(task)
        return task
    }

    private func initializeRequest() -> HTTPRequest {
        let body = try! JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": [
                "protocolVersion": "2025-11-25",
                "capabilities": [:] as [String: Any],
                "clientInfo": ["name": "delete-test", "version": "1.0"],
            ],
        ])
        return HTTPRequest(
            method: "POST", path: "/calyx-mcp",
            headers: ["Content-Type": "application/json", "Authorization": "Bearer \(testToken)"],
            body: body
        )
    }

    private func toolsListRequest(sessionID: String) -> HTTPRequest {
        let body = try! JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 2, "method": "tools/list"])
        return HTTPRequest(
            method: "POST", path: "/calyx-mcp",
            headers: [
                "Content-Type": "application/json",
                "Authorization": "Bearer \(testToken)",
                "Mcp-Session-Id": sessionID,
            ],
            body: body
        )
    }

    private func getStreamRequest(sessionID: String) -> HTTPRequest {
        HTTPRequest(
            method: "GET", path: "/calyx-mcp",
            headers: [
                "Authorization": "Bearer \(testToken)",
                "Mcp-Session-Id": sessionID,
                "Accept": "text/event-stream",
            ],
            body: nil
        )
    }

    private func deleteRequest(sessionID: String) -> HTTPRequest {
        HTTPRequest(
            method: "DELETE", path: "/calyx-mcp",
            headers: ["Authorization": "Bearer \(testToken)", "Mcp-Session-Id": sessionID],
            body: nil
        )
    }

    private func responseHeader(_ name: String, in response: HTTPResponse) -> String? {
        response.headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    private func mintSessionID() async throws -> String {
        let resp = await server.route(request: initializeRequest())
        XCTAssertEqual(resp.statusCode, 200)
        return try XCTUnwrap(responseHeader("Mcp-Session-Id", in: resp), "initialize must mint Mcp-Session-Id")
    }

    // MARK: - DELETE closes the live GET stream and returns 200

    func test_delete_validSession_returns200() async throws {
        let sessionID = try await mintSessionID()
        let resp = await server.route(request: deleteRequest(sessionID: sessionID))
        XCTAssertEqual(resp.statusCode, 200, "section 10.10: DELETE closes the SSE stream and returns 200")
    }

    func test_delete_closesTheOpenGETStream() async throws {
        let sessionID = try await mintSessionID()
        let routed = await server.routeStreaming(request: getStreamRequest(sessionID: sessionID), lifetime: openLifetime())
        guard case .stream(_, let body) = routed else {
            return XCTFail("a valid session's GET must open a stream")
        }

        let deleteResp = await server.route(request: deleteRequest(sessionID: sessionID))
        XCTAssertEqual(deleteResp.statusCode, 200)

        // The stream's AsyncStream must finish once DELETE closes it --
        // observed by draining it to completion under a bounded
        // watchdog, never a wall-clock sleep alone.
        let finished = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await _ in body {}
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
        XCTAssertTrue(finished, "DELETE must terminate the session's open GET SSE stream")
    }

    // MARK: - The signed session id itself is never revoked

    func test_delete_thenSameSessionUsedForAPOSTRequest_stillReturns200() async throws {
        let sessionID = try await mintSessionID()

        let deleteResp = await server.route(request: deleteRequest(sessionID: sessionID))
        XCTAssertEqual(deleteResp.statusCode, 200)

        let afterDelete = await server.route(request: toolsListRequest(sessionID: sessionID))
        XCTAssertEqual(afterDelete.statusCode, 200,
                       "MCPDownstreamSessionID is stateless -- DELETE must never make the signed session id " +
                       "itself read as invalid; only its live SSE stream is closed")
    }

    func test_delete_unknownSessionID_returns404() async throws {
        // An id that does not verify at all (never minted) is a
        // distinct case from a validly-signed, "deleted" id above --
        // signature verification failure is still 404 (section 10.4).
        let resp = await server.route(request: deleteRequest(sessionID: "not-a-real-session-token"))
        XCTAssertEqual(resp.statusCode, 404)
    }

    func test_delete_doesNotCloseADifferentSessionsStream() async throws {
        let sessionA = try await mintSessionID()
        let sessionB = try await mintSessionID()
        XCTAssertNotEqual(sessionA, sessionB, "two independent initialize calls must mint distinct session ids")

        let deleteResp = await server.route(request: deleteRequest(sessionID: sessionA))
        XCTAssertEqual(deleteResp.statusCode, 200)

        let stillWorks = await server.route(request: toolsListRequest(sessionID: sessionB))
        XCTAssertEqual(stillWorks.statusCode, 200, "deleting one session must never affect an unrelated session")
    }

    func test_delete_missingSessionIdHeader_returns400() async throws {
        let req = HTTPRequest(
            method: "DELETE", path: "/calyx-mcp",
            headers: ["Authorization": "Bearer \(testToken)"],
            body: nil
        )
        let resp = await server.route(request: req)
        XCTAssertEqual(resp.statusCode, 400, "DELETE with no session to close at all is a client error")
    }
}
