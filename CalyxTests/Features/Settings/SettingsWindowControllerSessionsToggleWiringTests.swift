//
//  SettingsWindowControllerSessionsToggleWiringTests.swift
//  CalyxTests
//
//  TDD Red phase (session-UI defect review, DEFECT 1, SEVERE/top
//  priority): the four Settings > Sessions switches
//  (persistentSessionsSwitch/agentResumeSwitch/agentResumeAutoExecuteSwitch/
//  historyPersistenceSwitch, SettingsWindowController.swift ~18-21) are
//  built via `controlRow(label:control:)` (contentView(for:), ~154-161),
//  which never sets `.target`/`.action` and never seeds an initial
//  `.state` -- unlike smoothScrollingRow()/lspAutoInstallRow()/
//  lspRequireConfirmationRow() (~212-234), which each build a LOCAL
//  NSSwitch, seed its `.state` from the backing setting, and wire
//  `.target`/`.action`, all at construction. The @objc handlers
//  (persistentSessionsDidChange/historyPersistenceDidChange/
//  agentResumeDidChange/agentResumeAutoExecuteDidChange, ~366-383)
//  exist and are individually correct, but nothing ever invokes them:
//  flipping any of the four switches changes no SessionSettings value
//  and never persists, so persistent sessions cannot be enabled from
//  the shipped UI at all.
//
//  THIS FILE'S SCOPE splits the fix contract into its two independently
//  testable halves:
//
//  (A) TARGET/ACTION WIRING -- tested against the REAL
//  SettingsWindowController.shared singleton. Reachable exactly the way
//  SettingsWindowControllerTabIconTests already reaches
//  `.window?.contentViewController`/`.tabViewItems`: this file goes one
//  level deeper, forcing the Sessions pane's own NSTabViewItem.viewController
//  .view to load (safe -- see that file's own header: construction only
//  reads UserDefaults/SessionSettings/LSPSettings, no ghostty FFI, no
//  network) and walking its real AppKit subview tree for NSSwitch
//  instances. This assertion is ORDER-INDEPENDENT across the whole test
//  process: `.target`/`.action` are (once fixed) assigned
//  UNCONDITIONALLY at construction, regardless of whatever
//  SessionSettings value happened to be live at that moment, so it does
//  not matter whether some earlier test file in this same process
//  already triggered `.shared`'s one-time construction first.
//
//  (B) INITIAL-STATE SEEDING -- NOT safely testable against the real
//  singleton: `SettingsWindowController.shared` is built EXACTLY ONCE
//  for the whole test process's lifetime (private init, first access
//  wins), and multiple other test files in this same target already
//  access `.shared` too (SettingsWindowControllerTabIconTests, and any
//  sibling file exercising Settings). By the time THIS file's tests
//  run, `.shared` may already be constructed, with whatever
//  SessionSettings value was live at THAT moment -- there is no
//  reliable way to control the build-time snapshot through the real
//  singleton at all. Per the team-lead handoff's own escape hatch
//  ("if the switches aren't reachable... extract a small helper... and
//  unit-test THAT"), this half is pinned instead against a new, pure,
//  singleton-independent static function proposed below.
//
//  Held-out compile-RED, half (B) only:
//  `SettingsWindowController.sessionToggleInitialState(for:)` does not
//  exist yet. This file fails to compile until the Green phase adds it.
//  Half (A) is runtime-RED (an assertion failure against today's
//  missing `.target`/`.action`), not a compile failure.
//
//  Proposed API (SettingsWindowController.swift addition, no access-level
//  change to any existing private member needed -- selectors are
//  compared via a raw `Selector(_:)` string literal, which reaches an
//  `@objc` method's runtime-visible selector regardless of its Swift
//  access level):
//
//    /// Pure mapping from a Sessions-pane toggle row to the SessionSettings
//    /// value it must seed its initial `.state` from. Extracted as its own
//    /// function because SettingsWindowController.shared's one-shot,
//    /// process-lifetime construction (see this file's own header) makes
//    /// the seeding behavior unobservable through the real singleton in a
//    /// test -- this has none of that lifetime, so a test can set
//    /// SessionSettings._testStore immediately before calling it.
//    static func sessionToggleInitialState(for row: SettingsRow) -> Bool {
//        switch row {
//        case .persistentSessions: return SessionSettings.persistentSessionsEnabled
//        case .historyPersistence: return SessionSettings.historyPersistenceEnabled
//        case .agentResume: return SessionSettings.agentResumeEnabled
//        case .agentResumeAutoExecute: return SessionSettings.agentResumeAutoExecute
//        default: return false
//        }
//    }
//
//  contentView(for:)'s four toggle cases should route each switch's
//  `.state` seed through this function (mirroring
//  smoothScrollingRow()'s existing `UserDefaults`-backed seeding shape),
//  replacing the four stored, never-wired NSSwitch properties with
//  local switches built the same self-contained way
//  smoothScrollingRow()/lspAutoInstallRow()/lspRequireConfirmationRow()
//  already are -- those four stored properties (persistentSessionsSwitch
//  et al.) have no other reference anywhere in the file besides their
//  own contentView(for:) case, so nothing else depends on them staying
//  stored properties.
//
//  Coverage:
//  - (A) each of the four switches has SettingsWindowController.shared
//    as its `.target` and its own expected handler selector as `.action`
//  - (A) exactly 5 switches exist in the Sessions pane's own view
//    subtree, in SettingsRow's declared top-to-bottom order
//    (openSessionBrowserButton is a button, not a switch, so excluded;
//    P4 added a 5th, commandTracking)
//  - (B) sessionToggleInitialState(for:) reads true/false exactly from
//    each row's own backing SessionSettings value
//

