//
//  CalyxMCPServerTests.swift
//  CalyxTests
//
//  Tests for CalyxMCPServer: the MCP server's handleJSONRPC method
//  (authentication, routing, tool execution) and start/stop lifecycle.
//
//  Coverage:
//  - Authentication: no token, wrong token, correct token
//  - JSON-RPC routing: initialize, tools/list, unknown method, invalid JSON, notification
//  - Tool calls: register_peer, list_peers, send_message (success + errors),
//    receive_messages, broadcast, get_peer_status
//  - Lifecycle: start/stop, rapid toggle
//
//  NOTE: All handleJSONRPC tests exercise the method directly with Data,
//  no actual HTTP networking is involved.
//

import XCTest
@testable import Calyx

@MainActor
final class CalyxMCPServerTests: XCTestCase {

    // MARK: - Properties

    private var server: CalyxMCPServer!
    private let testToken = "test-token-12345"

    /// Test-isolated `agent-endpoint.json` directory. `stop()` (called
    /// from `tearDown` and by `start()` on a toggle) always removes
    /// whatever's at `agentEndpointDirectory`, so every server instance
    /// in this suite — including the ad-hoc `srv` locals in the lifecycle
    /// tests below — must be redirected here rather than touching the
    /// real `~/Library/Application Support/Calyx/agent-endpoint.json`.
    private var agentEndpointDir: String!

    // MARK: - Lifecycle

    override func setUp() {
        super.setUp()
        agentEndpointDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).path
        server = CalyxMCPServer()
        server.agentEndpointDirectory = agentEndpointDir
        // stop() (called unconditionally from tearDown) now also resets
        // agentRegistry; since server.agentRegistry defaults to the true
        // AgentRegistry.shared singleton, every test in this file would
        // otherwise reset shared app-wide state on teardown.
        server.agentRegistry = AgentRegistry()
        // Direct token set for testing, bypassing start() / NWListener
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

    /// Build a JSON-RPC request as Data.
    /// When `id` is nil the resulting object omits the "id" key (notification).
    private func makeRequest(
        id: Int? = 1,
        method: String,
        params: [String: Any]? = nil
    ) -> Data {
        var dict: [String: Any] = ["jsonrpc": "2.0", "method": method]
        if let id { dict["id"] = id }
        if let params { dict["params"] = params }
        return try! JSONSerialization.data(withJSONObject: dict)
    }

    /// Build a JSON-RPC tools/call request.
    private func makeToolCallRequest(
        id: Int = 1,
        toolName: String,
        arguments: [String: Any]
    ) -> Data {
        return makeRequest(id: id, method: "tools/call", params: [
            "name": toolName,
            "arguments": arguments,
        ])
    }

    /// Decode the response body as a JSON dictionary.
    private func responseJSON(_ body: Data?) throws -> [String: Any] {
        let data = try XCTUnwrap(body, "Response body must not be nil")
        let obj = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(obj as? [String: Any], "Response body must be a JSON object")
    }

    /// Extract the "result" field from a JSON-RPC response body.
    private func resultFromBody(_ body: Data?) throws -> [String: Any] {
        let json = try responseJSON(body)
        return try XCTUnwrap(json["result"] as? [String: Any],
                             "Response must contain a 'result' object")
    }

    /// Extract the "error" field from a JSON-RPC response body.
    private func errorFromBody(_ body: Data?) throws -> [String: Any] {
        let json = try responseJSON(body)
        return try XCTUnwrap(json["error"] as? [String: Any],
                             "Response must contain an 'error' object")
    }

    /// Extract the text content from a tool call result.
    /// Tool call results have shape: { content: [{ type: "text", text: "..." }], isError: Bool }
    private func toolCallText(_ body: Data?) throws -> (text: String, isError: Bool) {
        let result = try resultFromBody(body)
        let content = try XCTUnwrap(result["content"] as? [[String: Any]],
                                    "Tool call result must have 'content' array")
        XCTAssertFalse(content.isEmpty, "content array must not be empty")
        let text = try XCTUnwrap(content[0]["text"] as? String,
                                 "First content item must have 'text' string")
        let isError = result["isError"] as? Bool ?? false
        return (text, isError)
    }

    /// Parse a tool call text response as a JSON dictionary.
    private func toolCallJSON(_ body: Data?) throws -> (json: [String: Any], isError: Bool) {
        let (text, isError) = try toolCallText(body)
        let data = Data(text.utf8)
        let obj = try JSONSerialization.jsonObject(with: data)
        let dict = try XCTUnwrap(obj as? [String: Any],
                                 "Tool call text should be parseable JSON object")
        return (dict, isError)
    }

    /// Register a peer via tools/call and return the peer ID.
    @discardableResult
    private func registerPeer(name: String, role: String = "terminal") async throws -> String {
        let data = makeToolCallRequest(toolName: "register_peer", arguments: [
            "name": name,
            "role": role,
        ])
        let (statusCode, body) = await server.handleJSONRPC(data: data, authToken: testToken)
        XCTAssertEqual(statusCode, 200, "register_peer should return 200")
        let (json, isError) = try toolCallJSON(body)
        XCTAssertFalse(isError, "register_peer should not be an error")
        let peerId = try XCTUnwrap(json["peerId"] as? String,
                                   "register_peer result must contain peerId")
        XCTAssertFalse(peerId.isEmpty, "peerId must not be empty")
        return peerId
    }

    // ==================== Authentication Tests ====================

    // 1. No auth token → 401
    func test_handleJSONRPC_noAuth_returns401() async throws {
        // Arrange
        let data = makeRequest(method: "initialize")

        // Act
        let (statusCode, body) = await server.handleJSONRPC(data: data, authToken: nil)

        // Assert
        XCTAssertEqual(statusCode, 401,
                       "Request without auth token must return 401")
        XCTAssertNotNil(body, "401 response should include an error body")
    }

    // 2. Wrong token → 401
    func test_handleJSONRPC_wrongToken_returns401() async throws {
        // Arrange
        let data = makeRequest(method: "initialize")

        // Act
        let (statusCode, body) = await server.handleJSONRPC(data: data, authToken: "wrong-token")

        // Assert
        XCTAssertEqual(statusCode, 401,
                       "Request with wrong auth token must return 401")
        XCTAssertNotNil(body, "401 response should include an error body")
    }

    // 3. Correct token → processes the request (200)
    func test_handleJSONRPC_correctToken_processes() async throws {
        // Arrange
        let data = makeRequest(method: "initialize", params: [
            "protocolVersion": "2024-11-05",
            "capabilities": [:] as [String: Any],
            "clientInfo": ["name": "test", "version": "1.0"],
        ])

        // Act
        let (statusCode, body) = await server.handleJSONRPC(data: data, authToken: testToken)

        // Assert
        XCTAssertEqual(statusCode, 200,
                       "Request with correct auth token must return 200")
        let result = try resultFromBody(body)
        XCTAssertNotNil(result["protocolVersion"],
                        "Initialize result must include protocolVersion")
    }

    // ==================== JSON-RPC Routing Tests ====================

