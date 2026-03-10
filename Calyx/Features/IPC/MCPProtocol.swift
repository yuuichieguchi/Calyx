//
//  MCPProtocol.swift
//  Calyx
//
//  MCP (Model Context Protocol) JSON-RPC types and router for the Calyx IPC system.
//

import Foundation

// MARK: - AnyCodable

/// Type-erased Codable + Equatable wrapper for JSON values.
struct AnyCodable: @unchecked Sendable, Codable, Equatable {

    private enum Storage: Equatable {
        case string(String)
        case int(Int)
        case double(Double)
        case bool(Bool)
        case array([AnyCodable])
        case dictionary([String: AnyCodable])
        case null
    }

    private let storage: Storage

    // MARK: Typed Initializers

    init(_ value: String) {
        self.storage = .string(value)
    }

    init(_ value: Int) {
        self.storage = .int(value)
    }

    init(_ value: Double) {
        self.storage = .double(value)
    }

    init(_ value: Bool) {
        self.storage = .bool(value)
    }

    init(_ value: [AnyCodable]) {
        self.storage = .array(value)
    }

    init(_ value: [String: AnyCodable]) {
        self.storage = .dictionary(value)
    }

    /// Initialize from an untyped JSON-compatible value.
    /// Accepts String, Int, Double, Bool, [Any], [String: Any], AnyCodable, or nil.
    init(_ value: Any) {
        switch value {
        case let a as AnyCodable:
            self.storage = a.storage
        case let s as String:
            self.storage = .string(s)
        case let b as Bool:
            // Bool must be checked before Int/Double because NSNumber(bool) bridges to both.
            self.storage = .bool(b)
        case let i as Int:
            self.storage = .int(i)
        case let d as Double:
            self.storage = .double(d)
        case let arr as [Any]:
            self.storage = .array(arr.map { AnyCodable($0) })
        case let dict as [String: Any]:
            self.storage = .dictionary(dict.mapValues { AnyCodable($0) })
        default:
            self.storage = .null
        }
    }

    // MARK: Codable

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self.storage = .null
        } else if let b = try? container.decode(Bool.self) {
            self.storage = .bool(b)
        } else if let i = try? container.decode(Int.self) {
            self.storage = .int(i)
        } else if let d = try? container.decode(Double.self) {
            self.storage = .double(d)
        } else if let s = try? container.decode(String.self) {
            self.storage = .string(s)
        } else if let arr = try? container.decode([AnyCodable].self) {
            self.storage = .array(arr)
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            self.storage = .dictionary(dict)
        } else {
            self.storage = .null
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch storage {
        case .string(let v):
            try container.encode(v)
        case .int(let v):
            try container.encode(v)
        case .double(let v):
            try container.encode(v)
        case .bool(let v):
            try container.encode(v)
        case .array(let v):
            try container.encode(v)
        case .dictionary(let v):
            try container.encode(v)
        case .null:
            try container.encodeNil()
        }
    }

    // MARK: Internal Helpers

    /// Convert any Encodable value to AnyCodable via JSON serialization roundtrip.
    fileprivate static func from<T: Encodable>(_ value: T) -> AnyCodable {
        guard let data = try? JSONEncoder().encode(value),
              let jsonObject = try? JSONSerialization.jsonObject(with: data) else {
            return AnyCodable([String: AnyCodable]())
        }
        return AnyCodable(jsonObject)
    }
}

// MARK: - JSON-RPC Base Types

/// JSON-RPC id — either an integer or a string.
enum JSONRPCId: Sendable, Codable, Equatable {
    case int(Int)
    case string(String)

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let i = try? container.decode(Int.self) {
            self = .int(i)
        } else if let s = try? container.decode(String.self) {
            self = .string(s)
        } else {
            throw DecodingError.typeMismatch(
                JSONRPCId.self,
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Expected Int or String for JSON-RPC id"
                )
            )
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .int(let i):
            try container.encode(i)
        case .string(let s):
            try container.encode(s)
        }
    }
}

/// JSON-RPC 2.0 request.
struct JSONRPCRequest: Sendable, Codable {
    let jsonrpc: String
    let id: JSONRPCId?
    let method: String
    let params: [String: AnyCodable]?
}

/// JSON-RPC 2.0 error object.
struct JSONRPCError: Sendable, Codable {
    let code: Int
    let message: String
}

/// JSON-RPC 2.0 response.
struct JSONRPCResponse: Sendable, Codable {
    let jsonrpc: String
    let id: JSONRPCId?
    let result: AnyCodable?
    let error: JSONRPCError?
}

// MARK: - MCP Types

/// Result of the MCP `initialize` method.
struct MCPInitializeResult: Sendable, Codable {
    let protocolVersion: String
    let capabilities: MCPCapabilities
    let serverInfo: MCPServerInfo
}

/// MCP server capabilities.
struct MCPCapabilities: Sendable, Codable {
    let tools: MCPToolsCapability
}

/// MCP tools capability.
struct MCPToolsCapability: Sendable, Codable {
    let listChanged: Bool
}

/// MCP server information.
struct MCPServerInfo: Sendable, Codable {
    let name: String
    let version: String
}

/// MCP tool definition.
struct MCPTool: Sendable, Codable {
    let name: String
    let description: String
    let inputSchema: [String: AnyCodable]
}

