//
//  SettingsRow.swift
//  Calyx
//
//  Enumerates every interactive element in the Settings window and pins
//  which SettingsPane it belongs to. SettingsWindowController builds each
//  pane's content by filtering SettingsRow.allCases on `pane`, so moving a
//  row between panes (or dropping one) is a change to this file alone,
//  not to a second, independently-maintained layout.
//

import Foundation

enum SettingsRow: String, CaseIterable {
    case themeColorPreset
    case themeColorWell
    case themeColorHex
    case glassOpacity
    case smoothScrolling
    case lspAutoInstall
    case lspRequireConfirmation
    case persistentSessions
    case historyPersistence
    case agentResume
    case agentResumeAutoExecute
    case cockpitAutoApprove
    case commandTracking
    case openSessionBrowserButton
    case openConfigFileFooter

    var pane: SettingsPane {
        switch self {
        case .themeColorPreset, .themeColorWell, .themeColorHex,
             .glassOpacity, .smoothScrolling, .openConfigFileFooter:
            return .appearance
        case .lspAutoInstall, .lspRequireConfirmation:
            return .lsp
        case .persistentSessions, .historyPersistence, .openSessionBrowserButton:
            return .sessions
        case .agentResume, .agentResumeAutoExecute, .cockpitAutoApprove, .commandTracking:
            return .agents
        }
    }
}
