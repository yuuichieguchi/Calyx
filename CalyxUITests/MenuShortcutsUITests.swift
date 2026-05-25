// MenuShortcutsUITests.swift
// CalyxUITests
//
// Tests for issue #33: surface README-documented keyboard shortcuts in the
// macOS menu bar, organised to match Ghostty's upstream menu layout. Covers:
//   - Submenu / item existence (Window > Group, File > Split*, Window >
//     Focus Split, Edit > Find)
//   - Menu-triggered actions (New Group, Split Right, Find, Next/Previous
//     Group)
//   - validateMenuItem behavior for Find Next when the search bar is hidden

import XCTest

final class MenuShortcutsUITests: CalyxUITestCase {

    // MARK: - Helpers

    /// Opens a menu bar item by name and waits briefly so the system has time
    /// to populate submenu contents in the accessibility hierarchy.
    private func openMenuBarItem(_ name: String) {
        let menuItem = app.menuBars.menuBarItems[name]
        XCTAssertTrue(
            menuItem.waitForExistence(timeout: 3),
            "Top-level menu '\(name)' should exist in the menu bar"
        )
        menuItem.click()
        Thread.sleep(forTimeInterval: 0.2)
    }

    /// Hovers a menu item by title to expand its submenu, then waits.
    private func hoverMenuItem(_ title: String) {
        let item = app.menuBars.menuItems[title]
        XCTAssertTrue(
            item.waitForExistence(timeout: 3),
            "Menu item '\(title)' should exist before hovering"
        )
        item.hover()
        Thread.sleep(forTimeInterval: 0.3)
    }

    /// Dismisses any open menu by sending Escape twice (one to close the
    /// submenu, one to close the top-level menu) so tests don't leave state.
    private func dismissOpenMenus() {
        app.typeKey(.escape, modifierFlags: [])
        app.typeKey(.escape, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.1)
    }

    /// Returns true if the menu hierarchy currently exposes a menu item with
    /// the given title (under any open submenu).
    private func menuItemExists(_ title: String) -> Bool {
        app.menuBars.menuItems[title].exists
    }

    /// Counts sidebar groups so tests can verify Group menu actions create /
    /// switch groups using the existing `calyx.sidebar.group.<UUID>` identifier
    /// scheme.
    private func currentGroupCount() -> Int {
        countElements(matching: "calyx.sidebar.group.", excludingSuffix: "Button")
    }

    /// Polls `currentGroupCount()` until it reaches `expected` or the timeout
    /// elapses. Returns the final observed count. Replaces fixed
    /// `Thread.sleep` waits for state changes triggered by Group menu actions.
    @discardableResult
    private func waitForGroupCount(_ expected: Int, timeout: TimeInterval = 5) -> Int {
        let deadline = Date().addingTimeInterval(timeout)
        var observed = currentGroupCount()
        while observed != expected, Date() < deadline {
            // Pump the runloop briefly so the sidebar can update.
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            observed = currentGroupCount()
        }
        return observed
    }

