//
//  JSONRPC.swift
//  Calyx
//
//  JSON-RPC 2.0 base types shared by MCP, LSP, and other JSON-RPC clients
//  in the Calyx IPC system.
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
        case let n as NSNumber:
            // JSON numbers and booleans both arrive as `NSNumber` after a
            // `JSONSerialization.jsonObject(...)` parse. The plain `as? Bool`
            // / `as? Int` cast is *not* sufficient to discriminate them:
            // every numeric `NSNumber` whose value is `0` or `1` will also
            // satisfy `as? Bool`, so an integer 1 (e.g. an LSP `line: 1`)
            // would be misclassified as `true` and re-encoded as a JSON
            // boolean. Use `CFGetTypeID` to identify the boolean variant
            // (`__NSCFBoolean`) explicitly before falling back to Int /
            // Double.
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                self.storage = .bool(n.boolValue)
            } else if CFNumberIsFloatType(n) {
                self.storage = .double(n.doubleValue)
            } else {
                self.storage = .int(n.intValue)
            }
        case let b as Bool:
            // Pure Swift `Bool` (not bridged through NSNumber). Kept after
            // the `NSNumber` branch so JSON-derived numerics never hit
            // this arm.
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
    static func from<T: Encodable>(_ value: T) -> AnyCodable {
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
