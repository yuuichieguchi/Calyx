//
//  MCPServerSettingsActions.swift
//  Calyx
//
//  The server actions and the sign-in state that Settings > MCP Servers
//  needs but no MCP host type exposes to it directly. The composition
//  root implements this over the upstream supervisor and the OAuth
//  credential store.
//

import Foundation

@MainActor
protocol MCPServerSettingsActions: AnyObject {
    /// Moves a `failed` connection back to `connecting`.
    func retry(serverID: MCPServerID) async throws
    /// Runs the OAuth sign-in of a server in `needsAuthorization`.
    /// Cancelling the calling task cancels the sign-in and closes its
    /// loopback listener.
    func signIn(serverID: MCPServerID) async throws
    /// Deletes the server's stored tokens.
    func signOut(serverID: MCPServerID) async throws
    func authState(for serverID: MCPServerID) async throws -> MCPServerAuthState
}