    /// Polls `descendants(matching:.splitter).count` on the first window until
    /// the count satisfies `predicate`, then returns the observed count.
    @discardableResult
    private func waitForSplitterCount(
        timeout: TimeInterval = 5,
        where predicate: (Int) -> Bool
    ) -> Int {
        let deadline = Date().addingTimeInterval(timeout)
        var observed = app.windows.firstMatch.descendants(matching: .splitter).count
        while !predicate(observed), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            observed = app.windows.firstMatch.descendants(matching: .splitter).count
        }
        return observed
    }

    // MARK: - 1. Submenu Existence Tests

    func test_groupSubmenu_existsInWindowMenu() {
        openMenuBarItem("Window")
        hoverMenuItem("Group")

        XCTAssertTrue(
            menuItemExists("New Group"),
            "Window > Group submenu should contain 'New Group'"
        )
        XCTAssertTrue(
            menuItemExists("Close Group"),
            "Window > Group submenu should contain 'Close Group'"
        )
        XCTAssertTrue(
            menuItemExists("Next Group"),
            "Window > Group submenu should contain 'Next Group'"
        )
        XCTAssertTrue(
            menuItemExists("Previous Group"),
            "Window > Group submenu should contain 'Previous Group'"
        )

        dismissOpenMenus()
    }

    func test_splitMenuItems_existInFileMenu() {
        openMenuBarItem("File")

        XCTAssertTrue(
            menuItemExists("Split Right"),
            "File menu should contain 'Split Right'"
        )
        XCTAssertTrue(
            menuItemExists("Split Left"),
            "File menu should contain 'Split Left'"
        )
        XCTAssertTrue(
            menuItemExists("Split Down"),
            "File menu should contain 'Split Down'"
        )
        XCTAssertTrue(
            menuItemExists("Split Up"),
            "File menu should contain 'Split Up'"
        )

        dismissOpenMenus()
    }

    func test_focusSplitSubmenu_existsInWindowMenu() {
        openMenuBarItem("Window")
        hoverMenuItem("Focus Split")

        XCTAssertTrue(
            menuItemExists("Focus Split Up"),
            "Window > Focus Split submenu should contain 'Focus Split Up'"
        )
        XCTAssertTrue(
            menuItemExists("Focus Split Down"),
            "Window > Focus Split submenu should contain 'Focus Split Down'"
        )
        XCTAssertTrue(
            menuItemExists("Focus Split Left"),
            "Window > Focus Split submenu should contain 'Focus Split Left'"
        )
        XCTAssertTrue(
            menuItemExists("Focus Split Right"),
            "Window > Focus Split submenu should contain 'Focus Split Right'"
        )

        dismissOpenMenus()
    }

    func test_findSubmenu_existsInEditMenu() {
        openMenuBarItem("Edit")
        hoverMenuItem("Find")

        // The canonical macOS title is "Find…" (with the U+2026 ellipsis
        // character) — match it exactly. We must NOT use BEGINSWITH 'Find'
        // because that would also resolve the parent "Find" submenu item.
        let findItem = app.menuBars.menuItems["Find\u{2026}"]
        XCTAssertTrue(
            findItem.exists,
            "Edit > Find submenu should contain a 'Find…' entry"
        )
        XCTAssertTrue(
            menuItemExists("Find Next"),
            "Edit > Find submenu should contain 'Find Next'"
        )
        XCTAssertTrue(
            menuItemExists("Find Previous"),
            "Edit > Find submenu should contain 'Find Previous'"
        )

        dismissOpenMenus()
    }

    // MARK: - 2. Menu-Driven Action Tests

    func test_newGroupViaMenu_createsSecondGroup() {
        // 起動直後は 1 グループのみ
        XCTAssertEqual(
            currentGroupCount(), 1,
            "Initial state should have exactly one group"
        )

        openMenuBarItem("Window")
        hoverMenuItem("Group")

        let newGroup = app.menuBars.menuItems["New Group"]
        XCTAssertTrue(
            newGroup.waitForExistence(timeout: 3),
            "'New Group' menu item must exist"
        )
        newGroup.click()

        // グループ生成完了を待つ (固定 sleep ではなく count==2 になるまでポーリング)
        let finalCount = waitForGroupCount(2, timeout: 5)

        XCTAssertEqual(
            finalCount, 2,
            "Window > Group > New Group should create a second sidebar group"
        )
    }

    func test_splitRightViaMenu_createsSecondSurface() {
        // 起動直後の split divider 数 (= 0)
        let dividersBefore = app.windows.firstMatch
            .descendants(matching: .splitter)
            .count

        openMenuBarItem("File")

        let splitRight = app.menuBars.menuItems["Split Right"]
        XCTAssertTrue(
            splitRight.waitForExistence(timeout: 3),
            "'Split Right' menu item must exist under File"
        )
        splitRight.click()

        // Split 作成および surface 起動を待つ (固定 sleep ではなく
        // divider 数が増えるまでポーリング)。
        let dividersAfter = waitForSplitterCount(timeout: 8) { $0 > dividersBefore }

        // SplitDividerView は AppKit splitter として露出されることを期待する
        // (divider が増える = surface が 1 → 2 に増えた)
        XCTAssertGreaterThan(
            dividersAfter, dividersBefore,
            "File > Split Right should add a split divider (surface count should grow). before=\(dividersBefore), after=\(dividersAfter)"
        )
    }

    func test_findViaMenu_opensSearchBar() {
        // 起動直後は search bar が非表示
        let searchField = app.descendants(matching: .any)
            .matching(identifier: "calyx.search.searchField")
            .firstMatch
        XCTAssertFalse(
            searchField.exists,
            "Search bar should NOT be visible before invoking Find"
        )

        openMenuBarItem("Edit")
        hoverMenuItem("Find")

        // "Find…" の正式タイトルは U+2026 ellipsis 文字を含む — 親 "Find" 項目を
        // 誤ヒットしないよう厳密一致で取得する。
        let findItem = app.menuBars.menuItems["Find\u{2026}"]
        XCTAssertTrue(
            findItem.waitForExistence(timeout: 3),
            "Edit > Find > Find… menu item must exist"
        )
        findItem.click()

        XCTAssertTrue(
            waitFor(searchField, timeout: 3),
            "Edit > Find > Find… should reveal the in-terminal search bar (identifier: calyx.search.searchField)"
        )
    }

    func test_nextGroupViaMenu_switchesGroup() {
        // まず 2 つ目のグループを作成
        openMenuBarItem("Window")
        hoverMenuItem("Group")
        let newGroup = app.menuBars.menuItems["New Group"]
        XCTAssertTrue(newGroup.waitForExistence(timeout: 3), "'New Group' must exist")
        newGroup.click()
        let observedAfterNew = waitForGroupCount(2, timeout: 5)

        XCTAssertEqual(observedAfterNew, 2, "Should have 2 groups after creating a new one")

        // Previous Group に切り替え
        openMenuBarItem("Window")
        hoverMenuItem("Group")
        let prevGroup = app.menuBars.menuItems["Previous Group"]
        XCTAssertTrue(
            prevGroup.waitForExistence(timeout: 3),
            "'Previous Group' menu item must exist"
        )
        prevGroup.click()
        // Previous Group はグループ数を変えない (active 切替のみ)。
        // 決定論的な完了シグナルが乏しいため短い settle wait を保持する
        // (メニュー dismiss と active-group rebroadcast を待つ)。
        Thread.sleep(forTimeInterval: 0.3)

        // グループ数は変わらない
        XCTAssertEqual(
            currentGroupCount(), 2,
            "Previous Group should switch active group, not remove one"
        )

        // Next Group で戻れることも確認
        openMenuBarItem("Window")
        hoverMenuItem("Group")
        let nextGroup = app.menuBars.menuItems["Next Group"]
        XCTAssertTrue(
            nextGroup.waitForExistence(timeout: 3),
            "'Next Group' menu item must exist"
        )
        nextGroup.click()
        Thread.sleep(forTimeInterval: 0.3)

        XCTAssertEqual(
            currentGroupCount(), 2,
            "Next Group should switch active group, not remove one"
        )
    }

    // MARK: - 3. validateMenuItem Tests

    func test_findNext_isDisabled_whenSearchBarNotVisible() {
        // 起動直後 (search bar は非表示) で Edit > Find > Find Next を覗く
        let searchField = app.descendants(matching: .any)
            .matching(identifier: "calyx.search.searchField")
            .firstMatch
        XCTAssertFalse(
            searchField.exists,
            "Precondition: search bar must NOT be visible at app launch"
        )

        openMenuBarItem("Edit")
        hoverMenuItem("Find")

        let findNext = app.menuBars.menuItems["Find Next"]
        XCTAssertTrue(
            findNext.waitForExistence(timeout: 3),
            "'Find Next' menu item must exist"
        )
        XCTAssertFalse(
            findNext.isEnabled,
            "Find Next should be DISABLED when the search bar is not visible (validateMenuItem should return false)"
        )

        dismissOpenMenus()
    }

    func test_findNext_isEnabled_afterFindStarted() {
        // Step 1: Find… を実行して search bar を出す
        openMenuBarItem("Edit")
        hoverMenuItem("Find")

        // 親 "Find" 項目を誤ヒットしないよう "Find…" を厳密一致で取得する
        // (U+2026 ellipsis を含む正式タイトル)。
        let findItem = app.menuBars.menuItems["Find\u{2026}"]
        XCTAssertTrue(
            findItem.waitForExistence(timeout: 3),
            "'Find…' menu item must exist"
        )
        findItem.click()

        let searchField = app.descendants(matching: .any)
            .matching(identifier: "calyx.search.searchField")
            .firstMatch
        XCTAssertTrue(
            waitFor(searchField, timeout: 3),
            "Search bar must be visible after clicking Find…"
        )

        // Step 2: 再度メニューを開いて Find Next の活性状態を確認
        openMenuBarItem("Edit")
        hoverMenuItem("Find")

        let findNext = app.menuBars.menuItems["Find Next"]
        XCTAssertTrue(
            findNext.waitForExistence(timeout: 3),
            "'Find Next' menu item must exist"
        )
        XCTAssertTrue(
            findNext.isEnabled,
            "Find Next should be ENABLED while the search bar is visible"
        )

        dismissOpenMenus()
    }

    // MARK: - 4. Browser Tab Menu Validation

    /// `Split Right` (and the rest of the split actions) are surfaced by
    /// `SurfaceView` which is only in the responder chain when a terminal
    /// surface is focused. For browser tabs the responder chain has no
    /// `splitRight:` target, so AppKit must auto-disable the menu item.
    func test_splitRight_isDisabled_inBrowserTab() {
        // Open a browser tab via the File menu using the same flow as
        // `BrowserUITests.openBrowserTab(url:)`.
        menuAction("File", item: "New Browser Tab")

        let dialog = app.dialogs.firstMatch
        XCTAssertTrue(
            dialog.waitForExistence(timeout: 5),
            "Browser URL input dialog should appear"
        )

        let textField = dialog.textFields.firstMatch
        if textField.waitForExistence(timeout: 2) {
            textField.click()
            textField.typeText("https://example.com")
        }
        let openButton = dialog.buttons["Open"]
        XCTAssertTrue(
            openButton.waitForExistence(timeout: 2),
            "Browser dialog 'Open' button must exist"
        )
        openButton.click()

        // Wait until the browser toolbar appears so we know the tab has
        // switched to browser content (BrowserView becomes first responder).
        let toolbar = app.descendants(matching: .any)
            .matching(identifier: "calyx.browser.toolbar")
            .firstMatch
        XCTAssertTrue(
            waitFor(toolbar, timeout: 15),
            "Browser toolbar should be visible before we inspect Split Right"
        )

        // File > Split Right must be disabled while the active tab is a
        // browser (SurfaceView is not in the responder chain).
        openMenuBarItem("File")

        let splitRight = app.menuBars.menuItems["Split Right"]
        XCTAssertTrue(
            splitRight.waitForExistence(timeout: 3),
            "'Split Right' menu item must exist under File"
        )
        XCTAssertFalse(
            splitRight.isEnabled,
            "Split Right should be DISABLED in a browser tab (no SurfaceView responder)"
        )

        dismissOpenMenus()
    }

    // MARK: - 5. Single-state grayout (Next/Previous Tab / Group / Focus Split)

    func test_nextTab_isDisabled_whenOnlyOneTab() {
        openMenuBarItem("Window")
        let nextTab = app.menuBars.menuItems["Select Next Tab"]
        XCTAssertTrue(nextTab.waitForExistence(timeout: 3))
        XCTAssertFalse(nextTab.isEnabled, "Select Next Tab should be disabled when only one tab exists")
        dismissOpenMenus()
    }

    func test_nextGroup_isDisabled_whenOnlyOneGroup() {
        openMenuBarItem("Window")
        hoverMenuItem("Group")
        let nextGroup = app.menuBars.menuItems["Next Group"]
        XCTAssertTrue(nextGroup.waitForExistence(timeout: 3))
        XCTAssertFalse(nextGroup.isEnabled, "Next Group should be disabled when only one group exists")
        dismissOpenMenus()
    }

    func test_focusSplit_isDisabled_whenNoSplit() {
        openMenuBarItem("Window")
        hoverMenuItem("Focus Split")
        let focusUp = app.menuBars.menuItems["Focus Split Up"]
        XCTAssertTrue(focusUp.waitForExistence(timeout: 3))
        XCTAssertFalse(focusUp.isEnabled, "Focus Split Up should be disabled when no split exists")
        dismissOpenMenus()
    }
}
