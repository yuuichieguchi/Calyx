// TabContextMenu.swift
// Calyx

import AppKit

/// Builds the context menu for one tab. Shared by the tab bar
/// (`TabItemButton`) and the sidebar tab rows (`TabRowItemView`).
enum TabContextMenu {
    struct Actions {
        var close: () -> Void
        var closeOthers: () -> Void
        var closeToTheRight: () -> Void
        var showAllTabs: () -> Void
        var rename: () -> Void
        /// Promotes a preview diff tab to a permanent one (issue #51).
        /// Non-nil only when the tab `isPreview`; the "Keep Open" item is
        /// shown only then, so permanent tabs get the menu unchanged.
        var keepOpen: (() -> Void)? = nil
    }

    @MainActor
    static func make(tabIndex: Int, tabCount: Int, actions: Actions) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        menu.addItem(ClosureMenuItem(title: "Close Tab", symbolName: "xmark", handler: actions.close))

        menu.addItem(ClosureMenuItem(
            title: "Close Other Tabs", symbolName: "xmark", isEnabled: tabCount > 1, handler: actions.closeOthers
        ))

        menu.addItem(ClosureMenuItem(
            title: "Close Tabs to the Right", symbolName: "xmark", isEnabled: tabIndex < tabCount - 1,
            handler: actions.closeToTheRight
        ))

        menu.addItem(ClosureMenuItem(
            title: "Show All Tabs", symbolName: "square.grid.2x2", handler: actions.showAllTabs
        ))

        menu.addItem(.separator())

        menu.addItem(ClosureMenuItem(title: "Rename Tab...", symbolName: "pencil.line", handler: actions.rename))

        if let keepOpen = actions.keepOpen {
            menu.addItem(ClosureMenuItem(title: "Keep Open", symbolName: "pin", handler: keepOpen))
        }

        return menu
    }
}
