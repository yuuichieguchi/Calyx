// DiffLayoutE2ETests.swift
// CalyxUITests
//
// End-to-end coverage for the diff layout feature (plan §8):
// (a) Settings -> Appearance layout popup persists across relaunch;
// (b) diff toolbar "..." -> Diff View -> Inline / Side by Side swaps the
//     gutter(s) (calyx.diff.lineNumbers.inline vs .old + .new).
//
// No existing UI test opens a diff tab. (b) builds the steps from
// AccessibilityID ids: a fixture repo with an unstaged edit is created by
// the pane's shell (pattern WorktreeTaskFlowE2ETests), the Changes sidebar
// is opened with the "Show Git Changes" palette command, and the file row
// calyx.git.file.<path> is clicked.

import AppKit
import XCTest

final class DiffLayoutE2ETests: CalyxUITestCase {

    private var homeDir: String = ""
    private var repoDir: String = ""
    private let repoName = "difflayoutrepo"
    private let fileName = "notes.txt"
    private var counter = 0

    override var additionalLaunchEnvironment: [String: String] {
        ["HOME": homeDir]
    }

    override func setUp() async throws {
        homeDir = "/private/tmp/cxdl-" + UUID().uuidString.prefix(8).lowercased()
        repoDir = homeDir + "/" + repoName
        try await super.setUp()
    }

    override func tearDown() async throws {
        removeScratchHomeViaPane()
        try await super.tearDown()
        if !homeDir.isEmpty {
            try? FileManager.default.removeItem(atPath: homeDir)
        }
    }

