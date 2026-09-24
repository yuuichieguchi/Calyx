//
//  MCPAppBridgeDispatch.swift
//  Calyx
//
//  Protocol rules of the view bridge that do not need WebKit. Messages are
//  parsed by Wire's `JSONRPCMessage.parse`; there is no view-specific
//  parser.
//

import Foundation

enum MCPAppBridgeDispatch {
    /// A serialized message from the view larger than this is refused.
    static let maxMessageBytes = 16 * 1024 * 1024

    /// Requests from the view are accepted before `initialized` too,
    /// `ui/initialize` and `ping` included: the spec restricts only what
    /// the host sends before `initialized`.
    static func validate(initialized: Bool, method: String) -> JSONRPCError? {
        nil
    }

    /// Per-method params checks (-32602) for `ui/message`, `ui/open-link`,
    /// `ui/request-display-mode` and `ui/download-file`.
    static func validateParams(method: String, params: AnyCodable?) -> JSONRPCError? {
        switch method {
        case "ui/message":
            guard params?["role"]?.stringValue == "user" else {
                return invalidParams("ui/message requires role \"user\".")
            }
            guard params?["content"]?.arrayValue != nil else {
                return invalidParams("ui/message requires a content array.")
            }
            return nil
        case "ui/open-link":
            guard let url = params?["url"]?.stringValue, URL(string: url) != nil else {
                return invalidParams("ui/open-link requires a url string.")
            }
            return nil
        case "ui/request-display-mode":
            guard params?["mode"]?.stringValue != nil else {
                return invalidParams("ui/request-display-mode requires a mode string.")
            }
            return nil
        case "ui/download-file":
            guard let contents = params?["contents"]?.arrayValue, !contents.isEmpty else {
                return invalidParams("ui/download-file requires a non-empty contents array.")
            }
            return nil
        default:
            return nil
        }
    }

    static func errorForUnknownMethod(id: JSONRPCId) -> JSONRPCMessage {
        .response(id: id, result: nil, error: JSONRPCError(code: -32601, message: "Method not found", data: nil))
    }

    static func invalidParams(_ message: String) -> JSONRPCError {
        JSONRPCError(code: -32602, message: message, data: nil)
    }
}
