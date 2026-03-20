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
        static func groupNameTextField(_ id: UUID) -> String { "calyx.sidebar.groupNameTextField.\(id.uuidString)" }
        static func groupCollapseButton(_ id: UUID) -> String { "calyx.sidebar.groupCollapseButton.\(id.uuidString)" }
        static func tabCloseButton(_ id: UUID) -> String { "calyx.sidebar.tab.\(id.uuidString).closeButton" }
        static func groupCloseAllButton(_ id: UUID) -> String { "calyx.sidebar.group.\(id.uuidString).closeAllButton" }
        static func tabAtIndex(_ groupID: UUID, _ index: Int) -> String {
            "calyx.sidebar.group.\(groupID.uuidString).tab.index.\(index)"
        }
    }
    enum TabBar {
        static let container = "calyx.tabBar"
        static let newTabButton = "calyx.tabBar.newTabButton"
        static func tab(_ id: UUID) -> String { "calyx.tabBar.tab.\(id.uuidString)" }
        static func tabCloseButton(_ id: UUID) -> String { "calyx.tabBar.tab.\(id.uuidString).closeButton" }
        static func tabAtIndex(_ index: Int) -> String { "calyx.tabBar.tab.index.\(index)" }
    }
    enum CommandPalette {
        static let container = "calyx.commandPalette"
        static let searchField = "calyx.commandPalette.searchField"
        static let resultsTable = "calyx.commandPalette.resultsTable"
    }
    enum Compose {
        static let container = "calyx.compose"
        static let textView = "calyx.compose.textView"
        static let placeholder = "calyx.compose.placeholder"
    }
    enum Search {
        static let container = "calyx.search"
        static let searchField = "calyx.search.searchField"
        static let matchCount = "calyx.search.matchCount"
        static let previousButton = "calyx.search.previousButton"
        static let nextButton = "calyx.search.nextButton"
        static let closeButton = "calyx.search.closeButton"
    }
    enum Browser {
        static let toolbar = "calyx.browser.toolbar"
        static let backButton = "calyx.browser.backButton"
        static let forwardButton = "calyx.browser.forwardButton"
        static let reloadButton = "calyx.browser.reloadButton"
        static let urlDisplay = "calyx.browser.urlDisplay"
        static let errorBanner = "calyx.browser.errorBanner"
    }
    enum Git {
        static let changesContainer = "calyx.git.changes"
        static let refreshButton = "calyx.git.refreshButton"
        static let modeToggle = "calyx.git.modeToggle"
        static let stagedSection = "calyx.git.staged"
        static let unstagedSection = "calyx.git.unstaged"
        static let untrackedSection = "calyx.git.untracked"
        static let commitsSection = "calyx.git.commits"
        static func fileEntry(_ path: String) -> String { "calyx.git.file.\(path)" }
        static func commitRow(_ hash: String) -> String { "calyx.git.commit.\(hash)" }
    }
    enum Diff {
        static let container = "calyx.diff"
        static let toolbar = "calyx.diff.toolbar"
        static let content = "calyx.diff.content"
        static let lineNumberGutter = "calyx.diff.lineNumbers"
    }
    enum DiffReview {
        static let submitButton = "calyx.diff.review.submitButton"
        static let discardButton = "calyx.diff.review.discardButton"
        static let commentBadge = "calyx.diff.review.commentBadge"
        static let commentPopover = "calyx.diff.review.commentPopover"
        static let submitAllButton = "calyx.diff.review.submitAllButton"
        static let discardAllButton = "calyx.diff.review.discardAllButton"
    }
}
