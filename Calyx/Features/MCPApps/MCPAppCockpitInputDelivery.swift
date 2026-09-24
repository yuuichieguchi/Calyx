//
//  MCPAppCockpitInputDelivery.swift
//  Calyx
//
//  Pastes a `ui/message` into a Calyx pane through the same path and the
//  same Return rule as `pane_run`: a pane with an AgentRegistry entry gets
//  two synthetic Returns, any other pane one. No CLI-name branching.
//

import Foundation

@MainActor
final class MCPAppCockpitInputDelivery: MCPAppInputDelivering {
    private let access: any CockpitAppAccessing
    private let isAgentPane: @MainActor (UUID) -> Bool

    /// In the app, `isAgentPane` is `{ agentRegistry.entries[$0] != nil }`.
    init(access: any CockpitAppAccessing, isAgentPane: @escaping @MainActor (UUID) -> Bool) {
        self.access = access
        self.isAgentPane = isAgentPane
    }

    func deliverUserMessage(_ text: String, to surfaceID: UUID) async throws {
        try access.sendCommand(surfaceID: surfaceID, command: text, doubleReturn: isAgentPane(surfaceID))
    }
}
