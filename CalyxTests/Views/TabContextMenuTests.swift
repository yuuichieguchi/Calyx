// TabContextMenuTests.swift
// CalyxTests
//
// Covers `TabContextMenu.make(tabIndex:tabCount:actions:)`
// (Calyx/Views/TabBar/TabContextMenu.swift). The
// menu shown on right-click/Ctrl+click for a tab bar tab or a sidebar
// tab row must always contain exactly 6 items, in this exact order:
// "Close Tab", "Close Other Tabs", "Close Tabs to the Right", "Show All
// Tabs", a separator, "Rename Tab...". Enabled state for "Close Other Tabs" is
// `tabCount > 1`; for "Close Tabs to the Right" it is
// `tabIndex < tabCount - 1`. "Close Tab", "Show All Tabs" and
// "Rename Tab..." are always enabled. Firing an item's `target`/`action` must invoke exactly the
// matching `Actions` closure, targeting the right-clicked tab (the
// caller supplies `tabIndex`/`tabCount` for THAT tab, never the active
// one).

import XCTest
import AppKit
@testable import Calyx

@MainActor
final class TabContextMenuTests: XCTestCase {

    // MARK: - Fixture

    /// Five independent counters, one per `Actions` closure, so firing
    /// one item can be asserted to increment ONLY its own counter and
    /// none of the others.
    private final class ActionCounters {
        var close = 0
        var closeOthers = 0
        var closeToTheRight = 0
        var showAllTabs = 0
        var rename = 0
    }

    private func makeCounters() -> (ActionCounters, TabContextMenu.Actions) {
        let counters = ActionCounters()
        let actions = TabContextMenu.Actions(
            close: { counters.close += 1 },
            closeOthers: { counters.closeOthers += 1 },
            closeToTheRight: { counters.closeToTheRight += 1 },
            showAllTabs: { counters.showAllTabs += 1 },
            rename: { counters.rename += 1 }
        )
        return (counters, actions)
    }

    // MARK: - Structure

    /// By hand, per spec: 6 items, titles at indices 0/1/2/3/5 exactly as
    /// listed, index 4 a separator, `autoenablesItems == false` (so the
    /// enabled-state tests below are meaningful -- AppKit would otherwise
    /// override them based on `target`/`action` validation).
    func test_make_returnsSixItemsInOrder_withSeparatorAtIndex4_andAutoenablesItemsDisabled() {
        let (_, actions) = makeCounters()
        let menu = TabContextMenu.make(tabIndex: 0, tabCount: 3, actions: actions)

        XCTAssertFalse(menu.autoenablesItems, "autoenablesItems must be false so enabled flags are set explicitly, not by AppKit target/action validation")
        XCTAssertEqual(menu.items.count, 6, "Menu must have exactly 6 items")
        XCTAssertEqual(menu.items[0].title, "Close Tab")
        XCTAssertEqual(menu.items[1].title, "Close Other Tabs")
        XCTAssertEqual(menu.items[2].title, "Close Tabs to the Right")
        XCTAssertEqual(menu.items[3].title, "Show All Tabs", "Show All Tabs must sit right after the close items, before the separator (Ghostty order)")
        XCTAssertTrue(menu.items[4].isSeparatorItem, "Item at index 4 must be a separator")
        XCTAssertEqual(menu.items[5].title, "Rename Tab...")
    }

    // MARK: - Enabled state

    /// (tabIndex 0, tabCount 1): the only tab in its group. "Close Other
    /// Tabs" must be disabled (no other tab exists to close) and "Close
    /// Tabs to the Right" must be disabled (0 is not < 1 - 1 == 0).
    /// "Close Tab" and "Rename Tab..." are always enabled.
    func test_enabledState_singleTab_disablesCloseOthersAndCloseToTheRight() {
        let (_, actions) = makeCounters()
        let menu = TabContextMenu.make(tabIndex: 0, tabCount: 1, actions: actions)

        XCTAssertTrue(menu.items[0].isEnabled, "Close Tab must always be enabled")
        XCTAssertFalse(menu.items[1].isEnabled, "Close Other Tabs must be disabled when tabCount == 1")
        XCTAssertFalse(menu.items[2].isEnabled, "Close Tabs to the Right must be disabled for the last (only) tab")
        XCTAssertTrue(menu.items[5].isEnabled, "Rename Tab... must always be enabled")
    }

    /// (tabIndex 0, tabCount 3): first of three tabs. "Close Other Tabs"
    /// enabled (2 other tabs exist), "Close Tabs to the Right" enabled
    /// (0 < 3 - 1 == 2).
    func test_enabledState_firstOfThreeTabs_enablesBoth() {
        let (_, actions) = makeCounters()
        let menu = TabContextMenu.make(tabIndex: 0, tabCount: 3, actions: actions)

        XCTAssertTrue(menu.items[0].isEnabled)
        XCTAssertTrue(menu.items[1].isEnabled, "Close Other Tabs must be enabled when tabCount > 1")
        XCTAssertTrue(menu.items[2].isEnabled, "Close Tabs to the Right must be enabled when tabIndex < tabCount - 1")
        XCTAssertTrue(menu.items[5].isEnabled)
    }

