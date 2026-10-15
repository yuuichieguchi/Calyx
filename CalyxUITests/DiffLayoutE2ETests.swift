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
        let submenu = app.menuItems["Diff View"]
        XCTAssertTrue(waitFor(submenu, timeout: 5), "More Actions must contain a Diff View submenu")
        submenu.hover()
        let item = app.menuItems[title]
        XCTAssertTrue(waitFor(item, timeout: 5), "Diff View submenu must contain \(title)")
        item.click()
    }

    func test_diffToolbarMoreActions_switchesBetweenInlineAndSideBySide() {
        waitForMainWindow()
        let pane = terminalPane()
        XCTAssertTrue(waitFor(pane, timeout: 10), "terminal pane not found")
        pane.click()

        let setup = shell(
            "mkdir -p '\(repoDir)' && cd '\(repoDir)' && git init -q -b main && " +
            "git config user.name t && git config user.email t@e && " +
            "printf 'a\\nb\\nc\\nd\\ne\\n' > \(fileName) && git add \(fileName) && git commit -q -m init && " +
            "printf 'a\\nb\\nX\\nd\\ne\\n' > \(fileName) && echo ready"
        )
        XCTAssertEqual(setup, "ready", "fixture repo setup failed: \(setup)")
        typeIntoPane("cd \(repoDir)\n")
        Thread.sleep(forTimeInterval: 2)
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
}
