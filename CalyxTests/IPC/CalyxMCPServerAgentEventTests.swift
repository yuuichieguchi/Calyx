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
    // then the real send_message/receive_messages tool handlers through
    // handleJSONRPC, and asserts on the same injected AgentRegistry both
    // paths share.

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

    // Round 4 review: previously duplicated the same
    // `JSONSerialization`/`peerId` extraction inline; now delegates to
    // `peerID(fromToolResultBody:)` below, the single place that logic
    // lives.
    private func registerPeerID(name: String) async throws -> String {
        let request = rpcToolCallRequest(id: 1, toolName: "register_peer", arguments: ["name": name, "role": "terminal"])
        let (status, body) = await server.handleJSONRPC(data: request, authToken: testToken)
        XCTAssertEqual(status, 200)
        return try peerID(fromToolResultBody: body)
    }

    private func extractMessageIDs(fromReceiveResultText text: String) throws -> [String] {
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        return messages.compactMap { $0["id"] as? String }
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

    // MARK: - Round 4: MCP-connection surface binding (X-Calyx-Surface-ID
    // on /mcp itself), so a passive recipient that never calls a
    // calyx-ipc tool still gets its unread badge lit.
    //
    // All three tests below drive `initialize`/`register_peer` through
    // `route(request:)` with an `HTTPRequest` carrying the
    // `X-Calyx-Surface-ID` header, exactly as Claude Code's own MCP
    // client would send it once `ClaudeConfigManager` starts emitting the
    // header (see ClaudeConfigManagerTests). `routeMCP` does not yet read
    // that header at all, so every one of these is expected to fail red:
    // the binding never happens, and the surface's `unreadCount` never
    // moves off its initial value.

    /// Builds a `POST /mcp` request carrying the given bearer token and
    /// (optionally) an `X-Calyx-Surface-ID` header, mirroring
    /// `agentEventRequest`'s shape for `/agent-event`.
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

    /// Extracts the `instructions` prose from an `initialize` response
    /// body. Shared by `peerID(fromInitializeResponseBody:)` below (which
    /// additionally requires a `peer_id` sentence to be present) and by
    /// callers that need to assert on the prose itself, including when no
    /// peer was auto-registered at all (see the invalid-header cases in
    /// `test_initializeHeaderBinding_onlyValidUUIDHeaderBinds`).
    private func instructionsText(fromInitializeResponseBody body: Data?) throws -> String {
        let data = try XCTUnwrap(body)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let result = try XCTUnwrap(json["result"] as? [String: Any])
        return try XCTUnwrap(result["instructions"] as? String)
    }

    /// `initialize`'s response carries the auto-registered peer ID only
    /// inside the `instructions` prose (`MCPRouter.buildInitializeResponse`),
    /// not as a separate JSON field the way `register_peer`'s tool result
    /// does — so extraction here parses that sentence with a regex, rather
    /// than reusing `registerPeerID`'s `json["peerId"]` lookup.
    private func peerID(fromInitializeResponseBody body: Data?) throws -> String {
        let instructions = try instructionsText(fromInitializeResponseBody: body)

        let regex = try NSRegularExpression(pattern: #"Your peer_id is: ([0-9A-Fa-f-]+)\."#)
        let fullRange = NSRange(instructions.startIndex..<instructions.endIndex, in: instructions)
        let match = try XCTUnwrap(
            regex.firstMatch(in: instructions, range: fullRange),
            "initialize response instructions must contain a 'Your peer_id is: <uuid>.' sentence"
        )
        let peerIDRange = try XCTUnwrap(Range(match.range(at: 1), in: instructions))
        return String(instructions[peerIDRange])
    }

    /// `register_peer`'s tool result carries `peerId` as a JSON field
    /// directly (unlike `initialize`'s prose-embedded form above).
    private func peerID(fromToolResultBody body: Data?) throws -> String {
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(try toolResultText(body).utf8)) as? [String: Any]
        )
        return try XCTUnwrap(json["peerId"] as? String)
    }

    // MARK: - User-scenario reproduction

    func test_userScenario_bothPanesInitializeWithSurfaceHeader_passiveRecipientGetsBadgeWithoutCallingAnyTool() async throws {
        let registry = AgentRegistry()
        server.agentRegistry = registry

        let surfaceA = UUID()
        let surfaceB = UUID()

        // Pane A and Pane B each connect with their own surface header —
        // exactly what two Ghostty panes' `claude` processes do once
        // ClaudeConfigManager emits `X-Calyx-Surface-ID` on the calyx-ipc
        // MCP entry.
        let initA = await server.route(request: mcpRequest(
            token: testToken, surfaceIDHeader: surfaceA.uuidString, body: initializeRequestBody(id: 1)
        ))
        XCTAssertEqual(initA.statusCode, 200)
        let peerA = try peerID(fromInitializeResponseBody: initA.body)

        let initB = await server.route(request: mcpRequest(
            token: testToken, surfaceIDHeader: surfaceB.uuidString, body: initializeRequestBody(id: 2)
        ))
        XCTAssertEqual(initB.statusCode, 200)
        let peerB = try peerID(fromInitializeResponseBody: initB.body)

        // Both panes' sessions start — this creates the sidebar rows via
        // the existing hook path, independent of the surface -> peer
        // binding under test.
        let sessionStartA = await server.route(request: agentEventRequest(
            token: testToken, surfaceIDHeader: surfaceA.uuidString,
            body: validAgentEventBody(sessionID: "session-a", cwd: "/Users/dev/repo-a")
        ))
        XCTAssertEqual(sessionStartA.statusCode, 204)

        let sessionStartB = await server.route(request: agentEventRequest(
            token: testToken, surfaceIDHeader: surfaceB.uuidString,
            body: validAgentEventBody(sessionID: "session-b", cwd: "/Users/dev/repo-b")
        ))
        XCTAssertEqual(sessionStartB.statusCode, 204)

        // A sends to B via the real send_message tool — B never calls any
        // calyx-ipc tool itself, so the pre-Round-4 PreToolUse/
        // PostToolUse-only binding path never learns B's surface.
        let sendResponse = await server.route(request: mcpRequest(
            token: testToken, surfaceIDHeader: nil,
            body: rpcToolCallRequest(id: 3, toolName: "send_message", arguments: [
                "from": peerA, "to": peerB, "content": "hello from A",
            ])
        ))
        XCTAssertEqual(sendResponse.statusCode, 200)

        XCTAssertEqual(registry.entries[surfaceB]?.unreadCount, 1,
                       "B's surface -> peer binding must be learned from its own surface-tagged " +
                       "initialize alone, so a message sent to B lights up its badge even though B " +
                       "never called a calyx-ipc tool")

        // B checks its inbox — the badge clears.
        let receiveResponse = await server.route(request: mcpRequest(
            token: testToken, surfaceIDHeader: nil,
            body: rpcToolCallRequest(id: 4, toolName: "receive_messages", arguments: ["peer_id": peerB])
        ))
        XCTAssertEqual(receiveResponse.statusCode, 200)
        XCTAssertEqual(registry.entries[surfaceB]?.unreadCount, 0,
                       "receive_messages must clear the badge once B actually reads its inbox")
    }

    // MARK: - initialize header validation

    // Round 6 review: `initialize`'s auto-registration is now itself
    // gated on a valid `X-Calyx-Surface-ID` header (see
    // `test_initialize_withoutSurfaceHeader_doesNotAutoRegisterPeer`) —
    // a surfaceless connection has no surface for a peer to ever be bound
    // to, so registering one for it just leaves an orphaned identity
    // behind. That subsumes what this test originally checked (a peer was
    // always auto-registered, but only *bound* when the header was
    // valid): for the three invalid-header cases there is now no
    // auto-registered peer at all, so the contract under test for those
    // cases is "no peer_id is reported in `instructions`", not "a peer_id
    // is reported but left unbound".
    func test_initializeHeaderBinding_onlyValidUUIDHeaderBinds() async throws {
        let validSurfaceID = UUID()
        let cases: [(label: String, header: String?, shouldBind: Bool)] = [
            ("valid UUID", validSurfaceID.uuidString, true),
            ("empty string", "", false),
            ("missing", nil, false),
            ("non-UUID", "not-a-uuid", false),
        ]

        for testCase in cases {
            let registry = AgentRegistry()
            server.agentRegistry = registry
            let surfaceID = UUID(uuidString: testCase.header ?? "") ?? UUID()

            let initResponse = await server.route(request: mcpRequest(
                token: testToken, surfaceIDHeader: testCase.header, body: initializeRequestBody(id: 1)
            ))
            XCTAssertEqual(initResponse.statusCode, 200, "[\(testCase.label)] initialize must still succeed")

            guard testCase.shouldBind else {
                let instructions = try instructionsText(fromInitializeResponseBody: initResponse.body)
                XCTAssertFalse(instructions.contains("Your peer_id is:"),
                               "[\(testCase.label)] an invalid/missing X-Calyx-Surface-ID header must not " +
                               "auto-register a peer at all — there is no surface to ever bind it to")
                continue
            }

            let recipientPeerID = try peerID(fromInitializeResponseBody: initResponse.body)

            // The recipient's row must exist for the valid-header case —
            // created via the same real surface UUID used for the
            // initialize call.
            let sessionStart = await server.route(request: agentEventRequest(
                token: testToken, surfaceIDHeader: surfaceID.uuidString,
                body: validAgentEventBody(sessionID: "session-\(testCase.label)", cwd: "/Users/dev/repo")
            ))
            XCTAssertEqual(sessionStart.statusCode, 204, "[\(testCase.label)] SessionStart must still succeed")

            let senderPeerID = try await registerPeerID(name: "sender-\(testCase.label)")
            let sendResponse = await server.route(request: mcpRequest(
                token: testToken, surfaceIDHeader: nil,
                body: rpcToolCallRequest(id: 2, toolName: "send_message", arguments: [
                    "from": senderPeerID, "to": recipientPeerID, "content": "hi",
                ])
            ))
            XCTAssertEqual(sendResponse.statusCode, 200, "[\(testCase.label)] send_message must still succeed")

            XCTAssertEqual(registry.entries[surfaceID]?.unreadCount ?? 0, 1,
                           "[\(testCase.label)] a valid X-Calyx-Surface-ID header must auto-register and " +
                           "bind a peer to the surface")
        }
    }

    // MARK: - register_peer tool call surface binding

    func test_registerPeerToolCall_surfaceHeader_bindsNewPeerToSurface() async throws {
        let registry = AgentRegistry()
        server.agentRegistry = registry
        let surfaceID = UUID()

        // register_peer's own HTTP request carries the surface header —
        // covers explicit re-registration (e.g. after `/clear`), distinct
        // from initialize's automatic peer registration.
        let registerResponse = await server.route(request: mcpRequest(
            token: testToken, surfaceIDHeader: surfaceID.uuidString,
            body: rpcToolCallRequest(id: 1, toolName: "register_peer", arguments: ["name": "B", "role": "terminal"])
        ))
        XCTAssertEqual(registerResponse.statusCode, 200)
        let peerB = try peerID(fromToolResultBody: registerResponse.body)

        let sessionStart = await server.route(request: agentEventRequest(
            token: testToken, surfaceIDHeader: surfaceID.uuidString,
            body: validAgentEventBody(sessionID: "session-1", cwd: "/Users/dev/repo")
        ))
        XCTAssertEqual(sessionStart.statusCode, 204)

        let peerA = try await registerPeerID(name: "A")
        let sendResponse = await server.route(request: mcpRequest(
            token: testToken, surfaceIDHeader: nil,
            body: rpcToolCallRequest(id: 2, toolName: "send_message", arguments: [
                "from": peerA, "to": peerB, "content": "hi",
            ])
        ))
        XCTAssertEqual(sendResponse.statusCode, 200)

        XCTAssertEqual(registry.entries[surfaceID]?.unreadCount, 1,
                       "register_peer's own X-Calyx-Surface-ID header must bind the newly created " +
                       "peer to that surface, the same way initialize's auto-registered peer does")
    }

    // MARK: - Round 4 review / Round 6 fix review: initialize only binds
    // an unbound surface
    //
    // This test originally (Round 4) asserted that a second `initialize`
    // on an already-bound surface mints a distinct "ghost" peer whose
    // binding must not steal the first peer's — i.e. it treated the ghost
    // peer as an accepted side effect and only guarded against its
    // binding leaking. That ghost peer WAS the Round 6 defect (see
    // `test_initialize_sameSurfaceReconnect_reportsSamePeerID_singleListPeersEntry_registerPeerAlsoSameID`
    // for the direct contract): a second `initialize` on a still-alive,
    // already-bound surface no longer mints anything at all, so there is
    // no second peer here to compare bindings against. This test now
    // instead confirms the ORIGINAL Round 4 concern — that message
    // delivery/badges keep working across a reconnect — holds under the
    // new single-identity behavior.

    func test_initialize_surfaceAlreadyBound_secondInitializeDoesNotDisruptMessageDelivery() async throws {
        let registry = AgentRegistry()
        server.agentRegistry = registry
        let surfaceID = UUID()

        // First connection: initialize binds the surface to its
        // auto-registered peer, exactly like every other test above.
        let firstInit = await server.route(request: mcpRequest(
            token: testToken, surfaceIDHeader: surfaceID.uuidString, body: initializeRequestBody(id: 1)
        ))
        XCTAssertEqual(firstInit.statusCode, 200)
        let firstPeer = try peerID(fromInitializeResponseBody: firstInit.body)

        // A second `initialize` on the SAME surface (e.g. a reconnect, or
        // a nested `claude` invoked as a subprocess and inheriting the
        // same CALYX_SURFACE_ID env var) resolves to the SAME peer — the
        // surface is still bound and that peer is still alive.
        let secondInit = await server.route(request: mcpRequest(
            token: testToken, surfaceIDHeader: surfaceID.uuidString, body: initializeRequestBody(id: 2)
        ))
        XCTAssertEqual(secondInit.statusCode, 200)
        let secondPeer = try peerID(fromInitializeResponseBody: secondInit.body)
        XCTAssertEqual(firstPeer, secondPeer,
                       "a second initialize on an already-bound, still-alive surface must resolve to " +
                       "the SAME peer_id as the first, not mint a distinct one")

        let sessionStart = await server.route(request: agentEventRequest(
            token: testToken, surfaceIDHeader: surfaceID.uuidString,
            body: validAgentEventBody(sessionID: "session-1", cwd: "/Users/dev/repo")
        ))
        XCTAssertEqual(sessionStart.statusCode, 204)

        let senderPeerID = try await registerPeerID(name: "sender")

        // A message to the shared peer must still light up the badge,
        // unaffected by the intervening second initialize...
        let sendToFirst = await server.route(request: mcpRequest(
            token: testToken, surfaceIDHeader: nil,
            body: rpcToolCallRequest(id: 3, toolName: "send_message", arguments: [
                "from": senderPeerID, "to": firstPeer, "content": "hi",
            ])
        ))
        XCTAssertEqual(sendToFirst.statusCode, 200)
        XCTAssertEqual(registry.entries[surfaceID]?.unreadCount, 1,
                       "the surface's binding must still be lit up by a message to the shared peer id")

        // ...and receive_messages on that same shared peer clears it.
        let receiveFirst = await server.route(request: mcpRequest(
            token: testToken, surfaceIDHeader: nil,
            body: rpcToolCallRequest(id: 4, toolName: "receive_messages", arguments: ["peer_id": firstPeer])
        ))
        XCTAssertEqual(receiveFirst.statusCode, 200)
        XCTAssertEqual(registry.entries[surfaceID]?.unreadCount, 0)
    }

    // MARK: - Round 4 review: shared surface-ID header parsing (trim)
    // across /mcp and /agent-event

    func test_surfaceIDHeader_leadingTrailingWhitespace_parsesIdenticallyOnMCPAndAgentEvent() async throws {
        let registry = AgentRegistry()
        server.agentRegistry = registry
        let surfaceID = UUID()
        let paddedHeader = "  \(surfaceID.uuidString)  "

        // /agent-event: a padded header must parse to the same UUID, not
        // 400 — the trim now happens in the same shared helper /mcp uses.
        let sessionStart = await server.route(request: agentEventRequest(
            token: testToken, surfaceIDHeader: paddedHeader,
            body: validAgentEventBody(sessionID: "session-1", cwd: "/Users/dev/repo")
        ))
        XCTAssertEqual(sessionStart.statusCode, 204,
                       "A padded X-Calyx-Surface-ID must still parse on /agent-event, not 400")
        XCTAssertEqual(registry.entries[surfaceID]?.sessionID, "session-1",
                       "The trimmed UUID, not the padded string, must be the entry's key")

        // /mcp: the same padded header on `initialize` must bind the same
        // (trimmed) surface UUID, exactly as the unpadded form does
        // elsewhere in this file. The surface isn't yet peer-bound at
        // this point (SessionStart above never carries an
        // ipcSelfPeerID), so Round 4 review fix #1's "only bind an
        // unbound surface" gate doesn't block this.
        let initResponse = await server.route(request: mcpRequest(
            token: testToken, surfaceIDHeader: paddedHeader, body: initializeRequestBody(id: 1)
        ))
        XCTAssertEqual(initResponse.statusCode, 200)
        let peer = try peerID(fromInitializeResponseBody: initResponse.body)

        let senderPeerID = try await registerPeerID(name: "sender")
        let sendResponse = await server.route(request: mcpRequest(
            token: testToken, surfaceIDHeader: nil,
            body: rpcToolCallRequest(id: 2, toolName: "send_message", arguments: [
                "from": senderPeerID, "to": peer, "content": "hi",
            ])
        ))
        XCTAssertEqual(sendResponse.statusCode, 200)
        XCTAssertEqual(registry.entries[surfaceID]?.unreadCount, 1,
                       "A padded X-Calyx-Surface-ID on /mcp's initialize must bind the trimmed UUID, " +
                       "lighting up the same surface's badge")
    }

    // MARK: - Round 6: register_peer rename semantics (single identity per surface)
    //
    // Bug: register_peer always minted a fresh UUID (IPCStore.registerPeer),
    // so a pane that followed the (pre-Round-6) instructions' "call
    // register_peer once after connecting" ended up with TWO registered
    // identities for the same surface — the auto-registered peer from
    // `initialize`, and a second, disconnected one from its own
    // register_peer call. Senders addressing the auto-registered id never
    // reached the pane's own inbox. Fix: when the connecting surface
    // already has a bound, still-alive peer, register_peer now RENAMES
    // that peer in place (same peer_id returned) instead of creating a
    // second one.

    func test_registerPeer_boundSurfaceWithAlivePeer_renamesInPlace_singleListPeersEntry() async throws {
        let registry = AgentRegistry()
        server.agentRegistry = registry
        let surfaceA = UUID()

        // initialize with surface header A auto-registers a peer and binds
        // surfaceA to it.
        let initA = await server.route(request: mcpRequest(
            token: testToken, surfaceIDHeader: surfaceA.uuidString, body: initializeRequestBody(id: 1)
        ))
        XCTAssertEqual(initA.statusCode, 200)
        let autoPeerID = try peerID(fromInitializeResponseBody: initA.body)

        // register_peer on the SAME surface header, with a descriptive
        // name — per the new instructions contract, this must RENAME the
        // existing bound peer rather than mint a second identity.
        let registerResponse = await server.route(request: mcpRequest(
            token: testToken, surfaceIDHeader: surfaceA.uuidString,
            body: rpcToolCallRequest(id: 2, toolName: "register_peer", arguments: ["name": "my-task", "role": "worker"])
        ))
        XCTAssertEqual(registerResponse.statusCode, 200)
        let renamedPeerID = try peerID(fromToolResultBody: registerResponse.body)

        XCTAssertEqual(renamedPeerID, autoPeerID,
                       "register_peer on a surface with an already-bound, still-alive peer must return " +
                       "the SAME peer_id as initialize's auto-registration (rename, not a new identity)")

        let listResponse = await server.route(request: mcpRequest(
            token: testToken, surfaceIDHeader: nil,
            body: rpcToolCallRequest(id: 3, toolName: "list_peers", arguments: [:])
        ))
        XCTAssertEqual(listResponse.statusCode, 200)
        let listText = try toolResultText(listResponse.body)
        let listJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(listText.utf8)) as? [String: Any])
        let peers = try XCTUnwrap(listJSON["peers"] as? [[String: Any]])

        XCTAssertEqual(peers.count, 1,
                       "Exactly one peer entry must exist for this single pane — no ghost duplicate " +
                       "left behind by the auto-registration")
        XCTAssertEqual(peers.first?["id"] as? String, autoPeerID,
                       "The single surviving entry must be the original auto-registered peer, renamed in place")
        XCTAssertEqual(peers.first?["name"] as? String, "my-task",
                       "The single surviving entry's name must reflect register_peer's rename")
        XCTAssertEqual(peers.first?["role"] as? String, "worker",
                       "The single surviving entry's role must reflect register_peer's rename")
    }

    func test_registerPeer_rename_doesNotBreakMessageDelivery_badgeStillLightsUp() async throws {
        let registry = AgentRegistry()
        server.agentRegistry = registry
        let surfaceA = UUID()

        let initA = await server.route(request: mcpRequest(
            token: testToken, surfaceIDHeader: surfaceA.uuidString, body: initializeRequestBody(id: 1)
        ))
        XCTAssertEqual(initA.statusCode, 200)

        // SessionStart creates surfaceA's Agents sidebar row (independent
        // of the peer binding under test) — this is what carries unreadCount.
        let sessionStart = await server.route(request: agentEventRequest(
            token: testToken, surfaceIDHeader: surfaceA.uuidString,
            body: validAgentEventBody(sessionID: "session-1", cwd: "/Users/dev/repo")
        ))
        XCTAssertEqual(sessionStart.statusCode, 204)

        let registerResponse = await server.route(request: mcpRequest(
            token: testToken, surfaceIDHeader: surfaceA.uuidString,
            body: rpcToolCallRequest(id: 2, toolName: "register_peer", arguments: ["name": "my-task", "role": "worker"])
        ))
        XCTAssertEqual(registerResponse.statusCode, 200)
        let renamedPeerID = try peerID(fromToolResultBody: registerResponse.body)

        // A different peer sends to the RENAMED peer_id.
        let otherPeerID = try await registerPeerID(name: "other")
        let sendResponse = await server.route(request: mcpRequest(
            token: testToken, surfaceIDHeader: nil,
            body: rpcToolCallRequest(id: 3, toolName: "send_message", arguments: [
                "from": otherPeerID, "to": renamedPeerID, "content": "hello after rename",
            ])
        ))
        XCTAssertEqual(sendResponse.statusCode, 200)

        XCTAssertEqual(registry.entries[surfaceA]?.unreadCount, 1,
                       "A message sent to the renamed peer_id must still light up surface A's badge — " +
                       "the rename must not break the surface -> peer binding")
    }

    func test_registerPeer_noSurfaceHeader_alwaysRegistersNewPeer() async throws {
        let registry = AgentRegistry()
        server.agentRegistry = registry

        // An external MCP client without X-Calyx-Surface-ID (e.g. a
        // non-Ghostty-pane client) has no surface binding, so register_peer
        // must keep its pre-Round-6 behavior: always mint a fresh peer.
        // Non-regression — this must pass both before and after the fix.
        let register1 = await server.route(request: mcpRequest(
            token: testToken, surfaceIDHeader: nil,
            body: rpcToolCallRequest(id: 1, toolName: "register_peer", arguments: ["name": "ext-client", "role": "cli"])
        ))
        XCTAssertEqual(register1.statusCode, 200)
        let peer1 = try peerID(fromToolResultBody: register1.body)

        let register2 = await server.route(request: mcpRequest(
            token: testToken, surfaceIDHeader: nil,
            body: rpcToolCallRequest(id: 2, toolName: "register_peer", arguments: ["name": "ext-client-2", "role": "cli"])
        ))
        XCTAssertEqual(register2.statusCode, 200)
        let peer2 = try peerID(fromToolResultBody: register2.body)

        XCTAssertNotEqual(peer1, peer2,
                          "register_peer without a surface header must keep registering brand-new peers " +
                          "every time, exactly like before Round 6 — there is no binding to rename")
    }

    func test_registerPeer_boundPeerNotAliveInStore_selfHeals_createsNewAndRebinds() async throws {
        let registry = AgentRegistry()
        server.agentRegistry = registry
        let surfaceA = UUID()

        // Simulate a stale binding: surfaceA is bound to a peer id that was
        // never registered in (or has since been TTL-purged from) the
        // IPCStore. bindSurface is called directly, standing in for that
        // purge, rather than driving a real TTL expiry through the store.
        let staleBoundPeerID = UUID()
        registry.bindSurface(surfaceA, toPeer: staleBoundPeerID)

        let sessionStart = await server.route(request: agentEventRequest(
            token: testToken, surfaceIDHeader: surfaceA.uuidString,
            body: validAgentEventBody(sessionID: "session-1", cwd: "/Users/dev/repo")
        ))
        XCTAssertEqual(sessionStart.statusCode, 204)

        let registerResponse = await server.route(request: mcpRequest(
            token: testToken, surfaceIDHeader: surfaceA.uuidString,
            body: rpcToolCallRequest(id: 1, toolName: "register_peer", arguments: ["name": "my-task", "role": "worker"])
        ))
        XCTAssertEqual(registerResponse.statusCode, 200)
        let newPeerID = try peerID(fromToolResultBody: registerResponse.body)

        XCTAssertNotEqual(newPeerID, staleBoundPeerID.uuidString,
                          "A stale/purged bound peer must not be resurrected by rename — a fresh peer " +
                          "must be created")

        // Self-repair is observed by continuity: a message sent to the
        // fresh peer id must light up surface A's badge, proving
        // register_peer rebound the surface to the newly created peer.
        let otherPeerID = try await registerPeerID(name: "other")
        let sendResponse = await server.route(request: mcpRequest(
            token: testToken, surfaceIDHeader: nil,
            body: rpcToolCallRequest(id: 2, toolName: "send_message", arguments: [
                "from": otherPeerID, "to": newPeerID, "content": "hello",
            ])
        ))
        XCTAssertEqual(sendResponse.statusCode, 200)

        XCTAssertEqual(registry.entries[surfaceA]?.unreadCount, 1,
                       "register_peer must rebind surfaceA to the freshly created peer when the " +
                       "previously bound peer is no longer alive in the store — self-healing")
    }

    // MARK: - Round 6 review: initialize's auto-registration limited to
    // surface-bound connections
    //
    // The rename semantics above only help a surface-bound pane — an
    // external MCP client with no X-Calyx-Surface-ID (e.g. OpenCode) has
    // no surface for a renamed peer to ever be bound to, so
    // auto-registering one for it on every `initialize` just leaves an
    // orphaned, unaddressable identity behind on every reconnect. Fix:
    // `initialize` now only auto-registers (and binds) a peer when a
    // valid X-Calyx-Surface-ID is present; instructions retain the
    // original "call register_peer yourself" guidance for the no-header
    // case (see MCPProtocolTests' peerID-nil instructions tests).

    func test_initialize_withoutSurfaceHeader_doesNotAutoRegisterPeer() async throws {
        let registry = AgentRegistry()
        server.agentRegistry = registry

        // An already-registered peer, used purely as a vantage point from
        // which to call list_peers before/after — its own registration
        // (via register_peer, not initialize) is unaffected by this fix.
        _ = try await registerPeerID(name: "observer")

        let countBefore = try await currentPeerCount()

        // initialize WITHOUT a surface header — e.g. an OpenCode / generic
        // MCP client that can't send X-Calyx-Surface-ID.
        let initResponse = await server.route(request: mcpRequest(
            token: testToken, surfaceIDHeader: nil, body: initializeRequestBody(id: 2)
        ))
        XCTAssertEqual(initResponse.statusCode, 200, "initialize must still succeed with no surface header")

        let countAfter = try await currentPeerCount()

        XCTAssertEqual(countAfter, countBefore,
                       "initialize without X-Calyx-Surface-ID must not auto-register a new peer — " +
                       "there is no surface to bind it to, so it would just be an orphaned, " +
                       "unaddressable identity")
    }

    /// Calls list_peers (through a fresh, unbound connection) and returns
    /// the current peer count. Helper for
    /// `test_initialize_withoutSurfaceHeader_doesNotAutoRegisterPeer`.
    private func currentPeerCount() async throws -> Int {
        let response = await server.route(request: mcpRequest(
            token: testToken, surfaceIDHeader: nil,
            body: rpcToolCallRequest(id: 999, toolName: "list_peers", arguments: [:])
        ))
        let text = try toolResultText(response.body)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let peers = try XCTUnwrap(json["peers"] as? [[String: Any]])
        return peers.count
    }

    /// Returns `peers` (as parsed from `list_peers`' JSON result) for
    /// assertions that need to inspect a peer's current name/role, not
    /// just its count or id.
    private func listPeersDicts() async throws -> [[String: Any]] {
        let response = await server.route(request: mcpRequest(
            token: testToken, surfaceIDHeader: nil,
            body: rpcToolCallRequest(id: 998, toolName: "list_peers", arguments: [:])
        ))
        XCTAssertEqual(response.statusCode, 200)
        let text = try toolResultText(response.body)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        return try XCTUnwrap(json["peers"] as? [[String: Any]])
    }

    // MARK: - Round 6 fix review: reconnect on an already-bound, still-
    // alive surface must not mint a ghost peer
    //
    // The Round 6 fix above only auto-registers a peer for a surface-bound
    // `initialize`, but it originally still called `registerPeer`
    // unconditionally whenever a surface header was present — including a
    // RECONNECT on a surface that was already bound to a still-alive peer
    // (e.g. an MCP client restart mid-session). That minted a second,
    // ghost identity on every reconnect and reported ITS id back as
    // "already registered", which `register_peer` could then never
    // reproduce — breaking the very promise the Round 6 instructions text
    // makes. Fix: `initialize` on an already-bound surface whose peer is
    // still alive in `IPCStore` reports that SAME peer_id and does
    // nothing else (no new `registerPeer`, no rebind).

    func test_initialize_sameSurfaceReconnect_reportsSamePeerID_singleListPeersEntry_registerPeerAlsoSameID() async throws {
        let registry = AgentRegistry()
        server.agentRegistry = registry
        let surfaceA = UUID()

        let init1 = await server.route(request: mcpRequest(
            token: testToken, surfaceIDHeader: surfaceA.uuidString, body: initializeRequestBody(id: 1)
        ))
        XCTAssertEqual(init1.statusCode, 200)
        let peerID1 = try peerID(fromInitializeResponseBody: init1.body)

        // Reconnect on the SAME surface header (e.g. the MCP client
        // restarted mid-session) while the original peer is still alive.
        let init2 = await server.route(request: mcpRequest(
            token: testToken, surfaceIDHeader: surfaceA.uuidString, body: initializeRequestBody(id: 2)
        ))
        XCTAssertEqual(init2.statusCode, 200)
        let peerID2 = try peerID(fromInitializeResponseBody: init2.body)

        XCTAssertEqual(peerID2, peerID1,
                       "reconnecting on an already-bound, still-alive surface must report the SAME " +
                       "peer_id as the original initialize, not mint a ghost second identity")

        let peers = try await listPeersDicts()
        XCTAssertEqual(peers.count, 1,
                       "a same-surface reconnect must not leave a ghost second list_peers entry behind")

        // register_peer on the reconnected surface must ALSO return the
        // same peer_id, fulfilling the instructions' "already
        // registered... register_peer returns the SAME peer_id" promise
        // even after a reconnect.
        let registerResponse = await server.route(request: mcpRequest(
            token: testToken, surfaceIDHeader: surfaceA.uuidString,
            body: rpcToolCallRequest(id: 3, toolName: "register_peer", arguments: ["name": "renamed", "role": "worker"])
        ))
        XCTAssertEqual(registerResponse.statusCode, 200)
        let registeredPeerID = try peerID(fromToolResultBody: registerResponse.body)
        XCTAssertEqual(registeredPeerID, peerID1,
                       "register_peer after a same-surface reconnect must still return the SAME " +
                       "peer_id as the very first initialize")
    }

    func test_initialize_boundPeerTTLPurged_selfHeals_newPeerIDAndRebinds() async throws {
        let registry = AgentRegistry()
        server.agentRegistry = registry
        let surfaceA = UUID()

        let init1 = await server.route(request: mcpRequest(
            token: testToken, surfaceIDHeader: surfaceA.uuidString, body: initializeRequestBody(id: 1)
        ))
        XCTAssertEqual(init1.statusCode, 200)
        let originalPeerID = try peerID(fromInitializeResponseBody: init1.body)
        let originalUUID = try XCTUnwrap(UUID(uuidString: originalPeerID))

        // Simulate the bound peer having aged out of IPCStore's TTL.
        await server.store._testSetPeerLastSeen(peerId: originalUUID, date: Date().addingTimeInterval(-3600))

        // Give surface A's Agents sidebar row somewhere to observe a badge.
        let sessionStart = await server.route(request: agentEventRequest(
            token: testToken, surfaceIDHeader: surfaceA.uuidString,
            body: validAgentEventBody(sessionID: "session-1", cwd: "/Users/dev/repo")
        ))
        XCTAssertEqual(sessionStart.statusCode, 204)

        let init2 = await server.route(request: mcpRequest(
            token: testToken, surfaceIDHeader: surfaceA.uuidString, body: initializeRequestBody(id: 2)
        ))
        XCTAssertEqual(init2.statusCode, 200)
        let newPeerID = try peerID(fromInitializeResponseBody: init2.body)

        XCTAssertNotEqual(newPeerID, originalPeerID,
                          "a TTL-purged bound peer must not be resurrected by reconnecting — a fresh " +
                          "peer must be minted")

        // Self-repair is observed by continuity: a message sent to the
        // fresh peer id must light up surface A's badge, proving
        // initialize rebound the surface to the newly created peer.
        let otherPeerID = try await registerPeerID(name: "other")
        let sendResponse = await server.route(request: mcpRequest(
            token: testToken, surfaceIDHeader: nil,
            body: rpcToolCallRequest(id: 3, toolName: "send_message", arguments: [
                "from": otherPeerID, "to": newPeerID, "content": "hello",
            ])
        ))
        XCTAssertEqual(sendResponse.statusCode, 200)

        XCTAssertEqual(registry.entries[surfaceA]?.unreadCount, 1,
                       "initialize must rebind surfaceA to the freshly created peer when the " +
                       "previously bound peer has been TTL-purged from the store — self-healing")
    }

    // MARK: - Round 6 fix review: register_peer rename must not blank out
    // an omitted/empty name or role
    //
    // `handleRegisterPeer`'s rename path originally passed the raw
    // `name`/`role` arguments straight through to `IPCStore.updatePeer`,
    // defaulting a missing argument to `""`. A caller that only supplied
    // one of the two (e.g. "just set a descriptive name") therefore wiped
    // out the other field's existing value. Fix: an omitted or
    // empty-string argument is passed through as `nil`, which
    // `updatePeer` treats as "leave this field unchanged".

    func test_registerPeer_rename_missingRoleArgument_preservesExistingRole() async throws {
        let registry = AgentRegistry()
        server.agentRegistry = registry
        let surfaceA = UUID()

        // initialize's auto-registration sets role to "claude-code" (see
        // CalyxMCPServer's `initialize` case) — the value the omitted
        // `role` argument below must not blank out.
        let initA = await server.route(request: mcpRequest(
            token: testToken, surfaceIDHeader: surfaceA.uuidString, body: initializeRequestBody(id: 1)
        ))
        XCTAssertEqual(initA.statusCode, 200)

        let registerResponse = await server.route(request: mcpRequest(
            token: testToken, surfaceIDHeader: surfaceA.uuidString,
            body: rpcToolCallRequest(id: 2, toolName: "register_peer", arguments: ["name": "my-task"])
        ))
        XCTAssertEqual(registerResponse.statusCode, 200)
        let renamedPeerID = try peerID(fromToolResultBody: registerResponse.body)

        let peers = try await listPeersDicts()
        let renamed = try XCTUnwrap(peers.first { $0["id"] as? String == renamedPeerID })

        XCTAssertEqual(renamed["name"] as? String, "my-task", "the supplied name must apply")
        XCTAssertEqual(renamed["role"] as? String, "claude-code",
                       "omitting role from register_peer must preserve initialize's auto-registered " +
                       "role, not blank it out to an empty string")
    }

    func test_registerPeer_rename_emptyNameArgument_preservesExistingName() async throws {
        let registry = AgentRegistry()
        server.agentRegistry = registry
        let surfaceA = UUID()

        // initialize's auto-registration derives name from clientInfo.name
        // ("test", per `initializeRequestBody`) — the value the
        // empty-string `name` argument below must not blank out.
        let initA = await server.route(request: mcpRequest(
            token: testToken, surfaceIDHeader: surfaceA.uuidString, body: initializeRequestBody(id: 1)
        ))
        XCTAssertEqual(initA.statusCode, 200)

        let registerResponse = await server.route(request: mcpRequest(
            token: testToken, surfaceIDHeader: surfaceA.uuidString,
            body: rpcToolCallRequest(id: 2, toolName: "register_peer", arguments: ["name": "", "role": "worker"])
        ))
        XCTAssertEqual(registerResponse.statusCode, 200)
        let renamedPeerID = try peerID(fromToolResultBody: registerResponse.body)

        let peers = try await listPeersDicts()
        let renamed = try XCTUnwrap(peers.first { $0["id"] as? String == renamedPeerID })

        XCTAssertEqual(renamed["name"] as? String, "test",
                       "an empty-string name argument to register_peer must preserve the existing " +
                       "name, not blank it out")
        XCTAssertEqual(renamed["role"] as? String, "worker", "the supplied role must apply")
    }

    // Code review follow-up: a whitespace-only argument (not just the
    // exact empty string `""`) must also be treated as "omitted" — the
    // one case Round 6 specifically set out to protect against, since a
    // caller sending `"name": " "` would otherwise blank out the
    // existing name with a whitespace-only value instead of preserving
    // it. Mirrors the header-parsing trim-before-isEmpty convention used
    // elsewhere in `CalyxMCPServer` (`parseSurfaceID`, the
    // `X-Calyx-Agent-Kind` handling in `routeAgentEvent`).
    func test_registerPeer_rename_whitespaceOnlyNameArgument_preservesExistingName() async throws {
        let registry = AgentRegistry()
        server.agentRegistry = registry
        let surfaceA = UUID()

        // initialize's auto-registration derives name from clientInfo.name
        // ("test", per `initializeRequestBody`) — the value the
        // whitespace-only `name` argument below must not blank out.
        let initA = await server.route(request: mcpRequest(
            token: testToken, surfaceIDHeader: surfaceA.uuidString, body: initializeRequestBody(id: 1)
        ))
        XCTAssertEqual(initA.statusCode, 200)

        let registerResponse = await server.route(request: mcpRequest(
            token: testToken, surfaceIDHeader: surfaceA.uuidString,
            body: rpcToolCallRequest(id: 2, toolName: "register_peer", arguments: ["name": " ", "role": "worker"])
        ))
        XCTAssertEqual(registerResponse.statusCode, 200)
        let renamedPeerID = try peerID(fromToolResultBody: registerResponse.body)

        let peers = try await listPeersDicts()
        let renamed = try XCTUnwrap(peers.first { $0["id"] as? String == renamedPeerID })

        XCTAssertEqual(renamed["name"] as? String, "test",
                       "a whitespace-only name argument to register_peer must preserve the existing " +
                       "name, not overwrite it with whitespace")
        XCTAssertEqual(renamed["role"] as? String, "worker", "the supplied role must apply")
    }

    // MARK: - Round 7: messages are deleted on receive (at-most-once);
    // ack_messages is removed entirely.

    func test_agentEventBinding_sendMessageIncrementsUnreadCount_receiveClearsIt_secondReceiveReturnsEmpty() async throws {
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

        // P2 sends a message to P1 via the real MCP tool-call path.
        let sendRequest = rpcToolCallRequest(id: 2, toolName: "send_message", arguments: [
            "from": p2, "to": p1, "content": "hello from P2",
        ])
        let (sendStatus, _) = await server.handleJSONRPC(data: sendRequest, authToken: testToken)
        XCTAssertEqual(sendStatus, 200)

        XCTAssertEqual(registry.entries[boundSurface]?.unreadCount, 1,
                       "Sending a message to the bound peer must increment the surface row's unreadCount")

        // The FIRST receive_messages call returns the message and clears
        // unreadCount — unchanged from the pre-Round-7 contract.
        let firstReceiveRequest = rpcToolCallRequest(id: 3, toolName: "receive_messages", arguments: ["peer_id": p1])
        let (firstReceiveStatus, firstReceiveBody) = await server.handleJSONRPC(data: firstReceiveRequest, authToken: testToken)
        XCTAssertEqual(firstReceiveStatus, 200)
        let firstMessageIDs = try extractMessageIDs(fromReceiveResultText: try toolResultText(firstReceiveBody))
        XCTAssertEqual(firstMessageIDs.count, 1,
                       "the first receive_messages call must return the one message that was sent")

        XCTAssertEqual(registry.entries[boundSurface]?.unreadCount, 0,
                       "receive_messages must clear the bound surface's unreadCount")

        // Round 7 core contract: a SECOND receive_messages call for the
        // same peer, with nothing new sent in between, must now return
        // an empty array — the message was already deleted from the
        // inbox by the first call (at-most-once delivery), with no
        // separate ack_messages step needed to remove it.
        let secondReceiveRequest = rpcToolCallRequest(id: 4, toolName: "receive_messages", arguments: ["peer_id": p1])
        let (secondReceiveStatus, secondReceiveBody) = await server.handleJSONRPC(data: secondReceiveRequest, authToken: testToken)
        XCTAssertEqual(secondReceiveStatus, 200)
        let secondMessageIDs = try extractMessageIDs(fromReceiveResultText: try toolResultText(secondReceiveBody))
        XCTAssertEqual(secondMessageIDs.count, 0,
                       "a second receive_messages call for the same peer must return no messages — " +
                       "receive_messages deletes on read, so a message is never returned twice")
    }

    func test_ackMessagesToolCall_returnsUnknownToolError() async throws {
        // Round 7: ack_messages is removed entirely — messages are
        // deleted on receive (at-most-once), so there is no longer a
        // separate ack step. A client still holding onto stale
        // instructions/tool list that calls ack_messages anyway must get
        // the same "unknown tool" error any other unrecognized tool name
        // gets, not a working handler.
        let p1 = try await registerPeerID(name: "P1")

        let ackRequest = rpcToolCallRequest(id: 1, toolName: "ack_messages", arguments: [
            "peer_id": p1, "message_ids": [] as [String],
        ])
        let (status, body) = await server.handleJSONRPC(data: ackRequest, authToken: testToken)
        XCTAssertEqual(status, 200, "an unknown-tool error is a 200 with isError:true, not an HTTP failure")

        let text = try toolResultText(body)
        XCTAssertTrue(text.contains("Unknown tool"),
                      "ack_messages must return the same 'Unknown tool: ack_messages' error any other " +
                      "unrecognized tool name gets — got: \(text)")
    }
}
