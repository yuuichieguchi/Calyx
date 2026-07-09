//
//  CommandTrackingSettingsToggleWiringTests.swift
//  CalyxTests
//
//  TDD Red phase (P4, command-log Settings section). Same two-half split
//  as SettingsWindowControllerSessionsToggleWiringTests (see that file's
//  own header for the full rationale of each half's reachability), plus
//  a third part (C) this file adds on top of that shape:
//
//  ROUND-3 UPDATE (user-directed Settings restructure): commandTracking
//  moved off the Sessions pane onto the new Agents pane along with
//  agentResume/agentResumeAutoExecute/cockpitAutoApprove -- everywhere
//  below originally said "Sessions pane"/`.pane == .sessions` (P4-era,
//  still accurate as history) now reads "Agents pane"/`.pane == .agents`
//  to match where the row actually lives today.
//
//  (A) TARGET/ACTION WIRING -- against the REAL SettingsWindowController
//  .shared singleton's Agents pane view tree, located by its OWN
//  accessibility identifier (not positional index), so this file is
//  independent of wherever the Green phase places the new row relative
//  to the other agent-related toggles.
//
//  (B) INITIAL-STATE SEEDING -- against
//  SettingsWindowController.sessionToggleInitialState(for:), the same
//  singleton-independent pure seam SettingsWindowControllerSessionsToggleWiringTests
//  established, extended with a new .commandTracking case that reads
//  CommandTrackingSettings.trackingEnabled instead of SessionSettings
//  (command tracking's backing store is CommandTrackingSettings, not
//  SessionSettings).
//
//  (C) SIDE EFFECTS (review finding, added post-Green) -- (A) only pins
//  that .target/.action are wired, never that invoking the handler does
//  the right thing. This part drives the real switch through its real
//  action via SettingsWindowController._shellIntegrationRootForTesting
//  (see that section's own header below).
//
//  Held-out compile-RED (see SessionCommandSynthesizerRemoteAttachTests'
//  header for this codebase's convention): SettingsRow.commandTracking,
//  AccessibilityID.Settings.commandTrackingSwitch, and the
//  #selector(commandTrackingDidChange:) target do not exist yet. This
//  file fails to compile until the Green phase adds all three.
//
//  Proposed API:
//
//    SettingsRow.swift: add `case commandTracking` to the enum, routed
//    to `.pane == .sessions` at the time (round-3 moved it to `.agents`
//    -- see this file's header).
//
//    AccessibilityID.swift, enum Settings: add
//    `static let commandTrackingSwitch = "calyx.settings.sessions.commandTrackingSwitch"`
//
//    SettingsWindowController.swift:
//    - sectionHeading(for: .commandTracking) returns
//      SectionHeading(title: "Command Tracking", subtitle: "Changes apply to new terminals only.")
//      -- the caption the plan requires ("変更は新しいターミナルから適用されます"),
//      translated, since this file uses English UI text throughout (verified: zero
//      Japanese strings anywhere in SettingsWindowController.swift).
//    - contentView(for: .commandTracking) returns a new
//      commandTrackingRow(), built the same self-contained way as
//      persistentSessionsRow()/agentResumeRow(): local NSSwitch, identifier
//      AccessibilityID.Settings.commandTrackingSwitch, state seeded from
//      Self.sessionToggleInitialState(for: .commandTracking), target self,
//      action #selector(commandTrackingDidChange:).
//    - sessionToggleInitialState(for:) gets a new
//      `case .commandTracking: return CommandTrackingSettings.trackingEnabled` arm.
//    - a new `@objc private func commandTrackingDidChange(_ sender: NSSwitch)`
//      sets `CommandTrackingSettings.trackingEnabled = (sender.state == .on)`.
//

import XCTest
import AppKit
@testable import Calyx

@MainActor
final class CommandTrackingSettingsToggleWiringTests: XCTestCase {

    // MARK: - (A) target/action wiring, via the real singleton's built view tree

    private func agentsPaneView() throws -> NSView {
        let tabViewController = try XCTUnwrap(
            SettingsWindowController.shared.window?.contentViewController as? NSTabViewController,
            "SettingsWindowController's window must host an NSTabViewController as its content"
        )
        let agentsIndex = try XCTUnwrap(
            SettingsPane.allCases.firstIndex(of: .agents),
            "SettingsPane must have a .agents case"
        )
        let tabItem = tabViewController.tabViewItems[agentsIndex]
        return try XCTUnwrap(tabItem.viewController?.view, "The Agents tab item must host a real view controller")
    }

    /// Depth-first walk collecting every NSSwitch in `view`'s subview
    /// tree whose accessibility identifier matches `identifier` --
    /// located by identifier rather than position, unlike
    /// SettingsWindowControllerSessionsToggleWiringTests' positional
    /// collectSwitches(in:), since this file must not assume where the
    /// Green phase places the new row relative to the four existing
    /// session toggles.
    private func findSwitch(identifier: String, in view: NSView) -> NSSwitch? {
        for subview in view.subviews {
            if let toggleSwitch = subview as? NSSwitch, toggleSwitch.accessibilityIdentifier() == identifier {
                return toggleSwitch
            }
            if let found = findSwitch(identifier: identifier, in: subview) {
                return found
            }
        }
        return nil
    }

