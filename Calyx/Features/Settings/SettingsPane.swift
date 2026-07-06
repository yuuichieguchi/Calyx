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
}
