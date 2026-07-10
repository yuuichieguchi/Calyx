//
//  AgentHookApprovalSettingsToggleWiringTests.swift
//  CalyxTests
//
//  TDD Red Phase for Stage E of the approval-inbox-for-CLI-agents
//  feature: a new Agents-pane toggle for
//  CockpitSettings.agentHookApprovalEnabled -- gates whether
//  CalyxMCPServer's POST /approval-request endpoint (a CLI agent's
//  PreToolUse hook call) ever submits a request to the approval inbox
//  at all (see CockpitSettings.swift's own doc comment). Mirrors
//  CommandTrackingSettingsToggleWiringTests' three-part split
//  (identifier-based target/action wiring against the real
//  SettingsWindowController.shared singleton's Agents pane, a
//  singleton-independent pure-function initial-state-seeding check, and
//  a direct real-selector invocation proving the handler's side effect)
//  -- simpler than that file's own part (C), since this handler's only
//  side effect is a straight CockpitSettings write, not a shell
//  integration install/env mutation.
//
//  Held-out compile-RED (see SessionCommandSynthesizerRemoteAttachTests'
//  header for this codebase's convention): SettingsRow.agentHookApproval,
//  AccessibilityID.Settings.agentHookApprovalSwitch, and the
//  #selector(agentHookApprovalDidChange:) target do not exist yet. This
//  file fails to compile until the Green phase adds all three.
//
//  Proposed API:
//
//    SettingsRow.swift: add `case agentHookApproval` (after
//    `commandTracking`), routed to `.pane == .agents`.
//
//    AccessibilityID.swift, enum Settings: add
//    `static let agentHookApprovalSwitch = "calyx.settings.sessions.agentHookApprovalSwitch"`
//    -- same "calyx.settings.sessions.*" prefix as cockpitAutoApproveSwitch,
//    even though both rows live on the Agents pane today (see that
//    constant's own composition for why the historical "sessions"
//    segment was kept rather than renamed).
//
//    SettingsWindowController.swift:
//    - contentView(for: .agentHookApproval) returns a new
//      agentHookApprovalRow(): local NSSwitch, identifier
//      AccessibilityID.Settings.agentHookApprovalSwitch, state seeded
//      from Self.sessionToggleInitialState(for: .agentHookApproval),
//      target self, action #selector(agentHookApprovalDidChange(_:)).
//    - sessionToggleInitialState(for:) gets a new
//      `case .agentHookApproval: return CockpitSettings.agentHookApprovalEnabled` arm.
//    - a new `@objc private func agentHookApprovalDidChange(_ sender: NSSwitch)`
//      sets `CockpitSettings.agentHookApprovalEnabled = (sender.state == .on)`.
//
//  Coverage:
//  - (A) the switch exists in the Agents pane, located by its own
//    accessibility identifier, with SettingsWindowController.shared as
//    its `.target` and #selector(agentHookApprovalDidChange:) as its
//    `.action`
//  - (B) sessionToggleInitialState(for: .agentHookApproval) reads
//    CockpitSettings.agentHookApprovalEnabled LIVE, not a cached snapshot
//  - (C) invoking the real switch's real action writes
//    CockpitSettings.agentHookApprovalEnabled, both ON and OFF
//

import XCTest
import AppKit
@testable import Calyx

@MainActor
final class AgentHookApprovalSettingsToggleWiringTests: XCTestCase {

    private let settingsSuiteName = "com.calyx.tests.AgentHookApprovalSettingsToggleWiringTests"

    override func setUp() {
        super.setUp()
        CockpitSettings._testUseSuite(named: settingsSuiteName)
    }

    override func tearDown() {
        CockpitSettings._testTeardownSuite(named: settingsSuiteName)
        super.tearDown()
    }

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
    /// located by identifier rather than position, same rationale as
    /// CommandTrackingSettingsToggleWiringTests' own findSwitch(identifier:in:).
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

    func test_agentHookApprovalSwitch_existsWithTargetAndActionWired() throws {
        let toggleSwitch = try XCTUnwrap(
            findSwitch(identifier: AccessibilityID.Settings.agentHookApprovalSwitch, in: try agentsPaneView()),
            "the Agents pane must contain exactly one switch with the agentHookApprovalSwitch accessibility identifier"
        )

        XCTAssertTrue(
            toggleSwitch.target === SettingsWindowController.shared,
            "the agent-hook approval switch must have SettingsWindowController.shared as its .target"
        )
        XCTAssertEqual(
            toggleSwitch.action, Selector(("agentHookApprovalDidChange:")),
            "the agent-hook approval switch's .action must be #selector(agentHookApprovalDidChange:)"
        )
    }

    // MARK: - (B) initial-state seeding, via the existing singleton-independent seam

    func test_sessionToggleInitialState_agentHookApproval_readsCockpitSettings() {
        CockpitSettings.agentHookApprovalEnabled = false
        XCTAssertFalse(
            SettingsWindowController.sessionToggleInitialState(for: .agentHookApproval),
            "agentHookApproval's initial state must read CockpitSettings.agentHookApprovalEnabled"
        )

        CockpitSettings.agentHookApprovalEnabled = true
        XCTAssertTrue(
            SettingsWindowController.sessionToggleInitialState(for: .agentHookApproval),
            "the mapping must read the setting LIVE, not cache a stale value from an earlier read"
        )
    }

    // MARK: - (C) agentHookApprovalDidChange(_:) writes CockpitSettings.agentHookApprovalEnabled
    //
    // Review-finding-style side-effect check (mirrors
    // CommandTrackingSettingsToggleWiringTests' own part (C)): (A) above
    // only pins that .target/.action are wired -- it never actually
    // invokes the handler, so a handler that silently did nothing (or
    // wrote the wrong setting) would still pass it. This drives the REAL
    // switch found by (A)'s own lookup through its real .action.

    func test_agentHookApprovalDidChange_writesCockpitSettings_onAndOff() throws {
        let toggleSwitch = try XCTUnwrap(
            findSwitch(identifier: AccessibilityID.Settings.agentHookApprovalSwitch, in: try agentsPaneView())
        )

        toggleSwitch.state = .on
        _ = SettingsWindowController.shared.perform(Selector(("agentHookApprovalDidChange:")), with: toggleSwitch)
        XCTAssertTrue(CockpitSettings.agentHookApprovalEnabled,
                     "flipping the switch ON must write CockpitSettings.agentHookApprovalEnabled = true")

        toggleSwitch.state = .off
        _ = SettingsWindowController.shared.perform(Selector(("agentHookApprovalDidChange:")), with: toggleSwitch)
        XCTAssertFalse(CockpitSettings.agentHookApprovalEnabled,
                      "flipping the switch OFF must write CockpitSettings.agentHookApprovalEnabled = false")
    }
}