    // 4. "initialize" → result with protocolVersion, capabilities, serverInfo
    func test_handleJSONRPC_initialize_returnsInitResult() async throws {
        // Arrange
        let data = makeRequest(method: "initialize", params: [
            "protocolVersion": "2024-11-05",
            "capabilities": [:] as [String: Any],
            "clientInfo": ["name": "test", "version": "1.0"],
        ])

        // Act
        let (statusCode, body) = await server.handleJSONRPC(data: data, authToken: testToken)

        // Assert
        XCTAssertEqual(statusCode, 200)
        let result = try resultFromBody(body)

        XCTAssertEqual(result["protocolVersion"] as? String, "2024-11-05",
                       "protocolVersion must be 2024-11-05")

        let serverInfo = try XCTUnwrap(result["serverInfo"] as? [String: Any],
                                       "result must contain serverInfo")
        XCTAssertEqual(serverInfo["name"] as? String, "calyx-ipc",
                       "serverInfo.name must be calyx-ipc")
        XCTAssertNotNil(serverInfo["version"],
                        "serverInfo must include version")

        let capabilities = try XCTUnwrap(result["capabilities"] as? [String: Any],
                                         "result must contain capabilities")
        XCTAssertNotNil(capabilities["tools"],
                        "capabilities must include tools")

        let instructions = result["instructions"] as? String
        XCTAssertNotNil(instructions,
                        "result must contain instructions")
        XCTAssertFalse(instructions?.isEmpty ?? true,
                       "instructions must not be empty")
    }

    // 5. "tools/list" → result with the IPC + LSP + terminal_* + Cockpit tool surface (6 + 70 + 3 + 6 = 85)
    func test_handleJSONRPC_toolsList_returnsAllTools() async throws {
        // Arrange
        let data = makeRequest(method: "tools/list")

        // Act
        let (statusCode, body) = await server.handleJSONRPC(data: data, authToken: testToken)

        // Assert
        XCTAssertEqual(statusCode, 200)
        let result = try resultFromBody(body)

        let tools = try XCTUnwrap(result["tools"] as? [[String: Any]],
                                  "tools/list result must contain 'tools' array")
        XCTAssertEqual(tools.count, 85,
                       "tools/list must return 6 IPC + 70 LSP + 3 terminal_* + 6 Cockpit = 85 tools " +
                       "(Round 7 removed ack_messages, P3 added the terminal_* surface, P4 added the ungated " +
                       "Cockpit tools, P5 added the 3 gated ones)")

        let toolNames = Set(tools.compactMap { $0["name"] as? String })
        let expectedIPCNames: Set<String> = [
            "register_peer", "list_peers", "send_message",
            "broadcast", "receive_messages", "get_peer_status",
        ]
        XCTAssertTrue(expectedIPCNames.isSubset(of: toolNames),
                      "tools/list must surface every IPC tool; got: \(toolNames)")
        XCTAssertTrue(toolNames.contains("lsp_hover"),
                      "tools/list must surface the LSP tool catalogue alongside IPC tools")
    }

    // 6. Unknown method → error code -32601
    func test_handleJSONRPC_unknownMethod_returnsError32601() async throws {
        // Arrange
        let data = makeRequest(method: "unknown/method")

        // Act
        let (statusCode, body) = await server.handleJSONRPC(data: data, authToken: testToken)

        // Assert
        XCTAssertEqual(statusCode, 200,
                       "JSON-RPC errors are returned with HTTP 200 per spec")
        let error = try errorFromBody(body)
        XCTAssertEqual(error["code"] as? Int, -32601,
                       "Unknown method must return error code -32601 (Method not found)")
    }

    // 7. Invalid JSON → error code -32700
    func test_handleJSONRPC_invalidJSON_returnsError32700() async throws {
        // Arrange
        let garbage = Data("this is not json {{{{".utf8)

        // Act
        let (statusCode, body) = await server.handleJSONRPC(data: garbage, authToken: testToken)

        // Assert
        XCTAssertEqual(statusCode, 200,
                       "Parse errors are returned with HTTP 200 per JSON-RPC spec")
        let error = try errorFromBody(body)
        XCTAssertEqual(error["code"] as? Int, -32700,
                       "Invalid JSON must return error code -32700 (Parse error)")
    }

    // 8. Notification (no id field) → (204, nil)
    func test_handleJSONRPC_notification_returns204() async throws {
        // Arrange — notification has no "id" key
        let data = makeRequest(id: nil, method: "notifications/initialized")

        // Act
        let (statusCode, body) = await server.handleJSONRPC(data: data, authToken: testToken)

        // Assert
        XCTAssertEqual(statusCode, 204,
                       "Notification (no id) must return 204 No Content")
        XCTAssertNil(body,
                     "Notification response must have nil body")
    }

    // ==================== Tool Call Tests ====================

    // 9. register_peer → returns peer ID
    func test_handleJSONRPC_registerPeer_success() async throws {
        // Arrange
        let data = makeToolCallRequest(toolName: "register_peer", arguments: [
            "name": "terminal-1",
            "role": "terminal",
        ])

        // Act
        let (statusCode, body) = await server.handleJSONRPC(data: data, authToken: testToken)

        // Assert
        XCTAssertEqual(statusCode, 200)
        let (json, isError) = try toolCallJSON(body)
        XCTAssertFalse(isError, "register_peer must not be an error")
        let peerId = json["peerId"] as? String
        XCTAssertNotNil(peerId, "Result must include peerId")
        XCTAssertFalse(peerId?.isEmpty ?? true, "peerId must not be empty")

        // Verify it's a valid UUID
        XCTAssertNotNil(UUID(uuidString: peerId!),
                        "peerId must be a valid UUID string")
    }

    // 10. list_peers after register → returns both peers
    func test_handleJSONRPC_listPeers_afterRegister() async throws {
        // Arrange — register 2 peers
        let peerIdA = try await registerPeer(name: "peer-A", role: "terminal")
        let peerIdB = try await registerPeer(name: "peer-B", role: "plugin")

        // Act
        let data = makeToolCallRequest(toolName: "list_peers", arguments: [:])
        let (statusCode, body) = await server.handleJSONRPC(data: data, authToken: testToken)

        // Assert
        XCTAssertEqual(statusCode, 200)
        let (json, isError) = try toolCallJSON(body)
        XCTAssertFalse(isError, "list_peers must not be an error")

        let peers = try XCTUnwrap(json["peers"] as? [[String: Any]],
                                  "list_peers result must contain 'peers' array")
        XCTAssertEqual(peers.count, 2,
                       "list_peers should return both registered peers")

        let peerIds = Set(peers.compactMap { $0["id"] as? String })
        XCTAssertTrue(peerIds.contains(peerIdA),
                      "list_peers should include peer-A")
        XCTAssertTrue(peerIds.contains(peerIdB),
                      "list_peers should include peer-B")
    }

    // 11. send_message success
    func test_handleJSONRPC_sendMessage_success() async throws {
        // Arrange — register 2 peers
        let peerIdA = try await registerPeer(name: "sender")
        let peerIdB = try await registerPeer(name: "receiver")

        // Act
        let data = makeToolCallRequest(toolName: "send_message", arguments: [
            "from": peerIdA,
            "to": peerIdB,
            "content": "hello from A",
        ])
        let (statusCode, body) = await server.handleJSONRPC(data: data, authToken: testToken)

        // Assert
        XCTAssertEqual(statusCode, 200)
        let (json, isError) = try toolCallJSON(body)
        XCTAssertFalse(isError, "send_message should succeed")
        XCTAssertNotNil(json["messageId"],
                        "send_message result must include messageId")
    }

    // 12. send_message to non-existent peer → isError with "Peer not found"
    func test_handleJSONRPC_sendMessage_unknownPeer_isError() async throws {
        // Arrange — register only the sender
        let peerIdA = try await registerPeer(name: "sender")
        let fakePeerId = UUID().uuidString

        // Act
        let data = makeToolCallRequest(toolName: "send_message", arguments: [
            "from": peerIdA,
            "to": fakePeerId,
            "content": "hello?",
        ])
        let (statusCode, body) = await server.handleJSONRPC(data: data, authToken: testToken)

        // Assert
        XCTAssertEqual(statusCode, 200)
        let (text, isError) = try toolCallText(body)
        XCTAssertTrue(isError,
                      "send_message to unknown peer must set isError: true")
        XCTAssertTrue(text.localizedCaseInsensitiveContains("peer not found"),
                      "Error text must mention 'Peer not found', got: \(text)")
    }

