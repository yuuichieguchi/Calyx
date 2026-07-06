// SettingsWindowE2ETests.swift
// CalyxUITests
//
// End-to-end coverage for the Settings window's toolbar-style pane
// switcher (Calyx/Features/Settings/SettingsWindowController.swift,
// SettingsPane.swift, SettingsRow.swift): opening Settings via the app
// menu's "Preferences…" (Cmd+,) shows a toolbar with one button per
// SettingsPane ("Appearance" / "Sessions" / "LSP"), each button carries
// an image (a shipped defect had these render as text-only buttons),
// clicking a button switches the window's content to that pane AND its
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

    /// `app.activate()` first: field-verified (not assumed) that this
    /// class's own launch, running right after another test class's app
    /// instance just terminated in the same xctest process, can lose the
    /// system menu bar to some other running Calyx process mid-click --
    /// macOS only exposes the CURRENTLY ACTIVE app's menu bar via
    /// Accessibility, and a background app's `NSApp.mainMenu` isn't
    /// reachable at all while it isn't frontmost. A single retry (with a
    /// fresh `activate()`) covers the case where the very first attempt
    /// loses the race.
    private func openSettingsViaMenu() {
        app.activate()
        Thread.sleep(forTimeInterval: 0.5)
        menuAction("Calyx", item: "Preferences…")
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

    /// Opens Settings, then for each of the three panes in order:
    /// clicks its toolbar button, asserts the button exists AND carries
    /// an image, asserts the window's title becomes that pane's title,
    /// and asserts a pane-specific control is visible. Screenshots each
    /// pane (plus the initial post-open state) to `CalyxUITestCase
    /// .uiShotDir` for manual review.
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

        for pane in ["Appearance", "Sessions", "LSP"] {
            let toolbarButton = settingsWindow.toolbars.buttons[pane]
            XCTAssertTrue(
                waitFor(toolbarButton, timeout: 5),
                "Settings toolbar has no button labeled \"\(pane)\". Window hierarchy: " +
                "\(settingsWindow.debugDescription.prefix(2000))"
            )
            XCTAssertGreaterThan(
                toolbarButton.images.count, 0,
                "Settings toolbar's \"\(pane)\" button has no image child element -- it is " +
                "rendering as a text-only button (the shipped defect this test pins the fix " +
                "for: SettingsWindowController.setupContent() never sets `tabItem.image`)."
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
