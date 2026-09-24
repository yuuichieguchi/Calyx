//
//  MCPOAuthCredentialSet.swift
//  Calyx
//
//  The credentials an OAuth token endpoint returned for one MCP server.
//  `description` and `debugDescription` never print the credential values.
//

import Foundation

struct MCPOAuthTokenSet: Sendable, Equatable {
    let accessToken: String
    let refreshToken: String?
    /// Absolute expiry computed from the response's `expires_in`; nil when
    /// the token endpoint did not report a lifetime.
    let expiresAt: Date?
    /// Space-separated granted scope, as received.
    let scope: String?
}

extension MCPOAuthTokenSet: CustomStringConvertible, CustomDebugStringConvertible {
    var description: String {
        "MCPOAuthTokenSet(accessToken: <redacted>, refreshToken: \(refreshToken == nil ? "nil" : "<redacted>"), expiresAt: \(String(describing: expiresAt)), scope: \(String(describing: scope)))"
    }

    var debugDescription: String { description }
}
