// SettingsSessionsToggleE2ETests.swift
// CalyxUITests
//
// End-to-end coverage for the exact user-visible gap DEFECT 1's own
// investigation found (SettingsWindowController.swift's
// persistentSessionsSwitch et al. never wiring `.target`/`.action`):
// flipping "Enable persistent sessions" in Settings > Sessions LOOKS
// like it worked (a plain NSSwitch always flips its own on-screen
// state on click, wired or not) but never writes
// SessionSettings.persistentSessionsEnabled at all, so the setting
// cannot actually be turned on from the shipped UI. A unit-level test
// (SettingsWindowControllerSessionsToggleWiringTests) pins the
// `.target`/`.action` wiring directly; this suite instead drives the
// real user journey end to end and observes the ONE consequence that
// distinguishes "looked like it worked" from "actually took effect":
// whether a FRESH process (a brand-new SettingsWindowController.shared
// singleton, seeded from whatever's actually on disk) shows the switch
// still on after a real quit and relaunch.
//
// WHY NO "-calyx.session.persistentSessionsEnabled" LAUNCH ARGUMENT
// (unlike RealQuitRestoreE2ETests/SessionPersistenceE2ETests/
// SessionBrowserAttachKillE2ETests/AgentResumeOfferE2ETests, which all
// force this exact setting on via that argument to exercise something
// ELSE with persistence already enabled): UserDefaults' search order
// puts NSArgumentDomain (command-line `-key value` overrides) ABOVE the
// app's own persistent domain for every read, for the lifetime of the
// process that received it -- an override for this key would shadow
// EVERY future read of SessionSettings.persistentSessionsEnabled for
// this whole process, silently reporting the override's value
// regardless of any `.set()` call, which is exactly the write this
// suite exists to prove happens (or doesn't).
//
// WHY A PER-TEST `CALYX_UITEST_DEFAULTS_SUITE`, NOT THE REAL
// `com.calyx.terminal.e2e` DOMAIN (investigated, not assumed -- an
// earlier version of this suite relied on a fresh per-test `HOME`
// override alone, on the assumption that `UserDefaults.standard`
// resolves `~/Library/Preferences/` against a launched process's
// spoofed `HOME`. It doesn't: `UserDefaults.standard` is mediated by
// `cfprefsd`, keyed by the real macOS account rather than by `HOME`, so
// every prior run of this suite was silently reading and writing the
// developer's REAL `com.calyx.terminal.e2e` defaults domain regardless
// of `homeDir`). `SessionSettings` now has its own dedicated seam for
// this (`CALYX_UITEST_DEFAULTS_SUITE`, mirroring
// `SessionPersistenceActor`'s existing `CALYX_UITEST_SESSION_DIR`
// convention): this suite launches Calyx with that variable set to a
// fresh, per-test-unique `UserDefaults` suite name, so
// `SessionSettings.persistentSessionsEnabled` reads/writes land there
// instead of `.standard`, and `tearDown()` removes that suite's on-disk
// domain afterward -- hermetic, and the developer's real defaults
// domain is never touched by running this suite.
//
// WHY THE PER-TEST `HOME`/`sessionDir` OVERRIDES STILL EXIST: they
// isolate everything else this journey touches (`CALYX_UITEST_SESSION_DIR`
// for the session daemon's own on-disk state, mirroring
// RealQuitRestoreE2ETests/SessionPersistenceE2ETests's established
// idiom) -- only the UserDefaults piece specifically needed its own
// separate seam.
//
// WHY RELAUNCH, NOT JUST RE-SHOWING THE SAME WINDOW: SettingsWindowController
// .shared is a singleton built once per process and never torn down
// while the app runs (`isReleasedWhenClosed = false`) -- closing and
// reopening the SAME running process's Settings window reuses the
// exact same NSSwitch instance that was just clicked, so it would
// still show "on" regardless of whether the underlying SessionSettings
// value actually changed. Only a genuine relaunch (a brand-new
// SettingsWindowController.shared, reading whatever the previous
// process actually persisted to disk) discriminates the bug from the
// fix. Mirrors RealQuitRestoreE2ETests/SessionPersistenceE2ETests's own
// established quit-via-menu-then-relaunch idiom exactly.

import XCTest