    // 13. send_message from unregistered peer → isError with "register_peer first"
    func test_handleJSONRPC_sendMessage_unregistered_isError() async throws {
        // Arrange — register only the recipient
        let peerIdB = try await registerPeer(name: "receiver")
        let unregisteredId = UUID().uuidString

        // Act
        let data = makeToolCallRequest(toolName: "send_message", arguments: [
            "from": unregisteredId,
            "to": peerIdB,
            "content": "who am I?",
        ])
        let (statusCode, body) = await server.handleJSONRPC(data: data, authToken: testToken)

        // Assert
        XCTAssertEqual(statusCode, 200)
        let (text, isError) = try toolCallText(body)
        XCTAssertTrue(isError,
                      "send_message from unregistered peer must set isError: true")
        XCTAssertTrue(text.localizedCaseInsensitiveContains("register_peer"),
                      "Error text must mention 'register_peer', got: \(text)")
    }

    // 14. receive_messages → returns the sent message
    func test_handleJSONRPC_receiveMessages_returnsMessages() async throws {
        // Arrange — register peers and send a message
        let peerIdA = try await registerPeer(name: "sender")
        let peerIdB = try await registerPeer(name: "receiver")

        let sendData = makeToolCallRequest(toolName: "send_message", arguments: [
            "from": peerIdA,
            "to": peerIdB,
            "content": "test message",
        ])
        let (sendStatus, _) = await server.handleJSONRPC(data: sendData, authToken: testToken)
        XCTAssertEqual(sendStatus, 200, "send_message should succeed")

        // Act — receive messages for peerB
        let recvData = makeToolCallRequest(toolName: "receive_messages", arguments: [
            "peer_id": peerIdB,
        ])
        let (statusCode, body) = await server.handleJSONRPC(data: recvData, authToken: testToken)

        // Assert
        XCTAssertEqual(statusCode, 200)
        let (json, isError) = try toolCallJSON(body)
        XCTAssertFalse(isError, "receive_messages should not be an error")

        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]],
                                     "receive_messages result must contain 'messages' array")
        XCTAssertEqual(messages.count, 1,
                       "Receiver should have exactly 1 message")
        XCTAssertEqual(messages[0]["content"] as? String, "test message",
                       "Message content should match what was sent")
    }

    // 16. broadcast → B and C receive, A does not
    func test_handleJSONRPC_broadcast_success() async throws {
        // Arrange — register 3 peers
        let peerIdA = try await registerPeer(name: "broadcaster")
        let peerIdB = try await registerPeer(name: "listener-B")
        let peerIdC = try await registerPeer(name: "listener-C")

        // Act — broadcast from A
        let data = makeToolCallRequest(toolName: "broadcast", arguments: [
            "from": peerIdA,
            "content": "hello everyone",
        ])
        let (statusCode, body) = await server.handleJSONRPC(data: data, authToken: testToken)

        // Assert
        XCTAssertEqual(statusCode, 200)
        let (_, isError) = try toolCallText(body)
        XCTAssertFalse(isError, "broadcast should not be an error")

        // Verify B received the broadcast
        let recvB = makeToolCallRequest(toolName: "receive_messages", arguments: [
            "peer_id": peerIdB,
        ])
        let (_, bodyB) = await server.handleJSONRPC(data: recvB, authToken: testToken)
        let (jsonB, _) = try toolCallJSON(bodyB)
        let messagesB = jsonB["messages"] as? [[String: Any]] ?? []
        XCTAssertEqual(messagesB.count, 1,
                       "Peer B should receive 1 broadcast message")
        XCTAssertEqual(messagesB.first?["content"] as? String, "hello everyone")

        // Verify C received the broadcast
        let recvC = makeToolCallRequest(toolName: "receive_messages", arguments: [
            "peer_id": peerIdC,
        ])
        let (_, bodyC) = await server.handleJSONRPC(data: recvC, authToken: testToken)
        let (jsonC, _) = try toolCallJSON(bodyC)
        let messagesC = jsonC["messages"] as? [[String: Any]] ?? []
        XCTAssertEqual(messagesC.count, 1,
                       "Peer C should receive 1 broadcast message")

        // Verify A did NOT receive the broadcast
        let recvA = makeToolCallRequest(toolName: "receive_messages", arguments: [
            "peer_id": peerIdA,
        ])
        let (_, bodyA) = await server.handleJSONRPC(data: recvA, authToken: testToken)
        let (jsonA, _) = try toolCallJSON(bodyA)
        let messagesA = jsonA["messages"] as? [[String: Any]] ?? []
        XCTAssertTrue(messagesA.isEmpty,
                      "Broadcaster A should NOT receive their own broadcast")
    }

    // 17. get_peer_status → returns peer info
    func test_handleJSONRPC_getPeerStatus_success() async throws {
        // Arrange
        let peerId = try await registerPeer(name: "status-peer", role: "terminal")

        // Act
        let data = makeToolCallRequest(toolName: "get_peer_status", arguments: [
            "peer_id": peerId,
        ])
        let (statusCode, body) = await server.handleJSONRPC(data: data, authToken: testToken)

        // Assert
        XCTAssertEqual(statusCode, 200)
        let (json, isError) = try toolCallJSON(body)
        XCTAssertFalse(isError, "get_peer_status should not be an error")
        XCTAssertEqual(json["id"] as? String, peerId,
                       "Returned peer id must match the queried id")
        XCTAssertEqual(json["name"] as? String, "status-peer",
                       "Returned peer name must match")
        XCTAssertEqual(json["role"] as? String, "terminal",
                       "Returned peer role must match")
    }

    // ==================== Lifecycle Tests ====================

    // 18. start/stop lifecycle
    func test_startStop_lifecycle() throws {
        // Arrange
        let srv = CalyxMCPServer()
        srv.agentEndpointDirectory = agentEndpointDir
        srv.agentRegistry = AgentRegistry()

        // Pre-condition
        XCTAssertFalse(srv.isRunning,
                       "Server should not be running before start()")
        XCTAssertEqual(srv.port, 0,
                       "Port should be 0 before start()")

        // Act — start
        try srv.start(token: "lifecycle-token")

        // Assert — running
        XCTAssertTrue(srv.isRunning,
                      "Server should be running after start()")
        XCTAssertGreaterThan(srv.port, 0,
                             "Port should be assigned after start()")
        XCTAssertEqual(srv.token, "lifecycle-token",
                       "Token should be set after start()")

        // Act — stop
        srv.stop()

        // Assert — stopped
        XCTAssertFalse(srv.isRunning,
                       "Server should not be running after stop()")
    }

    // 18b. start()/stop() drive AgentRegistry.isServerRunning — AgentStatusView
    // observes AgentRegistry (not CalyxMCPServer, which isn't @Observable)
    // directly, so this is what actually makes the sidebar redraw.
    func test_start_marksAgentRegistryServerRunning_stop_resetsIt() throws {
        let srv = CalyxMCPServer()
        srv.agentEndpointDirectory = agentEndpointDir
        let registry = AgentRegistry()
        srv.agentRegistry = registry
        XCTAssertFalse(registry.isServerRunning,
                       "Precondition: a fresh registry reports the server as not running")

        try srv.start(token: "registry-lifecycle-token")

        XCTAssertTrue(registry.isServerRunning,
                      "start() must mark the injected AgentRegistry as running")

        srv.stop()

        XCTAssertFalse(registry.isServerRunning,
                       "stop() must mark the injected AgentRegistry as not running")
    }

    // 18c. stop() clears every AgentRegistry entry, so disabling IPC (or a
    // start()-triggered restart) doesn't leave stale sidebar rows on screen.
    func test_stop_clearsAgentRegistryEntries() throws {
        let srv = CalyxMCPServer()
        srv.agentEndpointDirectory = agentEndpointDir
        let registry = AgentRegistry()
        srv.agentRegistry = registry
        try srv.start(token: "registry-clear-token")
        registry.handleHookEvent(
            AgentEvent(hookEventName: "SessionStart", sessionID: "s1", cwd: "/tmp/repo", message: nil),
            surfaceID: UUID()
        )
        XCTAssertEqual(registry.entries.count, 1, "Precondition: an entry must exist before stop()")

        srv.stop()

        XCTAssertTrue(registry.entries.isEmpty, "stop() must clear every AgentRegistry entry")
    }

    // 18d. agent-endpoint.json is written into the injected directory on
    // start() and removed from it on stop() — this is what
    // agentEndpointDirectory exists to redirect away from the real
    // ~/Library/Application Support/Calyx path in every test in this suite.
    func test_start_writesAgentEndpointFile_stop_removesIt() throws {
        let srv = CalyxMCPServer()
        srv.agentEndpointDirectory = agentEndpointDir
        srv.agentRegistry = AgentRegistry()

        try srv.start(token: "endpoint-file-token")

        let filePath = agentEndpointDir + "/agent-endpoint.json"
        XCTAssertTrue(FileManager.default.fileExists(atPath: filePath),
                     "start() must write agent-endpoint.json into agentEndpointDirectory")
        let data = try Data(contentsOf: URL(fileURLWithPath: filePath))
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(json?["port"] as? Int, srv.port)
        XCTAssertEqual(json?["token"] as? String, "endpoint-file-token")

        srv.stop()

        XCTAssertFalse(FileManager.default.fileExists(atPath: filePath),
                       "stop() must remove agent-endpoint.json from agentEndpointDirectory")
    }

    // 18e. A failure writing agent-endpoint.json (e.g. a plain file already
    // occupies the configured directory's path) must degrade the Agents
    // sidebar, not the whole IPC server — its MCP tools have nothing to do
    // with this file.
    func test_start_survivesAgentEndpointFileWriteFailure() throws {
        let srv = CalyxMCPServer()
        // A regular file (not a directory) at this path does NOT make
        // AgentEndpointFile.write's `createDirectory` call fail:
        // `fileExists(atPath:)` returns true for a plain file too, so
        // `createDirectory` is skipped entirely. The actual failure
        // happens one step later, inside ConfigFileUtils.atomicWrite:
        // `data.write(to: tempPath)` treats `blockedPath` as an
        // intermediate directory component of `tempPath` and fails with
        // ENOTDIR (the lock file itself lives elsewhere, under Calyx's
        // own Application Support directory, so acquiring it succeeds
        // regardless of `blockedPath`'s validity).
        let blockedPath = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).path
        FileManager.default.createFile(atPath: blockedPath, contents: Data())
        srv.agentEndpointDirectory = blockedPath
        srv.agentRegistry = AgentRegistry()
        defer { try? FileManager.default.removeItem(atPath: blockedPath) }

        try srv.start(token: "survives-endpoint-failure-token")

        XCTAssertTrue(srv.isRunning,
                      "start() must succeed even when agent-endpoint.json can't be written")

        srv.stop()
    }

    // 19. Rapid start/stop toggle — no crash, correct final state
    func test_enableDisable_rapidToggle() throws {
        let srv = CalyxMCPServer()
        srv.agentEndpointDirectory = agentEndpointDir
        srv.agentRegistry = AgentRegistry()

        for i in 0..<10 {
            try srv.start(token: "token-\(i)")
            XCTAssertTrue(srv.isRunning,
                          "Server should be running after start() iteration \(i)")
            srv.stop()
            XCTAssertFalse(srv.isRunning,
                           "Server should not be running after stop() iteration \(i)")
        }

        // Final state must be stopped
        XCTAssertFalse(srv.isRunning,
                       "Server should not be running after all toggle iterations")
        // The test passing without crash is itself a success
    }

    // ==================== Round 5: bound-port recording (task #47) ====================
    //
    // `start(token:preferredPort:)`'s canonical scan passes the *requested*
    // `tryPort` straight to `finishStart(boundPort:)` instead of the port
    // the listener actually bound. With `preferredPort: 0` some
    // environments let the `requiredLocalEndpoint` bind with the literal
    // port 0 reach `.ready` (see `bindListener(onPort:)`'s doc comment,
    // which documents the opposite as the *intended* macOS behavior — the
    // discrepancy is exactly what task #47 flagged as needing a real
    // assertion rather than a comment). When that happens, `self.port`
    // and `agent-endpoint.json`'s `port` both end up `0`, publishing an
    // unreachable endpoint to both MCP clients and calyx-agent-hook.
    //
    // Real Calyx instances hold 41830-41839 on this host, so both tests
    // below stay out of that range: the zero-port test never touches it
    // (kernel fallback lands far above it), and the free-port regression
    // test's `findFreeHighPort()` explicitly excludes it.

    /// Find a free loopback port via `CalyxMCPServer.askKernelForFreeLoopbackPort()`
    /// — Round 5 review made that production method `internal` precisely
    /// so this test suite no longer needs to maintain its own duplicate
    /// BSD-socket probe (see that method's doc comment). Retries if the
    /// kernel hands back a port inside the canonical `41830-41839` scan
    /// window, since the real Calyx app may be holding `41830` on this
    /// host.
    private func findFreeHighPort() -> Int? {
        for _ in 0..<10 {
            guard let port = server.askKernelForFreeLoopbackPort() else { continue }
            if !(41830...41839).contains(port) {
                return port
            }
        }
        return nil
    }

    /// Perform a real HTTP POST to `http://127.0.0.1:<port>/mcp` with an
    /// `initialize` JSON-RPC body — an actual `URLSession` request over a
    /// real socket, not a direct `handleJSONRPC` call, so this exercises
    /// whatever `server.port` claims is reachable. Uses a short request
    /// timeout so an unreachable port (e.g. the port-0 bug under test,
    /// where the published port never matches anything actually bound)
    /// fails fast instead of hanging for `URLSession`'s default 60s.
    /// Returns `(-1, nil)` on any transport-level failure rather than
    /// throwing, so a caller's other assertions in the same test still
    /// run and report their own failures.
    private func sendRealInitializeRequest(
        port: Int,
        token: String
    ) async -> (statusCode: Int, body: Data?) {
        guard let url = URL(string: "http://127.0.0.1:\(port)/mcp") else {
            return (-1, nil)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 3.0
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let bodyDict: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": [
                "protocolVersion": "2024-11-05",
                "capabilities": [:] as [String: Any],
                "clientInfo": ["name": "port-fix-test", "version": "1.0"],
            ],
        ]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: bodyDict) else {
            return (-1, nil)
        }
        request.httpBody = bodyData

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            return (statusCode, data)
        } catch {
            return (-1, nil)
        }
    }

    // 20. RED (task #47): `preferredPort: 0` must record the actual
    // kernel-bound port — `server.port > 0`, `agent-endpoint.json`'s
    // `port` matching that same non-zero value, and the published port
    // reachable over a real HTTP `initialize` call — never the requested
    // value of 0. Pre-fix, the canonical scan's first iteration
    // (`tryPort = 0`) can reach `.ready` and `finishStart(boundPort:
    // tryPort)` then records `self.port = 0` and writes `port: 0` into
    // `agent-endpoint.json`, unreachable by any MCP client or hook.
    // `start()` not throwing is itself part of the contract here — a
    // throw is also treated as a failure below rather than skipped,
    // since "fails to start" is not an acceptable alternative to "starts
    // unreachable".
    func test_start_preferredPortZero_recordsActualBoundPortAndIsReachable() async throws {
        let srv = CalyxMCPServer()
        srv.agentEndpointDirectory = agentEndpointDir
        srv.agentRegistry = AgentRegistry()
        let token = "port-zero-token"

        do {
            try srv.start(token: token, preferredPort: 0)
        } catch {
            XCTFail(
                """
                start(preferredPort: 0) must not throw — it must fall \
                back to a kernel-assigned ephemeral port and record the \
                actual bound port. Threw: \(error)
                """
            )
            return
        }

        // (a) server.port must be the actual bound port, not the
        // requested 0.
        XCTAssertGreaterThan(
            srv.port, 0,
            "server.port must be the actual kernel-bound port after preferredPort: 0, not the requested value 0"
        )

        // (b) agent-endpoint.json must publish that same non-zero port.
        let filePath = agentEndpointDir + "/agent-endpoint.json"
        let fileData = try Data(contentsOf: URL(fileURLWithPath: filePath))
        let fileJSON = try JSONSerialization.jsonObject(with: fileData) as? [String: Any]
        let publishedPort = fileJSON?["port"] as? Int
        XCTAssertEqual(
            publishedPort, srv.port,
            "agent-endpoint.json's port must match server.port exactly; got \(String(describing: publishedPort)) vs server.port=\(srv.port)"
        )
        XCTAssertNotEqual(
            publishedPort, 0,
            "agent-endpoint.json must not publish port: 0 — calyx-agent-hook cannot reach that"
        )

        // (c) the published port must actually be reachable over a real
        // HTTP connection.
        let (statusCode, body) = await sendRealInitializeRequest(port: srv.port, token: token)
        XCTAssertEqual(
            statusCode, 200,
            "http://127.0.0.1:\(srv.port)/mcp must accept a real HTTP initialize request and return 200"
        )
        if statusCode == 200 {
            let result = try? resultFromBody(body)
            XCTAssertNotNil(
                result?["protocolVersion"],
                "initialize response over the real bound port must contain protocolVersion"
            )
        }

        srv.stop()
    }

    // 21. Regression (should stay GREEN both pre- and post-fix): a free
    // high port passed as `preferredPort` must record exactly that port.
    // The canonical scan's first iteration binds it and `finishStart`
    // records `tryPort == preferredPort` — this is the common,
    // already-working path the port-0 fix must not disturb.
    func test_start_freeHighPort_recordsRequestedPort() throws {
        guard let freePort = findFreeHighPort() else {
            throw XCTSkip("Could not find a free loopback port to use as preferredPort on this host")
        }

        let srv = CalyxMCPServer()
        srv.agentEndpointDirectory = agentEndpointDir
        srv.agentRegistry = AgentRegistry()

        try srv.start(token: "free-high-port-token", preferredPort: freePort)

        XCTAssertEqual(
            srv.port, freePort,
            "start() with a free preferredPort must record exactly that requested port"
        )

        srv.stop()
    }

    // 22. RED: TCP-level split between the HTTP header segment and the
    // body segment. `handleConnection` passes whatever a *single*
    // `NWConnection.receive` call returns straight to `HTTPParser.parse`
    // without re-issuing `receive` for a request whose `Content-Length`
    // promises more body than actually arrived in that one read.
    // `HTTPParser.parse` doesn't treat that as an error either — with
    // the body segment not yet present, `bodyStart == data.endIndex`
    // and the parsed `HTTPRequest.body` is silently left `nil` rather
    // than an `HTTPParseError` being thrown, so `routeMCP`'s `guard let
    // body else { 400 }` fires on a request that is actually
    // well-formed, just not fully arrived yet. Reproduced here by
    // sending the header segment (through the terminating `\r\n\r\n`)
    // and the JSON body as two separate `send()` calls over a raw BSD
    // socket, with a sleep between them to force the server's
    // `receive` callback to fire on the header-only segment first —
    // this is the failure mode behind
    // `test_start_preferredPortZero_recordsActualBoundPortAndIsReachable`
    // intermittently seeing a 400 instead of 200 in full-suite runs.
    func test_realHTTPRequest_headersAndBodySplitAcrossTCPSegments_stillParsesCompleteRequest() async throws {
        let srv = CalyxMCPServer()
        srv.agentEndpointDirectory = agentEndpointDir
        srv.agentRegistry = AgentRegistry()
        let token = "split-segment-token"

        try srv.start(token: token, preferredPort: 0)
        let port = srv.port
        XCTAssertGreaterThan(port, 0, "Precondition: server must be bound to a real, reachable port")

        // Off the @MainActor entirely (Task.detached + a `nonisolated`
        // helper) so the blocking BSD socket calls below — including
        // the deliberate sleep between the two `send()`s — never
        // occupy the main thread the server's own
        // `Task { @MainActor in ... }` connection handling needs to
        // run on.
        let statusCode = try await Task.detached {
            try sendSplitInitializeRequestOverRawSocket(port: port, token: token)
        }.value

        XCTAssertEqual(
            statusCode, 200,
            """
            A request whose header segment (ending in \\r\\n\\r\\n) and \
            Content-Length-declared body arrive as two separate TCP \
            segments must still be parsed as one complete request once \
            the body arrives — not answered with 400 off the \
            header-only segment.
            """
        )

        srv.stop()
    }

    // ==================== Round 5 review fixes ====================

    // Fix 1 (pre-auth DoS / integer overflow): a `Content-Length` near
    // `Int.max` must be rejected with 413 immediately, not crash the
    // process by overflowing `headerLength + contentLength` inside
    // `HTTPParser.completeness(of:)`.
    func test_contentLengthNearIntMax_doesNotCrash_returns413() async throws {
        let srv = CalyxMCPServer()
        srv.agentEndpointDirectory = agentEndpointDir
        srv.agentRegistry = AgentRegistry()
        let token = "overflow-token"

        try srv.start(token: token, preferredPort: 0)
        let port = srv.port

        let statusCode = try await Task.detached {
            try sendHeadersOnlyOverRawSocket(port: port, token: token, declaredBodyLength: Int.max)
        }.value

        XCTAssertEqual(
            statusCode, 413,
            """
            An absurd Content-Length (Int.max) must be rejected with 413 \
            immediately — not crash the process via integer overflow, \
            and not wait for a body that will never fully arrive.
            """
        )

        srv.stop()
    }

    // Fix 1 / 3 (gate-vs-parse 413 threshold mismatch): a Content-Length
    // just over maxBodySize must be rejected with 413 as soon as the
    // header block arrives, without ever waiting to receive
    // maxBodySize+1 bytes of body that were never sent.
    func test_contentLengthJustOverMaxBodySize_headersOnlySent_returns413Promptly() async throws {
        let srv = CalyxMCPServer()
        srv.agentEndpointDirectory = agentEndpointDir
        srv.agentRegistry = AgentRegistry()
        let token = "oversized-body-token"

        try srv.start(token: token, preferredPort: 0)
        let port = srv.port

        let statusCode = try await Task.detached {
            try sendHeadersOnlyOverRawSocket(port: port, token: token, declaredBodyLength: HTTPParser.maxBodySize + 1)
        }.value

        XCTAssertEqual(
            statusCode, 413,
            """
            A Content-Length just over maxBodySize must be rejected with \
            413 as soon as the header block arrives, not left waiting \
            for a body that was never sent.
            """
        )

        srv.stop()
    }

    // Fix 2 (deadline scope): receiving is fast, but `route(request:)`
    // itself (simulated via the `_testRouteDelay` hook — standing in
    // for a slow `lsp_*` tool call, which can legitimately run for up
    // to an hour) outlasts the — deliberately shortened for this test —
    // receive-only deadline. The real response must still come back,
    // never a spurious 408.
    func test_slowRouteProcessing_doesNotTriggerReceiveDeadline408() async throws {
        let srv = CalyxMCPServer()
        srv.agentEndpointDirectory = agentEndpointDir
        srv.agentRegistry = AgentRegistry()
        srv.connectionReceiveDeadline = .milliseconds(100)
        srv._testRouteDelay = .milliseconds(400)
        let token = "slow-route-token"

        try srv.start(token: token, preferredPort: 0)
        let port = srv.port

        let (statusCode, body) = await sendRealInitializeRequest(port: port, token: token)

        XCTAssertEqual(
            statusCode, 200,
            """
            route(request:) outlasting the (shortened) receive-only \
            deadline must not be cut off with 408 — the deadline bounds \
            receiving the request, not processing it.
            """
        )
        if statusCode == 200 {
            let result = try? resultFromBody(body)
            XCTAssertNotNil(result?["protocolVersion"], "The real initialize response must still come back once route(request:) finishes")
        }

        srv.stop()
    }

    // Fix 2 (slow-loris guard retained): headers arrive, but the
    // Content-Length-declared body never does. The connection must
    // eventually be cut off with 408 by `connectionReceiveDeadline`
    // (shortened for this test), not left open indefinitely.
    func test_headersOnlyNoBodySent_hitsReceiveDeadline_returns408() async throws {
        let srv = CalyxMCPServer()
        srv.agentEndpointDirectory = agentEndpointDir
        srv.agentRegistry = AgentRegistry()
        srv.connectionReceiveDeadline = .milliseconds(300)
        let token = "headers-only-token"

        try srv.start(token: token, preferredPort: 0)
        let port = srv.port

        let statusCode = try await Task.detached {
            try sendHeadersOnlyOverRawSocket(port: port, token: token, declaredBodyLength: 100, recvTimeoutSeconds: 5)
        }.value

        XCTAssertEqual(
            statusCode, 408,
            """
            A connection whose headers arrive but whose declared body \
            never does must be cut off by the receive-only deadline \
            with 408, not left open indefinitely.
            """
        )

        srv.stop()
    }

    // Critical (Round 5 final review): the receive-deadline Task's 408
    // send calls `connection.cancel()`, which completes the
    // still-outstanding `receive()` call `receiveUntilComplete` had
    // re-issued while waiting for the (never-sent) body. That
    // completion used to re-enter `receiveUntilComplete`'s
    // `isComplete || error != nil` branch — indistinguishable there
    // from a genuine peer close — and send a *second*, spurious
    // response (a 400, since the accumulated buffer has headers but no
    // body) on the connection the 408 had already cancelled.
    // `sendHTTPResponse`'s `accumulator.didRespond` check-and-set is
    // what now guarantees only the first of the two ever actually
    // sends. `readRawSocketStatusCode` (used by the sibling test above)
    // only inspects the *first* status line and would not have caught
    // a second response silently concatenated after it — this test
    // reads the complete raw response text instead and asserts there
    // is exactly one HTTP status line in it.
    func test_headersOnlyRequest_neverReceivesASecondResponseAfter408() async throws {
        let srv = CalyxMCPServer()
        srv.agentEndpointDirectory = agentEndpointDir
        srv.agentRegistry = AgentRegistry()
        srv.connectionReceiveDeadline = .milliseconds(300)
        let token = "headers-only-double-send-token"

        try srv.start(token: token, preferredPort: 0)
        let port = srv.port

        let fullResponse = try await Task.detached {
            try sendHeadersOnlyOverRawSocketFullResponse(port: port, token: token, declaredBodyLength: 100, recvTimeoutSeconds: 5)
        }.value

        // Give any stale, already-outstanding `receive()` a chance to
        // complete and (pre-fix) attempt a second response even after
        // the client above has already finished reading and closed its
        // side. `_testSendHTTPResponseSentCount` — not a second
        // response actually landing on the wire, and not
        // `_testSendHTTPResponseAttemptCount` either — is the reliable
        // correctness signal here: this scenario deterministically
        // enters `sendHTTPResponse` *twice* (the deadline's 408, then a
        // stale `finishRequest` triggered by that 408's own
        // `connection.cancel()` completing the still-outstanding
        // `receive()` from before) even with the fix in place — the
        // fix's job is only to make the second entry a no-op past its
        // `accumulator.didRespond` guard, not to prevent the entry
        // itself. See both counters' doc comments on `CalyxMCPServer`.
        try? await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(
            srv._testSendHTTPResponseAttemptCount, 2,
            """
            Precondition: this scenario is expected to deterministically \
            enter sendHTTPResponse twice for one connection (the \
            deadline's 408, then a stale finishRequest unblocked by that \
            408's own connection.cancel()) — if this ever reads 1, the \
            race this test exercises isn't actually happening anymore \
            and the test should be revisited.
            """
        )
        XCTAssertEqual(
            srv._testSendHTTPResponseSentCount, 1,
            "Exactly one of the two sendHTTPResponse entries above must actually proceed to connection.send(...) — the accumulator.didRespond guard must block the other"
        )

        let responseCount = fullResponse.components(separatedBy: "HTTP/1.1 ").count - 1
        XCTAssertEqual(
            responseCount, 1,
            """
            Exactly one HTTP response must reach the client on this \
            connection — got \(responseCount) concatenated response(s). \
            Full response: \(fullResponse)
            """
        )
        XCTAssertTrue(
            fullResponse.hasPrefix("HTTP/1.1 408"),
            "The single response must be the 408 the receive-only deadline sends. Full response: \(fullResponse)"
        )

        srv.stop()
    }

    // Fix 4 (O(n²) accumulation → linear): a request split into many
    // single-byte TCP segments — the extreme case for
    // `CalyxMCPServer.ReceiveAccumulator`'s append loop — must still
    // assemble into one complete, correctly-parsed request. Doesn't
    // assert on timing/complexity directly (that would be a flaky
    // benchmark); it's a functional regression test for the refactor
    // from a per-call `Data` parameter to the reference-typed
    // accumulator with a cached `requiredTotal`.
    func test_manySingleByteChunksAcrossTCP_stillAssemblesOneCompleteRequest() async throws {
        let srv = CalyxMCPServer()
        srv.agentEndpointDirectory = agentEndpointDir
        srv.agentRegistry = AgentRegistry()
        let token = "many-chunks-token"

        try srv.start(token: token, preferredPort: 0)
        let port = srv.port

        let bodyDict: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": [
                "protocolVersion": "2024-11-05",
                "capabilities": [:] as [String: Any],
                "clientInfo": ["name": "many-chunks-test", "version": "1.0"],
            ],
        ]
        let bodyData = try JSONSerialization.data(withJSONObject: bodyDict)

        var headerString = "POST /mcp HTTP/1.1\r\n"
        headerString += "Host: 127.0.0.1:\(port)\r\n"
        headerString += "Authorization: Bearer \(token)\r\n"
        headerString += "Content-Type: application/json\r\n"
        headerString += "Content-Length: \(bodyData.count)\r\n"
        headerString += "Connection: close\r\n"
        headerString += "\r\n"
        let headerData = Data(headerString.utf8)

        var chunks: [Data] = []
        chunks.append(contentsOf: headerData.map { Data([$0]) })
        chunks.append(contentsOf: bodyData.map { Data([$0]) })

        let statusCode = try await Task.detached {
            try sendChunkedRequestOverRawSocket(port: port, chunks: chunks)
        }.value

        XCTAssertEqual(
            statusCode, 200,
            "A request split into many single-byte TCP segments must still assemble into one complete, correctly-parsed request"
        )

        srv.stop()
    }

    // Fix 5 (bindKernelAssignedListener port-readback symmetry): the
    // returned port must match the listener's own resolved
    // `nl.port?.rawValue`, not merely the pre-bind BSD-socket probe
    // value — exercised directly now that Round 5 review made this
    // method `internal` for testability.
    func test_bindKernelAssignedListener_recordsListenersActualResolvedPort() throws {
        let srv = CalyxMCPServer()

        guard let (listener, port) = srv.bindKernelAssignedListener() else {
            XCTFail("bindKernelAssignedListener should succeed on a host with free ephemeral loopback ports available")
            return
        }
        defer { listener.cancel() }

        XCTAssertGreaterThan(port, 0, "Returned port must be a real, non-zero bound port")
        XCTAssertEqual(
            Int(listener.port?.rawValue ?? 0), port,
            "The returned port must match the listener's own resolved port, not merely the pre-bind BSD-socket probe value"
        )
    }

}

