//
//  MCPLiveAppToolRegistry.swift
//  Calyx
//
//  The app tools each live view registered, by view, listed per pane in
//  registration order. `changes` yields the pane's surfaceID on every
//  registration and on every removal of a view that had registered tools.
//

import Foundation

@MainActor
final class MCPLiveAppToolRegistry: MCPAppToolRegistry {

    private struct Registration {
        let surfaceID: UUID
        let serverID: MCPServerID
        let tools: [MCPToolDefinition]
    }

    nonisolated let changes: AsyncStream<UUID>
    private let changesContinuation: AsyncStream<UUID>.Continuation
    private var registrations: [UUID: Registration] = [:]
    /// View ids in the order they first registered.
    private var order: [UUID] = []

    init() {
        (changes, changesContinuation) = AsyncStream<UUID>.makeStream()
    }

    /// Replaces any tools the same view registered before.
    func registerAppTools(_ tools: [MCPToolDefinition], forSurface surfaceID: UUID, viewID: UUID, serverID: MCPServerID) {
        if registrations[viewID] == nil {
            order.append(viewID)
        }
        registrations[viewID] = Registration(surfaceID: surfaceID, serverID: serverID, tools: tools)
        changesContinuation.yield(surfaceID)
    }

    func unregisterAppTools(forView viewID: UUID) {
        guard let removed = registrations.removeValue(forKey: viewID) else { return }
        order.removeAll { $0 == viewID }
        changesContinuation.yield(removed.surfaceID)
    }

    func appTools(forSurface surfaceID: UUID) -> [MCPCatalogPaneAppTool] {
        order.compactMap { viewID in registrations[viewID].map { (viewID, $0) } }
            .filter { $0.1.surfaceID == surfaceID }
            .flatMap { viewID, registration in
                registration.tools.map {
                    MCPCatalogPaneAppTool(
                        surfaceID: registration.surfaceID, viewID: viewID, serverID: registration.serverID,
                        name: $0.name, definition: $0
                    )
                }
            }
    }
}
