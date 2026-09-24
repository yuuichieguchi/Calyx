//
//  MCPAppActivityIndicator.swift
//  Calyx
//
//  Which tabs have an MCP App view that is live or waiting for its app,
//  for the dot in the tab bar and the sidebar. Derived from the store by
//  the composition root on every `.calyxMCPAppViewsChanged`; `Tab` itself
//  holds no MCP App state.
//

import Observation
import SwiftUI

@MainActor @Observable
final class MCPAppActivityIndicatorModel {

    static let shared = MCPAppActivityIndicatorModel()

    /// Tabs with a live or waiting view.
    private(set) var activeTabIDs: Set<UUID> = []

    func update(activeTabIDs: Set<UUID>) {
        guard activeTabIDs != self.activeTabIDs else { return }
        self.activeTabIDs = activeTabIDs
    }
}

/// A dot shown on a tab whose MCP App views keep running while the tab
/// is in the background.
struct MCPAppActivityDot: View {
    let tabID: UUID
    @State private var model = MCPAppActivityIndicatorModel.shared

    var body: some View {
        if model.activeTabIDs.contains(tabID) {
            Circle()
                .fill(Color.accentColor)
                .frame(width: 6, height: 6)
                .help("An MCP App is running in this tab")
                .accessibilityLabel("MCP App running")
                .accessibilityIdentifier(AccessibilityID.MCPApps.tabActivityIndicator(tabID))
        }
    }
}
