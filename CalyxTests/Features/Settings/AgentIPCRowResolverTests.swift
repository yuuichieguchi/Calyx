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
//  never appear while disabling). When idle, the status area renders a
//  one-line summary, with a detail line per non-success axis appended
//  only when at least one axis failed or was skipped.
//

import XCTest
@testable import Calyx

final class AgentIPCRowResolverTests: XCTestCase {

    // MARK: - Fixtures

    private func error(_ description: String) -> NSError {
        NSError(domain: "AgentIPCRowResolverTests", code: 1, userInfo: [NSLocalizedDescriptionKey: description])
    }

    private func allSuccessConfig() -> IPCConfigResult {
        IPCConfigResult(claudeCode: .success, codex: .success, openCode: .success, hermes: .success, grok: .success)
    }

    private func allSuccessHooks() -> AgentHooksResult {
        AgentHooksResult(claudeCode: .success, codex: .success, openCode: .success, grok: .success, pi: .success)
    }

    // MARK: - Switch mirrors the setting, not any server state

    func test_switchState_mirrorsSettingEnabled_true() {
        let state = AgentIPCRowResolver.resolve(settingEnabled: true, inFlight: .none, lastActivation: nil)

        XCTAssertTrue(state.switchOn, "The switch must reflect IPCSettings.enabled == true")
    }

    func test_switchState_mirrorsSettingEnabled_false() {
        let state = AgentIPCRowResolver.resolve(settingEnabled: false, inFlight: .none, lastActivation: nil)

        XCTAssertFalse(state.switchOn, "The switch must reflect IPCSettings.enabled == false")
    }

    // MARK: - In-flight distinguishes enabling from disabling

    func test_inFlightEnabling_and_inFlightDisabling_produceDifferentStatusText() {
        let enabling = AgentIPCRowResolver.resolve(settingEnabled: true, inFlight: .enabling, lastActivation: nil)
        let disabling = AgentIPCRowResolver.resolve(settingEnabled: false, inFlight: .disabling, lastActivation: nil)

        XCTAssertNotEqual(enabling.statusText, disabling.statusText,
                          "enabling and disabling must render distinguishable status text")
        XCTAssertFalse(disabling.statusText.contains("Starting"),
                       "\"Starting…\" must never appear while disabling")
    }

    // MARK: - Controls disabled while in flight

    func test_inFlightEnabling_disablesSwitchAndRefresh() {
        let state = AgentIPCRowResolver.resolve(settingEnabled: true, inFlight: .enabling, lastActivation: nil)

        XCTAssertFalse(state.switchEnabled, "The switch must be disabled while an activation is in flight")
        XCTAssertFalse(state.refreshEnabled, "Refresh must be disabled while an activation is in flight")
    }

    func test_inFlightDisabling_disablesSwitchAndRefresh() {
        let state = AgentIPCRowResolver.resolve(settingEnabled: false, inFlight: .disabling, lastActivation: nil)

        XCTAssertFalse(state.switchEnabled, "The switch must be disabled while a deactivation is in flight")
        XCTAssertFalse(state.refreshEnabled, "Refresh must be disabled while a deactivation is in flight")
    }

    // MARK: - Idle status: enabled, all axes succeed

    func test_idle_enabled_allAxesSucceed_summaryOnlyNoDetailLines() {
        let outcome = IPCActivationOutcome.enabled(
            IPCActivationReport(port: 41830, config: allSuccessConfig(), hooks: allSuccessHooks())
        )

        let state = AgentIPCRowResolver.resolve(settingEnabled: true, inFlight: .none, lastActivation: .enable(outcome))

        XCTAssertEqual(state.statusText, "Running on port 41830 · all agents configured")
        XCTAssertFalse(state.statusText.contains("\n"), "no detail lines when every axis succeeded")
    }

    // MARK: - Idle status: enabled, partial failure/skip

