// SettingsWindowE2ETests.swift
// CalyxUITests
//
// End-to-end coverage for the Settings window's toolbar-style pane
// switcher (Calyx/Features/Settings/SettingsWindowController.swift,
// SettingsPane.swift, SettingsRow.swift): opening Settings via the app
// menu's Cmd+, item (source: `AppDelegate.swift`'s `appMenu.addItem
// (withTitle: "Preferences…", ...)` -- field-verified that AppKit on
// this macOS (26.x, post-Ventura "System Settings" rename) silently
// relabels the standard Cmd+, app-menu item to "Settings…" at runtime
// regardless of the string the source passes to `withTitle:`, so this
// suite looks it up as "Settings…", not "Preferences…") shows a toolbar with one button per
// SettingsPane ("Appearance" / "Sessions" / "LSP") -- a shipped defect
// had these collapse into one degenerate merged header instead (no
// per-item image, per `SettingsWindowController.setupContent()`'s own
// doc comment; XCUITest cannot read an NSToolbarItem's NSImage directly,
// see `test_settingsWindow_toolbarTabsHaveImagesAndSwitchContent`'s own
// comment for what IS assertable here) -- clicking a button switches
// the window's content to that pane AND its
// title to the pane's own title (native NSTabViewController(tabStyle:
// .toolbar) behavior), and each pane shows the control the user actually
// came for.
//
// No accessibilityIdentifiers exist on any of these controls in
// production code (SettingsWindowController.swift never calls
// .accessibilityIdentifier/.setAccessibilityIdentifier) and this task
// is scoped to CalyxUITests/ only, so:
// - toolbar buttons are looked up by their own label (== SettingsPane
//   .title, set via `tabItem.label = pane.title`)
// - per-pane controls are looked up ordinally (the pane's FIRST
//   slider/switch in `SettingsRow.allCases` pane-filtered, top-to-bottom
//   NSStackView order == accessibility-tree order), mirroring
//   TabReorderUITests's own established ordinal-lookup idiom for this
//   codebase
//
// `app.windows.firstMatch` is used as the stable Settings-window handle
// throughout (rather than re-querying by title, which itself changes on
// every pane switch this test makes): Settings is shown via
// `showWindow(nil)` + `makeKeyAndOrderFront(nil)` and this test never
// re-focuses the main Calyx window afterward, so it stays the frontmost/
// key window (and XCUITest's `windows` query orders front-to-back) for
// this test's whole duration.

import XCTest

final class SettingsWindowE2ETests: CalyxUITestCase {

    /// `app.activate()` first as cheap insurance against this class's
    /// app launching right after another test class's app instance just
    /// terminated in the same xctest process. The actual, confirmed
    /// root cause of this suite's first RED run here was NOT a focus
    /// race, though: it was looking up "Preferences…" when the item's
    /// real runtime title is "Settings…" (see this file's header) --
    /// confirmed by reading the failure's own attached accessibility
    /// snapshot, which showed a perfectly healthy, fully-populated menu
    /// bar with `identifier: 'openPreferences:', title: 'Settings…'`.
    private func openSettingsViaMenu() {
        app.activate()
        Thread.sleep(forTimeInterval: 0.5)
        menuAction("Calyx", item: "Settings…")
    }

    /// A known control that only exists on `pane`'s own content
    /// (NSTabViewController swaps the whole content view on selection,
    /// so a control from a non-selected pane isn't just hidden -- it
    /// isn't in the accessibility tree at all), asserted present after
    /// clicking that pane's toolbar button.
    private func assertPaneContentVisible(_ pane: String, file: StaticString = #filePath, line: UInt = #line) {
        switch pane {
        case "Appearance":
            XCTAssertTrue(
                waitFor(app.sliders.firstMatch, timeout: 5),
                "No slider (glass opacity, SettingsRow.glassOpacity) found on the Appearance pane.",
                file: file, line: line
            )
        case "Sessions":
            XCTAssertTrue(
                waitFor(app.switches.firstMatch, timeout: 5),
                "No switch (persistent sessions toggle, SettingsRow.persistentSessions -- " +
                "first row in the Sessions pane) found on the Sessions pane.",
                file: file, line: line
            )
        case "LSP":
            XCTAssertTrue(
                waitFor(app.switches.firstMatch, timeout: 5),
                "No switch (LSP toggle, SettingsRow.lspAutoInstall -- first row in the " +
                "LSP pane) found on the LSP pane.",
                file: file, line: line
            )
        default:
            XCTFail("Unknown pane \"\(pane)\"", file: file, line: line)
        }
    }

