//
//  MCPOAuthRedirectConfig.swift
//  Calyx
//
//  Where the loopback OAuth redirect listener binds. The fixed Calyx port
//  is for authorization servers that require an exact port match.
//

import Foundation

enum MCPOAuthRedirectHost: String, Sendable, Equatable, Codable {
    /// `127.0.0.1`
    case loopback
    /// `localhost`
    case localhost
}

enum MCPOAuthRedirectPort: Sendable, Equatable, Codable {
    /// A kernel-assigned ephemeral port.
    case random
    /// `MCPOAuthRedirectConfig.calyxFixedPort`.
    case calyxFixed
}

struct MCPOAuthRedirectConfig: Sendable, Equatable, Codable {
    let host: MCPOAuthRedirectHost
    let port: MCPOAuthRedirectPort

    /// The only definition of the fixed port. It does not overlap the IPC
    /// server's 41830 range or the browser 41840 range.
    static let calyxFixedPort = 41890
}
