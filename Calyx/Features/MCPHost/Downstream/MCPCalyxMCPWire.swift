//
//  MCPCalyxMCPWire.swift
//  Calyx
//
//  JSON-RPC and SSE encoding shared by the `/calyx-mcp` routes.
//

import Foundation

/// One JSON-RPC message received on `/calyx-mcp`.
struct MCPCalyxMCPIncoming: Sendable {
    /// Nil for a notification.
    let id: JSONRPCId?
    let method: String
    let params: [String: AnyCodable]?

    /// Nil when `object` is not a JSON-RPC request or notification.
    init?(object: AnyCodable) {
        guard let dict = object.objectValue, let method = dict["method"]?.stringValue else { return nil }
        if let idValue = dict["id"] {
            if let int = idValue.intValue {
                self.id = .int(int)
            } else if let string = idValue.stringValue {
                self.id = .string(string)
            } else {
                return nil
            }
        } else {
            self.id = nil
        }
        self.method = method
        if let paramsValue = dict["params"] {
            guard let params = paramsValue.objectValue else { return nil }
            self.params = params
        } else {
            self.params = nil
        }
    }
}

enum MCPCalyxMCPWire {

    static let serverName = "calyx-mcp"
    static let uiExtensionID = MCPClientPayload.uiExtensionID
    static let serverInfoMetaKey = "io.modelcontextprotocol/serverInfo"
    static let protocolVersionMetaKey = "io.modelcontextprotocol/protocolVersion"
    static let clientInfoMetaKey = "io.modelcontextprotocol/clientInfo"
    static let clientCapabilitiesMetaKey = "io.modelcontextprotocol/clientCapabilities"
    static let subscriptionIDMetaKey = "io.modelcontextprotocol/subscriptionId"

    /// Every revision Calyx serves, newest first. The `data.supported` of
    /// `-32022` and `server/discover`'s `supportedVersions`.
    static let supportedVersions = MCPProtocolVersion.allCases.map(\.rawValue)

    static let headerMismatchCode = -32020
    static let unsupportedProtocolVersionCode = -32022
    static let appOnlyToolCode = -32000
    static let invalidParamsCode = -32602
    static let methodNotFoundCode = -32601
    static let parseErrorCode = -32700
    static let invalidRequestCode = -32600
    static let internalErrorCode = -32603

    static var serverInfo: AnyCodable {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return AnyCodable([
            "name": AnyCodable(serverName),
            "version": AnyCodable(version ?? "0"),
        ])
    }

    static func idValue(_ id: JSONRPCId) -> AnyCodable {
        switch id {
        case .int(let value): return AnyCodable(value)
        case .string(let value): return AnyCodable(value)
        }
    }

    static func resultMessage(id: JSONRPCId, result: [String: AnyCodable]) -> [String: AnyCodable] {
        ["jsonrpc": AnyCodable("2.0"), "id": idValue(id), "result": AnyCodable(result)]
    }

    static func errorMessage(id: JSONRPCId?, code: Int, message: String, data: AnyCodable? = nil) -> [String: AnyCodable] {
        var error: [String: AnyCodable] = ["code": AnyCodable(code), "message": AnyCodable(message)]
        if let data { error["data"] = data }
        return [
            "jsonrpc": AnyCodable("2.0"),
            "id": id.map(idValue) ?? AnyCodable.null,
            "error": AnyCodable(error),
        ]
    }

    static func notificationMessage(method: String, params: [String: AnyCodable]) -> [String: AnyCodable] {
        ["jsonrpc": AnyCodable("2.0"), "method": AnyCodable(method), "params": AnyCodable(params)]
    }

    /// Slashes are written unescaped, so a method such as
    /// `notifications/progress` reads the same on the wire as in the spec.
    static func encode(_ value: AnyCodable) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        // `AnyCodable` holds only JSON values, so encoding cannot fail.
        guard let data = try? encoder.encode(value) else {
            preconditionFailure("AnyCodable JSON encoding failed")
        }
        return data
    }

    static func encode(_ message: [String: AnyCodable]) -> Data {
        encode(AnyCodable(message))
    }

    /// One SSE event carrying a JSON-RPC message.
    static func sseFrame(_ message: [String: AnyCodable]) -> Data {
        var frame = Data("event: message\ndata: ".utf8)
        frame.append(encode(message))
        frame.append(Data("\n\n".utf8))
        return frame
    }

    /// An SSE comment line, sent as a keep-alive.
    static let keepAliveFrame = Data(":\n\n".utf8)

    static func jsonResponse(statusCode: Int, message: [String: AnyCodable], headers: [String: String] = [:]) -> HTTPResponse {
        response(HTTPParser.response(statusCode: statusCode, body: encode(message)), adding: headers)
    }

    static func jsonResponse(statusCode: Int, body: AnyCodable, headers: [String: String] = [:]) -> HTTPResponse {
        response(HTTPParser.response(statusCode: statusCode, body: encode(body)), adding: headers)
    }

    static func emptyResponse(statusCode: Int, headers: [String: String] = [:]) -> HTTPResponse {
        response(HTTPParser.response(statusCode: statusCode, body: nil), adding: headers)
    }

    static func eventStreamHead(headers: [String: String] = [:]) -> HTTPResponseHead {
        var all = headers
        all["Content-Type"] = "text/event-stream"
        all["Cache-Control"] = "no-cache"
        return HTTPResponseHead(statusCode: 200, headers: all)
    }

    private static func response(_ base: HTTPResponse, adding headers: [String: String]) -> HTTPResponse {
        guard !headers.isEmpty else { return base }
        return HTTPResponse(
            statusCode: base.statusCode,
            statusMessage: base.statusMessage,
            headers: base.headers.merging(headers) { _, added in added },
            body: base.body
        )
    }

    /// Case-insensitive header lookup.
    static func header(_ name: String, in headers: [String: String]) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    /// Whether `accept` lists `text/event-stream` (or a wildcard for it).
    static func acceptsEventStream(_ accept: String?) -> Bool {
        guard let accept else { return false }
        return accept.split(separator: ",").contains { item in
            let mediaType = item.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            return mediaType == "text/event-stream" || mediaType == "text/*" || mediaType == "*/*"
        }
    }

    private static let base64SentinelPrefix = "=?base64?"
    private static let base64SentinelSuffix = "?="

    /// Undoes the `=?base64?...?=` wrapping HTTP clients apply to an
    /// `Mcp-Name` value that is not header-safe. Nil when the wrapped
    /// value is not Base64 of UTF-8 text.
    static func decodeMcpNameHeader(_ value: String) -> String? {
        guard value.hasPrefix(base64SentinelPrefix), value.hasSuffix(base64SentinelSuffix),
              value.count >= base64SentinelPrefix.count + base64SentinelSuffix.count
        else {
            return value
        }
        let encoded = value.dropFirst(base64SentinelPrefix.count).dropLast(base64SentinelSuffix.count)
        guard let data = Data(base64Encoded: String(encoded)) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