/// Connects to `127.0.0.1:port` over a raw BSD socket and sends an
/// `initialize` JSON-RPC request's HTTP header block and JSON body as
/// two separate `send()` calls, sleeping between them, to force the
/// server's `NWConnection.receive` callback to fire on the header-only
/// segment before the body segment arrives. Returns the numeric HTTP
/// status code parsed from the response's status line.
///
/// Declared at file scope (not as a method on
/// `CalyxMCPServerTests`) so it carries no `@MainActor` isolation and
/// can run synchronously inside `Task.detached` — a same-actor
/// blocking call here would starve the server's own
/// connection-handling Task and deadlock the test.
private func sendSplitInitializeRequestOverRawSocket(port: Int, token: String) throws -> Int {
    let bodyDict: [String: Any] = [
        "jsonrpc": "2.0",
        "id": 1,
        "method": "initialize",
        "params": [
            "protocolVersion": "2024-11-05",
            "capabilities": [:] as [String: Any],
            "clientInfo": ["name": "split-segment-test", "version": "1.0"],
        ],
    ]
    let bodyData = try JSONSerialization.data(withJSONObject: bodyDict)

    var headerString = "POST /mcp HTTP/1.1\r\n"
    headerString += "Host: 127.0.0.1:\(port)\r\n"
    headerString += "Authorization: Bearer \(token)\r\n"
    headerString += "Content-Type: application/json\r\n"
    headerString += "Content-Length: \(bodyData.count)\r\n"
    headerString += "Connection: close\r\n"
    headerString += "\r\n"
    let headerData = Data(headerString.utf8)

    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = UInt16(port).bigEndian
    addr.sin_addr.s_addr = UInt32(0x7F00_0001).bigEndian  // 127.0.0.1
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)

    let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
    guard fd >= 0 else {
        throw NSError(domain: "SplitSegmentTest", code: 1, userInfo: [NSLocalizedDescriptionKey: "socket() failed: errno \(errno)"])
    }
    defer { close(fd) }

    // Fail fast instead of hanging if the server never answers.
    var recvTimeout = timeval(tv_sec: 5, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &recvTimeout, socklen_t(MemoryLayout<timeval>.size))

    let connectResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
            Darwin.connect(fd, saPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard connectResult == 0 else {
        throw NSError(domain: "SplitSegmentTest", code: 2, userInfo: [NSLocalizedDescriptionKey: "connect() to 127.0.0.1:\(port) failed: errno \(errno)"])
    }

    // Segment 1: everything through the header/body separator.
    try headerData.withUnsafeBytes { (rawBuf: UnsafeRawBufferPointer) in
        let sent = Darwin.send(fd, rawBuf.baseAddress, rawBuf.count, 0)
        guard sent == rawBuf.count else {
            throw NSError(domain: "SplitSegmentTest", code: 3, userInfo: [NSLocalizedDescriptionKey: "send(headers) sent \(sent)/\(rawBuf.count) bytes, errno \(errno)"])
        }
    }

    // Give the server's single `receive` callback a chance to fire on
    // the header-only segment before segment 2 arrives.
    usleep(80_000) // 80ms

    // Segment 2: the JSON body, declared by Content-Length above but
    // not yet sent.
    try bodyData.withUnsafeBytes { (rawBuf: UnsafeRawBufferPointer) in
        let sent = Darwin.send(fd, rawBuf.baseAddress, rawBuf.count, 0)
        guard sent == rawBuf.count else {
            throw NSError(domain: "SplitSegmentTest", code: 4, userInfo: [NSLocalizedDescriptionKey: "send(body) sent \(sent)/\(rawBuf.count) bytes, errno \(errno)"])
        }
    }

    // Read the response until the peer closes (the server always
    // responds with `Connection: close`).
    var responseData = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
        let received = buffer.withUnsafeMutableBytes { rawBuf -> Int in
            Darwin.recv(fd, rawBuf.baseAddress, rawBuf.count, 0)
        }
        if received <= 0 { break }
        responseData.append(contentsOf: buffer[0..<received])
    }

    guard let responseString = String(data: responseData, encoding: .utf8) else {
        throw NSError(domain: "SplitSegmentTest", code: 5, userInfo: [NSLocalizedDescriptionKey: "response was not valid UTF-8: \(responseData.count) bytes"])
    }
    let statusLine = responseString.components(separatedBy: "\r\n").first ?? ""
    let parts = statusLine.split(separator: " ", maxSplits: 2)
    guard parts.count >= 2, let statusCode = Int(parts[1]) else {
        throw NSError(domain: "SplitSegmentTest", code: 6, userInfo: [NSLocalizedDescriptionKey: "could not parse status code from response: \(responseString)"])
    }
    return statusCode
}