final class SettingsSessionsToggleE2ETests: CalyxUITestCase {

    private var homeDir: String!
    private var sessionDir: String!
    /// Per-test-unique `UserDefaults` suite name (see this file's header,
    /// "WHY A PER-TEST `CALYX_UITEST_DEFAULTS_SUITE`"): the app-under-test
    /// reads/writes `SessionSettings.persistentSessionsEnabled` here
    /// instead of the developer's real `com.calyx.terminal.e2e` defaults
    /// domain, for the lifetime of this one test.
    private var defaultsSuiteName: String!

    override func setUp() {
        continueAfterFailure = false
        let homeSuffix = String(UUID().uuidString.prefix(8))
        let sessionSuffix = String(UUID().uuidString.prefix(8))
        homeDir = "/tmp/cxe2e-\(homeSuffix)-h"
        sessionDir = "/tmp/cxe2e-\(sessionSuffix)-s"
        defaultsSuiteName = "com.calyx.tests.e2e.SettingsSessionsToggleE2ETests-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: homeDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(atPath: sessionDir, withIntermediateDirectories: true)
        launchApp()
    }

    override func tearDown() {
        app?.terminate()
        if let homeDir {
            try? FileManager.default.removeItem(atPath: homeDir)
        }
        if let sessionDir {
            try? FileManager.default.removeItem(atPath: sessionDir)
        }
        if let defaultsSuiteName {
            // Best-effort only (mirrors CalyxUITestCase.saveScreenshot's
            // own "best-effort supplement, not required for correctness"
            // shape): the app-under-test -- a SEPARATE process -- is the
            // one that actually wrote this suite's data via `cfprefsd`,
            // which flushes a just-terminated process's writes to its
            // on-disk plist on its OWN schedule, observed to sometimes
            // land AFTER a multi-second wait here -- so this cleanup can
            // race a pending flush and occasionally leave the throwaway
            // suite's plist behind. That's harmless: `defaultsSuiteName`
            // is a fresh UUID every run, so a leftover is never read by
            // anything again; it does NOT touch the real
            // `com.calyx.terminal.e2e` domain, which this suite never
            // writes to at all. Best-effort cleanup, not a correctness
            // requirement, same as the screenshot file write.
            Thread.sleep(forTimeInterval: 1.0)
            UserDefaults().removePersistentDomain(forName: defaultsSuiteName)
            let suitePlistPath = "\(NSHomeDirectory())/Library/Preferences/\(defaultsSuiteName).plist"
            try? FileManager.default.removeItem(atPath: suitePlistPath)
        }
        super.tearDown()
    }

    /// Deliberately NOT `additionalLaunchArguments`-based (see this
    /// file's header): no `-calyx.session.*` overrides at all.
    private func launchApp() {
        app = XCUIApplication()
        app.launchArguments = ["--uitesting", "-AppleLanguages", "(en)"]
        app.launchEnvironment["CALYX_UITEST_SESSION_DIR"] = sessionDir
        app.launchEnvironment["CALYX_UITEST_DEFAULTS_SUITE"] = defaultsSuiteName
        app.launchEnvironment["HOME"] = homeDir
        app.launch()
    }

    private func relaunchWithSameEnvironment() {
        launchApp()
    }

    /// Mirrors SessionPersistenceE2ETests.quitAppViaMenu() exactly: only
    /// a real menu quit (not `app.terminate()`, which sends SIGTERM and
    /// skips AppKit's termination flow) reaches
    /// `applicationShouldTerminate`, which under `--uitesting`
    /// short-circuits straight to `.terminateNow` with no confirmation
    /// dialog.
    private func quitAppViaMenu() {
        menuAction("Calyx", item: "Quit Calyx")
    }

    private func waitForMenuBarAndWindow() {
        XCTAssertTrue(waitFor(app.windows.firstMatch), "App window did not appear after launch.")
        XCTAssertTrue(
            waitFor(app.menuBars.firstMatch, timeout: 20),
            "Calyx's menu bar never appeared within ~20s of its window showing up."
        )
    }