    func test_idle_enabled_partialFailureAndSkip_summaryPlusDetailLinesInAxisOrder() {
        let config = IPCConfigResult(
            claudeCode: .success,
            codex: .failed(error("The ~/.codex/ directory does not exist")),
            openCode: .success,
            hermes: .success,
            grok: .success
        )
        let hooks = AgentHooksResult(
            claudeCode: .success,
            codex: .success,
            openCode: .success,
            grok: .success,
            pi: .skipped(reason: "not installed")
        )
        let outcome = IPCActivationOutcome.enabled(
            IPCActivationReport(port: 41830, config: config, hooks: hooks)
        )

        let state = AgentIPCRowResolver.resolve(settingEnabled: true, inFlight: .none, lastActivation: .enable(outcome))

        XCTAssertEqual(
            state.statusText,
            "Running on port 41830 · 8 of 10 configured\n" +
            "✗ Codex config: The ~/.codex/ directory does not exist\n" +
            "– pi extension: not installed"
        )
    }

    // MARK: - Idle status: enabled, nothing configured

    func test_idle_enabled_allAxesSkipped_summaryReadsNoAgentsConfigured() {
        let config = IPCConfigResult(
            claudeCode: .skipped(reason: "not installed"),
            codex: .skipped(reason: "not installed"),
            openCode: .skipped(reason: "not installed"),
            hermes: .skipped(reason: "not installed"),
            grok: .skipped(reason: "not installed")
        )
        let hooks = AgentHooksResult(
            claudeCode: .skipped(reason: "not installed"),
            codex: .skipped(reason: "not installed"),
            openCode: .skipped(reason: "not installed"),
            grok: .skipped(reason: "not installed"),
            pi: .skipped(reason: "not installed")
        )
        let outcome = IPCActivationOutcome.enabled(
            IPCActivationReport(port: 41830, config: config, hooks: hooks)
        )

        let state = AgentIPCRowResolver.resolve(settingEnabled: true, inFlight: .none, lastActivation: .enable(outcome))

        XCTAssertTrue(state.statusText.hasPrefix("Running on port 41830 · no agents configured\n"))
        XCTAssertEqual(state.statusText.components(separatedBy: "\n").count, 11, "one summary line plus 10 detail lines")
    }

    // MARK: - Idle status: hard enable failures

    func test_idle_serverFailedTokenGeneration_fixedMessageNoDetail() {
        let state = AgentIPCRowResolver.resolve(
            settingEnabled: true, inFlight: .none, lastActivation: .enable(.serverFailed(.tokenGeneration))
        )

        XCTAssertEqual(state.statusText, "Could not start: Failed to generate secure token.")
    }

    func test_idle_serverFailedStart_usesErrorLocalizedDescriptionNoDetail() {
        let state = AgentIPCRowResolver.resolve(
            settingEnabled: true, inFlight: .none,
            lastActivation: .enable(.serverFailed(.start(error("bind() failed: address in use"))))
        )

        XCTAssertEqual(state.statusText, "Could not start: bind() failed: address in use")
    }

    // MARK: - Idle status: disable

    func test_idle_disable_allAxesSucceed_summaryOnly() {
        let report = IPCDeactivationReport(config: allSuccessConfig(), hooks: allSuccessHooks())

        let state = AgentIPCRowResolver.resolve(settingEnabled: false, inFlight: .none, lastActivation: .disable(report))

        XCTAssertEqual(state.statusText, "Disabled")
    }

    func test_idle_disable_partialFailure_summaryPlusFailedAxesOnly_skippedOmitted() {
        let config = IPCConfigResult(
            claudeCode: .failed(error("permission denied")),
            codex: .success,
            openCode: .success,
            hermes: .success,
            grok: .skipped(reason: "not configured")
        )
        let hooks = allSuccessHooks()
        let report = IPCDeactivationReport(config: config, hooks: hooks)

        let state = AgentIPCRowResolver.resolve(settingEnabled: false, inFlight: .none, lastActivation: .disable(report))

        XCTAssertEqual(state.statusText, "Disabled\n✗ Claude Code config: permission denied")
    }
}
