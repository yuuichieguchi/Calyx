//
//  SettingsPane.swift
//  Calyx
//
//  Identifies the tabs of the Settings window. Order matches the on-screen
//  tab order (toolbar-style NSTabViewController).
//

import Foundation

enum SettingsPane: CaseIterable {
    case appearance
    case sessions
    case lsp

    var title: String {
        switch self {
        case .appearance: return "Appearance"
        case .sessions: return "Sessions"
        case .lsp: return "LSP"
        }
    }

    /// SF Symbol name for this pane's toolbar tab item. The toolbar-style
    /// NSTabViewController renders a tab item with no image as a
    /// degenerate fat header instead of a proper toolbar button.
    var icon: String {
        switch self {
        case .appearance: return "paintbrush"
        case .sessions: return "terminal"
        case .lsp: return "gearshape.2"
        }
    }
}
