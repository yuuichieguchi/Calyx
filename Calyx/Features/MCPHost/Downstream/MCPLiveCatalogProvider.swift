//
//  MCPLiveCatalogProvider.swift
//  Calyx
//
//  The catalog `/calyx-mcp` and Settings read: every enabled server that
//  has a connection, with the tools that connection last listed, named
//  under the server's alias, plus the app tools registered by the views
//  of the calling pane only.
//

import Foundation

@MainActor
final class MCPLiveCatalogProvider: MCPCatalogProviding {

    private let registry: MCPServerRegistry
    private let connections: any MCPConnectionLookup
    private let appToolRegistry: any MCPAppToolRegistry

    /// In the app, `connections` is the `MCPUpstreamSupervisor`.
    init(registry: MCPServerRegistry, connections: any MCPConnectionLookup, appToolRegistry: any MCPAppToolRegistry) {
        self.registry = registry
        self.connections = connections
        self.appToolRegistry = appToolRegistry
    }

    /// A server without a connection (not built yet, or retired while AI
    /// Agent IPC is off) contributes no tools.
    func currentCatalog(clientDeclaredUI: Bool, surfaceID: UUID?) async -> MCPCatalogResult {
        var serverTools: [MCPServerID: (alias: MCPServerAlias, displayName: String, tools: [MCPToolDefinition], clientDeclaredUI: Bool)] = [:]
        for config in registry.servers where config.isEnabled {
            guard let connection = await connections.connection(forServerID: config.id) else { continue }
            serverTools[config.id] = (config.alias, config.displayName, await connection.tools(), clientDeclaredUI)
        }
        let paneAppTools = surfaceID.map { appToolRegistry.appTools(forSurface: $0) } ?? []
        return MCPToolCatalog.build(serverTools: serverTools, paneAppTools: paneAppTools)
    }

    /// Looks the name up in the catalog of `surfaceID` as seen by a caller
    /// that declared the UI extension, so an app-only tool also resolves
    /// (the router rejects calling it with -32000).
    func resolve(exportedName: String, surfaceID: UUID?) async -> MCPCatalogResolvedTool? {
        await currentCatalog(clientDeclaredUI: true, surfaceID: surfaceID).tools.first { $0.exportedName == exportedName }
    }
}