    /// (tabIndex 2, tabCount 3): last of three tabs. "Close Other Tabs"
    /// enabled (2 other tabs exist), "Close Tabs to the Right" disabled
    /// (2 is not < 3 - 1 == 2).
    func test_enabledState_lastOfThreeTabs_enablesCloseOthers_disablesCloseToTheRight() {
        let (_, actions) = makeCounters()
        let menu = TabContextMenu.make(tabIndex: 2, tabCount: 3, actions: actions)

        XCTAssertTrue(menu.items[0].isEnabled)
        XCTAssertTrue(menu.items[1].isEnabled, "Close Other Tabs must be enabled when tabCount > 1")
        XCTAssertFalse(menu.items[2].isEnabled, "Close Tabs to the Right must be disabled for the last tab")
        XCTAssertTrue(menu.items[5].isEnabled)
    }

    // MARK: - Firing

    /// Firing "Close Tab" must invoke ONLY the `close` closure, exactly
    /// once, and none of the others.
    func test_firingCloseTab_invokesOnlyCloseClosure() {
        let (counters, actions) = makeCounters()
        let menu = TabContextMenu.make(tabIndex: 0, tabCount: 3, actions: actions)
        let item = menu.items[0]

        let fired = NSApp.sendAction(item.action!, to: item.target, from: item)

        XCTAssertTrue(fired, "NSApp.sendAction must find a responder for the item's target/action")
        XCTAssertEqual(counters.close, 1)
        XCTAssertEqual(counters.closeOthers, 0)
        XCTAssertEqual(counters.closeToTheRight, 0)
        XCTAssertEqual(counters.showAllTabs, 0)
        XCTAssertEqual(counters.rename, 0)
    }

    /// Firing "Close Other Tabs" must invoke ONLY the `closeOthers`
    /// closure, exactly once, and none of the others.
    func test_firingCloseOtherTabs_invokesOnlyCloseOthersClosure() {
        let (counters, actions) = makeCounters()
        let menu = TabContextMenu.make(tabIndex: 0, tabCount: 3, actions: actions)
        let item = menu.items[1]

        let fired = NSApp.sendAction(item.action!, to: item.target, from: item)

        XCTAssertTrue(fired)
        XCTAssertEqual(counters.close, 0)
        XCTAssertEqual(counters.closeOthers, 1)
        XCTAssertEqual(counters.closeToTheRight, 0)
        XCTAssertEqual(counters.showAllTabs, 0)
        XCTAssertEqual(counters.rename, 0)
    }

    /// Firing "Close Tabs to the Right" must invoke ONLY the
    /// `closeToTheRight` closure, exactly once, and none of the
    /// others.
    func test_firingCloseTabsToTheRight_invokesOnlyCloseToTheRightClosure() {
        let (counters, actions) = makeCounters()
        let menu = TabContextMenu.make(tabIndex: 0, tabCount: 3, actions: actions)
        let item = menu.items[2]

        let fired = NSApp.sendAction(item.action!, to: item.target, from: item)

        XCTAssertTrue(fired)
        XCTAssertEqual(counters.close, 0)
        XCTAssertEqual(counters.closeOthers, 0)
        XCTAssertEqual(counters.closeToTheRight, 1)
        XCTAssertEqual(counters.showAllTabs, 0)
        XCTAssertEqual(counters.rename, 0)
    }

    /// Firing "Rename Tab..." must invoke ONLY the `rename` closure,
    /// exactly once, and none of the others.
    func test_firingRenameTab_invokesOnlyRenameClosure() {
        let (counters, actions) = makeCounters()
        let menu = TabContextMenu.make(tabIndex: 0, tabCount: 3, actions: actions)
        let item = menu.items[5]

        let fired = NSApp.sendAction(item.action!, to: item.target, from: item)

        XCTAssertTrue(fired)
        XCTAssertEqual(counters.close, 0)
        XCTAssertEqual(counters.closeOthers, 0)
        XCTAssertEqual(counters.closeToTheRight, 0)
        XCTAssertEqual(counters.showAllTabs, 0)
        XCTAssertEqual(counters.rename, 1)
    }
    // MARK: - Show All Tabs

    /// "Show All Tabs" is always enabled, whatever the tab position/count.
    func test_enabledState_showAllTabs_isAlwaysEnabled() {
        let (_, actions) = makeCounters()
        for (tabIndex, tabCount) in [(0, 1), (0, 3), (2, 3)] {
            let menu = TabContextMenu.make(tabIndex: tabIndex, tabCount: tabCount, actions: actions)
            XCTAssertEqual(menu.items[3].title, "Show All Tabs")
            XCTAssertTrue(menu.items[3].isEnabled, "Show All Tabs must be enabled for tabIndex \(tabIndex), tabCount \(tabCount)")
        }
    }

    /// Firing "Show All Tabs" must invoke ONLY the `showAllTabs` closure,
    /// exactly once, and none of the others.
    func test_firingShowAllTabs_invokesOnlyShowAllTabsClosure() {
        let (counters, actions) = makeCounters()
        let menu = TabContextMenu.make(tabIndex: 0, tabCount: 3, actions: actions)
        let item = menu.items[3]

        let fired = NSApp.sendAction(item.action!, to: item.target, from: item)

        XCTAssertTrue(fired)
        XCTAssertEqual(counters.close, 0)
        XCTAssertEqual(counters.closeOthers, 0)
        XCTAssertEqual(counters.closeToTheRight, 0)
        XCTAssertEqual(counters.showAllTabs, 1)
        XCTAssertEqual(counters.rename, 0)
    }
}
