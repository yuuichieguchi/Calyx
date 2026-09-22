// SettingsAgentIPCToggleE2ETests.swift
// CalyxUITests
//
// End-to-end coverage for the AI Agent IPC Settings toggle
// (SettingsWindowController.agentIPCRow, AccessibilityID.Settings
// .agentIPCSwitch) that only became possible once CALYX_ENDPOINT_FILE
// closed the pane-side path-resolution hole: with it, a real click on
// the toggle can run real launch-time/manual activation
// (IPCActivationCoordinator.enable/disable, AppDelegate
// .resyncAgentHooksIfInstalled) against a
// `--calyx-path-root=<scoped temp dir>` scratch root and be
// observed end to end -- the real `CalyxMCPServer` binds a real
// loopback port, writes a real `agent-endpoint.json` under the scoped
// root, and writes real calyx-ipc entries into the scoped root's CLI
// config files (`.claude.json` here) -- without ever touching the
// developer's own `~/.claude`, `~/Library/Application Support/Calyx`,
// or `~/.claude.json`.
//
// ISOLATION: mirrors CommandLogE2ETests.swift's own header exactly.
// `--calyx-path-root=<scopedPathRoot>` scopes every Calyx-owned and
// agent-owned config path (`AppSupportDirectory`, `AgentToolPaths`,
// `AgentEndpointFile`) beneath a fresh per-test temp directory.
// `setUp()` pre-creates `<scopedPathRoot>/.claude` so
// `IPCConfigManager.enableIPC`'s `anySucceeded` gate always succeeds,
// regardless of what CLIs happen to be installed on the machine running
// this suite. Deliberately NOT `-calyx.ipc.enabled YES` (unlike
// CommandLogE2ETests/CockpitApprovalE2ETests/
// CockpitAgentHookApprovalE2ETests, which all force IPC on to exercise
// something ELSE with it already enabled): this suite's own subject is
// the toggle itself, so `IPCSettings.enabled` must start at its real
// documented default (`false`) and change only in response to this
// suite's own clicks -- an NSArgumentDomain override would shadow every
// read of it for the process's whole lifetime, exactly the reason
// `SettingsSessionsToggleE2ETests`'s own header gives for avoiding the
// same override on its own setting.
//
// A per-test `CALYX_UITEST_DEFAULTS_SUITE` (mirroring
// `SettingsSessionsToggleE2ETests`'s own established isolation) keeps
// `IPCSettings.enabled` off the developer's real `com.calyx.terminal.e2e`
// defaults domain, so relaunching with the SAME suite name is what lets
// `test_toggleSurvivesRelaunch_reportingTheSamePortAndToken` observe a
// brand-new process's own launch-time activation reading back exactly
// what an earlier process's click persisted.

import XCTest

final class SettingsAgentIPCToggleE2ETests: CalyxUITestCase {

    private var scopedPathRoot: String!
    private var defaultsSuiteName: String!

    override func setUp() {
        continueAfterFailure = false
        let suffix = String(UUID().uuidString.prefix(8))
        scopedPathRoot = NSTemporaryDirectory() + "CalyxUITests-agentipc-\(suffix)"
        defaultsSuiteName = "com.calyx.tests.e2e.SettingsAgentIPCToggleE2ETests-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: scopedPathRoot, withIntermediateDirectories: true)
        // Satisfies IPCConfigManager.enableIPC's anySucceeded gate (see
        // this file's header) without depending on what CLIs happen to
        // be installed on the machine running this suite.
        try? FileManager.default.createDirectory(atPath: scopedPathRoot + "/.claude", withIntermediateDirectories: true)
        launchApp()
    }

    override func tearDown() {
        app?.terminate()
        if let scopedPathRoot {
            try? FileManager.default.removeItem(atPath: scopedPathRoot)
        }
        if let defaultsSuiteName {
            // Best-effort only, mirroring SettingsSessionsToggleE2ETests's
            // own documented cfprefsd-flush caveat.
            Thread.sleep(forTimeInterval: 1.0)
            UserDefaults().removePersistentDomain(forName: defaultsSuiteName)
            let suitePlistPath = "\(NSHomeDirectory())/Library/Preferences/\(defaultsSuiteName).plist"
            try? FileManager.default.removeItem(atPath: suitePlistPath)
        }
        super.tearDown()
    }

    // MARK: - Launch