    // MARK: - Helpers

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func terminalPane() -> XCUIElement {
        app.textViews
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "calyx.terminal.pane."))
            .firstMatch
    }

    @discardableResult
    private func shell(_ script: String) -> String {
        paneExec("(export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 LC_ALL=C; \(script))", counter: &counter, timeoutAttempts: 40)
    }

    private func removeScratchHomeViaPane() {
        guard !homeDir.isEmpty, let app,
              app.state == .runningForeground || app.state == .runningBackground else { return }
        let pane = terminalPane()
        guard pane.waitForExistence(timeout: 5) else { return }
        pane.click()
        _ = shell("cd / && rm -rf '\(homeDir)' && echo removed")
    }

    private func waitForMainWindow() {
        XCTAssertTrue(waitFor(app.windows.firstMatch, timeout: 10), "main window did not appear")
        XCTAssertTrue(waitFor(app.menuBars.firstMatch, timeout: 20), "menu bar did not appear")
    }

    private func openAppearancePane() {
        app.activate()
        Thread.sleep(forTimeInterval: 0.5)
        menuAction("Calyx", item: "Settings…")
        let settingsWindow = app.windows.firstMatch
        XCTAssertTrue(waitFor(settingsWindow, timeout: 10), "Settings window never appeared.")
        let paneButton = settingsWindow.toolbars.buttons["Appearance"]
        XCTAssertTrue(waitFor(paneButton, timeout: 5), "No Appearance toolbar button in Settings.")
        paneButton.click()
    }

    private func revealInScrollView(_ target: XCUIElement) {
        let scrollView = app.scrollViews.containing(.any, identifier: target.identifier).firstMatch
        guard scrollView.waitForExistence(timeout: 5) else { return }
        var attempts = 0
        while !(target.isHittable && scrollView.frame.contains(target.frame)) && attempts < 10 {
            scrollView.scroll(byDeltaX: 0, deltaY: -200)
            attempts += 1
        }
    }

    private func layoutPopup() -> XCUIElement {
        element("calyx.settings.appearance.gitDiffLayoutPopup")
    }

    // MARK: - (a) Settings popup persists across relaunch

    func test_layoutPopupSelection_persistsAcrossRelaunch() {
        waitForMainWindow()
        openAppearancePane()

        let popup = layoutPopup()
        XCTAssertTrue(waitFor(popup, timeout: 5), "gitDiffLayoutPopup not found on the Appearance pane")
        revealInScrollView(popup)
        XCTAssertEqual(popup.value as? String, "Automatic", "default preference must be Automatic")

        popup.click()
        let inlineItem = app.menuItems["Side by Side"]
        XCTAssertTrue(waitFor(inlineItem, timeout: 5), "popup must offer Side by Side")
        inlineItem.click()
        XCTAssertEqual(popup.value as? String, "Side by Side")

        menuAction("Calyx", item: "Quit Calyx")
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 10), "Calyx did not quit")

        terminateStaleAppUnderTestInstances()
        app.launch()
        waitForMainWindow()
        openAppearancePane()

        let popupAfter = layoutPopup()
        XCTAssertTrue(waitFor(popupAfter, timeout: 5), "gitDiffLayoutPopup not found after relaunch")
        revealInScrollView(popupAfter)
        XCTAssertEqual(popupAfter.value as? String, "Side by Side",
                       "a new process must seed the popup from the persisted preference")
    }

    // MARK: - (b) Toolbar "..." -> Diff View switches layout

    private func chooseDiffView(_ title: String) {
        let more = element("calyx.diff.moreActions")
        XCTAssertTrue(waitFor(more, timeout: 10), "diff toolbar must have the More Actions (…) button")
        more.click()
        // Scoped to the open More Actions menu so a "Diff View" item elsewhere
        // (e.g. the app's View menu) cannot make the lookup ambiguous.
        let submenu = more.menuItems["Diff View"]
        XCTAssertTrue(waitFor(submenu, timeout: 5), "More Actions must contain a Diff View submenu")
        submenu.hover()
        let item = submenu.menuItems[title]
        XCTAssertTrue(waitFor(item, timeout: 5), "Diff View submenu must contain \(title)")
        item.click()
    }

    /// Creates the fixture repo, opens the Changes sidebar and the diff tab.
    private func openDiffTab() {
        waitForMainWindow()
        let pane = terminalPane()
        XCTAssertTrue(waitFor(pane, timeout: 10), "terminal pane not found")
        pane.click()

        let setup = shell(
            "rm -rf '\(repoDir)' && mkdir -p '\(repoDir)' && cd '\(repoDir)' && git init -q -b main && " +
            "git config user.name t && git config user.email t@e && " +
            "printf 'a\\nb\\nc\\nd\\ne\\n' > \(fileName) && git add \(fileName) && git commit -q -m init && " +
            "printf 'a\\nb\\nX\\nd\\ne\\n' > \(fileName) && echo ready"
        )
        XCTAssertEqual(setup, "ready", "fixture repo setup failed: \(setup)")
        typeIntoPane("cd \(repoDir)\n")
        // shell() waits for its own completion marker, so this runs after the cd.
        XCTAssertEqual(shell("pwd"), repoDir, "pane cwd must be the fixture repo")

        openCommandPaletteViaMenu()
        let searchField = element("calyx.commandPalette.searchField")
        XCTAssertTrue(waitFor(searchField), "Command palette should appear")
        searchField.typeText("Show Git Changes")
        searchField.typeKey(.enter, modifierFlags: [])

        let fileRow = element("calyx.git.file.\(fileName)")
        let fileRowAppeared = waitFor(fileRow, timeout: 20)
        if !fileRowAppeared {
            let gitIDs = app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH %@", "calyx.git"))
                .allElementsBoundByIndex.map(\.identifier)
            print("DiffLayoutE2E git identifiers: \(gitIDs)")
            print("DiffLayoutE2E tree: \(app.debugDescription)")
        }
        XCTAssertTrue(fileRowAppeared, "the unstaged file must appear in the Changes sidebar")
        fileRow.click()

        let toolbarAppeared = waitFor(element("calyx.diff.toolbar"), timeout: 10)
        if !toolbarAppeared {
            print("DiffLayoutE2E tree after row click: \(app.debugDescription)")
        }
        XCTAssertTrue(toolbarAppeared, "a diff tab must open")

        XCTAssertTrue(waitFor(app.descendants(matching: .any)["calyx.diff.nextChange"], timeout: 5),
                      "diff toolbar must have the Next Change button")
        XCTAssertTrue(waitFor(app.descendants(matching: .any)["calyx.diff.previousChange"], timeout: 5),
                      "diff toolbar must have the Previous Change button")
        XCTAssertTrue(waitFor(app.descendants(matching: .any)["calyx.diff.overviewRuler"], timeout: 5),
                      "the diff view must show the overview ruler")

    }

    func test_diffToolbarMoreActions_switchesBetweenInlineAndSideBySide() {
        openDiffTab()

        chooseDiffView("Inline")
        XCTAssertTrue(waitFor(element("calyx.diff.lineNumbers.inline"), timeout: 5),
                      "Inline layout must show the single dual-column gutter")

        chooseDiffView("Side by Side")
        XCTAssertTrue(waitFor(element("calyx.diff.lineNumbers.old"), timeout: 5),
                      "Side by Side must show the original-side gutter")
        XCTAssertTrue(waitFor(element("calyx.diff.lineNumbers.new"), timeout: 5),
                      "Side by Side must show the modified-side gutter")
        XCTAssertFalse(element("calyx.diff.lineNumbers.inline").exists,
                       "the inline gutter must be removed in Side by Side")
    }

    // MARK: - (c) Toolbar "..." -> Word Wrap toggles the Settings switch

    private func wordWrapSwitch() -> XCUIElement {
        element("calyx.settings.appearance.gitDiffWordWrapSwitch")
    }

    private func toggleWordWrapFromMoreActions() {
        let more = element("calyx.diff.moreActions")
        XCTAssertTrue(waitFor(more, timeout: 10), "diff toolbar must have the More Actions (…) button")
        more.click()
        let item = more.menuItems["Word Wrap"]
        XCTAssertTrue(waitFor(item, timeout: 5), "More Actions must contain a Word Wrap item")
        item.click()
    }

    private func assertWordWrapSwitch(_ expected: Int, _ message: String) {
        openAppearancePane()
        let toggle = wordWrapSwitch()
        XCTAssertTrue(waitFor(toggle, timeout: 5), "gitDiffWordWrapSwitch not found on the Appearance pane")
        revealInScrollView(toggle)
        XCTAssertEqual(toggle.value as? Int, expected, message) // NSSwitch exposes an NSNumber, not a String
        app.typeKey("w", modifierFlags: .command) // close Settings, back to the diff tab
        Thread.sleep(forTimeInterval: 0.5)
    }

    func test_moreActionsWordWrap_togglesSettingsSwitch() {
        openDiffTab()

        toggleWordWrapFromMoreActions()
        assertWordWrapSwitch(0, "word wrap defaults on; one toggle must turn it off")

        toggleWordWrapFromMoreActions()
        assertWordWrapSwitch(1, "a second toggle must turn word wrap back on")
    }

    // MARK: - (d) Long diff, inline: screenshots for visual inspection

    private func shot(_ name: String) {
        let a = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        a.name = name
        a.lifetime = .deleteOnSuccess
        add(a)
    }

    /// After each step: the diff content and the expected gutter(s) exist and the app is alive.
    private func assertDiffHealthy(sideBySide: Bool, _ step: String,
                                   file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(waitFor(element("calyx.diff.content"), timeout: 5),
                      "[\(step)] calyx.diff.content must exist", file: file, line: line)
        let gutters = sideBySide
            ? ["calyx.diff.lineNumbers.old", "calyx.diff.lineNumbers.new"]
            : ["calyx.diff.lineNumbers.inline"]
        for id in gutters {
            XCTAssertTrue(waitFor(element(id), timeout: 5),
                          "[\(step)] \(id) must exist", file: file, line: line)
        }
        XCTAssertTrue(app.state == .runningForeground || app.state == .runningBackground,
                      "[\(step)] app must still be running (state: \(app.state.rawValue))",
                      file: file, line: line)
    }

    /// Polls `condition` until it holds or `timeout` elapses.
    private func waitUntil(timeout: TimeInterval = 10, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline { return false }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return true
    }

    /// The diff host of the long.txt diff (AX label "Diff of …long.txt").
    private func longDiffContent() -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == %@ AND label ENDSWITH %@", "calyx.diff.content", "long.txt"))
            .firstMatch
    }

    private func overviewRuler() -> XCUIElement {
        longDiffContent().descendants(matching: .any)["calyx.diff.overviewRuler"]
    }

    /// Visible modified lines from the ruler's AX value "lines A–B of N".
    private func visibleLines() -> (first: Int, last: Int, total: Int)? {
        guard let value = overviewRuler().value as? String else { return nil }
        let numbers = value.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        guard value.hasPrefix("lines "), numbers.count == 3 else { return nil }
        return (numbers[0], numbers[1], numbers[2])
    }

    /// Waits for the More Actions menu item just chosen to disappear (menu closed).
    private func waitForMenuClosed(item title: String, _ step: String,
                                   file: StaticString = #filePath, line: UInt = #line) {
        let item = element("calyx.diff.moreActions").menuItems[title]
        XCTAssertTrue(waitUntil(timeout: 5) { !item.exists },
                      "[\(step)] More Actions menu must close", file: file, line: line)
    }

    private func openLongDiffInline() {
        waitForMainWindow()
        let pane = terminalPane()
        XCTAssertTrue(waitFor(pane, timeout: 10), "terminal pane not found")
        pane.click()

        let setup = shell(
            "rm -rf '\(repoDir)' && mkdir -p '\(repoDir)' && cd '\(repoDir)' && git init -q -b main && " +
            "git config user.name t && git config user.email t@e && " +
            "printf 'a\\nb\\nc\\n' > \(fileName) && " +
            "awk 'BEGIN{for(i=1;i<=3000;i++){s=\"line \" i \" - some text to make the line reasonably long so it wraps when narrow\"; if(i%10==0){while(length(s)<200)s=s\" pad\"}; print s}}' > long.txt && " +
            "git add . && git commit -q -m init && " +
            "printf 'a\\nX\\nc\\n' > \(fileName) && sed -i '' '2700s/$/ MODIFIED LINE/' long.txt && echo ready"
        )
        XCTAssertEqual(setup, "ready", "fixture repo setup failed: \(setup)")
        typeIntoPane("cd \(repoDir)\n")
        XCTAssertEqual(shell("pwd"), repoDir, "pane cwd must be the fixture repo")

        openCommandPaletteViaMenu()
        let searchField = element("calyx.commandPalette.searchField")
        XCTAssertTrue(waitFor(searchField), "Command palette should appear")
        searchField.typeText("Show Git Changes")
        searchField.typeKey(.enter, modifierFlags: [])

        let notesRow = element("calyx.git.file.\(fileName)")
        XCTAssertTrue(waitFor(notesRow, timeout: 20), "notes.txt row must appear")
        let longRow = element("calyx.git.file.long.txt")
        XCTAssertTrue(waitFor(longRow, timeout: 20), "long.txt row must appear")
        shot("00-before-open")

        notesRow.click()
        XCTAssertTrue(waitFor(element("calyx.diff.toolbar"), timeout: 10), "a diff tab must open")
        chooseDiffView("Inline")
        XCTAssertTrue(waitFor(element("calyx.diff.lineNumbers.inline"), timeout: 5),
                      "notes.txt must switch to the inline gutter")

        longRow.click()
    }

    func test_longDiff_inline_scrollLayoutAndWrapSmoke() {
        openLongDiffInline()
        let content = longDiffContent()
        XCTAssertTrue(waitFor(content, timeout: 10),
                      "[open] the diff tab must show long.txt (AX label \"Diff of …long.txt\")")
        // Reveal-first-change scrolls the 3000-line file to the edit on line 2700.
        XCTAssertTrue(waitUntil { visibleLines().map { $0.total == 3000 && ($0.first...$0.last).contains(2700) } ?? false },
                      "[open] the viewport must show line 2700 (ruler: \(String(describing: overviewRuler().value)))")
        assertDiffHealthy(sideBySide: false, "open")
        shot("01-open-inline")
        guard let opened = visibleLines() else {
            XCTFail("[open] overview ruler must report the visible lines")
            return
        }

        // Scroll the pane's scroll view: wheel events synthesized on the host
        // group did not move the viewport. Keep this to 2 up + 2 down.
        let paneScroll = content.scrollViews.firstMatch
        for _ in 0..<2 { paneScroll.scroll(byDeltaX: 0, deltaY: 400) }
        XCTAssertTrue(waitUntil { (visibleLines()?.first ?? .max) < opened.first },
                      "[scroll up] first visible line must decrease from \(opened.first) (ruler: \(String(describing: overviewRuler().value)))")
        assertDiffHealthy(sideBySide: false, "scroll up")
        shot("02-scrolled-up")
        guard let scrolledUp = visibleLines() else {
            XCTFail("[scroll up] overview ruler must report the visible lines")
            return
        }

        for _ in 0..<2 { paneScroll.scroll(byDeltaX: 0, deltaY: -400) }
        XCTAssertTrue(waitUntil { (visibleLines()?.first ?? .min) > scrolledUp.first },
                      "[scroll down] first visible line must increase from \(scrolledUp.first) (ruler: \(String(describing: overviewRuler().value)))")
        assertDiffHealthy(sideBySide: false, "scroll down")
        shot("03-scrolled-down")

        chooseDiffView("Side by Side")
        waitForNonExistence(element("calyx.diff.lineNumbers.inline"), timeout: 5)
        assertDiffHealthy(sideBySide: true, "side by side")
        shot("04-side-by-side")

        toggleWordWrapFromMoreActions()
        waitForMenuClosed(item: "Word Wrap", "wrap off")
        assertDiffHealthy(sideBySide: true, "wrap off")
        shot("05-wrap-off")
        toggleWordWrapFromMoreActions()
        waitForMenuClosed(item: "Word Wrap", "wrap on")
        assertDiffHealthy(sideBySide: true, "wrap on")
        shot("06-wrap-on")

        chooseDiffView("Automatic")
        waitForMenuClosed(item: "Diff View", "automatic")
        // Automatic resolves by window width, so accept either gutter configuration.
        XCTAssertTrue(waitFor(element("calyx.diff.content"), timeout: 5),
                      "[automatic] calyx.diff.content must exist")
        let inlineGutter = element("calyx.diff.lineNumbers.inline")
        let oldGutter = element("calyx.diff.lineNumbers.old")
        let newGutter = element("calyx.diff.lineNumbers.new")
        XCTAssertTrue(waitUntil(timeout: 5) { inlineGutter.exists || (oldGutter.exists && newGutter.exists) },
                      "[automatic] inline gutter or both side-by-side gutters must exist")
        XCTAssertTrue(app.state == .runningForeground || app.state == .runningBackground,
                      "[automatic] app must still be running (state: \(app.state.rawValue))")
        shot("07-automatic")
    }

    func test_diffBody_contextMenu_opensOnRightClickAndControlClick() {
        openLongDiffInline()
        let content = longDiffContent()
        XCTAssertTrue(waitFor(content, timeout: 10), "the diff tab must show long.txt")
        XCTAssertTrue(waitUntil { visibleLines()?.total == 3000 }, "the long diff must be laid out")
        let copy = app.menuItems["calyx.diff.contextMenu.copy"]
        let selectAll = app.menuItems["calyx.diff.contextMenu.selectAll"]
        let target = content.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5))

        target.rightClick()
        XCTAssertTrue(waitFor(copy, timeout: 5), "right-click must show Copy")
        XCTAssertTrue(waitFor(selectAll, timeout: 5), "right-click must show Select All")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(waitUntil(timeout: 5) { !copy.exists && !selectAll.exists }, "Escape must close the right-click menu")

        XCUIElement.perform(withKeyModifiers: .control) { target.click() }
        XCTAssertTrue(waitFor(copy, timeout: 5), "Control-click must show Copy")
        XCTAssertTrue(waitFor(selectAll, timeout: 5), "Control-click must show Select All")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(waitUntil(timeout: 5) { !copy.exists && !selectAll.exists }, "Escape must close the Control-click menu")
    }

    private func verticalScrollValue(_ content: XCUIElement) -> String {
        content.scrollViews.allElementsBoundByIndex
            .map { scrollView in String(describing: scrollView.scrollBars.allElementsBoundByIndex.map { $0.value }) }
            .joined(separator: " | ")
    }

    private func assertDragSelectionKeepsViewport(_ step: String, in content: XCUIElement,
                                                  from start: CGVector, to end: CGVector,
                                                  file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(waitUntil { visibleLines()?.total == 3000 }, "[\(step)] the long diff must be laid out",
                      file: file, line: line)
        Thread.sleep(forTimeInterval: 1.0)
        guard let before = visibleLines() else {
            XCTFail("[\(step)] overview ruler must report the visible lines", file: file, line: line)
            return
        }
        let scrollBefore = verticalScrollValue(content)
        NSPasteboard.general.clearContents()
        let from = content.coordinate(withNormalizedOffset: start)
        let to = content.coordinate(withNormalizedOffset: end)
        from.click(forDuration: 0.3, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 1.5)
        Thread.sleep(forTimeInterval: 0.5)
        let after = visibleLines()
        let scrollAfter = verticalScrollValue(content)
        app.typeKey("c", modifierFlags: .command)
        XCTAssertTrue(waitUntil(timeout: 3) { !(NSPasteboard.general.string(forType: .string) ?? "").isEmpty },
                      "[\(step)] the drag must select text that Copy puts on the pasteboard", file: file, line: line)
        XCTAssertTrue(after.map { $0.first == before.first && $0.last == before.last } ?? false,
                      "[\(step)] drag-selecting inside the body must not scroll: before \(before) after \(String(describing: after)); scrollers before \(scrollBefore) after \(scrollAfter)",
                      file: file, line: line)
    }

    private func openLongDiffShowingEdit() -> XCUIElement {
        openLongDiffInline()
        let content = longDiffContent()
        XCTAssertTrue(waitFor(content, timeout: 10), "the diff tab must show long.txt")
        XCTAssertTrue(waitUntil { visibleLines().map { $0.total == 3000 && ($0.first...$0.last).contains(2700) } ?? false },
                      "the viewport must show line 2700 (ruler: \(String(describing: overviewRuler().value)))")
        return content
    }

    func test_diffBody_dragSelect_inline_keepsViewport() {
        let content = openLongDiffShowingEdit()
        assertDragSelectionKeepsViewport("inline", in: content,
                                         from: CGVector(dx: 0.3, dy: 0.45), to: CGVector(dx: 0.6, dy: 0.55))
    }

    func test_diffBody_dragSelect_inlineWithoutWordWrap_keepsViewport() {
        let content = openLongDiffShowingEdit()
        toggleWordWrapFromMoreActions()
        waitForMenuClosed(item: "Word Wrap", "wrap off")
        assertDragSelectionKeepsViewport("inline wrap off", in: content,
                                         from: CGVector(dx: 0.3, dy: 0.45), to: CGVector(dx: 0.6, dy: 0.55))
    }

    func test_diffBody_dragSelect_sideBySide_keepsViewport() {
        let content = openLongDiffShowingEdit()
        chooseDiffView("Side by Side")
        XCTAssertTrue(waitFor(element("calyx.diff.lineNumbers.new"), timeout: 5), "Side by Side must show the new gutter")
        assertDragSelectionKeepsViewport("side by side right", in: content,
                                         from: CGVector(dx: 0.62, dy: 0.45), to: CGVector(dx: 0.8, dy: 0.55))
        assertDragSelectionKeepsViewport("side by side left", in: content,
                                         from: CGVector(dx: 0.15, dy: 0.45), to: CGVector(dx: 0.35, dy: 0.55))
    }

    func test_diffBody_dragSelect_afterAddCommentButton_keepsViewport() {
        let content = openLongDiffShowingEdit()
        let gutter = element("calyx.diff.lineNumbers.inline")
        XCTAssertTrue(waitFor(gutter, timeout: 5), "the inline gutter must exist")
        let plus = gutter.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5)).withOffset(CGVector(dx: 10, dy: 0))
        plus.hover()
        Thread.sleep(forTimeInterval: 0.5)
        plus.click()
        Thread.sleep(forTimeInterval: 1.0)
        app.typeKey(.escape, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.5)
        assertDragSelectionKeepsViewport("after + then Escape", in: content,
                                         from: CGVector(dx: 0.3, dy: 0.45), to: CGVector(dx: 0.6, dy: 0.55))
    }
}