import XCTest
import AppKit
@testable import Calyx

@MainActor
final class SettingsWindowControllerSessionsToggleWiringTests: XCTestCase {

    // MARK: - (A) target/action wiring, via the real singleton's built view tree

    private func sessionsPaneView() throws -> NSView {
        let tabViewController = try XCTUnwrap(
            SettingsWindowController.shared.window?.contentViewController as? NSTabViewController,
            "SettingsWindowController's window must host an NSTabViewController as its content"
        )
        let sessionsIndex = try XCTUnwrap(
            SettingsPane.allCases.firstIndex(of: .sessions),
            "SettingsPane must have a .sessions case"
        )
        let tabItem = tabViewController.tabViewItems[sessionsIndex]
        return try XCTUnwrap(tabItem.viewController?.view, "The Sessions tab item must host a real view controller")
    }

    /// Depth-first walk collecting every NSSwitch in `view`'s subview
    /// tree, in subview-array order -- matches the Sessions pane's own
    /// top-to-bottom NSStackView arrangement, since each row was added
    /// via `addArrangedSubview` (which also appends to `.subviews` in
    /// the same call).
    private func collectSwitches(in view: NSView) -> [NSSwitch] {
        var result: [NSSwitch] = []
        for subview in view.subviews {
            if let toggleSwitch = subview as? NSSwitch {
                result.append(toggleSwitch)
            } else {
                result.append(contentsOf: collectSwitches(in: subview))
            }
        }
        return result
    }

    // P4 added a 5th Sessions-pane switch (commandTracking, wired and
    // covered independently by CommandTrackingSettingsToggleWiringTests)
    // -- renamed from ...exactlyFour... and the count/message updated
    // accordingly so this pin stays accurate rather than self-contradicting
    // its own name.
    func test_sessionsToggleSwitches_exactlyFive_inRowOrder() throws {
        let switches = collectSwitches(in: try sessionsPaneView())

        XCTAssertEqual(
            switches.count, 5,
            "The Sessions pane must show exactly 5 switches (persistentSessions/historyPersistence/" +
            "agentResume/agentResumeAutoExecute/commandTracking -- openSessionBrowserButton is a button, " +
            "not a switch). Found \(switches.count)."
        )
    }

    func test_sessionsToggleSwitches_haveTargetAndActionWired() throws {
        let switches = collectSwitches(in: try sessionsPaneView())
        try XCTSkipIf(switches.count != 5, "covered, and already failing, by the count pin above")

        // SettingsRow's own declared order for the Sessions pane, filtered
        // to the four switch-backed rows (SettingsPaneTests.expectedRows
        // pins this exact ordering).
        let expected: [(name: String, selectorName: String)] = [
            ("persistentSessions", "persistentSessionsDidChange:"),
            ("historyPersistence", "historyPersistenceDidChange:"),
            ("agentResume", "agentResumeDidChange:"),
            ("agentResumeAutoExecute", "agentResumeAutoExecuteDidChange:"),
        ]

        for (toggleSwitch, (name, selectorName)) in zip(switches, expected) {
            XCTAssertTrue(
                toggleSwitch.target === SettingsWindowController.shared,
                "\(name)'s switch must have SettingsWindowController.shared as its .target, so toggling it " +
                "actually invokes a handler -- today it is nil, so the click changes no SessionSettings value"
            )
            XCTAssertEqual(
                toggleSwitch.action, Selector((selectorName)),
                "\(name)'s switch .action must be #selector(\(selectorName)) -- today it is nil"
            )
        }
    }

    // MARK: - (B) initial-state seeding, via a proposed singleton-independent seam

    private let settingsSuiteName = "com.calyx.tests.SettingsWindowControllerSessionsToggleWiringTests"

    override func setUp() {
        super.setUp()
        SessionSettings._testUseSuite(named: settingsSuiteName)
    }

    override func tearDown() {
        SessionSettings._testTeardownSuite(named: settingsSuiteName)
        super.tearDown()
    }

    func test_sessionToggleInitialState_readsEachRowsOwnBackingSetting() {
        SessionSettings.persistentSessionsEnabled = true
        SessionSettings.historyPersistenceEnabled = false
        SessionSettings.agentResumeEnabled = true
        SessionSettings.agentResumeAutoExecute = false

        XCTAssertTrue(SettingsWindowController.sessionToggleInitialState(for: .persistentSessions),
                      "persistentSessions's initial state must read SessionSettings.persistentSessionsEnabled")
        XCTAssertFalse(SettingsWindowController.sessionToggleInitialState(for: .historyPersistence),
                       "historyPersistence's initial state must read SessionSettings.historyPersistenceEnabled")
        XCTAssertTrue(SettingsWindowController.sessionToggleInitialState(for: .agentResume),
                      "agentResume's initial state must read SessionSettings.agentResumeEnabled")
        XCTAssertFalse(SettingsWindowController.sessionToggleInitialState(for: .agentResumeAutoExecute),
                       "agentResumeAutoExecute's initial state must read SessionSettings.agentResumeAutoExecute")
    }

    func test_sessionToggleInitialState_flipsWithTheBackingSetting() {
        SessionSettings.persistentSessionsEnabled = false
        XCTAssertFalse(SettingsWindowController.sessionToggleInitialState(for: .persistentSessions))

        SessionSettings.persistentSessionsEnabled = true
        XCTAssertTrue(
            SettingsWindowController.sessionToggleInitialState(for: .persistentSessions),
            "The mapping must read the setting LIVE, not cache a stale value from an earlier read"
        )
    }
}