    /// Opens Settings, asserts the toolbar shows three distinct
    /// individually-labeled buttons (not one merged header -- see this
    /// method's own inline comment for why that, not an image-presence
    /// check, is what's actually assertable here), then for each pane in
    /// order: clicks its toolbar button, asserts the window's title
    /// becomes that pane's title, and asserts a pane-specific control is
    /// visible. Screenshots each pane (plus the initial post-open state)
    /// to `CalyxUITestCase.uiShotDir` for manual review -- including of
    /// the icons themselves, which only a human eye can confirm here.
    func test_settingsWindow_toolbarTabsHaveImagesAndSwitchContent() {
        XCTAssertTrue(waitFor(app.windows.firstMatch), "App window did not appear after launch.")
        app.activate()

        // Back-to-back app launches within one xctest process (this
        // class's own launch immediately follows whatever ran right
        // before it in the same suite) can leave the freshly-launched
        // app's menu bar not yet registered with the Accessibility
        // server for a moment even after its first window exists --
        // field-verified: a run with no wait here failed at the very
        // first menu click with "No matches found for Descendants
        // matching type MenuBar". A generous explicit wait here, before
        // any menu interaction, costs nothing once the bar is already
        // up.
        XCTAssertTrue(
            waitFor(app.menuBars.firstMatch, timeout: 20),
            "Calyx's menu bar never appeared within ~20s of its window showing up."
        )

        openSettingsViaMenu()

        let settingsWindow = app.windows.firstMatch
        XCTAssertTrue(
            waitFor(settingsWindow, timeout: 10),
            "No window appeared after invoking Preferences… from the Calyx application menu."
        )

        // The window is expected to open already showing the first
        // pane (Appearance) -- SettingsWindowController.setupContent()
        // adds tab items in SettingsPane.allCases order (Appearance,
        // Sessions, LSP) with no explicit initial-selection override, so
        // NSTabViewController defaults to index 0.
        XCTAssertEqual(
            settingsWindow.title, "Appearance",
            "Settings window's title on first open should be \"Appearance\" (the first " +
            "SettingsPane, auto-selected), reflecting NSTabViewController(tabStyle: " +
            ".toolbar)'s built-in window-title sync. Actual title: " +
            "\"\(settingsWindow.title)\". Window hierarchy: " +
            "\(settingsWindow.debugDescription.prefix(2000))"
        )
        saveScreenshot(name: "settings-appearance-initial")

        // Icon check: field-verified that XCUITest CANNOT read an
        // NSToolbarItem's NSImage directly here -- a passing toolbar
        // button's own accessibility subtree is a single leaf element
        // (`title`/`label` only, no child `.images`, no distinguishing
        // attribute), confirmed by attaching its `debugDescription` to a
        // failing assertion during this suite's own development. What
        // IS assertable, and what actually distinguishes the shipped
        // defect (`SettingsWindowController.setupContent()`'s own doc
        // comment: "the toolbar-style NSTabViewController renders a tab
        // item with no image as a degenerate fat header instead of a
        // proper toolbar button"): whether THREE separate,
        // individually-labeled buttons exist at all, vs. one merged
        // header. A screenshot is saved below for the one part of this
        // (the icon glyphs themselves) that only a human eye can
        // confirm.
        let toolbarButtonLabels = Set(settingsWindow.toolbars.buttons.allElementsBoundByIndex.map { $0.label })
        XCTAssertEqual(
            toolbarButtonLabels, ["Appearance", "Sessions", "LSP"],
            "Settings toolbar should expose three distinct, individually-labeled buttons " +
            "(Appearance/Sessions/LSP), not a single merged/degenerate header. Actual labels " +
            "found: \(toolbarButtonLabels). Window hierarchy: " +
            "\(settingsWindow.debugDescription.prefix(2000))"
        )

        for pane in ["Appearance", "Sessions", "LSP"] {
            let toolbarButton = settingsWindow.toolbars.buttons[pane]
            XCTAssertTrue(
                waitFor(toolbarButton, timeout: 5),
                "Settings toolbar has no button labeled \"\(pane)\". Window hierarchy: " +
                "\(settingsWindow.debugDescription.prefix(2000))"
            )

            toolbarButton.click()

            XCTAssertEqual(
                settingsWindow.title, pane,
                "Settings window title did not become \"\(pane)\" after clicking its " +
                "toolbar button (actual: \"\(settingsWindow.title)\")."
            )
            assertPaneContentVisible(pane)
            saveScreenshot(name: "settings-\(pane.lowercased())")
        }
    }
}
