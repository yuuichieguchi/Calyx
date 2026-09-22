// IPCActivationPresenter.swift
// Calyx
//
// Turns an IPCActivationOutcome / IPCDeactivationReport into the alert
// title and message CalyxWindowController shows the user. Pure
// formatting: no file system, no server, no AppKit, so every branch is
// reachable by constructing a value and reading the returned text back.

import Foundation

enum IPCActivationPresenter {
    struct AlertContent: Sendable, Equatable {
        let title: String
        let message: String
    }

    static func enableAlert(for outcome: IPCActivationOutcome) -> AlertContent {
        switch outcome {
        case .enabled(let report):
            return enabledAlert(for: report)
        case .tokenGenerationFailed:
            return AlertContent(title: "IPC Error", message: "Failed to generate secure token.")
        case .serverStartFailed(let error):
            return AlertContent(title: "IPC Error", message: error.localizedDescription)
        }
    }

    static func disableAlert(for report: IPCDeactivationReport) -> AlertContent {
        let message = [
            "MCP server stopped.",
            statusMessage(for: report.config.axes, verb: "removed"),
            statusMessage(for: report.hooks.axes, verb: "removed"),
        ].joined(separator: "\n")
        return AlertContent(title: "IPC Disabled", message: message)
    }

    // MARK: - Private: enabled

    /// Every client that keeps working while an agent CLI config write
    /// or hooks install fails: the LSP proxy, cockpit and command-log
    /// tools, and any MCP client pointed at this server by hand. herdr
    /// panes are deliberately absent -- they reach Calyx over their own
    /// transport, independent of this server, so this server stopping
    /// or serving nobody says nothing about herdr.
    private static let serverKeepsServingLine =
        "The server keeps serving the LSP proxy, the cockpit and command-log tools, and any MCP client you point at it by hand."

    /// Branches on two independent facts: whether any agent CLI is
    /// actually reachable (`anyAgentWired`) and whether either result
    /// contributed a failure line (`hasFailures`). Conflating the two
    /// produces a self-contradicting alert -- an installed agent whose
    /// only write failed would otherwise read as "no supported agent CLI
    /// was found" two lines above the error naming that exact agent.
    private static func enabledAlert(for report: IPCActivationReport) -> AlertContent {
        let runningLine = report.wasAlreadyRunning
            ? "MCP server already running on port \(report.port)."
            : "MCP server running on port \(report.port)."
        let configLines = statusMessage(for: report.config.axes, verb: "configured")
        let hooksLines = statusMessage(for: report.hooks.axes, verb: "configured")
        let hasFailures = !report.config.issueMessages.isEmpty || !report.hooks.issueMessages.isEmpty

        switch (report.anyAgentWired, hasFailures) {
        case (true, false):
            let title = report.wasAlreadyRunning ? "IPC Refreshed" : "IPC Enabled"
            let message = [runningLine, configLines, hooksLines, "Restart agent instances to connect."]
                .joined(separator: "\n")
            return AlertContent(title: title, message: message)

        case (true, true):
            let title = (report.wasAlreadyRunning ? "IPC Refreshed" : "IPC Enabled") + " with Errors"
            let message = [
                runningLine, configLines, hooksLines,
                "Restart agent instances to connect.",
                "Fix the errors above and click Refresh in Settings > Agents.",
            ].joined(separator: "\n")
            return AlertContent(title: title, message: message)

        case (false, true):
            // At least one agent CLI is installed, but every config
            // write and hooks install attempted for it failed. Distinct
            // from the "nothing installed" case below: the fix here is
            // fixing the error, not installing an agent that is already
            // present.
            let message = [
                runningLine,
                "No agent CLI could be configured.",
                configLines, hooksLines,
                serverKeepsServingLine,
                "Fix the errors above and click Refresh in Settings > Agents.",
            ].joined(separator: "\n")
            return AlertContent(title: "Agent Setup Failed", message: message)

        case (false, false):
            // Not an error: the server started (or was already running)
            // and keeps serving every client that doesn't depend on an
            // agent CLI config file. Telling the user to configure a
            // client by hand would be dead advice, since there is no
            // agent CLI installed to configure.
            let message = [
                runningLine,
                "No supported agent CLI was found to configure.",
                configLines, hooksLines,
                serverKeepsServingLine,
                "Install a supported agent and click Refresh in Settings > Agents.",
            ].joined(separator: "\n")
            return AlertContent(title: "No Agents Configured", message: message)
        }
    }

    // MARK: - Private: status lines

    /// Formats one axis's `ConfigStatus` as a single line: `name: verb`
    /// on success, `name: reason (skipped)` on skip, `name: error -
    /// localizedDescription` on failure.
    private static func statusLine(_ status: ConfigStatus, name: String, verb: String) -> String {
        switch status {
        case .success:
            return "\(name): \(verb)"
        case .skipped(let reason):
            return "\(name): \(reason) (skipped)"
        case .failed(let error):
            return "\(name): error - \(error.localizedDescription)"
        }
    }

    /// Renders every axis in `axes` as one line each, joined in print
    /// order. Generic over `IPCConfigResult.axes` and
    /// `AgentHooksResult.axes` alike; holds no agent name of its own.
    private static func statusMessage(for axes: [(name: String, status: ConfigStatus)], verb: String) -> String {
        axes.map { statusLine($0.status, name: $0.name, verb: verb) }.joined(separator: "\n")
    }
}
