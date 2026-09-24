//
//  MCPServerAuthState.swift
//  Calyx
//
//  Sign-in state of one configured MCP server, as shown in Settings.
//

import Foundation

enum MCPServerAuthState: Sendable, Equatable {
    case signedOut
    /// `account` is nil unless a primary source (such as an ID token)
    /// names the account.
    case signedIn(account: String?)
    case notRequired
}
