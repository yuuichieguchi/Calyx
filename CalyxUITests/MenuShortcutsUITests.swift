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

    /// Shared by the Split Left/Up/Down functional tests below --
    /// mirrors `test_splitRightViaMenu_createsSecondSurface`'s own body
    /// exactly, parameterized on the File-menu item title.
    private func assertSplitViaMenuAddsDivider(menuItemTitle: String) {
        let dividersBefore = app.windows.firstMatch
            .descendants(matching: .splitter)
            .count

        openMenuBarItem("File")

        let splitItem = app.menuBars.menuItems[menuItemTitle]
        XCTAssertTrue(
            splitItem.waitForExistence(timeout: 3),
            "'\(menuItemTitle)' menu item must exist under File"
        )
        splitItem.click()

        let dividersAfter = waitForSplitterCount(timeout: 8) { $0 > dividersBefore }

        XCTAssertGreaterThan(
            dividersAfter, dividersBefore,
            "File > \(menuItemTitle) should add a split divider (surface count should grow). before=\(dividersBefore), after=\(dividersAfter)"
        )
    }

    func test_splitLeftViaMenu_createsSecondSurface() {
        assertSplitViaMenuAddsDivider(menuItemTitle: "Split Left")
    }

    func test_splitUpViaMenu_createsSecondSurface() {
        assertSplitViaMenuAddsDivider(menuItemTitle: "Split Up")
    }

    func test_splitDownViaMenu_createsSecondSurface() {
        assertSplitViaMenuAddsDivider(menuItemTitle: "Split Down")
    }

    // MARK: - Focus Split (functional: focus actually moves)

    /// After a real split, each `Focus Split <direction>` menu action must
    /// actually move keyboard focus to a DIFFERENT surface, not just be
    /// enabled/clickable (see `test_focusSplit_isDisabled_whenNoSplit`
    /// for the disabled-state coverage this complements).
    ///
    /// Focus is not exposed through any accessibility identifier today
    /// (`SurfaceView`, the raw ghostty-backed `NSView` each split surface
    /// renders into, sets none -- investigated, not assumed) and adding
    /// one is outside this task's identifier-only production scope
    /// (limited to the named Settings switches). Instead this proves
    /// focus moved BEHAVIORALLY: `PaneCLIExec.paneExec`/
    /// `panePasteAndReturn` paste into whatever surface is CURRENTLY the
    /// key window's first responder (the same mechanism every other
    /// pane-driving suite in this directory relies on), so tagging each
    /// surface's own shell with a distinct `$PANE` value the moment it is
    /// known to be focused (right after `File > Split Right`/`Split
    /// Down`, whose own `handleNewSplitNotification` calls
    /// `window?.makeFirstResponder(newView)` on the just-created surface)
    /// lets a later `echo $PANE` read back EXACTLY which surface is
    /// focused at that moment -- a Focus Split action that failed to
    /// move focus would read back the SAME (stale) tag, making this
    /// assertion fail for the right reason.
    func test_focusSplitDirections_moveFocusBetweenSurfaces() {
        var cmdCounter = 0

        // Tag the original (only) surface while it is necessarily the
        // one with focus.
        _ = paneExec("export PANE=ORIGINAL; echo tagged", counter: &cmdCounter)

        // Split Right: the new surface becomes first responder
        // immediately (handleNewSplitNotification). Tag it while known-focused.
        let dividersBeforeRight = app.windows.firstMatch.descendants(matching: .splitter).count
        menuAction("File", item: "Split Right")
        _ = waitForSplitterCount(timeout: 8) { $0 > dividersBeforeRight }
        _ = paneExec("export PANE=RIGHT; echo tagged", counter: &cmdCounter)

        // Focus Split Left should move focus from RIGHT back to ORIGINAL.
        openMenuBarItem("Window")
        hoverMenuItem("Focus Split")
        let focusLeft = app.menuBars.menuItems["Focus Split Left"]
        XCTAssertTrue(focusLeft.waitForExistence(timeout: 3), "'Focus Split Left' menu item must exist")
        focusLeft.click()
        Thread.sleep(forTimeInterval: 0.3)
        let afterFocusLeft = paneExec("echo $PANE", counter: &cmdCounter)
        XCTAssertEqual(
            afterFocusLeft, "ORIGINAL",
            "Focus Split Left should move focus back to the original (left) surface"
        )

        // Focus Split Right should move focus back to RIGHT.
        openMenuBarItem("Window")
        hoverMenuItem("Focus Split")
        let focusRight = app.menuBars.menuItems["Focus Split Right"]
        XCTAssertTrue(focusRight.waitForExistence(timeout: 3), "'Focus Split Right' menu item must exist")
        focusRight.click()
        Thread.sleep(forTimeInterval: 0.3)
        let afterFocusRight = paneExec("echo $PANE", counter: &cmdCounter)
        XCTAssertEqual(
            afterFocusRight, "RIGHT",
            "Focus Split Right should move focus to the right surface"
        )

        // From RIGHT (currently focused), split down to create a
        // vertical neighbor; tag it while known-focused.
        let dividersBeforeDown = app.windows.firstMatch.descendants(matching: .splitter).count
        menuAction("File", item: "Split Down")
        _ = waitForSplitterCount(timeout: 8) { $0 > dividersBeforeDown }
        _ = paneExec("export PANE=BOTTOM; echo tagged", counter: &cmdCounter)

        // Focus Split Up should move focus from BOTTOM to its upper neighbor, RIGHT.
        openMenuBarItem("Window")
        hoverMenuItem("Focus Split")
        let focusUp = app.menuBars.menuItems["Focus Split Up"]
        XCTAssertTrue(focusUp.waitForExistence(timeout: 3), "'Focus Split Up' menu item must exist")
        focusUp.click()
        Thread.sleep(forTimeInterval: 0.3)
        let afterFocusUp = paneExec("echo $PANE", counter: &cmdCounter)
        XCTAssertEqual(
            afterFocusUp, "RIGHT",
            "Focus Split Up should move focus to the surface above (RIGHT)"
        )

        // Focus Split Down should move focus back to BOTTOM.
        openMenuBarItem("Window")
        hoverMenuItem("Focus Split")
        let focusDown = app.menuBars.menuItems["Focus Split Down"]
        XCTAssertTrue(focusDown.waitForExistence(timeout: 3), "'Focus Split Down' menu item must exist")
        focusDown.click()
        Thread.sleep(forTimeInterval: 0.3)
        let afterFocusDown = paneExec("echo $PANE", counter: &cmdCounter)
        XCTAssertEqual(
            afterFocusDown, "BOTTOM",
            "Focus Split Down should move focus back to the surface below (BOTTOM)"
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
        // Baseline: the first group's own tab-bar tab identifier set,
        // captured before a second group exists, so a later switch BACK
        // to it can be proven by observing the SAME set reappear
        // (`CalyxUITestCase.currentTabBarTabIdentifiers()`'s own doc
        // comment: `TabBarContentView` is fed exclusively from
        // `windowSession.activeGroup?.tabs`) -- not just that the group
        // COUNT is unchanged, which a no-op switch would also satisfy.
        let firstGroupTabIdentifiers = currentTabBarTabIdentifiers()

        // まず 2 つ目のグループを作成
        openMenuBarItem("Window")
        hoverMenuItem("Group")
        let newGroup = app.menuBars.menuItems["New Group"]
        XCTAssertTrue(newGroup.waitForExistence(timeout: 3), "'New Group' must exist")
        newGroup.click()
        let observedAfterNew = waitForGroupCount(2, timeout: 5)

        XCTAssertEqual(observedAfterNew, 2, "Should have 2 groups after creating a new one")

        // The newly created group becomes active on creation, so the tab
        // bar should now show its own (different) tab.
        let secondGroupTabIdentifiers = currentTabBarTabIdentifiers()
        XCTAssertNotEqual(
            secondGroupTabIdentifiers, firstGroupTabIdentifiers,
            "Creating a new group via the menu should make it active, so the tab bar should show its own tab"
        )

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

        // The ACTIVE group must have actually switched back to the
        // first group: the tab bar's visible tab set should match the
        // baseline captured before the second group ever existed.
        XCTAssertEqual(
            currentTabBarTabIdentifiers(), firstGroupTabIdentifiers,
            "Previous Group should switch the active group back to the first one, so the tab bar shows its tab again"
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

        // The ACTIVE group must have switched forward again, back to the
        // second group's own tab.
        XCTAssertEqual(
            currentTabBarTabIdentifiers(), secondGroupTabIdentifiers,
            "Next Group should switch the active group forward to the second one, so the tab bar shows its tab again"
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
