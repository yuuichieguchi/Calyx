//
//  FakeAppToolRegistry.swift
//  CalyxTests
//
//  `MCPAppToolRegistry` test double, Downstream-scoped (API contract
//  section 9 / section 14). Section 14's table places a
//  `FakeAppToolRegistry.swift` under `CalyxTests/MCPApps/` for the Apps
//  module's own tests; this one is a SEPARATE, Downstream-only double
//  (named `RouterFakeAppToolRegistry` to avoid a duplicate top-level
//  type in the shared test target) used solely to drive
//  `MCPCalyxMCPRouter`'s subscription to `changes` (section 10.6 rule
//  11's pane-scoped half): each yielded `UUID` is the surfaceID whose
//  registered/unregistered app tools changed, and the router is
//  expected to route `notifications/tools/list_changed` only to that
//  pane's own open notification stream.
//

import Foundation
@testable import Calyx

@MainActor
final class RouterFakeAppToolRegistry: MCPAppToolRegistry, @unchecked Sendable {
    private(set) var registerCalls: [(tools: [MCPToolDefinition], surfaceID: UUID, viewID: UUID, serverID: MCPServerID)] = []
    private(set) var unregisteredViewIDs: [UUID] = []
    private var toolsBySurface: [UUID: [MCPCatalogPaneAppTool]] = [:]

    nonisolated let changes: AsyncStream<UUID>
    private let changesContinuation: AsyncStream<UUID>.Continuation

    init() {
        var capturedContinuation: AsyncStream<UUID>.Continuation!
        self.changes = AsyncStream<UUID> { continuation in
            capturedContinuation = continuation
        }
        self.changesContinuation = capturedContinuation
    }

    func registerAppTools(_ tools: [MCPToolDefinition], forSurface surfaceID: UUID, viewID: UUID, serverID: MCPServerID) {
        registerCalls.append((tools, surfaceID, viewID, serverID))
    }

    func unregisterAppTools(forView viewID: UUID) {
        unregisteredViewIDs.append(viewID)
    }

    func appTools(forSurface surfaceID: UUID) -> [MCPCatalogPaneAppTool] {
        toolsBySurface[surfaceID] ?? []
    }

    /// Test-only: script `appTools(forSurface:)`'s return value ahead of
    /// emitting a change for that surface.
    func setAppTools(_ tools: [MCPCatalogPaneAppTool], forSurface surfaceID: UUID) {
        toolsBySurface[surfaceID] = tools
    }

    /// Test-only: simulate a view registering/unregistering an app tool
    /// for `surfaceID`, which a real implementation would yield from
    /// `changes` as a side effect of `registerAppTools`/`unregisterAppTools`.
    func emitChange(forSurface surfaceID: UUID) {
        changesContinuation.yield(surfaceID)
    }
}
