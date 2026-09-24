//
//  MCPAppInputDelivering.swift
//  Calyx
//
//  Delivery seams for a consented `ui/message`. Cockpit panes go through
//  `CockpitAppAccessing.sendCommand` (main actor); herdr panes go through
//  herdr's socket API (async I/O).
//

import Foundation

@MainActor
protocol MCPAppInputDelivering: AnyObject {
    func deliverUserMessage(_ text: String, to surfaceID: UUID) async throws
}

protocol MCPHerdrPaneInputSending: Sendable {
    func sendText(paneID: String, text: String, pressReturnTwice: Bool) async throws
}
