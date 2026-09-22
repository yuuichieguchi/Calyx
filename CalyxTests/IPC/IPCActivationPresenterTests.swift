//
//  IPCActivationPresenterTests.swift
//  CalyxTests
//
//  IPCActivationPresenter turns an IPCActivationOutcome or
//  IPCDeactivationReport into user-facing alert text. Pure formatting: no
//  file system, no server, no AppKit, so these tests build outcomes/reports
//  directly and check the returned AlertContent.
//

import XCTest
@testable import Calyx

// configResult(...) / hooksResult(...) come from
// IPCActivationResultFixtures.swift, shared with IPCActivationCoordinatorTests.

final class IPCActivationPresenterTests: XCTestCase {

    // MARK: - enableAlert: not wired, no failures

    func test_enableAlert_nothingWired_freshStart_neverClaimsStoppedOrAdvisesManualConfig() {
        // Given: the server started fine but no agent axis, config or hooks,
        // succeeded.
        let outcome = IPCActivationOutcome.enabled(
            IPCActivationReport(port: 41830, wasAlreadyRunning: false, config: configResult(), hooks: hooksResult())
        )

        let alert = IPCActivationPresenter.enableAlert(for: outcome)

        XCTAssertEqual(alert.title, "No Agents Configured",
                       "An agentless machine is not an error: the server is up and serving other clients")
        XCTAssertTrue(alert.message.contains("MCP server running on port 41830."),
                      "The message must state the server is running")
        XCTAssertFalse(alert.message.contains("stopped"),
                       "This path never calls stop(), so the message must never claim the server was running " +
                       "immediately after claiming it had already stopped")
        XCTAssertFalse(alert.message.contains("Configure manually"),
                       "Telling the user to configure a client by hand is dead advice when there is no agent CLI " +
                       "installed to configure")
    }

    func test_enableAlert_nothingWired_alreadyRunning_titleStaysNoAgentsConfiguredAndRunningLineChanges() {
        let outcome = IPCActivationOutcome.enabled(
            IPCActivationReport(port: 41835, wasAlreadyRunning: true, config: configResult(), hooks: hooksResult())
        )

        let alert = IPCActivationPresenter.enableAlert(for: outcome)

        XCTAssertEqual(alert.title, "No Agents Configured",
                       "The not-wired title never varies by wasAlreadyRunning; only the wired titles do")
        XCTAssertTrue(alert.message.contains("MCP server already running on port 41835."),
                      "The running line must still reflect wasAlreadyRunning even on the not-wired path")
    }

    func test_enableAlert_nothingWired_tellsUserToInstallAgentAndRerunAndServerKeepsServingOtherClients() {
        let outcome = IPCActivationOutcome.enabled(
            IPCActivationReport(port: 41830, wasAlreadyRunning: false, config: configResult(), hooks: hooksResult())
        )

        let alert = IPCActivationPresenter.enableAlert(for: outcome)

        XCTAssertTrue(alert.message.contains("Install a supported agent and click Refresh in Settings > Agents."),
                      "The fix for zero wired agents is installing one and re-running, not manual client configuration")
        XCTAssertTrue(
            alert.message.contains(
                "The server keeps serving the LSP proxy, the cockpit and command-log tools, and any MCP client you point at it by hand."
            ),
            "The message must make clear the server is not idle: it still serves every client that does not depend " +
            "on an agent CLI config file. herdr panes are deliberately absent: they reach Calyx over their own " +
            "transport, independent of this server entirely"
        )
    }

    // MARK: - enableAlert: not wired, with failures