/// Reads a raw-socket response (already fully written to `fd` by the
/// caller) until the peer closes, returning the complete decoded text
/// — which, per the Round 5 final review's Critical finding, may
/// contain *more than one* concatenated HTTP response if
/// `CalyxMCPServer` double-sends on this connection. Callers that only
/// care about the first response's status code should go through
/// `readRawSocketStatusCode`; callers checking for a double-send (e.g.
/// `test_headersOnlyRequest_neverReceivesASecondResponseAfter408`)
/// need the raw text itself.
private func readRawSocketFullResponseText(fd: Int32, errorDomain: String) throws -> String {
    var responseData = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
        let received = buffer.withUnsafeMutableBytes { rawBuf -> Int in
            Darwin.recv(fd, rawBuf.baseAddress, rawBuf.count, 0)
        }
        if received <= 0 { break }
        responseData.append(contentsOf: buffer[0..<received])
    }

    guard let responseString = String(data: responseData, encoding: .utf8) else {
        throw NSError(domain: errorDomain, code: 5, userInfo: [NSLocalizedDescriptionKey: "response was not valid UTF-8: \(responseData.count) bytes"])
    }
    return responseString
}

/// Reads a raw-socket HTTP response until the peer closes and parses
/// the numeric status code from its *first* status line only. Built on
/// `readRawSocketFullResponseText` — shared tail end for every
/// raw-socket test helper in this file except
/// `sendSplitInitializeRequestOverRawSocket`, which keeps its own
/// inline copy (predates this one) rather than being rewired to it, to
/// avoid touching a helper an already-green test depends on.
///
/// Deliberately blind to whatever follows the first status line — a
/// second, concatenated HTTP response would be silently absorbed here
/// without failing anything (this is exactly why the Round 5 final
/// review's Critical double-send bug went undetected by every test
/// built on this helper until `readRawSocketFullResponseText` was
/// added alongside it). Callers that need to assert "at most one
/// response" must use `readRawSocketFullResponseText` directly instead.
private func readRawSocketStatusCode(fd: Int32, errorDomain: String) throws -> Int {
    let responseString = try readRawSocketFullResponseText(fd: fd, errorDomain: errorDomain)
    let statusLine = responseString.components(separatedBy: "\r\n").first ?? ""
    let parts = statusLine.split(separator: " ", maxSplits: 2)
    guard parts.count >= 2, let statusCode = Int(parts[1]) else {
        throw NSError(domain: errorDomain, code: 6, userInfo: [NSLocalizedDescriptionKey: "could not parse status code from response: \(responseString)"])
    }
    return statusCode
}

