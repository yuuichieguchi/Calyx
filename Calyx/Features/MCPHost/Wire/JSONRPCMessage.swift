//
//  JSONRPCMessage.swift
//  Calyx
//
//  Generic JSON-RPC 2.0 message classification for MCP transports and the
//  MCP App view bridge.
//

import Foundation

/// A single JSON-RPC 2.0 message or a batch of them.
enum JSONRPCMessage: Sendable, Equatable {
    case request(id: JSONRPCId, method: String, params: [String: AnyCodable]?)
    case notification(method: String, params: [String: AnyCodable]?)
    /// `id` is nil for a response whose request id could not be determined
    /// (`"id": null` on the wire).
    case response(id: JSONRPCId?, result: AnyCodable?, error: JSONRPCError?)
    case batch([JSONRPCMessage])

    /// Classifies a JSON-RPC payload.
    ///
    /// - A top-level array is a batch; each element is classified by the same rules.
    /// - An object with `method` and a non-null `id` is a request.
    /// - An object with `method` and no `id` (or `"id": null`) is a notification.
    /// - An object without `method` but with `result` or `error` is a response.
    ///
    /// `0` is a valid id. A member present with the wrong JSON type (for example
    /// a non-object `params`) throws the underlying `DecodingError`.
    static func parse(_ data: Data) throws -> JSONRPCMessage {
        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
        } catch {
            throw JSONRPCMessageParseError.invalidJSON
        }
        return try classify(AnyCodable(json))
    }

    /// Encodes the message as JSON-RPC 2.0. A response with a nil id encodes
    /// `"id": null`; nil `params`, `result`, and `error` are omitted.
    func serialize() throws -> Data {
        try JSONEncoder().encode(jsonValue)
    }

    // MARK: - Private

    private static func classify(_ value: AnyCodable) throws -> JSONRPCMessage {
        if let elements = value.arrayValue {
            return .batch(try elements.map(classify))
        }
        guard let object = value.objectValue else {
            throw JSONRPCMessageParseError.notObjectOrArray
        }

        let id = try decodeMember(JSONRPCId.self, "id", in: object)

        if let methodValue = object["method"] {
            let method = try decode(String.self, from: methodValue)
            let params = try decodeMember([String: AnyCodable].self, "params", in: object)
            if let id {
                return .request(id: id, method: method, params: params)
            }
            return .notification(method: method, params: params)
        }

        guard object["result"] != nil || object["error"] != nil else {
            throw JSONRPCMessageParseError.missingMethodAndResult
        }
        let error = try decodeMember(JSONRPCError.self, "error", in: object)
        return .response(id: id, result: object["result"], error: error)
    }

    /// Decodes an object member. An absent key and an explicit JSON `null`
    /// both yield nil.
    private static func decodeMember<T: Decodable>(
        _ type: T.Type,
        _ key: String,
        in object: [String: AnyCodable]
    ) throws -> T? {
        guard let value = object[key], !value.isNull else { return nil }
        return try decode(type, from: value)
    }

    private static func decode<T: Decodable>(_ type: T.Type, from value: AnyCodable) throws -> T {
        try JSONDecoder().decode(type, from: JSONEncoder().encode(value))
    }

    private var jsonValue: AnyCodable {
        switch self {
        case .request(let id, let method, let params):
            var object: [String: AnyCodable] = [
                "jsonrpc": AnyCodable("2.0"),
                "id": Self.jsonValue(of: id),
                "method": AnyCodable(method),
            ]
            if let params { object["params"] = AnyCodable(params) }
            return AnyCodable(object)
        case .notification(let method, let params):
            var object: [String: AnyCodable] = [
                "jsonrpc": AnyCodable("2.0"),
                "method": AnyCodable(method),
            ]
            if let params { object["params"] = AnyCodable(params) }
            return AnyCodable(object)
        case .response(let id, let result, let error):
            var object: [String: AnyCodable] = [
                "jsonrpc": AnyCodable("2.0"),
                "id": id.map(Self.jsonValue(of:)) ?? .null,
            ]
            if let result { object["result"] = result }
            if let error { object["error"] = Self.jsonValue(of: error) }
            return AnyCodable(object)
        case .batch(let messages):
            return AnyCodable(messages.map(\.jsonValue))
        }
    }

    private static func jsonValue(of id: JSONRPCId) -> AnyCodable {
        switch id {
        case .int(let i): AnyCodable(i)
        case .string(let s): AnyCodable(s)
        }
    }

    private static func jsonValue(of error: JSONRPCError) -> AnyCodable {
        var object: [String: AnyCodable] = [
            "code": AnyCodable(error.code),
            "message": AnyCodable(error.message),
        ]
        if let data = error.data { object["data"] = data }
        return AnyCodable(object)
    }
}

/// Reasons `JSONRPCMessage.parse` rejects a payload.
enum JSONRPCMessageParseError: Error, Sendable, Equatable {
    case invalidJSON
    case notObjectOrArray
    case missingMethodAndResult
}