    func test_enableAlert_notWiredWithFailures_titleIsAgentSetupFailedAndLeadLineNamesTheProblem() {
        let error = NSError(domain: "test.ipc.presenter", code: 4, userInfo: [NSLocalizedDescriptionKey: "permission denied"])
        let outcome = IPCActivationOutcome.enabled(
            IPCActivationReport(
                port: 41830, wasAlreadyRunning: false,
                config: configResult(claudeCode: .failed(error)), hooks: hooksResult()
            )
        )

        let alert = IPCActivationPresenter.enableAlert(for: outcome)

        XCTAssertEqual(alert.title, "Agent Setup Failed",
                       "An agent CLI that is installed but whose every write failed is distinct from no agent CLI " +
                       "at all: the fix is fixing the error, not installing an agent that is already there")
        XCTAssertTrue(alert.message.contains("No agent CLI could be configured."),
                      "The lead line must say configuration failed, not that no agent CLI was found")
        XCTAssertTrue(alert.message.contains("Claude Code config: error - permission denied"),
                      "The failing axis must still be named, since fixing the error requires knowing which axis broke")
        XCTAssertFalse(alert.message.contains("No supported agent CLI was found to configure."),
                       "The not-installed lead line must never appear alongside a real per-axis error")
        XCTAssertTrue(alert.message.contains("Fix the errors above and click Refresh in Settings > Agents."),
                      "The fix for a failed write is fixing the error, not installing an agent")
    }

    // MARK: - enableAlert: wired, no failures

    func test_enableAlert_wired_freshStart_titleAndMessage() {
        let outcome = IPCActivationOutcome.enabled(
            IPCActivationReport(
                port: 41830, wasAlreadyRunning: false,
                config: configResult(claudeCode: .success), hooks: hooksResult()
            )
        )

        let alert = IPCActivationPresenter.enableAlert(for: outcome)

        XCTAssertEqual(alert.title, "IPC Enabled", "A fresh start with at least one agent wired is the plain success case")
        XCTAssertTrue(alert.message.hasPrefix("MCP server running on port 41830."),
                      "A fresh start must lead with 'running', not 'already running'")
        XCTAssertTrue(alert.message.contains("Restart agent instances to connect."),
                      "The user must be told existing agent instances will not pick up the new config until restarted")
    }

    func test_enableAlert_wired_alreadyRunning_titleAndMessage() {
        let outcome = IPCActivationOutcome.enabled(
            IPCActivationReport(
                port: 41835, wasAlreadyRunning: true,
                config: configResult(claudeCode: .success), hooks: hooksResult()
            )
        )

        let alert = IPCActivationPresenter.enableAlert(for: outcome)

        XCTAssertEqual(alert.title, "IPC Refreshed", "Re-running enable against a live server is a refresh, not a fresh enable")
        XCTAssertTrue(alert.message.contains("MCP server already running on port 41835."),
                      "wasAlreadyRunning must change the first line's wording to 'already running'")
    }

    func test_enableAlert_configAndHooksAxisNamesAreDistinguishable() {
        let outcome = IPCActivationOutcome.enabled(
            IPCActivationReport(
                port: 41830, wasAlreadyRunning: false,
                config: configResult(claudeCode: .success), hooks: hooksResult(claudeCode: .success)
            )
        )

        let alert = IPCActivationPresenter.enableAlert(for: outcome)

        XCTAssertTrue(alert.message.contains("Claude Code config: configured"),
                      "The config-file axis must be labeled distinctly from the hooks axis")
        XCTAssertTrue(alert.message.contains("Claude Code hooks: configured"),
                      "The hooks axis must be labeled distinctly from the config axis so the two are never confused")
    }

    func test_enableAlert_piOnlyReport_showsPiExtensionLineAndIsNotAnError() {
        let outcome = IPCActivationOutcome.enabled(
            IPCActivationReport(
                port: 41830, wasAlreadyRunning: false,
                config: configResult(), hooks: hooksResult(pi: .success)
            )
        )

        let alert = IPCActivationPresenter.enableAlert(for: outcome)

        XCTAssertTrue(alert.message.contains("pi extension: configured"),
                      "pi's only integration axis is the extension file; it must render as a normal status line")
        XCTAssertEqual(alert.title, "IPC Enabled",
                       "A pi-only machine that wired successfully is the plain success case, even though pi has no config axis")
    }

