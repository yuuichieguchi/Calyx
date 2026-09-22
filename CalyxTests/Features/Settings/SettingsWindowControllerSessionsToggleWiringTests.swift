//
//  SettingsWindowControllerSessionsToggleWiringTests.swift
//  CalyxTests
//
//  The defect this file pins: the four Settings > Sessions switches
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
//  singleton at all. Since the switches are not reachable, this half is
//  pinned instead against a pure,
//  singleton-independent static function: the small-helper extraction
//  this codebase uses whenever a real singleton blocks a direct test.
//
//  Half (B) covers
//  `SettingsWindowController.sessionToggleInitialState(for:)`; half (A)
//  covers the switches' own `.target`/`.action` wiring.
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
//  PANE SPLIT (user-directed information-architecture fix, Settings
//  restructure): agentResume/agentResumeAutoExecute/cockpitAutoApprove/
//  commandTracking moved out of the Sessions pane onto a new Agents pane
//  (SettingsPane.agents) -- Sessions now carries only persistentSessions/
//  historyPersistence (plus the non-switch openSessionBrowserButton).
//  This file's (A) half is split accordingly: the original
//  sessionsPaneView()-driven tests now cover just those 2 switches, and
//  new agentsPaneView()-driven tests cover the 4 that moved (commandTracking's
//  own wiring stays independently pinned by
//  CommandTrackingSettingsToggleWiringTests, same division of labor as
//  before the split -- see that file's own header).
//
//  STAGE E (approval-inbox-for-CLI-agents): a 5th Agents-pane switch,
//  agentHookApproval, was added after commandTracking -- its own wiring
//  stays independently pinned by AgentHookApprovalSettingsToggleWiringTests,
//  same division of labor as commandTracking's.
//
//  Coverage:
//  - (A) each Sessions-pane switch (persistentSessions/historyPersistence)
//    and each Agents-pane switch this file covers (agentResume/
//    agentResumeAutoExecute/cockpitAutoApprove) has
//    SettingsWindowController.shared as its `.target` and its own
//    expected handler selector as `.action`
//  - (A) exactly 2 switches exist in the Sessions pane's own view
//    subtree, and exactly 5 in the Agents pane's, both in SettingsRow's
//    declared top-to-bottom order (openSessionBrowserButton is a button,
//    not a switch, so excluded)
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

    /// Same shape as `sessionsPaneView()`, for the Agents pane the 4
    /// moved switches (agentResume/agentResumeAutoExecute/
    /// cockpitAutoApprove/commandTracking) now live on.
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

    // Pane split (see file header): agentResume/agentResumeAutoExecute/
    // cockpitAutoApprove/commandTracking moved to the Agents pane, so the
    // Sessions pane now shows only persistentSessions/historyPersistence.
    func test_sessionsToggleSwitches_exactlyTwo_inRowOrder() throws {
        let switches = collectSwitches(in: try sessionsPaneView())

        XCTAssertEqual(
            switches.count, 2,
            "The Sessions pane must show exactly 2 switches (persistentSessions/historyPersistence -- " +
            "openSessionBrowserButton is a button, not a switch; agentResume/agentResumeAutoExecute/" +
            "cockpitAutoApprove/commandTracking moved to the Agents pane). Found \(switches.count)."
        )
    }

    func test_sessionsToggleSwitches_haveTargetAndActionWired() throws {
        let switches = collectSwitches(in: try sessionsPaneView())
        try XCTSkipIf(switches.count != 2, "covered, and already failing, by the count pin above")

        // SettingsRow's own declared order for the Sessions pane, filtered
        // to the switch-backed rows (SettingsPaneTests.expectedRows pins
        // this exact ordering).
        let expected: [(name: String, selectorName: String)] = [
            ("persistentSessions", "persistentSessionsDidChange:"),
            ("historyPersistence", "historyPersistenceDidChange:"),
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

    // The 6 switches that live on the Agents pane. agentIPC, commandTracking
    // and agentHookApproval are intentionally NOT included in the wiring
    // zip below -- they're already independently covered by
    // test_agentIPCToggleSwitch_hasTargetAndActionWired below,
    // CommandTrackingSettingsToggleWiringTests
    // .test_commandTrackingSwitch_existsWithTargetAndActionWired and
    // AgentHookApprovalSettingsToggleWiringTests
    // .test_agentHookApprovalSwitch_existsWithTargetAndActionWired
    // (all identifier-based lookups, position-independent), same
    // division of labor this file used for the Sessions pane before the
    // split. Renamed from ...exactlyFive... (agentIPC added a 6th).
    func test_agentsToggleSwitches_exactlySix_inRowOrder() throws {
        let switches = collectSwitches(in: try agentsPaneView())

        XCTAssertEqual(
            switches.count, 6,
            "The Agents pane must show exactly 6 switches (agentIPC/agentResume/agentResumeAutoExecute/" +
            "cockpitAutoApprove/commandTracking/agentHookApproval). Found \(switches.count)."
        )
    }

    func test_agentIPCToggleSwitch_hasTargetAndActionWired() throws {
        let switches = collectSwitches(in: try agentsPaneView())
        try XCTSkipIf(switches.count != 6, "covered, and already failing, by the count pin above")

        let agentIPCSwitch = switches[0]
        XCTAssertTrue(
            agentIPCSwitch.target === SettingsWindowController.shared,
            "agentIPC's switch must have SettingsWindowController.shared as its .target, so toggling it " +
            "actually invokes a handler"
        )
        XCTAssertEqual(
            agentIPCSwitch.action, Selector(("agentIPCSwitchDidChange:")),
            "agentIPC's switch .action must be #selector(agentIPCSwitchDidChange:)"
        )
    }

    func test_agentsToggleSwitches_haveTargetAndActionWired() throws {
        let switches = collectSwitches(in: try agentsPaneView())
        try XCTSkipIf(switches.count != 6, "covered, and already failing, by the count pin above")

        // SettingsRow's own declared order for the Agents pane, filtered
        // to the switch-backed rows (SettingsPaneTests.expectedRows pins
        // this exact ordering). agentIPC (index 0) is skipped here --
        // its own wiring is covered by
        // test_agentIPCToggleSwitch_hasTargetAndActionWired above --
        // and only the next 3 are asserted: commandTracking's and
        // agentHookApproval's wiring are each covered by their own
        // dedicated files instead (see comment above).
        let expected: [(name: String, selectorName: String)] = [
            ("agentResume", "agentResumeDidChange:"),
            ("agentResumeAutoExecute", "agentResumeAutoExecuteDidChange:"),
            ("cockpitAutoApprove", "cockpitAutoApproveDidChange:"),
        ]

        for (toggleSwitch, (name, selectorName)) in zip(switches.dropFirst(), expected) {
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
