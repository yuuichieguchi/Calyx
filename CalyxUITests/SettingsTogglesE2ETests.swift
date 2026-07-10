// SettingsTogglesE2ETests.swift
// CalyxUITests
//
// Clones SettingsSessionsToggleE2ETests's click-quit-relaunch-readback
// journey (see that file's own header for the full incident rationale)
// for the 6 switches its own suite left uncovered: historyPersistence
// (Sessions pane, already carried a stable accessibility identifier
// before this cycle), agentResume, agentResumeAutoExecute (moved to the
// new Agents pane by a later Settings restructure -- same stable
// identifiers, still prefixed `calyx.settings.sessions.*`) plus
// smoothScrolling (Appearance pane), lspAutoInstall,
// lspRequireConfirmation (LSP pane) -- newly identified this cycle
// (AccessibilityID.Settings.*, wired onto their NSSwitch controls in
// SettingsWindowController.swift).
//
// HERMETICITY GAP FOUND WHILE WRITING THIS (investigated, not assumed):
// unlike the four Sessions-pane switches, which all read/write through
// `SessionSettings.store` (resolves `CALYX_UITEST_DEFAULTS_SUITE` before
// falling back to `.standard`, see that type's own doc comment),
// `smoothScrollDidChange`/`lspAutoInstallDidChange`/
// `lspRequireConfirmationDidChange` (SettingsWindowController.swift) and
// `LSPSettings`'s own two knobs read/write `UserDefaults.standard`
// DIRECTLY, with no suite-routing seam at all. That is a production
// hermeticity gap, but fixing it would be a behavior change beyond this
// task's identifier-only production scope, so it is not fixed here.
// Consequence: for THOSE three switches only, this suite's per-test
// `CALYX_UITEST_DEFAULTS_SUITE` isolates nothing -- the app-under-test's
// `.standard` still resolves to the real, standing
// `com.calyx.terminal.e2e` bundle-ID domain (PRODUCT_BUNDLE_IDENTIFIER
// for every E2E run, see project.yml's own comment on the
// `debuguitesting` config; distinct from the production
// `com.calyx.terminal` domain, but SHARED across every run of this
// suite, not per-test-isolated). Left alone, a run of this suite would
// durably flip that shared domain's `smoothScrollEnabled`/
// `calyx.lsp.autoInstallEnabled`/`calyx.lsp.requireInstallConfirmation`
// keys for every subsequent E2E run on this machine. `setUp()`/
// `tearDown()` below save and restore those three raw keys directly
// (via `UserDefaults(suiteName: "com.calyx.terminal.e2e")` from the TEST
// PROCESS itself -- the same "read/remove a persistent domain by name
// from the test process" technique `CalyxUITestCase.tearDown()`/
// `SettingsSessionsToggleE2ETests.tearDown()` already use for their own
// throwaway per-test suites) so this suite never leaves that shared
// domain in a different state than it found it, regardless of which
// switch's test ran.

import XCTest

final class SettingsTogglesE2ETests: CalyxUITestCase {

    /// The real, standing UserDefaults domain every `--uitesting` launch
    /// of Calyx.app resolves `UserDefaults.standard` to (see this file's
    /// header). Read directly from the TEST process to save/restore the
    /// three raw keys that bypass `CALYX_UITEST_DEFAULTS_SUITE`.
    /// `nonisolated(unsafe)`: `UserDefaults` isn't `Sendable` in this
    /// SDK, but XCTest runs one test class's methods serially and this
    /// value is read-only after initialization, mirroring
    /// `SessionSettings.uiTestSuite`'s own identical reasoning.
    private nonisolated(unsafe) static let e2eStandardDefaults = UserDefaults(suiteName: "com.calyx.terminal.e2e")!

    private static let smoothScrollKey = "smoothScrollEnabled"
    private static let lspAutoInstallKey = "calyx.lsp.autoInstallEnabled"
    private static let lspRequireConfirmationKey = "calyx.lsp.requireInstallConfirmation"

    private var homeDir: String!
    private var sessionDir: String!
    private var defaultsSuiteName: String!

    /// Original values of the three raw-`UserDefaults.standard`-backed
    /// keys (see this file's header), captured before this test runs so
    /// `tearDown()` can put them back exactly as found -- `nil` means
    /// "was unset", distinct from "was explicitly false".
    private var savedSmoothScroll: Bool?
    private var savedLSPAutoInstall: Bool?
    private var savedLSPRequireConfirmation: Bool?