    /// Opens Settings via the app menu and switches to the Sessions
    /// pane, mirroring SettingsWindowE2ETests's own openSettingsViaMenu()
    /// + toolbar-button-click idiom.
    private func openSettingsSessionsPane() {
        app.activate()
        Thread.sleep(forTimeInterval: 0.5)
        menuAction("Calyx", item: "Settings…")

        let settingsWindow = app.windows.firstMatch
        XCTAssertTrue(waitFor(settingsWindow, timeout: 10), "Settings window never appeared.")

        let sessionsButton = settingsWindow.toolbars.buttons["Sessions"]
        XCTAssertTrue(waitFor(sessionsButton, timeout: 5), "No \"Sessions\" toolbar button in Settings.")
        sessionsButton.click()
    }

    /// Accessibility identifier lookup by RAW STRING LITERAL, not the
    /// `AccessibilityID` enum type itself: CalyxUITests never imports
    /// the Calyx module (this whole target only `import XCTest`,
    /// confirmed by reading SessionBrowserAttachKillE2ETests.swift,
    /// which looks up `AccessibilityID.SessionBrowser`-documented
    /// identifiers the identical way, e.g.
    /// `app.buttons["calyx.sessionBrowser.row.\(id).attachButton"]`) --
    /// XCUITest drives the app-under-test as a separate OS process via
    /// the accessibility tree, never by linking its Swift symbols.
    /// Deliberately NOT ordinal (`app.switches.firstMatch`, the idiom
    /// SettingsWindowE2ETests's own pre-existing test already uses for
    /// a coarser check) -- the team-lead handoff for this defect
    /// specifically calls for investigating and adding a stable
    /// identifier, since ordinal lookup silently breaks the moment a
    /// row is reordered or another switch is added above it.
    ///
    /// This string must match whatever raw value the Green phase gives
    /// `AccessibilityID.Settings.persistentSessionsSwitch`
    /// (Calyx/Helpers/AccessibilityID.swift, a new case this cycle's
    /// fix proposes) once it's wired onto the real switch via
    /// `.setAccessibilityIdentifier(...)` in SettingsWindowController.swift.
    private static let persistentSessionsSwitchIdentifier = "calyx.settings.sessions.persistentSessionsSwitch"

    /// Type-agnostic lookup, NOT `app.switches[...]`: an AppKit `NSSwitch`
    /// surfaces to XCUITest as an `AXCheckBox`, not a `.switch` element,
    /// so `app.switches[identifier]` never matches it at all.
    private func persistentSessionsToggle() -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: Self.persistentSessionsSwitchIdentifier).firstMatch
    }

    func test_togglingPersistentSessionsSwitch_actuallyPersistsAcrossRelaunch() {
        waitForMenuBarAndWindow()
        openSettingsSessionsPane()

        let toggle = persistentSessionsToggle()
        XCTAssertTrue(waitFor(toggle, timeout: 5), "No persistent-sessions switch found on the Sessions pane.")
        saveScreenshot(name: "SettingsSessionsToggle_beforeClick")

        let valueBeforeClick = toggle.value as? Int
        toggle.click()
        let valueAfterClick = toggle.value as? Int
        XCTAssertNotEqual(
            valueAfterClick, valueBeforeClick,
            "Clicking the switch must visibly flip its own on-screen state (true even under the bug -- a " +
            "plain NSSwitch always does this on click regardless of whether .target/.action are wired)."
        )

        quitAppViaMenu()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 10), "Calyx did not fully quit after \"Quit Calyx\".")

        relaunchWithSameEnvironment()
        waitForMenuBarAndWindow()
        openSettingsSessionsPane()

        let toggleAfterRelaunch = persistentSessionsToggle()
        XCTAssertTrue(
            waitFor(toggleAfterRelaunch, timeout: 5),
            "No persistent-sessions switch found on the Sessions pane after relaunch."
        )
        XCTAssertEqual(
            toggleAfterRelaunch.value as? Int, valueAfterClick,
            "A brand-new process's SettingsWindowController.shared must seed the switch from what the " +
            "earlier click actually persisted to SessionSettings.persistentSessionsEnabled. Before the fix, " +
            "this reads back the switch's UNSEEDED bare default instead (i.e. reverts), because the click's " +
            "target/action were never wired, so nothing was ever written to disk to seed from -- exactly the " +
            "reported defect (\"flipping any of the four switches... never persists; reopening shows them all " +
            "OFF\")."
        )
    }
}
