//
//  AgentSidebarGateTests.swift
//  CalyxTests
//
//  Tests (herdr TRACK B): AgentSidebarGate.decide, the
//  pure decision behind AgentStatusView.content's placeholder branch.
//  Mirrors HerdrChildExitedPolicyTests' shape: a plain (non-@MainActor)
//  XCTestCase directly calling a pure, already-computed-discriminator
//  static function.
//
//  Coverage: the full 4-row truth table for
//  decide(isServerRunning:hasExternal:). Rows must show when EITHER
//  input is true; the "AI Agent IPC is disabled" placeholder is shown
//  only when BOTH are false -- an external (herdr) row must remain
//  visible even while Calyx's own IPC server is stopped, since it
//  doesn't depend on it.
//
//  Also covers showsMonitoringDisabledBanner(isServerRunning:hasExternal:),
//  decide's companion: whether the rows branch should ALSO show an
//  explanatory "Calyx's own agent monitoring is disabled" notice. Each
//  test below pairs BOTH functions for one row of the task's truth
//  table (neither / IPC only / herdr only / both), so each test reads
//  as one full row rather than an isolated fact:
//    neither      -> placeholder (notice does not apply)
//    IPC only     -> rows, no notice
//    herdr only   -> rows WITH notice
//    both         -> rows, no notice
//

import XCTest
@testable import Calyx

final class AgentSidebarGateTests: XCTestCase {

    func test_decide_serverRunning_noExternal_showsRows() {
        XCTAssertTrue(AgentSidebarGate.decide(isServerRunning: true, hasExternal: false))
    }

    func test_decide_serverRunning_hasExternal_showsRows() {
        XCTAssertTrue(AgentSidebarGate.decide(isServerRunning: true, hasExternal: true))
    }

    func test_decide_serverStopped_hasExternal_stillShowsRows() {
        // The case this change adds: external (herdr) rows must stay
        // visible even while Calyx's own IPC server is off.
        XCTAssertTrue(
            AgentSidebarGate.decide(isServerRunning: false, hasExternal: true),
            "External entries must keep the sidebar showing rows even while the IPC server is stopped"
        )
    }

    func test_decide_serverStopped_noExternal_showsPlaceholder() {
        XCTAssertFalse(AgentSidebarGate.decide(isServerRunning: false, hasExternal: false))
    }

    // MARK: - showsMonitoringDisabledBanner: full truth table, paired with decide()

    func test_neitherRunningNorExternal_showsPlaceholder_bannerDoesNotApply() {
        XCTAssertFalse(
            AgentSidebarGate.decide(isServerRunning: false, hasExternal: false),
            "neither input true -> placeholder"
        )
        XCTAssertFalse(
            AgentSidebarGate.showsMonitoringDisabledBanner(isServerRunning: false, hasExternal: false, serverIssues: []),
            "no rows are shown at all in this case, so the banner must not be shown either"
        )
    }

    func test_ipcOnly_showsRows_withNoBanner() {
        XCTAssertTrue(
            AgentSidebarGate.decide(isServerRunning: true, hasExternal: false),
            "Calyx's own IPC server running -> rows"
        )
        XCTAssertFalse(
            AgentSidebarGate.showsMonitoringDisabledBanner(isServerRunning: true, hasExternal: false, serverIssues: []),
            "Calyx's own agent monitoring IS running, so there is nothing to warn about"
        )
    }

    func test_herdrOnly_showsRows_withMonitoringDisabledBanner() {
        // The case this change adds: herdr rows are visible while
        // Calyx's own IPC server is off, but that must not be silent --
        // a user's own locally-run agents (which DO depend on Calyx's
        // own IPC server) would otherwise be missing from the list with
        // no explanation. See AgentSidebarGate.showsMonitoringDisabledBanner's
        // own doc comment.
        XCTAssertTrue(
            AgentSidebarGate.decide(isServerRunning: false, hasExternal: true),
            "herdr rows alone -> rows"
        )
        XCTAssertTrue(
            AgentSidebarGate.showsMonitoringDisabledBanner(isServerRunning: false, hasExternal: true, serverIssues: []),
            "Calyx's own agent monitoring is OFF while rows are shown from herdr alone -- this must be flagged, " +
            "not silent"
        )
    }

    func test_both_showsRows_withNoBanner() {
        XCTAssertTrue(
            AgentSidebarGate.decide(isServerRunning: true, hasExternal: true),
            "both sources -> rows"
        )
        XCTAssertFalse(
            AgentSidebarGate.showsMonitoringDisabledBanner(isServerRunning: true, hasExternal: true, serverIssues: []),
            "Calyx's own agent monitoring IS running (in addition to herdr), so there is nothing to warn about"
        )
    }

    func test_herdrOnly_withServerIssues_suppressesMonitoringDisabledBanner() {
        // A herdr row is present AND Calyx's own server failed to start:
        // the server-issues banner (rendered from serverIssues) already
        // explains why, so the generic "disabled, open Settings" notice
        // must not also render -- that notice implies the setting is
        // OFF, contradicting a switch that reads ON while a start
        // attempt merely failed.
        XCTAssertFalse(
            AgentSidebarGate.showsMonitoringDisabledBanner(isServerRunning: false, hasExternal: true, serverIssues: ["Failed to start the local server."]),
            "A standing server-start failure must suppress the disabled-monitoring notice, not stack with it"
        )
    }

    // MARK: - showsServerIssuesBanner: applies whenever the server is down, rows or not

    func test_showsServerIssuesBanner_serverNotRunning_withIssues_showsBanner() {
        XCTAssertTrue(
            AgentSidebarGate.showsServerIssuesBanner(isServerRunning: false, serverIssues: ["Failed to generate secure token."]),
            "A server-start failure must surface as the server-issues banner whenever the server isn't running"
        )
    }

    func test_showsServerIssuesBanner_serverNotRunning_noIssues_doesNotShow() {
        XCTAssertFalse(
            AgentSidebarGate.showsServerIssuesBanner(isServerRunning: false, serverIssues: []),
            "No server issues means the ordinary disabled placeholder still applies"
        )
    }

    func test_showsServerIssuesBanner_serverRunning_withIssues_doesNotApply() {
        XCTAssertFalse(
            AgentSidebarGate.showsServerIssuesBanner(isServerRunning: true, serverIssues: ["stale issue"]),
            "The server-issues banner must not appear once the server is actually running"
        )
    }
}