    func test_commandTrackingSwitch_existsWithTargetAndActionWired() throws {
        let toggleSwitch = try XCTUnwrap(
            findSwitch(identifier: AccessibilityID.Settings.commandTrackingSwitch, in: try agentsPaneView()),
            "the Agents pane must contain exactly one switch with the commandTrackingSwitch accessibility identifier"
        )

        XCTAssertTrue(
            toggleSwitch.target === SettingsWindowController.shared,
            "the command tracking switch must have SettingsWindowController.shared as its .target"
        )
        XCTAssertEqual(
            toggleSwitch.action, Selector(("commandTrackingDidChange:")),
            "the command tracking switch's .action must be #selector(commandTrackingDidChange:)"
        )
    }

    // MARK: - (C) commandTrackingDidChange(_:) side effects, via the real
    // singleton's own switch and the _shellIntegrationRootForTesting seam
    //
    // Review finding: (A) above only pins that .target/.action are wired
    // -- it never actually invokes the handler, so a handler that
    // resolved the wrong root, or silently did nothing, would still pass
    // it. This drives the REAL switch found by (A)'s own lookup through
    // its real .action, routed at a temp root via
    // SettingsWindowController._shellIntegrationRootForTesting (the same
    // DEBUG-only seam AppDelegateApplyCalyxShellIntegrationTests uses for
    // AppDelegate's own copy), and asserts the actual install+env-apply /
    // env-remove side effects landed.

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CommandTrackingSettingsToggleWiringTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func currentEnvValue(_ name: String) -> String? {
        getenv(name).map { String(cString: $0) }
    }

    func test_commandTrackingDidChange_onInstallsAndAppliesEnv_offRemovesEnv() throws {
        let root = try makeTempDir()
        SettingsWindowController.shared._shellIntegrationRootForTesting = root
        addTeardownBlock { SettingsWindowController.shared._shellIntegrationRootForTesting = nil }

        let toggleSwitch = try XCTUnwrap(
            findSwitch(identifier: AccessibilityID.Settings.commandTrackingSwitch, in: try agentsPaneView())
        )

        toggleSwitch.state = .on
        _ = SettingsWindowController.shared.perform(Selector(("commandTrackingDidChange:")), with: toggleSwitch)

        XCTAssertTrue(
            ShellIntegrationInstaller.isInstalled(inDirectory: root),
            "flipping the switch ON must install the shell integration scripts into the seam root"
        )
        XCTAssertEqual(
            currentEnvValue("ZDOTDIR"), root.appendingPathComponent("zsh").path,
            "flipping the switch ON must point ZDOTDIR at the installed root"
        )

        toggleSwitch.state = .off
        _ = SettingsWindowController.shared.perform(Selector(("commandTrackingDidChange:")), with: toggleSwitch)

        XCTAssertNotEqual(
            currentEnvValue("ZDOTDIR"), root.appendingPathComponent("zsh").path,
            "flipping the switch OFF must remove the env injection (ZDOTDIR no longer points at the seam root)"
        )
    }

    // MARK: - (B) initial-state seeding, via the existing singleton-independent seam

    private let settingsSuiteName = "com.calyx.tests.CommandTrackingSettingsToggleWiringTests"

    private var originalZdotdir: String?
    private var originalXdgDataDirs: String?
    private var originalCalyxZshZdotdir: String?

    override func setUp() {
        super.setUp()
        CommandTrackingSettings._testUseSuite(named: settingsSuiteName)
        originalZdotdir = ProcessInfo.processInfo.environment["ZDOTDIR"]
        originalXdgDataDirs = ProcessInfo.processInfo.environment["XDG_DATA_DIRS"]
        originalCalyxZshZdotdir = ProcessInfo.processInfo.environment["CALYX_ZSH_ZDOTDIR"]
    }

    override func tearDown() {
        CommandTrackingSettings._testTeardownSuite(named: settingsSuiteName)
        for (name, value) in [
            ("ZDOTDIR", originalZdotdir),
            ("XDG_DATA_DIRS", originalXdgDataDirs),
            ("CALYX_ZSH_ZDOTDIR", originalCalyxZshZdotdir),
        ] {
            if let value {
                setenv(name, value, 1)
            } else {
                unsetenv(name)
            }
        }
        super.tearDown()
    }

    func test_sessionToggleInitialState_commandTracking_readsCommandTrackingSettings() {
        CommandTrackingSettings.trackingEnabled = false
        XCTAssertFalse(
            SettingsWindowController.sessionToggleInitialState(for: .commandTracking),
            "commandTracking's initial state must read CommandTrackingSettings.trackingEnabled, not SessionSettings"
        )

        CommandTrackingSettings.trackingEnabled = true
        XCTAssertTrue(
            SettingsWindowController.sessionToggleInitialState(for: .commandTracking),
            "the mapping must read the setting LIVE, not cache a stale value from an earlier read"
        )
    }
}
