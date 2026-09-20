// AuxiliaryWindowCloseE2ETests.swift
// CalyxUITests
//
// GitHub issue #45 ("Cmd+W doesn't work across all windows"): the one
// negative condition the fix's own unit tests (CalyxTests) CANNOT
// reproduce -- see `NSWindow+CalyxClose.swift`'s header comment for the
// full root-cause writeup, and `AppDelegateFileMenuCloseItemsTests`/
// `CalyxWindowCalyxPerformCloseRoutingTests`/`NSWindowCalyxCloseTests`/
// `CalyxWindowControllerCloseFocusedTargetTests`/
// `CalyxWindowControllerKeyWindowMenuValidationTests` for the structural
// (menu wiring, pure-function target selection, key-window-gated
// validateMenuItem) coverage those files already carry.
//
// `NSApp.keyWindow`/`NSApp.mainWindow` are WindowServer-assigned, not
// settable from inside the app process under test -- an XCTest host
// cannot manufacture a real "key but not main" window (`NSWindow
// +CalyxClose.swift`'s header documents both key/main shapes a panel can
// take, which is the production-code premise this file exists to
// exercise end-to-end, NOT a fact this file itself re-derives -- XCUITest exposes no API to read an element's key/main
// state directly, so what follows verifies the resulting BEHAVIOR
// through a real menu click + a real keystroke, not the AX-level
// key/main mechanics themselves) without an actual end-to-end run
// driving the real WindowServer. A test that tried to fake this some
// other way -- e.g. calling `makeKey()` on an off-screen panel without
// it ever really taking focus -- would not exercise `-[NSApplication
// targetForAction:]`'s real key-window-chain-then-main-window-fallback
// resolution at all; it would pass for the wrong reason.
//
// This codebase already has a cautionary example of exactly that wrong-
// reason failure mode, one directory over:
// `MenuShortcutsUITests.test_nextTab_isDisabled_whenOnlyOneTab` only
// ever asserts the "Select Next Tab" menu item's OWN `.isEnabled` state
// -- it never presses the real Cmd+Shift+] key combo. That is not an
// oversight so much as unavoidable: the real keystroke never reaches
// that menu item's `validateMenuItem`-gated path at all.
// `AppDelegate.installKeyMonitor`'s local key-event monitor intercepts
// Cmd+Shift+] directly (`AppDelegate.matchKeyEvent`'s `.nextTab` case)
// and calls `wc.selectNextTab(nil)` unconditionally -- no tab-count
// gate of its own -- consuming the event (`return nil`) before AppKit's
// menu key-equivalent dispatch ever sees it. So that menu item's
// enabled/disabled state is, for the real keystroke, dead code.
//
// Cmd+W (plain, no Shift/Option) is confirmed NOT one of the shortcuts
// `AppDelegate.matchKeyEvent` intercepts (read that switch directly,
// not assumed -- it matches Cmd+Shift+P, Cmd+Shift+U, Cmd+Shift+],
// Cmd+Shift+[, Cmd+1...9, and, UI-testing-only, Ctrl+Shift+D; nothing
// on plain "w"). So `app.typeKey("w", modifierFlags: .command)` below
// genuinely round-trips through AppKit's real menu key-equivalent
// dispatch and `-[NSApplication targetForAction:]` resolution, unlike
// Cmd+Shift+] would.
//
// THIS FILE COVERS (one scenario per test, mirroring this directory's
// established style, e.g. `LastWindowCloseDoesNotQuitE2ETests`): for
// each of About / Settings / Session Browser, opened via its own real
// menu item (the ordinary way any of these becomes the frontmost,
// user-focused panel -- all three are today plain `NSWindow`s that DO
// become main the moment they become key, but still never the terminal's
// `CalyxWindowController`; About was AppKit's standard `NSPanel` when
// this file was written, and `NSWindow+CalyxClose.swift`'s header keeps
// the writeup of how those two shapes used to fail DIFFERENTLY pre-fix),
// a real Cmd+W keystroke must close ONLY
// that panel and must leave the terminal window's own tab count
// completely unchanged. This file verifies that user-visible CONTRACT;
// it does not (and, per the note above, cannot) directly inspect which
// AX-level key/main state produced it -- that mechanism is what
// `NSWindowCalyxCloseTests`/`CalyxWindowCalyxPerformCloseRoutingTests`/
// `CalyxWindowControllerKeyWindowMenuValidationTests` pin at the unit
// level. The terminal window is fixed at exactly 2 tabs
// (`fixTabCountAtTwo()`) BEFORE any panel opens, specifically so a
// post-Cmd+W tab count of 2 proves the count is UNCHANGED, not merely
// "still more than zero" -- pre-fix, the `NSPanel`-shaped symptom (then
// About's, and still reachable by any `canBecomeMain == false` panel)
// was silently closing the terminal's ACTIVE tab out from under the user
// (2 -> 1), which a weaker "at least one tab remains" assertion would
// not have caught.
//
// THIS FILE DELIBERATELY DOES NOT COVER:
//   - The ClipboardConfirmation sheet's own Cmd+W handling (beeps and
//     does nothing, per `NSWindow.calyxPerformClose(_:)`'s `sheetParent`
//     guard) -- driving a real libghostty clipboard-permission prompt
//     from XCUITest is its own can of worms, unrelated to the
//     About/Settings/Session-Browser key-vs-main root cause this file
//     targets, and no existing E2E suite in this directory drives that
//     prompt today.
//   - QuickTerminal's own Cmd+W path (`QuickTerminalWindow`/
//     `QuickTerminalController`, also touched by this same commit) --
//     a separate, non-`.titled` overlay window with its own hide/show
//     lifecycle rather than an ordinary closable window; out of this
//     task's stated scope (About/Settings/Session Browser only).
//   - The `focusSplit*` known gap `CalyxWindowController
//     .keyWindowGatedActions`'s own doc comment records as an
//     intentionally UNFIXED, lower-severity instance of the same
//     root-cause mechanism -- out of scope for issue #45's fix and
//     this file's job of verifying it.
//
// Uses real key input (`app.typeKey`), never `app.terminate()`
// (SIGTERM bypasses AppKit's close path entirely) -- same discipline
// as `LastWindowCloseDoesNotQuitE2ETests`'s own header note.
//
// About window locator -- About is now Calyx's OWN window
// (`AboutWindowController`, a SwiftUI `AboutView` in a plain `NSWindow`),
// NOT `NSApp.orderFrontStandardAboutPanel`'s panel any more, so it is a
// normal `XCUIElementTypeWindow` located by its title, exactly like the
// Settings and Session Browser tests below ("Appearance" --
// `SettingsWindowE2ETests`; "Sessions" --
// `SessionBrowserAttachKillE2ETests`). `AboutWindowController` sets
// `window.title = "About Calyx"` even though `titleVisibility` is
// `.hidden`, precisely so this AX title exists to key on -- a hidden
// title bar does NOT blank out the AX title (independently confirmed for
// the terminal window, whose `titleVisibility = .hidden` still reads back
// as the shell's current directory).
//
// HISTORICAL, kept because it is the reason the assertions below check
// WINDOW counts and not `app.dialogs`: while About was the standard
// AppKit panel, it was field-verified NOT to be an
// `XCUIElementTypeWindow` at all (`app.windows.count` stayed at 1 for the
// panel's entire 5s post-open poll while a screenshot showed it fully
// rendered) and reported an EMPTY AXTitle, so it could only be located as
// the app's one `app.dialogs` element. Both facts died with the panel:
// today opening About takes `app.windows.count` from 1 to 2 and leaves
// `app.dialogs` empty.

