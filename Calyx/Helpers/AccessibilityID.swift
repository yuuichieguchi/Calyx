// AccessibilityID.swift
// Calyx
//
// Stable accessibility identifiers for XCUITest element lookup.

import Foundation

enum AccessibilityID {
    enum Sidebar {
        static let container = "calyx.sidebar"
        static let newGroupButton = "calyx.sidebar.newGroupButton"
        static func group(_ id: UUID) -> String { "calyx.sidebar.group.\(id.uuidString)" }
        static func tab(_ id: UUID) -> String { "calyx.sidebar.tab.\(id.uuidString)" }
    }
    enum TabBar {
        static let container = "calyx.tabBar"
        static let newTabButton = "calyx.tabBar.newTabButton"
        static func tab(_ id: UUID) -> String { "calyx.tabBar.tab.\(id.uuidString)" }
        static func tabCloseButton(_ id: UUID) -> String { "calyx.tabBar.tab.\(id.uuidString).closeButton" }
    }
    enum CommandPalette {
        static let container = "calyx.commandPalette"
        static let searchField = "calyx.commandPalette.searchField"
        static let resultsTable = "calyx.commandPalette.resultsTable"
    }
    enum Browser {
        static let toolbar = "calyx.browser.toolbar"
        static let backButton = "calyx.browser.backButton"
        static let forwardButton = "calyx.browser.forwardButton"
        static let reloadButton = "calyx.browser.reloadButton"
        static let urlDisplay = "calyx.browser.urlDisplay"
        static let errorBanner = "calyx.browser.errorBanner"
    }
}
