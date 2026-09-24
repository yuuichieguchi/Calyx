//
//  CalyxMCPServerCalyxMCPMissingCapabilityTests.swift
//  CalyxTests
//
//  Coverage: MCP 2026-07-28's `MissingRequiredClientCapabilityError`
//  (`-32021`) as it applies (or, per this file's own read of the
//  primary source, does NOT apply) to /calyx-mcp's own methods.
//
//  Primary source (schema.md, `MissingRequiredClientCapabilityError`):
//  "Returned when processing a request requires a capability the client
//  did not declare in `clientCapabilities`. For HTTP, the response
//  status code MUST be `400 Bad Request`." Its own worked example is
//  "Missing elicitation capability" -- a server that needs the CALLING
//  client to participate in an `elicitation/create` MRTR round-trip
//  requires that client to have declared `clientCapabilities.elicitation`
//  first.
//
//  This does NOT apply to any of /calyx-mcp's own methods
//  (`tools/list`, `tools/call`, `resources/read`, `resources/list`,
//  `resources/templates/list`, `prompts/list`, `server/discover`,
//  `subscriptions/listen`): per the plan's own §1 decision, "Elicitation
//  は Calyx が提示します（CLI の TUI に委ねない）" -- Calyx presents any
//  elicitation itself, through its own UI, and never asks the CALLING
//  agent CLI to participate in an MRTR round-trip back to it. Calyx's
//  own `roots`/`elicitation` declarations (plan §1's "宣言する
//  capabilities") are what CALYX declares to its UPSTREAM MCP servers as
//  a CLIENT -- the reverse direction from `-32021`, which is about what
//  CALYX (as a SERVER) would require from the DOWNSTREAM agent CLI. No
//  /calyx-mcp operation asks anything of the downstream caller beyond
//  the baseline `_meta` fields (already covered by
//  CalyxMCPServerCalyxMCPModernRouteTests.swift's own missing-
//  `clientCapabilities`-FIELD test, which is the separate `-32602`
//  case, not this one).
//
//  So rather than inventing a required-capability scenario the spec
//  does not define for this server, this file pins the regression the
//  real risk actually is: an implementation that (incorrectly) starts
//  requiring SOME core capability (`roots`, `elicitation`, or
//  `sampling`) from the calling client for an ordinary operation. Every
//  test below sends `clientCapabilities: {}` (present, but declaring
//  nothing) and asserts the request is NOT rejected with `-32021` --
//  the empty object is exactly what a conforming client sends when it
//  needs none of the optional core capabilities, per every example in
//  the primary source itself (`server/discover`'s own request example
//  uses `"io.modelcontextprotocol/clientCapabilities": {}`).
//

import XCTest
@testable import Calyx

@MainActor
final class CalyxMCPServerCalyxMCPMissingCapabilityTests: XCTestCase {

    private var server: CalyxMCPServer!
    private let testToken = "missing-capability-test-token"
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

    private func modernRequest(method: String, params: [String: Any] = [:]) -> HTTPRequest {
        var fullParams = params
        fullParams["_meta"] = [
            "io.modelcontextprotocol/protocolVersion": "2026-07-28",
            // Declares nothing beyond the baseline -- an empty object is
            // a fully conforming, capability-free declaration.
            "io.modelcontextprotocol/clientCapabilities": [:] as [String: Any],
        ]
        let dict: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": method, "params": fullParams]
        let body = try! JSONSerialization.data(withJSONObject: dict)
        return HTTPRequest(
            method: "POST", path: "/calyx-mcp",
            headers: [
                "Content-Type": "application/json",
                "Authorization": "Bearer \(testToken)",
                "MCP-Protocol-Version": "2026-07-28",
                "Mcp-Method": method,
            ],
            body: body
        )
    }

    private func errorCode(_ resp: HTTPResponse) -> Int? {
        guard let body = resp.body,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let error = json["error"] as? [String: Any] else { return nil }
        return error["code"] as? Int
    }

    // MARK: - Empty clientCapabilities never triggers -32021

    func test_serverDiscover_emptyClientCapabilities_neverReturnsDashError32021() async throws {
        let resp = await server.route(request: modernRequest(method: "server/discover"))
        XCTAssertNotEqual(errorCode(resp), -32021,
                          "server/discover requires no core client capability -- Calyx presents its own " +
                          "elicitation UI rather than asking the calling client to participate")
    }

    func test_toolsList_emptyClientCapabilities_neverReturnsDashError32021() async throws {
        let resp = await server.route(request: modernRequest(method: "tools/list"))
        XCTAssertNotEqual(errorCode(resp), -32021)
    }

    func test_resourcesList_emptyClientCapabilities_neverReturnsDashError32021() async throws {
        let resp = await server.route(request: modernRequest(method: "resources/list"))
        XCTAssertNotEqual(errorCode(resp), -32021)
    }
}