/// Opens a raw BSD socket to `127.0.0.1:port` with `SO_RCVTIMEO` set to
/// `recvTimeoutSeconds`. Shared connection setup for
/// `sendHeadersOnlyOverRawSocket` and `sendChunkedRequestOverRawSocket`
/// below.
private func openRawSocketToLoopback(port: Int, recvTimeoutSeconds: Int32, errorDomain: String) throws -> Int32 {
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = UInt16(port).bigEndian
    addr.sin_addr.s_addr = UInt32(0x7F00_0001).bigEndian  // 127.0.0.1
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)

    let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
    guard fd >= 0 else {
        throw NSError(domain: errorDomain, code: 1, userInfo: [NSLocalizedDescriptionKey: "socket() failed: errno \(errno)"])
    }

    var recvTimeout = timeval(tv_sec: Int(recvTimeoutSeconds), tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &recvTimeout, socklen_t(MemoryLayout<timeval>.size))

    let connectResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
            Darwin.connect(fd, saPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard connectResult == 0 else {
        close(fd)
        throw NSError(domain: errorDomain, code: 2, userInfo: [NSLocalizedDescriptionKey: "connect() to 127.0.0.1:\(port) failed: errno \(errno)"])
    }
    return fd
}

/// Connects to `127.0.0.1:port` and sends only an HTTP header block
/// (through the terminating `\r\n\r\n`) — declaring `declaredBodyLength`
/// in `Content-Length` but never actually sending a body at all. Shared
/// send-only half of `sendHeadersOnlyOverRawSocket` /
/// `sendHeadersOnlyOverRawSocketFullResponse` below — returns the
/// connected socket, still open, with the header block already
/// written; the caller is responsible for reading the response and
/// closing it.
private func sendHeadersOnlyRequest(
    port: Int,
    token: String,
    declaredBodyLength: Int,
    recvTimeoutSeconds: Int32,
    errorDomain: String
) throws -> Int32 {
    var headerString = "POST /mcp HTTP/1.1\r\n"
    headerString += "Host: 127.0.0.1:\(port)\r\n"
    headerString += "Authorization: Bearer \(token)\r\n"
    headerString += "Content-Type: application/json\r\n"
    headerString += "Content-Length: \(declaredBodyLength)\r\n"
    headerString += "Connection: close\r\n"
    headerString += "\r\n"
    let headerData = Data(headerString.utf8)

    let fd = try openRawSocketToLoopback(port: port, recvTimeoutSeconds: recvTimeoutSeconds, errorDomain: errorDomain)

    do {
        try headerData.withUnsafeBytes { (rawBuf: UnsafeRawBufferPointer) in
            let sent = Darwin.send(fd, rawBuf.baseAddress, rawBuf.count, 0)
            guard sent == rawBuf.count else {
                throw NSError(domain: errorDomain, code: 3, userInfo: [NSLocalizedDescriptionKey: "send(headers) sent \(sent)/\(rawBuf.count) bytes, errno \(errno)"])
            }
        }
    } catch {
        close(fd)
        throw error
    }

    // Deliberately never sends a body — `declaredBodyLength` in
    // Content-Length is a promise the server must not keep waiting on
    // forever.
    return fd
}