import XCTest

final class AuxiliaryWindowCloseE2ETests: CalyxUITestCase {

    // MARK: - Helpers

    /// Mirrors `SettingsWindowE2ETests
    /// .test_settingsWindow_toolbarTabsHaveImagesAndSwitchContent`'s own
    /// field-verified boilerplate exactly: back-to-back app launches
    /// within one xctest process can leave a freshly-launched app's menu
    /// bar not yet registered with the Accessibility server for a
    /// moment even after its first window exists.
    private func ensureMenuBarReady() {
        XCTAssertTrue(waitFor(app.windows.firstMatch), "App window did not appear after launch.")
        app.activate()
        XCTAssertTrue(
            waitFor(app.menuBars.firstMatch, timeout: 20),
            "Calyx's menu bar never appeared within ~20s of its window showing up."
        )
    }

    /// Fixes the terminal window's tab count at exactly 2 (1 initial + 1
    /// created here) BEFORE any auxiliary panel opens -- see this file's
    /// header for why a later `waitForTabCount(2)` proves the count is
    /// UNCHANGED, not merely non-zero.
    private func fixTabCountAtTwo() {
        createNewTabViaMenu()
        XCTAssertEqual(
            waitForCount(countTabBarTabs, toEqual: 2), 2,
            "Precondition: expected exactly two tabs before opening the auxiliary window under test."
        )
    }