    func test_enableAlert_skipAndFailureLineShapes() {
        let error = NSError(domain: "test.ipc.presenter", code: 1, userInfo: [NSLocalizedDescriptionKey: "permission denied"])
        let outcome = IPCActivationOutcome.enabled(
            IPCActivationReport(
                port: 41830, wasAlreadyRunning: false,
                config: configResult(), hooks: hooksResult(grok: .failed(error))
            )
        )

        let alert = IPCActivationPresenter.enableAlert(for: outcome)

        XCTAssertTrue(alert.message.contains("Codex config: not installed (skipped)"),
                      "A skipped axis must render as '<name>: <reason> (skipped)'")
        XCTAssertTrue(alert.message.contains("Grok hooks: error - permission denied"),
                      "A failed axis must render as '<name>: error - <localizedDescription>'")
    }

    // MARK: - enableAlert: wired, with failures

    func test_enableAlert_wiredAlreadyRunningWithFailedAxis_titleIsRefreshedWithErrors() {
        let error = NSError(domain: "test.ipc.presenter", code: 5, userInfo: [NSLocalizedDescriptionKey: "permission denied"])
        let outcome = IPCActivationOutcome.enabled(
            IPCActivationReport(
                port: 41835, wasAlreadyRunning: true,
                config: configResult(claudeCode: .success, grok: .failed(error)), hooks: hooksResult()
            )
        )

        let alert = IPCActivationPresenter.enableAlert(for: outcome)

        XCTAssertEqual(alert.title, "IPC Refreshed with Errors",
                       "A refresh that wired at least one agent but also failed another axis must flag both facts " +
                       "in the title, not just report a clean refresh")
        XCTAssertTrue(alert.message.contains("Restart agent instances to connect."),
                      "The wired agent still needs a restart to pick up the config")
        XCTAssertTrue(alert.message.contains("Fix the errors above and click Refresh in Settings > Agents."),
                      "The failed axis still needs its own fix-and-rerun instruction alongside the restart instruction")
    }

    // MARK: - enableAlert: hard failures

    func test_enableAlert_tokenGenerationFailed_titleAndMessage() {
        let alert = IPCActivationPresenter.enableAlert(for: .tokenGenerationFailed)

        XCTAssertEqual(
            alert,
            IPCActivationPresenter.AlertContent(title: "IPC Error", message: "Failed to generate secure token."),
            "tokenGenerationFailed's title and message are fully determined by the spec; no server or agent state is involved"
        )
    }

    func test_enableAlert_serverStartFailed_messageIsErrorsLocalizedDescription() {
        let error = NSError(domain: "test.ipc.presenter", code: 2, userInfo: [NSLocalizedDescriptionKey: "port 41830 already in use"])

        let alert = IPCActivationPresenter.enableAlert(for: .serverStartFailed(error))

        XCTAssertEqual(
            alert,
            IPCActivationPresenter.AlertContent(title: "IPC Error", message: "port 41830 already in use"),
            "The message must be exactly the thrown error's localizedDescription, not a wrapped or generic string"
        )
    }

    // MARK: - disableAlert

    func test_disableAlert_titleMessageAndRemovedVerb() {
        let report = IPCDeactivationReport(config: configResult(claudeCode: .success), hooks: hooksResult(pi: .success))

        let alert = IPCActivationPresenter.disableAlert(for: report)

        XCTAssertEqual(alert.title, "IPC Disabled")
        XCTAssertTrue(alert.message.contains("MCP server stopped."),
                      "The disable alert must confirm the server actually stopped")
        XCTAssertTrue(alert.message.contains("Claude Code config: removed"),
                      "Disable must use the verb 'removed', not 'configured', for a successful config removal")
        XCTAssertTrue(alert.message.contains("pi extension: removed"),
                      "Disable must use the verb 'removed' for the hooks axes too")
    }
}
