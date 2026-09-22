//
//  SettingsRowAgentIPCTests.swift
//  CalyxTests
//
//  Covers SettingsRow.agentIPC (L2.7 / L2.6's "AI Agent IPC" master
//  switch row) and its three new accessibility identifiers.
//
//  agentIPC must be FIRST among the Agents-pane rows: the three existing
//  Agents rows (agentResume, cockpitAutoApprove/agentHookApproval,
//  commandTracking) all depend on this master switch. Per P1 (the
//  verified fact overriding the plan's original "index 0 is the one
//  place a divider is skipped" claim), SettingsWindowController's
//  divider rule is actually two conditions ANDed together --
//  sectionHeading(for:) non-nil AND index > 0 within the pane-filtered
//  array -- so agentIPC landing at index 0 gets no divider regardless of
//  whether it has a heading, and agentResume landing at index 1 (with
//  its own heading) gets one. That divider rendering itself lives in a
//  private method and isn't asserted here; this file only pins the
//  ordering fact (.agentIPC is index 0) that rule depends on.
//
//  The new accessibility identifiers exist in AccessibilityID.Settings.
//

import XCTest
@testable import Calyx

final class SettingsRowAgentIPCTests: XCTestCase {

    // MARK: - Row existence, pane, and ordering

    func test_agentIPC_paneIsAgents() {
        XCTAssertEqual(SettingsRow.agentIPC.pane, .agents,
                       "SettingsRow.agentIPC must belong to the Agents pane")
    }

    func test_agentIPC_isFirstAmongAgentsPaneRows() {
        let agentsRows = SettingsRow.allCases.filter { $0.pane == .agents }

        XCTAssertEqual(agentsRows.first, .agentIPC,
                       "agentIPC must be the first row in the Agents pane -- the three existing rows " +
                       "(agentResume, cockpitAutoApprove/agentHookApproval, commandTracking) all depend on " +
                       "this master switch")
    }

    // MARK: - Accessibility identifiers

    func test_accessibilityIdentifiers_matchSpecdLiterals() {
        XCTAssertEqual(AccessibilityID.Settings.agentIPCSwitch, "calyx.settings.agents.agentIPCSwitch")
        XCTAssertEqual(AccessibilityID.Settings.agentIPCRefreshButton, "calyx.settings.agents.agentIPCRefreshButton")
        XCTAssertEqual(AccessibilityID.Settings.agentIPCStatusLabel, "calyx.settings.agents.agentIPCStatusLabel")
    }
}
