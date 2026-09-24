//
//  MCPServerHTTPHint.swift
//  Calyx
//
//  User-specified hint for an HTTP MCP server.
//

import Foundation

/// `legacySSE` skips era detection and connects with the 2024-11-05
/// HTTP+SSE transport directly.
enum MCPServerHTTPHint: String, Sendable, Equatable, Codable {
    case legacySSE
}
