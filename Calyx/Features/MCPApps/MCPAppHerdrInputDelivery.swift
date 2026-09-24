//
//  MCPAppHerdrInputDelivery.swift
//  Calyx
//
//  Pastes a `ui/message` into a herdr pane with the same Return rule as
//  the cockpit path.
//

import Foundation

@MainActor
final class MCPAppHerdrInputDelivery {
    private let herdrInput: any MCPHerdrPaneInputSending
    private let isAgentPane: @MainActor (UUID) -> Bool

    init(herdrInput: any MCPHerdrPaneInputSending, isAgentPane: @escaping @MainActor (UUID) -> Bool) {
        self.herdrInput = herdrInput
        self.isAgentPane = isAgentPane
    }

    /// A herdr pane without a Calyx surface gets one Return.
    func deliverUserMessage(_ text: String, to ref: HerdrPaneRef, surfaceID: UUID?) async throws {
        let pressReturnTwice = surfaceID.map { isAgentPane($0) } ?? false
        try await herdrInput.sendText(paneID: ref.paneID, text: text, pressReturnTwice: pressReturnTwice)
    }
}
