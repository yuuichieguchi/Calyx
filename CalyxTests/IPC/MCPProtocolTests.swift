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
    }

    // ==================== 2. Tools List — All 7 Tools ====================

    func test_toolsListResponse_containsAllTools() throws {
        // Arrange
        let id = JSONRPCId.int(2)
        let expectedToolNames: Set<String> = [
            "register_peer",
            "list_peers",
            "send_message",
            "broadcast",
            "receive_messages",
            "ack_messages",
            "get_peer_status",
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
        XCTAssertEqual(actualNames, expectedToolNames,
                       "Tools list must contain exactly the 7 expected tools")
        XCTAssertEqual(toolsResult.tools.count, 7,
                       "Tools list must contain exactly 7 tools")
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

    func test_router_tools_staticProperty_returns7Tools() {
        // Act
        let tools = MCPRouter.tools

        // Assert
        XCTAssertEqual(tools.count, 7,
                       "MCPRouter.tools must expose exactly 7 tool definitions")

        let names = tools.map(\.name)
        XCTAssertTrue(names.contains("register_peer"))
        XCTAssertTrue(names.contains("list_peers"))
        XCTAssertTrue(names.contains("send_message"))
        XCTAssertTrue(names.contains("broadcast"))
        XCTAssertTrue(names.contains("receive_messages"))
        XCTAssertTrue(names.contains("ack_messages"))
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
}