/// Result of the MCP `tools/list` method.
struct MCPToolsListResult: Sendable, Codable {
    let tools: [MCPTool]
}

/// Result of an MCP tool call.
struct MCPToolCallResult: Sendable, Codable {
    let content: [MCPContent]
    let isError: Bool
}

/// MCP content block (text type).
struct MCPContent: Sendable, Codable {
    let type: String
    let text: String
}

// MARK: - MCPRouter

/// Routes MCP JSON-RPC requests and builds responses.
struct MCPRouter: Sendable {

    // MARK: - Schema Helpers

    private static func prop(_ type: String, _ desc: String) -> AnyCodable {
        AnyCodable(["type": AnyCodable(type), "description": AnyCodable(desc)] as [String: AnyCodable])
    }

    private static func arrayProp(_ itemType: String, _ desc: String) -> AnyCodable {
        AnyCodable([
            "type": AnyCodable("array"),
            "items": AnyCodable(["type": AnyCodable(itemType)] as [String: AnyCodable]),
            "description": AnyCodable(desc),
        ] as [String: AnyCodable])
    }

    private static func schema(
        properties: [String: AnyCodable],
        required: [String] = []
    ) -> [String: AnyCodable] {
        var s: [String: AnyCodable] = [
            "type": AnyCodable("object"),
            "properties": AnyCodable(properties),
        ]
        if !required.isEmpty {
            s["required"] = AnyCodable(required.map { AnyCodable($0) } as [AnyCodable])
        }
        return s
    }

    /// All tool definitions exposed by this MCP server.
    static var tools: [MCPTool] {
        [
            MCPTool(
                name: "register_peer",
                description: "Register this Claude Code instance as a peer for IPC communication",
                inputSchema: schema(
                    properties: [
                        "name": prop("string", "Peer display name"),
                        "role": prop("string", "Peer role"),
                    ],
                    required: ["name"]
                )
            ),
            MCPTool(
                name: "list_peers",
                description: "List all registered peers",
                inputSchema: schema(properties: [:])
            ),
            MCPTool(
                name: "send_message",
                description: "Send a message to a specific peer",
                inputSchema: schema(
                    properties: [
                        "from": prop("string", "Sender peer ID"),
                        "to": prop("string", "Target peer ID"),
                        "content": prop("string", "Message content"),
                    ],
                    required: ["from", "to", "content"]
                )
            ),
            MCPTool(
                name: "broadcast",
                description: "Broadcast a message to all other peers",
                inputSchema: schema(
                    properties: [
                        "from": prop("string", "Sender peer ID"),
                        "content": prop("string", "Message content"),
                    ],
                    required: ["from", "content"]
                )
            ),
            MCPTool(
                name: "receive_messages",
                description: "Receive pending messages for this peer",
                inputSchema: schema(
                    properties: [
                        "peer_id": prop("string", "Your peer ID"),
                    ],
                    required: ["peer_id"]
                )
            ),
            MCPTool(
                name: "ack_messages",
                description: "Acknowledge and delete received messages",
                inputSchema: schema(
                    properties: [
                        "peer_id": prop("string", "Peer ID"),
                        "message_ids": arrayProp("string", "Message IDs to acknowledge"),
                    ],
                    required: ["peer_id", "message_ids"]
                )
            ),
            MCPTool(
                name: "get_peer_status",
                description: "Get status information for a specific peer",
                inputSchema: schema(
                    properties: [
                        "peer_id": prop("string", "Peer ID to check"),
                    ],
                    required: ["peer_id"]
                )
            ),
        ]
    }

    /// Build the response for `initialize`.
    static func buildInitializeResponse(id: JSONRPCId) -> JSONRPCResponse {
        let initResult = MCPInitializeResult(
            protocolVersion: "2024-11-05",
            capabilities: MCPCapabilities(
                tools: MCPToolsCapability(listChanged: false)
            ),
            serverInfo: MCPServerInfo(name: "calyx-ipc", version: "1.0.0")
        )

        return JSONRPCResponse(
            jsonrpc: "2.0",
            id: id,
            result: AnyCodable.from(initResult),
            error: nil
        )
    }

    /// Build the response for `tools/list`.
    static func buildToolsListResponse(id: JSONRPCId) -> JSONRPCResponse {
        let toolsList = MCPToolsListResult(tools: tools)

        return JSONRPCResponse(
            jsonrpc: "2.0",
            id: id,
            result: AnyCodable.from(toolsList),
            error: nil
        )
    }

    /// Build a JSON-RPC error response.
    static func buildErrorResponse(
        id: JSONRPCId?,
        code: Int,
        message: String
    ) -> JSONRPCResponse {
        JSONRPCResponse(
            jsonrpc: "2.0",
            id: id,
            result: nil,
            error: JSONRPCError(code: code, message: message)
        )
    }

    /// Build a tool call result response.
    static func buildToolCallResponse(
        id: JSONRPCId,
        content: [MCPContent],
        isError: Bool
    ) -> JSONRPCResponse {
        let callResult = MCPToolCallResult(content: content, isError: isError)

        return JSONRPCResponse(
            jsonrpc: "2.0",
            id: id,
            result: AnyCodable.from(callResult),
            error: nil
        )
    }
}
