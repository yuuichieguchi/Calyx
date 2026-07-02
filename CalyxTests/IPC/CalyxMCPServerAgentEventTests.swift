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

    // MARK: - Round 3: unread-badge wiring (route() binding + real tool calls)
    //
    // No mocking: drives the real PreToolUse-binding path through route(),
    // then the real send_message/receive_messages/ack_messages tool
    // handlers through handleJSONRPC, and asserts on the same injected
    // AgentRegistry both paths share.

    private func rpcToolCallRequest(id: Int, toolName: String, arguments: [String: Any]) -> Data {
        let dict: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": "tools/call",
            "params": ["name": toolName, "arguments": arguments],
        ]
        return try! JSONSerialization.data(withJSONObject: dict)
    }

    private func toolResultText(_ body: Data?) throws -> String {
        let data = try XCTUnwrap(body)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let result = try XCTUnwrap(json["result"] as? [String: Any])
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        return try XCTUnwrap(content.first?["text"] as? String)
    }

    private func registerPeerID(name: String) async throws -> String {
        let request = rpcToolCallRequest(id: 1, toolName: "register_peer", arguments: ["name": name, "role": "terminal"])
        let (status, body) = await server.handleJSONRPC(data: request, authToken: testToken)
        XCTAssertEqual(status, 200)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(try toolResultText(body).utf8)) as? [String: Any]
        )
        return try XCTUnwrap(json["peerId"] as? String)
    }

    private func extractMessageIDs(fromReceiveResultText text: String) throws -> [String] {
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        return messages.compactMap { $0["id"] as? String }
    }

    func test_agentEventBinding_sendMessageIncrementsUnreadCount_ackMessagesClearsIt() async throws {
        let registry = AgentRegistry()
        server.agentRegistry = registry

        let p1 = try await registerPeerID(name: "P1")
        let p2 = try await registerPeerID(name: "P2")

        // P1's pane reports a PreToolUse for its own send_message call —
        // this is how the registry learns the surface -> peer binding.
        let boundSurface = UUID()
        let bindingRequest = agentEventRequest(
            token: testToken,
            surfaceIDHeader: boundSurface.uuidString,
            body: Data("""
            {"hook_event_name":"PreToolUse","session_id":"s1",
             "tool_name":"mcp__calyx-ipc__send_message",
             "tool_input":{"from":"\(p1)","to":"\(p2)","content":"hi"}}
            """.utf8)
        )
        let bindingResponse = await server.route(request: bindingRequest)
        XCTAssertEqual(bindingResponse.statusCode, 204)

        // P2 now actually sends a message to P1 via the real MCP tool-call
        // path — this must update the bound surface's unreadCount through
        // the injected registry (no mocking of IPCStore or the registry).
        let sendRequest = rpcToolCallRequest(id: 2, toolName: "send_message", arguments: [
            "from": p2, "to": p1, "content": "hello from P2",
        ])
        let (sendStatus, _) = await server.handleJSONRPC(data: sendRequest, authToken: testToken)
        XCTAssertEqual(sendStatus, 200)

        XCTAssertEqual(registry.entries[boundSurface]?.unreadCount, 1,
                       "Sending a message to the bound peer must increment the surface row's unreadCount")

        // Contract updated post-review: receive_messages alone (no ack)
        // must already clear unreadCount to 0 — the fix for a defect
        // where the badge stayed lit even after the agent had genuinely
        // read its inbox, only clearing once it was separately ack'd.
        let receiveRequest = rpcToolCallRequest(id: 3, toolName: "receive_messages", arguments: ["peer_id": p1])
        let (_, receiveBody) = await server.handleJSONRPC(data: receiveRequest, authToken: testToken)
        let messageIDs = try extractMessageIDs(fromReceiveResultText: try toolResultText(receiveBody))

        XCTAssertEqual(registry.entries[boundSurface]?.unreadCount, 0,
                       "receive_messages alone (no ack yet) must already clear the bound surface's " +
                       "unreadCount, since it marks the retrieved messages delivered")

        // ack_messages (message removal) must not resurrect the badge.
        let ackRequest = rpcToolCallRequest(id: 4, toolName: "ack_messages", arguments: [
            "peer_id": p1, "message_ids": messageIDs,
        ])
        let (ackStatus, _) = await server.handleJSONRPC(data: ackRequest, authToken: testToken)
        XCTAssertEqual(ackStatus, 200)

        XCTAssertEqual(registry.entries[boundSurface]?.unreadCount, 0,
                       "unreadCount must remain 0 after ack_messages too")
    }

    func test_agentEventBinding_postToolUseRegisterPeerResponse_bindsSurface_firstMessageLightsUpBadge() async throws {
        // Round 3 fix: a surface is now also bound to its own peer ID
        // right from register_peer's PostToolUse response
        // (tool_response.peerId), not only from a later PreToolUse for
        // one of the other calyx-ipc tools — so a message sent to a pane
        // immediately after it registers still lights up the badge.
        let registry = AgentRegistry()
        server.agentRegistry = registry

        let p1 = try await registerPeerID(name: "P1")
        let p2 = try await registerPeerID(name: "P2")

        let boundSurface = UUID()
        let bindingRequest = agentEventRequest(
            token: testToken,
            surfaceIDHeader: boundSurface.uuidString,
            body: Data("""
            {"hook_event_name":"PostToolUse","session_id":"s1",
             "tool_name":"mcp__calyx-ipc__register_peer",
             "tool_response":{"peerId":"\(p1)"}}
            """.utf8)
        )
        let bindingResponse = await server.route(request: bindingRequest)
        XCTAssertEqual(bindingResponse.statusCode, 204)

        let sendRequest = rpcToolCallRequest(id: 2, toolName: "send_message", arguments: [
            "from": p2, "to": p1, "content": "welcome",
        ])
        let (sendStatus, _) = await server.handleJSONRPC(data: sendRequest, authToken: testToken)
        XCTAssertEqual(sendStatus, 200)

        XCTAssertEqual(registry.entries[boundSurface]?.unreadCount, 1,
                       "A message sent to the peer bound via register_peer's PostToolUse response " +
                       "must light up the badge on its first send, with no prior PreToolUse needed")
    }

    // MARK: - Round 3 review follow-up: syncBoundPeerInboxCounts gating

    func test_agentEventBinding_lspToolCall_doesNotRefreshInboxCounts_messagingToolDoes() async throws {
        let registry = AgentRegistry()
        server.agentRegistry = registry

        let p1 = try await registerPeerID(name: "P1")
        let p2 = try await registerPeerID(name: "P2")
        let p1ID = try XCTUnwrap(UUID(uuidString: p1))
        let p2ID = try XCTUnwrap(UUID(uuidString: p2))

        let boundSurface = UUID()
        let bindingRequest = agentEventRequest(
            token: testToken,
            surfaceIDHeader: boundSurface.uuidString,
            body: Data("""
            {"hook_event_name":"PreToolUse","session_id":"s1",
             "tool_name":"mcp__calyx-ipc__send_message",
             "tool_input":{"from":"\(p1)","to":"\(p2)","content":"hi"}}
            """.utf8)
        )
        let bindingResponse = await server.route(request: bindingRequest)
        XCTAssertEqual(bindingResponse.statusCode, 204)

        // Deliver a message straight through the shared IPCStore, bypassing
        // the send_message tool handler (and therefore
        // syncBoundPeerInboxCounts) entirely — this manufactures a stale
        // unreadCount without going through any tools/call gate, so the
        // assertions below can attribute a lack of refresh solely to the
        // lsp_* tool name, not to this setup step.
        _ = try await server.store.sendMessage(from: p2ID, to: p1ID, content: "hello from P2")

        let lspRequest = rpcToolCallRequest(id: 10, toolName: "lsp_hover", arguments: [:])
        let (lspStatus, _) = await server.handleJSONRPC(data: lspRequest, authToken: testToken)
        XCTAssertEqual(lspStatus, 200, "lsp_hover with no bridge started must still return a structured tool error, not fail the HTTP layer")
        XCTAssertEqual(registry.entries[boundSurface]?.unreadCount, 0,
                       "An lsp_* tools/call must never trigger syncBoundPeerInboxCounts, so the " +
                       "unreadCount left stale by the direct IPCStore delivery above must stay 0")

        let statusRequest = rpcToolCallRequest(id: 11, toolName: "get_peer_status", arguments: ["peer_id": p1])
        let (statusStatus, _) = await server.handleJSONRPC(data: statusRequest, authToken: testToken)
        XCTAssertEqual(statusStatus, 200)
        XCTAssertEqual(registry.entries[boundSurface]?.unreadCount, 1,
                       "A calyx-ipc messaging tools/call (get_peer_status here) must still trigger " +
                       "syncBoundPeerInboxCounts and pick up the count left stale by the earlier lsp_* call")
    }
}