    override func setUp() {
        continueAfterFailure = false
        let homeSuffix = String(UUID().uuidString.prefix(8))
        let sessionSuffix = String(UUID().uuidString.prefix(8))
        homeDir = "/tmp/cxe2e-\(homeSuffix)-h"
        sessionDir = "/tmp/cxe2e-\(sessionSuffix)-s"
        defaultsSuiteName = "com.calyx.tests.e2e.SettingsTogglesE2ETests-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: homeDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(atPath: sessionDir, withIntermediateDirectories: true)

        savedSmoothScroll = Self.e2eStandardDefaults.object(forKey: Self.smoothScrollKey) as? Bool
        savedLSPAutoInstall = Self.e2eStandardDefaults.object(forKey: Self.lspAutoInstallKey) as? Bool
        savedLSPRequireConfirmation = Self.e2eStandardDefaults.object(forKey: Self.lspRequireConfirmationKey) as? Bool

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
            // Best-effort only, mirroring SettingsSessionsToggleE2ETests's
            // own documented cfprefsd-flush caveat.
            Thread.sleep(forTimeInterval: 1.0)
            UserDefaults().removePersistentDomain(forName: defaultsSuiteName)
            let suitePlistPath = "\(NSHomeDirectory())/Library/Preferences/\(defaultsSuiteName).plist"
            try? FileManager.default.removeItem(atPath: suitePlistPath)
        }

        // Restore the three raw `com.calyx.terminal.e2e` keys to exactly
        // what this test found before it ran (see this file's header).
        if let savedSmoothScroll {
            Self.e2eStandardDefaults.set(savedSmoothScroll, forKey: Self.smoothScrollKey)
        } else {
            Self.e2eStandardDefaults.removeObject(forKey: Self.smoothScrollKey)
        }
        if let savedLSPAutoInstall {
            Self.e2eStandardDefaults.set(savedLSPAutoInstall, forKey: Self.lspAutoInstallKey)
        } else {
            Self.e2eStandardDefaults.removeObject(forKey: Self.lspAutoInstallKey)
        }
        if let savedLSPRequireConfirmation {
            Self.e2eStandardDefaults.set(savedLSPRequireConfirmation, forKey: Self.lspRequireConfirmationKey)
        } else {
            Self.e2eStandardDefaults.removeObject(forKey: Self.lspRequireConfirmationKey)
        }