/// Used by the Round 5 review regression tests for the size gate (an
/// absurd `declaredBodyLength` must be rejected immediately, before the
/// connection ever waits for a body) and the receive-only deadline (a
/// `declaredBodyLength` within bounds, but never satisfied, must
/// eventually be cut off with 408). Returns the numeric HTTP status
/// code parsed from the response's *first* status line only — see
/// `sendHeadersOnlyOverRawSocketFullResponse` for a variant that
/// returns the complete raw text instead.
///
/// Declared at file scope for the same reason as
/// `sendSplitInitializeRequestOverRawSocket`: no `@MainActor`
/// isolation, so it can block synchronously inside `Task.detached`
/// without starving the server's own connection-handling Task.
private func sendHeadersOnlyOverRawSocket(
    port: Int,
    token: String,
    declaredBodyLength: Int,
    recvTimeoutSeconds: Int32 = 5
) throws -> Int {
    let errorDomain = "HeadersOnlyTest"
    let fd = try sendHeadersOnlyRequest(port: port, token: token, declaredBodyLength: declaredBodyLength, recvTimeoutSeconds: recvTimeoutSeconds, errorDomain: errorDomain)
    defer { close(fd) }
    return try readRawSocketStatusCode(fd: fd, errorDomain: errorDomain)
}

