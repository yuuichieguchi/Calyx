//
//  MCPAppHostInterfaces.swift
//  Calyx
//
//  The contract between the downstream `/calyx-mcp` side and the MCP Apps
//  view host: protocols and values only.
//

import Foundation

/// Identifies one UI tool invocation for the lifetime of its view.
struct MCPInvocationID: Sendable, Equatable, Hashable {
    let rawValue: UUID

    init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

/// A proxied `tools/call` whose result Calyx renders.
struct MCPUIToolInvocation: Sendable, Equatable {
    let id: MCPInvocationID
    let serverID: MCPServerID
    let serverDisplayName: String
    let tool: MCPToolDefinition
    let upstreamRequestID: JSONRPCId
    let arguments: [String: AnyCodable]
    /// The calling pane. Nil renders in a standalone panel.
    let surfaceID: UUID?
    /// `_meta.clientInfo.name`, or the legacy session's client name.
    let clientName: String?
    let clientDeclaredUI: Bool
    let requestedAt: Date
}

@MainActor
protocol MCPAppViewHosting: AnyObject {
    func uiToolInvocationDidStart(_ invocation: MCPUIToolInvocation, session: any MCPAppServerSession) async
    func hasActiveView(forSurface surfaceID: UUID) -> Bool
    func isStandalonePanel(_ id: MCPInvocationID) -> Bool
    func remapSurface(old: UUID, new: UUID)
    func teardownViews(forServer serverID: MCPServerID, reason: String) async
    /// Calls an app tool (`MCPCatalogToolOrigin.app`) on the view in
    /// `surfaceID` that registered it. Without such a view the result is
    /// `isError`.
    func callAppTool(surfaceID: UUID, name: String, arguments: [String: AnyCodable]) async -> MCPCallToolResult
    /// The upstream call finished. `result` is the same result returned to
    /// the agent, `isError` included. Records it and returns at once,
    /// without waiting for the view: `ui/notifications/tool-result` goes
    /// out in lifecycle order.
    func uiToolInvocationDidFinish(_ id: MCPInvocationID, result: MCPCallToolResult) async
    /// The upstream call was cancelled (`ui/notifications/tool-cancelled`).
    /// Returns at once.
    func uiToolInvocationWasCancelled(_ id: MCPInvocationID) async
    /// Every state change of a server's connection, in order. The views of
    /// a server that is not `ready` show it as disconnected, and their
    /// proxied requests fail with -32000.
    func serverConnectionChanged(serverID: MCPServerID, state: MCPConnectionState)
}

/// Bound to one server. No method takes a server, so a view cannot reach
/// another server through its session.
protocol MCPAppServerSession: Sendable {
    var serverID: MCPServerID { get }
    var serverDisplayName: String { get }
    func callTool(name: String, arguments: [String: AnyCodable]) async throws -> MCPCallToolResult
    func readResource(uri: String) async throws -> [String: AnyCodable]
    /// Only the tools whose visibility includes `app`.
    func listTools() async -> [MCPToolDefinition]
    func listResources(cursor: String?) async throws -> (items: [[String: AnyCodable]], nextCursor: String?)
    func listResourceTemplates(cursor: String?) async throws -> (items: [[String: AnyCodable]], nextCursor: String?)
    func listPrompts(cursor: String?) async throws -> (items: [[String: AnyCodable]], nextCursor: String?)
    func events() -> AsyncStream<MCPServerEvent>
}

@MainActor
protocol MCPAppToolRegistry: AnyObject, Sendable {
    /// Publishes the app tools a view registered to the agent of the pane
    /// that owns the view, through the dynamic catalog.
    func registerAppTools(_ tools: [MCPToolDefinition], forSurface surfaceID: UUID, viewID: UUID, serverID: MCPServerID)
    func unregisterAppTools(forView viewID: UUID)
    /// The app tools registered by the live views of that pane.
    func appTools(forSurface surfaceID: UUID) -> [MCPCatalogPaneAppTool]
    /// Yields the pane's surfaceID on every registration and removal.
    /// Single consumer.
    nonisolated var changes: AsyncStream<UUID> { get }
}

@MainActor
protocol MCPAuthorizationPrompting: AnyObject, Sendable {
    /// Shown near the calling pane when one is known, app-wide otherwise,
    /// naming the server.
    func promptSignIn(serverID: MCPServerID, serverDisplayName: String, surfaceID: UUID?) async
}

/// The latest `ui/update-model-context` of one live view.
struct MCPAppModelContextEntry: Sendable, Equatable {
    let viewID: UUID
    let serverDisplayName: String
    let toolName: String
    /// Text and image content blocks only.
    let content: [AnyCodable]?
    let structuredContent: AnyCodable?
}

@MainActor
protocol MCPAppModelContextProviding: AnyObject {
    func modelContexts(forSurface surfaceID: UUID) -> [MCPAppModelContextEntry]
}