        super.tearDown()
    }

    /// Deliberately NOT `additionalLaunchArguments`-based, mirroring
    /// SettingsSessionsToggleE2ETests exactly: no `-calyx.session.*` /
    /// `-calyx.lsp.*` NSArgumentDomain overrides, which would shadow
    /// every future read of the setting under test for this process's
    /// whole lifetime regardless of any `.set()` call this suite
    /// exercises.
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

    /// Opens Settings via the app menu and switches to `pane`'s own
    /// toolbar button, mirroring SettingsWindowE2ETests's/
    /// SettingsSessionsToggleE2ETests's own openSettings*Pane() idiom.
    private func openSettingsPane(_ pane: String) {
        app.activate()
        Thread.sleep(forTimeInterval: 0.5)
        menuAction("Calyx", item: "Settings…")

        let settingsWindow = app.windows.firstMatch
        XCTAssertTrue(waitFor(settingsWindow, timeout: 10), "Settings window never appeared.")

        let paneButton = settingsWindow.toolbars.buttons[pane]
        XCTAssertTrue(waitFor(paneButton, timeout: 5), "No \"\(pane)\" toolbar button in Settings.")
        paneButton.click()
    }

    /// Type-agnostic lookup, NOT `app.switches[...]`: an AppKit `NSSwitch`
    /// surfaces to XCUITest as an `AXCheckBox`, not a `.switch` element
    /// (see SettingsSessionsToggleE2ETests's own doc comment for this
    /// exact finding).
    private func toggle(identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// Drives the full click-quit-relaunch-readback journey for one
    /// switch, mirroring SettingsSessionsToggleE2ETests
    /// .test_togglingPersistentSessionsSwitch_actuallyPersistsAcrossRelaunch()
    /// exactly, parameterized on the switch's own accessibility
    /// identifier and the Settings pane it lives on.
    private func assertTogglePersistsAcrossRelaunch(
        identifier: String,
        pane: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        waitForMenuBarAndWindow()
        openSettingsPane(pane)

        let toggleElement = toggle(identifier: identifier)
        XCTAssertTrue(
            waitFor(toggleElement, timeout: 5),
            "No switch with identifier \"\(identifier)\" found on the \"\(pane)\" pane.",
            file: file, line: line
        )

        let valueBeforeClick = toggleElement.value as? Int
        toggleElement.click()
        let valueAfterClick = toggleElement.value as? Int
        XCTAssertNotEqual(
            valueAfterClick, valueBeforeClick,
            "Clicking the switch (\(identifier)) must visibly flip its own on-screen state.",
            file: file, line: line
        )

        quitAppViaMenu()
        XCTAssertTrue(
            app.wait(for: .notRunning, timeout: 10),
            "Calyx did not fully quit after \"Quit Calyx\".",
            file: file, line: line
        )

        relaunchWithSameEnvironment()
        waitForMenuBarAndWindow()
        openSettingsPane(pane)

        let toggleAfterRelaunch = toggle(identifier: identifier)
        XCTAssertTrue(
            waitFor(toggleAfterRelaunch, timeout: 5),
            "No switch with identifier \"\(identifier)\" found on the \"\(pane)\" pane after relaunch.",
            file: file, line: line
        )
        XCTAssertEqual(
            toggleAfterRelaunch.value as? Int, valueAfterClick,
            "A brand-new process's SettingsWindowController.shared must seed the switch " +
            "(\(identifier)) from what the earlier click actually persisted to disk.",
            file: file, line: line
        )
    }

    func test_historyPersistenceSwitch_persistsAcrossRelaunch() {
        assertTogglePersistsAcrossRelaunch(
            identifier: "calyx.settings.sessions.historyPersistenceSwitch",
            pane: "Sessions"
        )
    }

    func test_agentResumeSwitch_persistsAcrossRelaunch() {
        assertTogglePersistsAcrossRelaunch(
            identifier: "calyx.settings.sessions.agentResumeSwitch",
            pane: "Agents"
        )
    }

    func test_agentResumeAutoExecuteSwitch_persistsAcrossRelaunch() {
        assertTogglePersistsAcrossRelaunch(
            identifier: "calyx.settings.sessions.agentResumeAutoExecuteSwitch",
            pane: "Agents"
        )
    }

    func test_smoothScrollingSwitch_persistsAcrossRelaunch() {
        assertTogglePersistsAcrossRelaunch(
            identifier: "calyx.settings.appearance.smoothScrollingSwitch",
            pane: "Appearance"
        )
    }

    func test_lspAutoInstallSwitch_persistsAcrossRelaunch() {
        assertTogglePersistsAcrossRelaunch(
            identifier: "calyx.settings.lsp.lspAutoInstallSwitch",
            pane: "LSP"
        )
    }

    func test_lspRequireConfirmationSwitch_persistsAcrossRelaunch() {
        assertTogglePersistsAcrossRelaunch(
            identifier: "calyx.settings.lsp.lspRequireConfirmationSwitch",
            pane: "LSP"
        )
    }

    /// Pins the Agents pane's "Agent Hook Approval" toggle (its own
    /// heading + wrapping subtitle pushed this pane to be the tallest of
    /// all Settings panes) as actually reachable and operable, not merely
    /// present in the AX tree: SettingsPaneContentViewController sizes
    /// the Settings window to each pane's `view.fittingSize.height` with
    /// no scroll view (see SettingsWindowController.swift), so a pane
    /// taller than the screen clips its own trailing content below the
    /// window's bottom edge with no way to reach it.
    func test_agentHookApprovalSwitch_isReachableAndTogglesOnAgentsPane() {
        waitForMenuBarAndWindow()
        openSettingsPane("Agents")

        let toggleElement = toggle(identifier: "calyx.settings.sessions.agentHookApprovalSwitch")
        XCTAssertTrue(waitFor(toggleElement, timeout: 5), "agentHookApproval switch not found on Agents pane.")
        // The bug: the switch exists in the AX tree but is clipped below the
        // window with no scroll view, so it is not hittable / cannot be clicked.
        XCTAssertTrue(toggleElement.isHittable, "agentHookApproval switch is present but not hittable — it is clipped outside the Settings window (no scroll).")
        let before = toggleElement.value as? Int
        toggleElement.click()
        XCTAssertNotEqual(toggleElement.value as? Int, before, "Clicking the switch must flip its visible state.")
    }
}