/// Like `sendHeadersOnlyOverRawSocket`, but returns the complete raw
/// response text instead of just the first status code. Used by
/// `test_headersOnlyRequest_neverReceivesASecondResponseAfter408` to
/// assert at most one HTTP response ever comes back on the connection
/// — the Round 5 final review's Critical finding was exactly that
/// `readRawSocketStatusCode`-based assertions alone cannot detect a
/// second, concatenated response following the first.
private func sendHeadersOnlyOverRawSocketFullResponse(
    port: Int,
    token: String,
    declaredBodyLength: Int,
    recvTimeoutSeconds: Int32 = 5
) throws -> String {
    let errorDomain = "HeadersOnlyFullResponseTest"
    let fd = try sendHeadersOnlyRequest(port: port, token: token, declaredBodyLength: declaredBodyLength, recvTimeoutSeconds: recvTimeoutSeconds, errorDomain: errorDomain)
    defer { close(fd) }
    return try readRawSocketFullResponseText(fd: fd, errorDomain: errorDomain)
}

/// Connects to `127.0.0.1:port` and sends `chunks` as `chunks.count`
/// separate `send()` calls — one `NWConnection.receive` callback per
/// chunk on the server side, in the common case — forcing
/// `CalyxMCPServer.ReceiveAccumulator` to accumulate one logical
/// request across many small appends. Returns the numeric HTTP status
/// code parsed from the response's status line.
///
/// Declared at file scope for the same reason as
/// `sendSplitInitializeRequestOverRawSocket`.
private func sendChunkedRequestOverRawSocket(port: Int, chunks: [Data], recvTimeoutSeconds: Int32 = 5) throws -> Int {
    let errorDomain = "ChunkedRequestTest"
    let fd = try openRawSocketToLoopback(port: port, recvTimeoutSeconds: recvTimeoutSeconds, errorDomain: errorDomain)
    defer { close(fd) }

    for (index, chunk) in chunks.enumerated() {
        try chunk.withUnsafeBytes { (rawBuf: UnsafeRawBufferPointer) in
            guard rawBuf.count > 0 else { return }
            let sent = Darwin.send(fd, rawBuf.baseAddress, rawBuf.count, 0)
            guard sent == rawBuf.count else {
                throw NSError(domain: errorDomain, code: 3, userInfo: [NSLocalizedDescriptionKey: "send(chunk \(index)) sent \(sent)/\(rawBuf.count) bytes, errno \(errno)"])
            }
        }
    }

    return try readRawSocketStatusCode(fd: fd, errorDomain: errorDomain)
}
