//
//  MCPServerTransportConfig.swift
//  Calyx
//
//  How Calyx reaches a configured MCP server. Holds env var and header
//  names only; their values live in the secret store.
//

import CryptoKit
import Foundation

enum MCPServerTransportConfig: Sendable, Equatable, Codable {
    case stdio(command: String, args: [String], envNames: [String], cwd: String?)
    case http(url: String, headerNames: [String], hint: MCPServerHTTPHint?)

    /// Key of the protocol-era cache. SHA-256 hex of a canonical encoding
    /// of the case and every payload field, each field length-prefixed so
    /// no two distinct configurations share an encoding.
    var fingerprint: String {
        var canonical = ""
        func append(_ field: String?) {
            guard let field else {
                canonical += "-;"
                return
            }
            canonical += "\(field.utf8.count):\(field);"
        }
        func append(_ list: [String]) {
            canonical += "[\(list.count)]"
            list.forEach { append($0) }
        }
        switch self {
        case .stdio(let command, let args, let envNames, let cwd):
            append("stdio")
            append(command)
            append(args)
            append(envNames)
            append(cwd)
        case .http(let url, let headerNames, let hint):
            append("http")
            append(url)
            append(headerNames)
            append(hint?.rawValue)
        }
        return SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
