//
//  FakeAppToolRegistry.swift
//  CalyxTests
//
//  Test double for MCPAppToolRegistry (Host §9, assigned in contract v2
//  §14). Records every registerAppTools/unregisterAppTools call so a test
//  can assert the owning surfaceID/serverID MCPAppHostStore forwards, and
//  yields on `changes` exactly as the real registry would.
//

import Foundation
@testable import Calyx

@MainActor
final class FakeAppToolRegistry: MCPAppToolRegistry {
    struct RegisterCall: Equatable {
        let tools: [String]
        let surfaceID: UUID
        let viewID: UUID
        let serverID: MCPServerID
    }

    private(set) var registerCalls: [RegisterCall] = []
    private(set) var unregisteredViewIDs: [UUID] = []
    private var toolsByViewID: [UUID: (surfaceID: UUID, serverID: MCPServerID, tools: [MCPToolDefinition])] = [:]

    private let continuation: AsyncStream<UUID>.Continuation
    nonisolated let changes: AsyncStream<UUID>

    init() {
        var continuation: AsyncStream<UUID>.Continuation!
        self.changes = AsyncStream { continuation = $0 }
        self.continuation = continuation
    }

    func registerAppTools(_ tools: [MCPToolDefinition], forSurface surfaceID: UUID, viewID: UUID, serverID: MCPServerID) {
        registerCalls.append(RegisterCall(tools: tools.map(\.name), surfaceID: surfaceID, viewID: viewID, serverID: serverID))
        toolsByViewID[viewID] = (surfaceID, serverID, tools)
        continuation.yield(surfaceID)
    }

    func unregisterAppTools(forView viewID: UUID) {
        unregisteredViewIDs.append(viewID)
        if let entry = toolsByViewID.removeValue(forKey: viewID) {
            continuation.yield(entry.surfaceID)
        }
    }

    func appTools(forSurface surfaceID: UUID) -> [MCPCatalogPaneAppTool] {
        toolsByViewID
            .filter { $0.value.surfaceID == surfaceID }
            .flatMap { viewID, entry in
                entry.tools.map {
                    MCPCatalogPaneAppTool(surfaceID: entry.surfaceID, viewID: viewID, serverID: entry.serverID, name: $0.name, definition: $0)
                }
            }
    }
}
