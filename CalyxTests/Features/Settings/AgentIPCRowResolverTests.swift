//
//  AgentIPCRowResolverTests.swift
//  CalyxTests
//
//  Covers AgentIPCRowResolver, the pure state resolver behind the new
//  Settings > Agents "AI Agent IPC" row (SettingsRow.agentIPC, L2.7).
//  The switch mirrors the SETTING (IPCSettings.enabled), never the live
//  server -- a server that failed to start must not flip the switch
//  back off underneath a user who left it on. While an activation is in
//  flight, both the switch and the Refresh button are disabled, and the
//  status text distinguishes enabling from disabling ("Starting..." must
//  never appear while disabling). When idle, the status area renders the
//  last activation report's message verbatim (IPCActivationPresenter's
//  own text, not a re-derived summary).
//

import XCTest
@testable import Calyx

final class AgentIPCRowResolverTests: XCTestCase {

    // MARK: - Switch mirrors the setting, not any server state

    func test_switchState_mirrorsSettingEnabled_true() {
        let state = AgentIPCRowResolver.resolve(settingEnabled: true, inFlight: .none, lastReport: nil)

        XCTAssertTrue(state.switchOn, "The switch must reflect IPCSettings.enabled == true")
    }

    func test_switchState_mirrorsSettingEnabled_false() {
        let state = AgentIPCRowResolver.resolve(settingEnabled: false, inFlight: .none, lastReport: nil)

        XCTAssertFalse(state.switchOn, "The switch must reflect IPCSettings.enabled == false")
    }

    // MARK: - In-flight distinguishes enabling from disabling

    func test_inFlightEnabling_and_inFlightDisabling_produceDifferentStatusText() {
        let enabling = AgentIPCRowResolver.resolve(settingEnabled: true, inFlight: .enabling, lastReport: nil)
        let disabling = AgentIPCRowResolver.resolve(settingEnabled: false, inFlight: .disabling, lastReport: nil)

        XCTAssertNotEqual(enabling.statusText, disabling.statusText,
                          "enabling and disabling must render distinguishable status text")
        XCTAssertFalse(disabling.statusText.contains("Starting"),
                       "\"Starting…\" must never appear while disabling")
    }

    // MARK: - Controls disabled while in flight

    func test_inFlightEnabling_disablesSwitchAndRefresh() {
        let state = AgentIPCRowResolver.resolve(settingEnabled: true, inFlight: .enabling, lastReport: nil)

        XCTAssertFalse(state.switchEnabled, "The switch must be disabled while an activation is in flight")
        XCTAssertFalse(state.refreshEnabled, "Refresh must be disabled while an activation is in flight")
    }

    func test_inFlightDisabling_disablesSwitchAndRefresh() {
        let state = AgentIPCRowResolver.resolve(settingEnabled: false, inFlight: .disabling, lastReport: nil)

        XCTAssertFalse(state.switchEnabled, "The switch must be disabled while a deactivation is in flight")
        XCTAssertFalse(state.refreshEnabled, "Refresh must be disabled while a deactivation is in flight")
    }

    // MARK: - Idle status renders the last report verbatim

    func test_idle_withLastReport_rendersReportMessageVerbatim() {
        let report = IPCActivationPresenter.AlertContent(
            title: "AI Agent IPC Enabled",
            message: "MCP server running on port 41830.\nClaude Code: configured"
        )

        let state = AgentIPCRowResolver.resolve(settingEnabled: true, inFlight: .none, lastReport: report)

        XCTAssertTrue(state.statusText.contains(report.message),
                      "The status area must render the last activation report's message verbatim -- reusing " +
                      "IPCActivationPresenter's existing text, not a re-derived summary")
    }
}
