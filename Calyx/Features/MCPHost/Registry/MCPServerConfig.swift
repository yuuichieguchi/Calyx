//
//  MCPServerConfig.swift
//  Calyx
//
//  One entry of `mcp-servers.json`.
//

import Foundation

struct MCPServerConfig: Sendable, Equatable, Codable {
    let id: MCPServerID
    /// Fixed at creation.
    let alias: MCPServerAlias
    var displayName: String
    var isEnabled: Bool
    let transport: MCPServerTransportConfig
    var auth: MCPServerAuthConfig?
}