    /// Prints, AND attaches (mirrors `CalyxUITestCase.saveScreenshot`'s
    /// own dual-channel rationale: stdout is easy to lose, an
    /// `XCTAttachment` survives in the run's `.xcresult` regardless), a
    /// snapshot of every current `app.windows` element's own AXTitle/
    /// identifier/label -- the real, field-verified evidence this
    /// suite's locators were built from (see this file's header, "About
    /// panel locator"), captured on every run (not just on failure) so
    /// it is available for inspection regardless of outcome.
    private func logWindowsSnapshot(_ context: String) {
        let windows = app.windows.allElementsBoundByIndex
        let lines = windows.enumerated().map { index, window in
            "  [\(index)] title=\"\(window.title)\" identifier=\"\(window.identifier)\" label=\"\(window.label)\""
        }
        let message = "[AuxiliaryWindowCloseE2ETests] windows snapshot (\(context)): count=\(windows.count)\n"
            + lines.joined(separator: "\n")
        print(message)
        let attachment = XCTAttachment(string: message)
        attachment.name = "windows-snapshot-\(context)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: - Tests

    /// THE reported bug's core negative condition (see this file's
    /// header): with About key, Cmd+W must close ONLY About and leave
    /// the terminal's tabs alone. Pre-fix, `-[NSApplication
    /// targetForAction:]`'s main-window fallback found the terminal's own
    /// `CalyxWindowController.closeTab(_:)` instead, silently closing its
    /// active tab while About sat untouched in front.
    ///
    /// About is now a plain `NSWindow` (`AboutWindowController`), so it
    /// is the Settings case of the two failure modes
    /// `NSWindow+CalyxClose.swift`'s header documents -- `canBecomeMain
    /// == true`, so pre-fix Cmd+W here would have been inert rather than
    /// destructive. The fix (`calyxPerformClose(_:)` resolving against
    /// the KEY window's own chain) covers both identically, and this
    /// test's post-conditions -- About gone, tab count untouched -- are
    /// the same either way.
    func test_cmdW_withAboutKey_closesAbout_andLeavesTerminalTabsIntact() {
        ensureMenuBarReady()
        fixTabCountAtTwo()

        XCTAssertEqual(app.windows.count, 1, "Precondition: only the terminal window should be open before About.")

        app.activate()
        Thread.sleep(forTimeInterval: 0.5)
        menuAction("Calyx", item: "About Calyx")

        // About is Calyx's own `NSWindow`, located by the AX title
        // `AboutWindowController` sets -- see this file's header,
        // "About window locator".
        let aboutWindow = app.windows["About Calyx"]
        XCTAssertTrue(waitFor(aboutWindow, timeout: 5), "About window did not appear after \"About Calyx\".")
        logWindowsSnapshot("after opening About")
        saveScreenshot(name: "auxiliary-close-about-open")
        XCTAssertEqual(app.windows.count, 2, "Opening About must add exactly one window (terminal + About).")

        // About was just made key by AboutWindowController.show() --
        // send Cmd+W while it, not the terminal, is on top / key.
        app.typeKey("w", modifierFlags: .command)

        // THE NEGATIVE CONDITION, part 1: About must actually disappear
        // (proves Cmd+W resolved against About's OWN key-window chain,
        // not silently swallowed) -- checked BEFORE the tab count below,
        // since a misrouted close is async and checking tabs first
        // could pass vacuously ahead of a delayed wrong close landing.
        waitForNonExistence(aboutWindow, timeout: 5)
        logWindowsSnapshot("after Cmd+W")
        XCTAssertFalse(aboutWindow.exists, "About did not close after Cmd+W while it was key.")

        // THE NEGATIVE CONDITION, part 2: the terminal's own tabs, fixed
        // at 2 by fixTabCountAtTwo() above, must be completely untouched.
        XCTAssertEqual(
            waitForCount(countTabBarTabs, toEqual: 2), 2,
            "Terminal tab count changed after Cmd+W closed About -- Cmd+W must have misrouted to the " +
            "terminal window's active tab (the exact pre-fix symptom this test exists to catch)."
        )

        XCTAssertEqual(app.windows.count, 1, "Exactly the terminal window should remain open.")
        XCTAssertTrue(app.windows.firstMatch.exists, "The terminal window should still be alive.")
    }

    /// Settings (`SettingsWindowController`) is a plain `NSWindow`:
    /// `canBecomeMain == true`, so making it key ALSO makes it main. Pre-fix, `targetForAction:`'s main-window
    /// fallback then walked Settings' OWN chain a second time, found no
    /// `closeTab:` receiver there either, and AppKit auto-disabled the
    /// menu item outright -- Cmd+W did nothing at all (no misroute, but
    /// no response either; Settings stayed open).
    func test_cmdW_withSettingsKey_closesSettings_andLeavesTerminalTabsIntact() {
        ensureMenuBarReady()
        fixTabCountAtTwo()

        let windowCountBeforeSettings = app.windows.count
        XCTAssertEqual(windowCountBeforeSettings, 1, "Precondition: only the terminal window should be open before Settings.")

        // Mirrors SettingsWindowE2ETests.openSettingsViaMenu() exactly --
        // "Settings…" (U+2026): field-verified that AppKit relabels the
        // standard Cmd+, "Preferences…" item to this at runtime on this
        // macOS (see that file's own header).
        app.activate()
        Thread.sleep(forTimeInterval: 0.5)
        menuAction("Calyx", item: "Settings…")

        // SettingsWindowController.setupContent() has no explicit
        // initial-pane override, so NSTabViewController defaults to
        // index 0 (Appearance); the window's own title tracks the
        // selected pane, so "Appearance" is its title on first open --
        // field-verified precedent: SettingsWindowE2ETests
        // .test_settingsWindow_toolbarTabsHaveImagesAndSwitchContent.
        let settingsWindow = app.windows["Appearance"]
        XCTAssertTrue(waitFor(settingsWindow, timeout: 10), "Settings window (titled \"Appearance\" on open) did not appear.")
        logWindowsSnapshot("after opening Settings")
        saveScreenshot(name: "auxiliary-close-settings-open")

        XCTAssertEqual(
            app.windows.count, windowCountBeforeSettings + 1,
            "Settings should open exactly one additional window."
        )

        app.typeKey("w", modifierFlags: .command)

        // THE NEGATIVE CONDITION, part 1: Settings must actually close.
        waitForNonExistence(settingsWindow, timeout: 5)
        XCTAssertEqual(
            app.windows.count, windowCountBeforeSettings,
            "Settings window (\"Appearance\") did not close after Cmd+W while it was key."
        )

        // THE NEGATIVE CONDITION, part 2.
        XCTAssertEqual(
            waitForCount(countTabBarTabs, toEqual: 2), 2,
            "Terminal tab count changed after Cmd+W closed Settings -- the terminal's tabs must be untouched."
        )
    }

    /// Session Browser (`SessionBrowserWindowController`) is, like
    /// Settings, a plain `NSWindow` (`canBecomeMain == true`) -- pre-fix
    /// it shared Settings' exact symptom (Cmd+W silently disabled, not
    /// misrouted to the terminal). `app.windows["Sessions"]` is this
    /// window's own established locator elsewhere in this test target
    /// (`SessionBrowserAttachKillE2ETests`).
    func test_cmdW_withSessionBrowserKey_closesBrowser_andLeavesTerminalTabsIntact() {
        ensureMenuBarReady()
        fixTabCountAtTwo()

        let windowCountBeforeBrowser = app.windows.count
        XCTAssertEqual(
            windowCountBeforeBrowser, 1,
            "Precondition: only the terminal window should be open before Session Browser."
        )

        app.activate()
        Thread.sleep(forTimeInterval: 0.5)
        menuAction("View", item: "Session Browser")

        let sessionsWindow = app.windows["Sessions"]
        XCTAssertTrue(waitFor(sessionsWindow, timeout: 10), "Session Browser window (titled \"Sessions\") did not appear.")
        logWindowsSnapshot("after opening Session Browser")
        saveScreenshot(name: "auxiliary-close-sessionbrowser-open")

        XCTAssertEqual(
            app.windows.count, windowCountBeforeBrowser + 1,
            "Session Browser should open exactly one additional window."
        )

        app.typeKey("w", modifierFlags: .command)

        // THE NEGATIVE CONDITION, part 1: Session Browser must actually close.
        waitForNonExistence(sessionsWindow, timeout: 5)
        XCTAssertEqual(
            app.windows.count, windowCountBeforeBrowser,
            "Session Browser window (\"Sessions\") did not close after Cmd+W while it was key."
        )

        // THE NEGATIVE CONDITION, part 2.
        XCTAssertEqual(
            waitForCount(countTabBarTabs, toEqual: 2), 2,
            "Terminal tab count changed after Cmd+W closed the Session Browser -- the terminal's tabs must be untouched."
        )
    }
}