    /// Deliberately NOT `additionalLaunchArguments`-based (see this
    /// file's header): no `-calyx.ipc.enabled` override.
    private func launchApp() {
        app = XCUIApplication()
        app.launchArguments = ["--uitesting", "-AppleLanguages", "(en)", "--calyx-path-root=\(scopedPathRoot!)"]
        app.launchEnvironment["CALYX_UITEST_DEFAULTS_SUITE"] = defaultsSuiteName
        terminateStaleAppUnderTestInstances()
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

    // MARK: - Settings > Agents navigation

    private func openSettingsAgentsPane() {
        app.activate()
        Thread.sleep(forTimeInterval: 0.5)
        menuAction("Calyx", item: "Settings…")

        let settingsWindow = app.windows.firstMatch
        XCTAssertTrue(waitFor(settingsWindow, timeout: 10), "Settings window never appeared.")

        let agentsButton = settingsWindow.toolbars.buttons["Agents"]
        XCTAssertTrue(waitFor(agentsButton, timeout: 5), "No \"Agents\" toolbar button in Settings.")
        agentsButton.click()
    }

    private func closeSettingsWindow() {
        let settingsWindow = app.windows.firstMatch
        let closeButton = settingsWindow.buttons[XCUIIdentifierCloseWindow]
        if waitFor(closeButton, timeout: 5) {
            closeButton.click()
        }
    }

    /// Type-agnostic lookup, NOT `app.switches[...]`: an AppKit `NSSwitch`
    /// surfaces to XCUITest as an `AXCheckBox` (see
    /// `SettingsSessionsToggleE2ETests.persistentSessionsToggle`'s own
    /// identical doc comment).
    private func agentIPCToggle() -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "calyx.settings.agents.agentIPCSwitch").firstMatch
    }

    // MARK: - Scoped-root readback

    private var scopedEndpointPath: String { scopedPathRoot + "/Calyx/agent-endpoint.json" }
    private var scopedClaudeConfigPath: String { scopedPathRoot + "/.claude.json" }

    private func waitForFileToExist(atPath path: String, timeout: TimeInterval = 20) {
        let deadline = Date().addingTimeInterval(timeout)
        while !FileManager.default.fileExists(atPath: path), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.2)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: path), "\(path) never appeared within \(timeout)s")
    }

    private func waitForFileToBeAbsent(atPath path: String, timeout: TimeInterval = 20) {
        let deadline = Date().addingTimeInterval(timeout)
        while FileManager.default.fileExists(atPath: path), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.2)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: path), "\(path) was still present after \(timeout)s")
    }

    private func readEndpoint() throws -> (port: Int, token: String) {
        let data = try XCTUnwrap(FileManager.default.contents(atPath: scopedEndpointPath))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let port = try XCTUnwrap(json["port"] as? Int)
        let token = try XCTUnwrap(json["token"] as? String)
        return (port, token)
    }

    // MARK: - Test 1: the toggle survives a relaunch, reporting the SAME port and the SAME token

    func test_toggleSurvivesRelaunch_reportingTheSamePortAndToken() throws {
        waitForMenuBarAndWindow()
        openSettingsAgentsPane()

        let toggle = agentIPCToggle()
        XCTAssertTrue(waitFor(toggle, timeout: 5), "No AI Agent IPC switch found on the Agents pane.")
        toggle.click()
        closeSettingsWindow()

        waitForFileToExist(atPath: scopedEndpointPath)
        let firstEndpoint = try readEndpoint()

        quitAppViaMenu()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 10), "Calyx did not fully quit after \"Quit Calyx\".")

        relaunchWithSameEnvironment()
        waitForMenuBarAndWindow()

        // A brand-new process's own launch-time activation
        // (AppDelegate.resyncAgentHooksIfInstalled takes its activation
        // branch since IPCSettings.enabled is true) re-writes
        // agent-endpoint.json; poll past that in-flight window before
        // reading it back.
        waitForFileToExist(atPath: scopedEndpointPath)
        // IPCEndpointReuse.decide reuses the on-disk port/token from the
        // previous run rather than generating fresh ones, so give the
        // async activation Task a moment to actually land before
        // reading -- there is no UI-visible signal this suite can poll
        // for "activation settled" beyond the file's own existence,
        // which the very first write already satisfies.
        Thread.sleep(forTimeInterval: 1.0)
        let secondEndpoint = try readEndpoint()

        openSettingsAgentsPane()
        let toggleAfterRelaunch = agentIPCToggle()
        XCTAssertTrue(waitFor(toggleAfterRelaunch, timeout: 5), "No AI Agent IPC switch found after relaunch.")
        XCTAssertEqual(toggleAfterRelaunch.value as? Int, 1,
                       "a brand-new process's SettingsWindowController.shared must seed the switch from " +
                       "IPCSettings.enabled as this run's own earlier click persisted it")

        XCTAssertEqual(secondEndpoint.port, firstEndpoint.port,
                       "IPCEndpointReuse.decide must reuse the on-disk port across a relaunch")
        XCTAssertEqual(secondEndpoint.token, firstEndpoint.token,
                       "IPCEndpointReuse.decide must reuse the on-disk token across a relaunch")
    }

    // MARK: - Test 2: turning off removes agent-endpoint.json and Calyx's CLI config entries

    func test_togglingOff_removesEndpointFileAndCLIConfigEntries() throws {
        waitForMenuBarAndWindow()
        openSettingsAgentsPane()

        let toggle = agentIPCToggle()
        XCTAssertTrue(waitFor(toggle, timeout: 5), "No AI Agent IPC switch found on the Agents pane.")
        toggle.click()

        waitForFileToExist(atPath: scopedEndpointPath)

        let enabledConfigContent = try? String(contentsOfFile: scopedClaudeConfigPath, encoding: .utf8)
        XCTAssertTrue(enabledConfigContent?.contains("calyx-ipc") == true,
                     "enabling must write a calyx-ipc entry into the scoped root's .claude.json -- got: " +
                     "\(enabledConfigContent ?? "(file absent)")")

        toggle.click()
        closeSettingsWindow()

        waitForFileToBeAbsent(atPath: scopedEndpointPath)

        let disabledConfigContent = try? String(contentsOfFile: scopedClaudeConfigPath, encoding: .utf8)
        XCTAssertFalse(disabledConfigContent?.contains("calyx-ipc") ?? false,
                       "disabling must remove the calyx-ipc entry from the scoped root's .claude.json -- got: " +
                       "\(disabledConfigContent ?? "(file absent)")")
    }
}
