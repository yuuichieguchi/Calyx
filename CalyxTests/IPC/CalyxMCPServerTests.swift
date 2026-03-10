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
//    receive_messages, ack_messages, broadcast, get_peer_status
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

    // MARK: - Lifecycle

    override func setUp() {
        super.setUp()
        server = CalyxMCPServer()
        // Direct token set for testing, bypassing start() / NWListener
        server._testSetToken(testToken)
    }

    override func tearDown() {
        server.stop()
        server = nil
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
    }

    // 5. "tools/list" → result with 7 tools
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
        XCTAssertEqual(tools.count, 7,
                       "tools/list must return exactly 7 tools")

        let toolNames = Set(tools.compactMap { $0["name"] as? String })
        let expectedNames: Set<String> = [
            "register_peer", "list_peers", "send_message",
            "broadcast", "receive_messages", "ack_messages", "get_peer_status",
        ]
        XCTAssertEqual(toolNames, expectedNames,
                       "tools/list must return the 7 expected tool names")
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

    // 15. ack_messages → receive again returns empty
    func test_handleJSONRPC_ackMessages_removesMessages() async throws {
        // Arrange — register, send, receive to get the message ID
        let peerIdA = try await registerPeer(name: "sender")
        let peerIdB = try await registerPeer(name: "receiver")

        let sendData = makeToolCallRequest(toolName: "send_message", arguments: [
            "from": peerIdA,
            "to": peerIdB,
            "content": "ack me",
        ])
        let (_, sendBody) = await server.handleJSONRPC(data: sendData, authToken: testToken)
        let (sendJSON, _) = try toolCallJSON(sendBody)
        let messageId = try XCTUnwrap(sendJSON["messageId"] as? String,
                                      "send_message must return messageId")

        // Act — ack the message
        let ackData = makeToolCallRequest(toolName: "ack_messages", arguments: [
            "peer_id": peerIdB,
            "message_ids": [messageId],
        ])
        let (ackStatus, ackBody) = await server.handleJSONRPC(data: ackData, authToken: testToken)
        XCTAssertEqual(ackStatus, 200)
        let (_, ackIsError) = try toolCallText(ackBody)
        XCTAssertFalse(ackIsError, "ack_messages should not be an error")

        // Assert — receive again returns empty
        let recvData = makeToolCallRequest(toolName: "receive_messages", arguments: [
            "peer_id": peerIdB,
        ])
        let (recvStatus, recvBody) = await server.handleJSONRPC(data: recvData, authToken: testToken)
        XCTAssertEqual(recvStatus, 200)
        let (recvJSON, recvIsError) = try toolCallJSON(recvBody)
        XCTAssertFalse(recvIsError)

        let messages = recvJSON["messages"] as? [[String: Any]] ?? []
        XCTAssertTrue(messages.isEmpty,
                      "After ack, receive_messages should return empty")
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

    // 19. Rapid start/stop toggle — no crash, correct final state
    func test_enableDisable_rapidToggle() throws {
        let srv = CalyxMCPServer()

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
}
