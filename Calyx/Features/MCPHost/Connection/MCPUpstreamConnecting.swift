//
//  MCPUpstreamConnecting.swift
//  Calyx
//
//  What the rest of the MCP host needs from one supervised upstream
//  server connection.
//

import Foundation

/// A supervised connection to one upstream MCP server.
///
/// `events` is a single-consumer stream; every read returns the same
/// stream. `callTool`, `readResource` and the list requests are cancelled
/// by cancelling the Task that awaits them.
///
/// `listResources`, `listResourceTemplates` and `listPrompts` return one
/// page with its items as received; the caller follows `nextCursor`.
protocol MCPUpstreamConnecting: Sendable {
    nonisolated var serverID: MCPServerID { get }
    func tools() async -> [MCPToolDefinition]
    func state() async -> MCPConnectionState
    var events: AsyncStream<MCPServerEvent> { get async }
    func callTool(
        name: String,
        arguments: [String: AnyCodable],
        context: MCPToolCallContext
    ) async -> MCPUpstreamClient.ToolCallOutcome
    func readResource(uri: String) async throws -> [String: AnyCodable]
    func listResources(cursor: String?) async throws -> (items: [[String: AnyCodable]], nextCursor: String?)
    func listResourceTemplates(cursor: String?) async throws -> (items: [[String: AnyCodable]], nextCursor: String?)
    func listPrompts(cursor: String?) async throws -> (items: [[String: AnyCodable]], nextCursor: String?)
}

enum MCPServerEvent: Sendable, Equatable {
    /// Emitted for every state change, in order.
    case stateChanged(MCPConnectionState)
    /// Emitted after the tool list was fetched again because of
    /// `notifications/tools/list_changed` or a `-32020` reply.
    case toolsChanged
}
