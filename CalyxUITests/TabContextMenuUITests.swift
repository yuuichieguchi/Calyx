// TabContextMenuUITests.swift
// CalyxUITests
//
// E2E tests for the right-click/Ctrl+click tab context menu, shown on
// both the horizontal tab bar and the sidebar tab rows.
//
// Coverage:
// - Right-click a tab bar tab, choose "Close Other Tabs" -> only that tab survives
// - Right-click a sidebar tab row, choose "Rename Tab..." -> the inline editor opens
// - Right-click the single initial tab -> "Close Other Tabs"/"Close Tabs to the Right" are disabled
// - Rename via context menu while a sidebar rename editor is already open ->
//   the tab bar editor opens with the typed (uncommitted) title, proving the
//   sidebar editor was committed first
// - Right-click a tab bar tab, choose "Show All Tabs" -> Mission Map opens

import XCTest

final class TabContextMenuUITests: CalyxUITestCase {

    func test_rightClickTabBarTab_closeOtherTabs_leavesOnlyThatTab() {
        createNewTabViaMenu()
        createNewTabViaMenu()
        waitForTabCount(3)
        XCTAssertEqual(countTabBarTabs(), 3, "Should have three tabs after creating two more")

        let firstTab = tabBarTabsQuery().element(boundBy: 0)
        XCTAssertTrue(firstTab.exists, "First tab bar tab should exist")
        let rightClickedIdentifier = firstTab.identifier

        firstTab.rightClick()

        let closeOtherTabsItem = app.menuItems["Close Other Tabs"]
        XCTAssertTrue(waitFor(closeOtherTabsItem, timeout: 3), "Close Other Tabs menu item should appear")
        closeOtherTabsItem.click()

        waitForTabCount(1)
        XCTAssertEqual(countTabBarTabs(), 1, "Only the right-clicked tab should remain after Close Other Tabs")
        XCTAssertEqual(
            currentTabBarTabIdentifiers(), [rightClickedIdentifier],
            "The survivor must be the tab that was right-clicked, not merely any single tab"
        )
    }

    func test_rightClickSidebarTabRow_renameTab_opensInlineEditor() {
        let sidebarTab = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "calyx.sidebar.tab."))
            .firstMatch
        XCTAssertTrue(waitFor(sidebarTab, timeout: 5), "A sidebar tab row should exist (sidebar is shown by default)")

        sidebarTab.rightClick()

        let renameItem = app.menuItems["Rename Tab..."]
        XCTAssertTrue(waitFor(renameItem, timeout: 3), "Rename Tab... menu item should appear")
        renameItem.click()

        let renameField = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "calyx.sidebar.tabNameTextField."))
            .firstMatch
        XCTAssertTrue(waitFor(renameField, timeout: 3), "Inline rename editor should open after choosing Rename Tab...")

        renameField.typeKey(.escape, modifierFlags: [])
        waitForNonExistence(renameField)
    }

    func test_rightClickSingleTab_closeOthersAndCloseRightAreDisabled() {
        XCTAssertEqual(countTabBarTabs(), 1, "Should start with exactly one tab")

        let onlyTab = tabBarTabsQuery().element(boundBy: 0)
        XCTAssertTrue(onlyTab.exists, "The single tab bar tab should exist")

        onlyTab.rightClick()

        // "Close Tab" also exists in the File menu, so it cannot prove the
        // context menu is open; "Close Other Tabs" is unique to it.
        let closeOtherTabsItem = app.menuItems["Close Other Tabs"]
        XCTAssertTrue(waitFor(closeOtherTabsItem, timeout: 3), "Close Other Tabs menu item should appear")

        XCTAssertFalse(closeOtherTabsItem.isEnabled, "Close Other Tabs must be disabled for the only tab")
        XCTAssertFalse(app.menuItems["Close Tabs to the Right"].isEnabled, "Close Tabs to the Right must be disabled for the only tab")

        app.typeKey(.escape, modifierFlags: [])
    }

    func test_renameViaContextMenu_whileSidebarEditorOpen_carriesTypedTitle() {
        let sidebarTab = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "calyx.sidebar.tab."))
            .firstMatch
        XCTAssertTrue(waitFor(sidebarTab, timeout: 5), "A sidebar tab row should exist (sidebar is shown by default)")

        sidebarTab.doubleClick()

        let sidebarField = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "calyx.sidebar.tabNameTextField."))
            .firstMatch
        XCTAssertTrue(waitFor(sidebarField, timeout: 3), "Double-clicking the sidebar tab row should open its inline editor")

        sidebarField.typeKey("a", modifierFlags: .command)
        sidebarField.typeText("foo")

        // `InlineTextField.makeNSView` installs the click-outside-to-commit
        // monitor via `DispatchQueue.main.asyncAfter(deadline: .now() + 0.3)`;
        // this sleep must exceed that delay before the right-click below.
        Thread.sleep(forTimeInterval: 0.5)

        let firstTabBarTab = tabBarTabsQuery().element(boundBy: 0)
        XCTAssertTrue(firstTabBarTab.exists, "First tab bar tab should exist")

        firstTabBarTab.rightClick()

        let renameItem = app.menuItems["Rename Tab..."]
        XCTAssertTrue(waitFor(renameItem, timeout: 3), "Rename Tab... menu item should appear")
        renameItem.click()

        let tabBarField = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "calyx.tabBar.tabNameTextField."))
            .firstMatch
        XCTAssertTrue(waitFor(tabBarField, timeout: 3), "Tab bar rename editor should open after choosing Rename Tab...")
        XCTAssertEqual(
            tabBarField.value as? String, "foo",
            "The tab bar editor must carry the typed title, proving the sidebar editor was committed before it opened"
        )

        tabBarField.typeKey(.escape, modifierFlags: [])
        waitForNonExistence(tabBarField)
    }

    func test_rightClickTabBarTab_showAllTabs_opensMissionMap() {
        let firstTab = tabBarTabsQuery().element(boundBy: 0)
        XCTAssertTrue(firstTab.exists, "First tab bar tab should exist")

        firstTab.rightClick()

        let showAllTabsItem = app.menuItems["Show All Tabs"]
        XCTAssertTrue(waitFor(showAllTabsItem, timeout: 3), "Show All Tabs menu item should appear")
        showAllTabsItem.click()

        let missionMap = app.descendants(matching: .any)
            .matching(identifier: "calyx.missionMap")
            .firstMatch
        XCTAssertTrue(waitFor(missionMap, timeout: 5), "Mission Map should appear after choosing Show All Tabs")

        app.typeKey(.escape, modifierFlags: [])
        waitForNonExistence(missionMap)
    }
}
