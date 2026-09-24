//
//  MCPOAuthTransportHooks.swift
//  Calyx
//
//  The three closures an HTTP transport receives for an OAuth-protected
//  server. Built by `MCPOAuthFlow.makeTransportHooks(serverID:mcpServerURL:)`.
//

import Foundation

struct MCPOAuthTransportHooks: Sendable {
    /// The bare access token value; the transport adds the `Bearer ` prefix.
    /// Refreshes an expired token first.
    let headerProvider: @Sendable () async throws -> String
    /// Refreshes after a 401; throws `MCPOAuthFlowError.needsAuthorization`
    /// when the refresh is not possible.
    let on401: @Sendable () async throws -> Void
    /// Re-authorizes with the challenge's scope merged into the granted one.
    let on403InsufficientScope: @Sendable (String?) async throws -> Void
}
