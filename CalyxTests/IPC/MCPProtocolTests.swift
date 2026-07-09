//
//  MCPProtocolTests.swift
//  CalyxTests
//
//  Tests for MCP (Model Context Protocol) JSON-RPC type definitions and router.
//
//  Coverage:
//  - MCPRouter.buildInitializeResponse matches MCP spec
//  - MCPRouter.buildToolsListResponse contains all 7 tools
//  - register_peer tool inputSchema correctness
//  - Error responses (parse error, method not found)
//  - Tool call responses (success / error)
//  - JSONRPCRequest decoding (int id, string id, notification)
//  - JSONRPCResponse encode/decode roundtrip
//

import XCTest
@testable import Calyx

final class MCPProtocolTests: XCTestCase {

    // MARK: - Helpers

    private let jsonDecoder = JSONDecoder()
    private let jsonEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return encoder
    }()

    /// Encode a Codable value to a JSON dictionary for assertion.
    private func jsonObject<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try jsonEncoder.encode(value)
        let obj = try JSONSerialization.jsonObject(with: data)
        return obj as! [String: Any]
    }

    // ==================== 1. Initialize Response ====================

    func test_initializeResponse_matchesMCPSpec() throws {
        // Arrange
        let id = JSONRPCId.int(1)

        // Act
        let response = MCPRouter.buildInitializeResponse(id: id)

        // Assert — structure
        XCTAssertEqual(response.jsonrpc, "2.0",
                       "JSON-RPC version must be 2.0")
        XCTAssertEqual(response.id, .int(1),
                       "Response id must match request id")
        XCTAssertNil(response.error,
                     "Initialize response must not contain an error")
        XCTAssertNotNil(response.result,
                        "Initialize response must contain a result")

        // Assert — decode result as MCPInitializeResult
        let resultData = try jsonEncoder.encode(response.result!)
        let initResult = try jsonDecoder.decode(MCPInitializeResult.self, from: resultData)

        XCTAssertEqual(initResult.protocolVersion, "2024-11-05",
                       "Protocol version must be 2024-11-05")
        XCTAssertEqual(initResult.serverInfo.name, "calyx-ipc",
                       "Server name must be calyx-ipc")
        XCTAssertEqual(initResult.serverInfo.version, "1.0.0",
                       "Server version must be 1.0.0")
        XCTAssertEqual(initResult.capabilities.tools.listChanged, false,
                       "listChanged must be false")

        XCTAssertNotNil(initResult.instructions,
                        "Initialize result must contain instructions")
        XCTAssertFalse(initResult.instructions?.isEmpty ?? true,
                       "instructions must be a non-empty string")
        XCTAssertTrue(initResult.instructions?.contains("register_peer") == true,
                      "instructions must mention register_peer")
        XCTAssertTrue(initResult.instructions?.contains("receive_messages") == true,
                      "instructions must mention receive_messages")
    }

    func test_initializeResult_instructions_codable_roundtrip() throws {
        // Non-nil case
        let withInstructions = MCPInitializeResult(
            protocolVersion: "2024-11-05",
            capabilities: MCPCapabilities(tools: MCPToolsCapability(listChanged: false)),
            serverInfo: MCPServerInfo(name: "test", version: "1.0.0"),
            instructions: "Test instructions"
        )
        let data1 = try jsonEncoder.encode(withInstructions)
        let decoded1 = try jsonDecoder.decode(MCPInitializeResult.self, from: data1)
        XCTAssertEqual(decoded1.instructions, "Test instructions",
                       "instructions must survive encode/decode roundtrip")

        // Nil case
        let withoutInstructions = MCPInitializeResult(
            protocolVersion: "2024-11-05",
            capabilities: MCPCapabilities(tools: MCPToolsCapability(listChanged: false)),
            serverInfo: MCPServerInfo(name: "test", version: "1.0.0"),
            instructions: nil
        )
        let data2 = try jsonEncoder.encode(withoutInstructions)
        let decoded2 = try jsonDecoder.decode(MCPInitializeResult.self, from: data2)
        XCTAssertNil(decoded2.instructions,
                     "nil instructions must remain nil after roundtrip")
    }

    // ==================== Round 6: instructions branch on whether a ====================
    // ==================== peer was already auto-registered ====================
    //
    // Bug: the old instructions told every connecting client "call
    // register_peer once immediately after connecting", while `initialize`
    // itself ALSO auto-registers a peer and announces its id in the same
    // response — a contradiction. An agent that dutifully followed the
    // instruction ended up minting a second, disconnected identity for the
    // same pane (two rows in list_peers; senders addressing the
    // auto-registered id never reached the pane's own inbox).
    //
    // Fix (Round 6 review): `initialize`'s auto-registration itself is now
    // limited to surface-bound connections (see
    // CalyxMCPServerAgentEventTests' `test_initialize_withoutSurfaceHeader_
    // doesNotAutoRegisterPeer`) — an external client with no
    // X-Calyx-Surface-ID (e.g. OpenCode) has no surface for a renamed peer
    // to be bound to, so it is never auto-registered at all. Instructions
    // must therefore branch on whether `buildInitializeResponse` was
    // called with a non-nil `peerID`:
    // - peerID present (surface-bound, already auto-registered): state
    //   that the client is already registered, and that register_peer is
    //   now only for attaching a descriptive name — a call that renames
    //   the existing registration and returns the SAME peer_id.
    // - peerID nil (no surface binding, never auto-registered): retain the
    //   original "call register_peer immediately" guidance — there is no
    //   surface binding for rename semantics to attach to, so
    //   self-registration remains the only path to a peer_id.

    func test_instructions_withPeerID_doesNotInstructImmediateRegisterPeerCall() throws {
        let response = MCPRouter.buildInitializeResponse(id: .int(1), peerID: UUID())
        let resultData = try jsonEncoder.encode(response.result!)
        let initResult = try jsonDecoder.decode(MCPInitializeResult.self, from: resultData)
        let instructions = try XCTUnwrap(initResult.instructions)

        XCTAssertFalse(
            instructions.contains("Immediately after connecting, call register_peer"),
            "instructions for a connection WITH an auto-registered peerID must no longer " +
            "unconditionally instruct the client to call register_peer immediately after connecting " +
            "— this contradicted initialize's own auto-registration and caused a second, orphaned " +
            "peer identity per pane"
        )
    }

    func test_instructions_withPeerID_explainsAutoRegistrationAndRenameSemantics() throws {
        let id = JSONRPCId.int(1)
        let peerID = UUID()

        let response = MCPRouter.buildInitializeResponse(id: id, peerID: peerID)
        let resultData = try jsonEncoder.encode(response.result!)
        let initResult = try jsonDecoder.decode(MCPInitializeResult.self, from: resultData)
        let instructions = try XCTUnwrap(initResult.instructions)

        // "Your peer_id is: <uuid>" must still appear (existing contract, unchanged).
        XCTAssertTrue(instructions.contains("Your peer_id is: \(peerID.uuidString)"),
                      "instructions must still announce the auto-registered peer_id")

        // The client must be told it is ALREADY registered, not that it
        // must register.
        XCTAssertNotNil(
            instructions.range(of: "already registered", options: .caseInsensitive),
            "instructions must state the client is already registered as a peer"
        )

        // register_peer must now be framed as returning the SAME peer_id
        // (a rename) rather than a fresh one — the core Round 6 fix.
        XCTAssertNotNil(
            instructions.range(of: "same peer_id", options: .caseInsensitive),
            "instructions must state that calling register_peer returns the SAME peer_id, not a new " +
            "one — otherwise a client that calls it anyway still ends up with two identities"
        )
    }

    func test_instructions_withoutPeerID_retainsImmediateRegisterPeerInstruction() throws {
        let response = MCPRouter.buildInitializeResponse(id: .int(1), peerID: nil)
        let resultData = try jsonEncoder.encode(response.result!)
        let initResult = try jsonDecoder.decode(MCPInitializeResult.self, from: resultData)
        let instructions = try XCTUnwrap(initResult.instructions)

        XCTAssertTrue(
            instructions.contains("Immediately after connecting, call register_peer once"),
            "instructions for a connection with no auto-registered peerID (no surface binding) must " +
            "retain the original 'call register_peer immediately' guidance — without a surface " +
            "binding there is no rename semantics to fall back on, so self-registration is still " +
            "required"
        )

        XCTAssertNil(
            instructions.range(of: "Your peer_id is:"),
            "instructions with no peerID must not claim a peer_id was already assigned"
        )
    }

    // ==================== 2. Tools List — IPC + LSP Tool Surface ====================

    func test_toolsListResponse_containsAllTools() throws {
        // Arrange — `tools/list` advertises the combined IPC + LSP +
        // terminal_* + Cockpit surface (6 IPC + 70 LSP + 3 terminal_* +
        // 6 Cockpit = 85 tools; Round 7 removed ack_messages, P3 added
        // the terminal_* surface, P4 added the ungated Cockpit tools,
        // P5 added the 3 gated ones). Each IPC name must be present and
        // the LSP catalogue must be surfaced alongside.
        let id = JSONRPCId.int(2)
        let expectedIPCTools: Set<String> = [
            "register_peer", "list_peers", "send_message",
            "broadcast", "receive_messages", "get_peer_status",
        ]

        // Act
        let response = MCPRouter.buildToolsListResponse(id: id)

        // Assert — structure
        XCTAssertEqual(response.jsonrpc, "2.0")
        XCTAssertEqual(response.id, .int(2))
        XCTAssertNil(response.error)
        XCTAssertNotNil(response.result)

        // Assert — decode result as MCPToolsListResult
        let resultData = try jsonEncoder.encode(response.result!)
        let toolsResult = try jsonDecoder.decode(MCPToolsListResult.self, from: resultData)

        let actualNames = Set(toolsResult.tools.map(\.name))
        XCTAssertTrue(expectedIPCTools.isSubset(of: actualNames),
                      "Tools list must contain every IPC tool; got: \(actualNames)")
        XCTAssertTrue(actualNames.contains("lsp_hover"),
                      "Tools list must surface the LSP tool catalogue alongside IPC tools")
        XCTAssertEqual(toolsResult.tools.count, 85,
                       "Tools list must contain 6 IPC + 70 LSP + 3 terminal_* + 6 Cockpit = 85 tools")
    }

    // ==================== Round 7: ack_messages removed; receive is ====================
    // ==================== delete-on-read (at-most-once) ====================
    //
    // Messages are now removed from the recipient's inbox by the same
    // receive_messages call that returns them, instead of staying
    // present until a separate ack_messages call. ack_messages is
    // therefore removed entirely, not just deprecated.

    func test_toolsListResponse_doesNotContainAckMessages() throws {
        let response = MCPRouter.buildToolsListResponse(id: .int(2))
        let resultData = try jsonEncoder.encode(response.result!)
        let toolsResult = try jsonDecoder.decode(MCPToolsListResult.self, from: resultData)
        let actualNames = Set(toolsResult.tools.map(\.name))

        XCTAssertFalse(actualNames.contains("ack_messages"),
                       "ack_messages must be removed from the tool catalogue — receive_messages now " +
                       "deletes on read, so there is no longer a separate ack step for a client to call")
    }

    func test_instructions_withoutPeerID_doesNotMentionAck() throws {
        let response = MCPRouter.buildInitializeResponse(id: .int(1), peerID: nil)
        let resultData = try jsonEncoder.encode(response.result!)
        let initResult = try jsonDecoder.decode(MCPInitializeResult.self, from: resultData)
        let instructions = try XCTUnwrap(initResult.instructions)

        XCTAssertNil(
            instructions.range(of: "ack", options: .caseInsensitive),
            "instructions for a connection with no auto-registered peerID must not mention " +
            "ack/ack_messages anywhere — the tool no longer exists"
        )
    }

    func test_instructions_withPeerID_doesNotMentionAck() throws {
        let response = MCPRouter.buildInitializeResponse(id: .int(1), peerID: UUID())
        let resultData = try jsonEncoder.encode(response.result!)
        let initResult = try jsonDecoder.decode(MCPInitializeResult.self, from: resultData)
        let instructions = try XCTUnwrap(initResult.instructions)

        XCTAssertNil(
            instructions.range(of: "ack", options: .caseInsensitive),
            "instructions for a connection with an auto-registered peerID must not mention " +
            "ack/ack_messages anywhere — the tool no longer exists"
        )
    }

    func test_instructions_describesReceiveMessagesAsDeleteOnRead() throws {
        // The receive_messages guidance paragraph must explain the new
        // at-most-once contract — that retrieving a message removes it
        // from the inbox in the same call, so it will not be returned
        // again — so an agent doesn't try to re-poll for (or expect a
        // reply flow around re-reading) a message it already retrieved.
        let response = MCPRouter.buildInitializeResponse(id: .int(1), peerID: nil)
        let resultData = try jsonEncoder.encode(response.result!)
        let initResult = try jsonDecoder.decode(MCPInitializeResult.self, from: resultData)
        let instructions = try XCTUnwrap(initResult.instructions)

        XCTAssertTrue(instructions.contains("receive_messages"),
                      "instructions must still mention receive_messages")

        let mentionsRemoval = instructions.range(of: "remov", options: .caseInsensitive) != nil
        let mentionsNotReturnedAgain =
            instructions.range(of: "only once", options: .caseInsensitive) != nil ||
            instructions.range(
                of: "will not.*again", options: [.regularExpression, .caseInsensitive]
            ) != nil ||
            instructions.range(
                of: "not be returned again", options: .caseInsensitive
            ) != nil

        XCTAssertTrue(
            mentionsRemoval && mentionsNotReturnedAgain,
            "instructions must explain that receive_messages removes messages from the inbox as it " +
            "returns them, and that a message will not be returned again on a later call — the " +
            "at-most-once contract ack_messages' removal step used to provide. instructions was: " +
            "\(instructions)"
        )
    }

    // ==================== 3. register_peer Schema ====================

    func test_toolsListResponse_registerPeerSchema() throws {
        // Arrange
        let id = JSONRPCId.int(3)

        // Act
        let response = MCPRouter.buildToolsListResponse(id: id)
        let resultData = try jsonEncoder.encode(response.result!)
        let toolsResult = try jsonDecoder.decode(MCPToolsListResult.self, from: resultData)

        // Assert — find register_peer
        let registerPeer = toolsResult.tools.first { $0.name == "register_peer" }
        XCTAssertNotNil(registerPeer, "register_peer tool must exist")

        guard let tool = registerPeer else { return }

        // Assert — description is non-empty
        XCTAssertFalse(tool.description.isEmpty,
                       "register_peer must have a non-empty description")

        // Assert — inputSchema structure
        let schemaData = try jsonEncoder.encode(tool.inputSchema)
        let schema = try JSONSerialization.jsonObject(with: schemaData) as! [String: Any]

        XCTAssertEqual(schema["type"] as? String, "object",
                       "inputSchema type must be 'object'")

        // Assert — properties contain "name" and "role"
        let properties = schema["properties"] as? [String: Any]
        XCTAssertNotNil(properties, "inputSchema must have properties")
        XCTAssertNotNil(properties?["name"], "properties must include 'name'")
        XCTAssertNotNil(properties?["role"], "properties must include 'role'")

        // Assert — "name" property has type string
        let nameProperty = properties?["name"] as? [String: Any]
        XCTAssertEqual(nameProperty?["type"] as? String, "string",
                       "'name' property type must be 'string'")

        // Assert — "role" property has type string
        let roleProperty = properties?["role"] as? [String: Any]
        XCTAssertEqual(roleProperty?["type"] as? String, "string",
                       "'role' property type must be 'string'")

        // Assert — required contains "name" but not "role"
        let required = schema["required"] as? [String]
        XCTAssertNotNil(required, "inputSchema must have 'required' array")
        XCTAssertTrue(required?.contains("name") == true,
                      "'name' must be in required array")
        XCTAssertFalse(required?.contains("role") == true,
                       "'role' must NOT be in required array (it is optional)")
    }

    // ==================== 4. Error Response — Parse Error ====================

    func test_errorResponse_parseError() throws {
        // Arrange & Act
        let response = MCPRouter.buildErrorResponse(
            id: .int(1),
            code: -32700,
            message: "Parse error"
        )

        // Assert
        XCTAssertEqual(response.jsonrpc, "2.0")
        XCTAssertEqual(response.id, .int(1))
        XCTAssertNil(response.result,
                     "Error response must not contain a result")
        XCTAssertNotNil(response.error,
                        "Error response must contain an error object")
        XCTAssertEqual(response.error?.code, -32700,
                       "Error code must be -32700 for parse error")
        XCTAssertEqual(response.error?.message, "Parse error",
                       "Error message must be 'Parse error'")
    }

    // ==================== 5. Error Response — Method Not Found ====================

    func test_errorResponse_methodNotFound() throws {
        // Arrange & Act
        let response = MCPRouter.buildErrorResponse(
            id: .string("req-42"),
            code: -32601,
            message: "Method not found"
        )

        // Assert
        XCTAssertEqual(response.jsonrpc, "2.0")
        XCTAssertEqual(response.id, .string("req-42"),
                       "Error response must preserve the string id")
        XCTAssertNil(response.result)
        XCTAssertNotNil(response.error)
        XCTAssertEqual(response.error?.code, -32601)
        XCTAssertEqual(response.error?.message, "Method not found")
    }

    // ==================== 6. Tool Call Response — Success ====================

    func test_toolCallResponse_success() throws {
        // Arrange
        let content = [MCPContent(type: "text", text: "Peer registered successfully")]

        // Act
        let response = MCPRouter.buildToolCallResponse(
            id: .int(10),
            content: content,
            isError: false
        )

        // Assert
        XCTAssertEqual(response.jsonrpc, "2.0")
        XCTAssertEqual(response.id, .int(10))
        XCTAssertNil(response.error)
        XCTAssertNotNil(response.result)

        let resultData = try jsonEncoder.encode(response.result!)
        let callResult = try jsonDecoder.decode(MCPToolCallResult.self, from: resultData)

        XCTAssertEqual(callResult.content.count, 1)
        XCTAssertEqual(callResult.content[0].type, "text")
        XCTAssertEqual(callResult.content[0].text, "Peer registered successfully")
        XCTAssertEqual(callResult.isError, false,
                       "isError must be false for successful tool calls")
    }

    // ==================== 7. Tool Call Response — Error ====================

    func test_toolCallResponse_error() throws {
        // Arrange
        let content = [MCPContent(type: "text", text: "Peer not found: unknown-peer")]

        // Act
        let response = MCPRouter.buildToolCallResponse(
            id: .int(11),
            content: content,
            isError: true
        )

        // Assert
        XCTAssertEqual(response.jsonrpc, "2.0")
        XCTAssertEqual(response.id, .int(11))
        XCTAssertNil(response.error,
                     "Tool call error uses isError in result, not JSON-RPC error")
        XCTAssertNotNil(response.result)

        let resultData = try jsonEncoder.encode(response.result!)
        let callResult = try jsonDecoder.decode(MCPToolCallResult.self, from: resultData)

        XCTAssertEqual(callResult.content.count, 1)
        XCTAssertEqual(callResult.content[0].text, "Peer not found: unknown-peer")
        XCTAssertEqual(callResult.isError, true,
                       "isError must be true for failed tool calls")
    }

    // ==================== 8. JSONRPCRequest Decode — Int Id ====================

    func test_jsonRPCRequest_decode_intId() throws {
        // Arrange
        let json = """
        {
            "jsonrpc": "2.0",
            "id": 42,
            "method": "initialize",
            "params": {"protocolVersion": "2024-11-05"}
        }
        """.data(using: .utf8)!

        // Act
        let request = try jsonDecoder.decode(JSONRPCRequest.self, from: json)

        // Assert
        XCTAssertEqual(request.jsonrpc, "2.0")
        XCTAssertEqual(request.id, .int(42),
                       "Integer id must decode as .int(42)")
        XCTAssertEqual(request.method, "initialize")
        XCTAssertNotNil(request.params,
                        "Params must be present")
    }

    // ==================== 9. JSONRPCRequest Decode — String Id ====================

    func test_jsonRPCRequest_decode_stringId() throws {
        // Arrange
        let json = """
        {
            "jsonrpc": "2.0",
            "id": "request-abc-123",
            "method": "tools/list",
            "params": {}
        }
        """.data(using: .utf8)!

        // Act
        let request = try jsonDecoder.decode(JSONRPCRequest.self, from: json)

        // Assert
        XCTAssertEqual(request.jsonrpc, "2.0")
        XCTAssertEqual(request.id, .string("request-abc-123"),
                       "String id must decode as .string(\"request-abc-123\")")
        XCTAssertEqual(request.method, "tools/list")
    }

    // ==================== 10. JSONRPCRequest Decode — Null Id (Notification) ====================

    func test_jsonRPCRequest_decode_nullId_notification() throws {
        // Arrange — notification has no "id" field
        let json = """
        {
            "jsonrpc": "2.0",
            "method": "notifications/initialized"
        }
        """.data(using: .utf8)!

        // Act
        let request = try jsonDecoder.decode(JSONRPCRequest.self, from: json)

        // Assert
        XCTAssertEqual(request.jsonrpc, "2.0")
        XCTAssertNil(request.id,
                     "Notification requests must have nil id")
        XCTAssertEqual(request.method, "notifications/initialized")
        XCTAssertNil(request.params,
                     "Notification with no params should decode as nil")
    }

    // ==================== 11. JSONRPCResponse Encode/Decode Roundtrip ====================

    func test_jsonRPCResponse_encode_roundtrip() throws {
        // Arrange — build a response with a result
        let original = MCPRouter.buildInitializeResponse(id: .string("roundtrip-1"))

        // Act — encode then decode
        let data = try jsonEncoder.encode(original)
        let decoded = try jsonDecoder.decode(JSONRPCResponse.self, from: data)

        // Assert
        XCTAssertEqual(decoded.jsonrpc, original.jsonrpc,
                       "jsonrpc field must survive roundtrip")
        XCTAssertEqual(decoded.id, original.id,
                       "id must survive roundtrip")
        XCTAssertNil(decoded.error,
                     "error must remain nil after roundtrip")
        XCTAssertNotNil(decoded.result,
                        "result must survive roundtrip")

        // Verify the result content is structurally identical
        let originalData = try jsonEncoder.encode(original.result!)
        let decodedData = try jsonEncoder.encode(decoded.result!)
        let originalJSON = try JSONSerialization.jsonObject(with: originalData) as! NSDictionary
        let decodedJSON = try JSONSerialization.jsonObject(with: decodedData) as! NSDictionary
        XCTAssertEqual(originalJSON, decodedJSON,
                       "Result content must be identical after encode/decode roundtrip")
    }

    // ==================== Supplementary: MCPRouter.tools Static Property ====================

    func test_router_tools_staticProperty_returns6Tools() {
        // Act
        let tools = MCPRouter.tools

        // Assert
        XCTAssertEqual(tools.count, 6,
                       "MCPRouter.tools must expose exactly 6 tool definitions " +
                       "(Round 7 removed ack_messages)")

        let names = tools.map(\.name)
        // IPC tools
        XCTAssertTrue(names.contains("register_peer"))
        XCTAssertTrue(names.contains("list_peers"))
        XCTAssertTrue(names.contains("send_message"))
        XCTAssertTrue(names.contains("broadcast"))
        XCTAssertTrue(names.contains("receive_messages"))
        XCTAssertTrue(names.contains("get_peer_status"))
    }

    // ==================== Supplementary: AnyCodable Basics ====================

    func test_anyCodable_string_roundtrip() throws {
        // Arrange
        let original = AnyCodable("hello")

        // Act
        let data = try jsonEncoder.encode(original)
        let decoded = try jsonDecoder.decode(AnyCodable.self, from: data)

        // Assert
        XCTAssertEqual(original, decoded,
                       "AnyCodable string must survive encode/decode roundtrip")
    }

    func test_anyCodable_int_roundtrip() throws {
        // Arrange
        let original = AnyCodable(42)

        // Act
        let data = try jsonEncoder.encode(original)
        let decoded = try jsonDecoder.decode(AnyCodable.self, from: data)

        // Assert
        XCTAssertEqual(original, decoded,
                       "AnyCodable int must survive encode/decode roundtrip")
    }

    func test_anyCodable_dictionary_roundtrip() throws {
        // Arrange
        let original = AnyCodable(["key": "value", "count": 3] as [String: Any])

        // Act
        let data = try jsonEncoder.encode(original)
        let decoded = try jsonDecoder.decode(AnyCodable.self, from: data)

        // Assert
        XCTAssertEqual(original, decoded,
                       "AnyCodable dictionary must survive encode/decode roundtrip")
    }

    // ==================== Supplementary: JSONRPCId Equatable ====================

    func test_jsonRPCId_equality() {
        XCTAssertEqual(JSONRPCId.int(1), JSONRPCId.int(1))
        XCTAssertNotEqual(JSONRPCId.int(1), JSONRPCId.int(2))
        XCTAssertEqual(JSONRPCId.string("a"), JSONRPCId.string("a"))
        XCTAssertNotEqual(JSONRPCId.string("a"), JSONRPCId.string("b"))
        XCTAssertNotEqual(JSONRPCId.int(1), JSONRPCId.string("1"),
                          "Int and String ids with same 'value' must NOT be equal")
    }

    // ==================== Supplementary: Error Response with Nil Id ====================

    func test_errorResponse_withNilId() throws {
        // Arrange — parse errors may have null id per JSON-RPC spec
        let response = MCPRouter.buildErrorResponse(
            id: nil,
            code: -32700,
            message: "Parse error"
        )

        // Assert
        XCTAssertEqual(response.jsonrpc, "2.0")
        XCTAssertNil(response.id,
                     "Error response with nil id must encode id as null")
        XCTAssertNotNil(response.error)
        XCTAssertEqual(response.error?.code, -32700)

        // Verify it encodes correctly (null id in JSON)
        let data = try jsonEncoder.encode(response)
        let jsonObj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertTrue(jsonObj["id"] is NSNull || jsonObj["id"] == nil,
                      "Nil id must serialize as JSON null")
    }

    // ==================== P3: terminal_* tool surface ====================

    // A single method (rather than separate true/false-only tests):
    // asserting a "must be true" case alongside the "must be false"
    // cases guards against a permanently-false isTerminalTool passing
    // vacuously.
    func test_isTerminalTool_classifiesByTerminalPrefix() {
        XCTAssertTrue(MCPRouter.isTerminalTool(name: "terminal_list_commands"))
        XCTAssertTrue(MCPRouter.isTerminalTool(name: "terminal_read_output"))
        XCTAssertTrue(MCPRouter.isTerminalTool(name: "terminal_await_command"))

        XCTAssertFalse(MCPRouter.isTerminalTool(name: "lsp_hover"))
        XCTAssertFalse(MCPRouter.isTerminalTool(name: "register_peer"))
        XCTAssertFalse(MCPRouter.isTerminalTool(name: "terminal"),
                       "The bare word 'terminal' (no trailing underscore) must not match the terminal_ prefix")
    }

    func test_allTools_containsTerminalTools() {
        // Sanity: terminalTools itself must actually enumerate the 3
        // tools -- otherwise the containment assertion below would be
        // indistinguishable from a permanently-empty terminalTools that
        // happens to be a subset of anything.
        XCTAssertEqual(Set(MCPRouter.terminalTools.map(\.name)),
                       Set(["terminal_list_commands", "terminal_read_output", "terminal_await_command"]),
                       "Precondition: terminalTools must enumerate exactly the 3 terminal_* tools")

        let allNames = Set(MCPRouter.allTools.map(\.name))
        XCTAssertTrue(allNames.isSuperset(of: Set(MCPRouter.terminalTools.map(\.name))),
                      "allTools must include every tool terminalTools advertises")
    }

    func test_instructions_mentionsTerminalAwaitCommand() {
        XCTAssertTrue(MCPRouter.instructions.contains("terminal_await_command"),
                      "The default instructions text must mention terminal_await_command so an MCP " +
                      "client can discover the terminal_* tool surface")
    }
}
