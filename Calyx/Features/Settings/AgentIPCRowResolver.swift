// AgentIPCRowResolver.swift
// Calyx
//
// Pure state resolver for the Settings > Agents "AI Agent IPC" row
// (SettingsRow.agentIPC). Never touches IPCSettings, IPCActivationChain
// (beyond its `LastActivation` value type), or AppKit directly -- every
// input is a value the caller already resolved, so this stays testable
// without a live server, a real UserDefaults suite, or a mounted window.

import Foundation

enum AgentIPCRowResolver {

    /// Whether an activation is currently running through
    /// IPCActivationChain, and if so which direction -- distinguishes
    /// "Starting…" from a disabling-specific status line. `.none` means
    /// the chain is idle.
    enum InFlight: Sendable, Equatable {
        case none
        case enabling
        case disabling
    }

    /// Everything the row's controls need to render: the switch mirrors
    /// `IPCSettings.enabled` (the SETTING, never the live server), both
    /// controls are disabled while an activation is in flight, and the
    /// status text is a one-line summary of the last activation, with a
    /// detail line per non-success axis appended only when at least one
    /// axis failed or was skipped.
    struct State: Sendable, Equatable {
        let switchOn: Bool
        let switchEnabled: Bool
        let refreshEnabled: Bool
        let statusText: String
    }

    static func resolve(
        settingEnabled: Bool,
        inFlight: InFlight,
        lastActivation: IPCActivationChain.LastActivation?
    ) -> State {
        let controlsEnabled = inFlight == .none
        return State(
            switchOn: settingEnabled,
            switchEnabled: controlsEnabled,
            // Refresh re-runs enable(), so it is only useful (and only
            // offered) while the setting is on -- running it while the
            // switch reads off would start a server the user just turned
            // off.
            refreshEnabled: controlsEnabled && settingEnabled,
            statusText: statusText(inFlight: inFlight, lastActivation: lastActivation)
        )
    }

    private static func statusText(inFlight: InFlight, lastActivation: IPCActivationChain.LastActivation?) -> String {
        switch inFlight {
        case .enabling:
            return "Starting…"
        case .disabling:
            return "Stopping…"
        case .none:
            guard let lastActivation else { return "" }
            return statusText(for: lastActivation)
        }
    }

    private static func statusText(for lastActivation: IPCActivationChain.LastActivation) -> String {
        switch lastActivation {
        case .enable(.enabled(let report)):
            return enabledStatusText(for: report)
        case .enable(.serverFailed(let failure)):
            return "Could not start: \(failure.description)"
        case .disable(let report):
            return disabledStatusText(for: report)
        }
    }

    private static func enabledStatusText(for report: IPCActivationReport) -> String {
        let axes = report.config.axes + report.hooks.axes
        let successCount = axes.filter { if case .success = $0.status { return true } else { return false } }.count
        let summarySuffix: String
        if successCount == axes.count {
            summarySuffix = "all agents configured"
        } else if successCount == 0 {
            summarySuffix = "no agents configured"
        } else {
            summarySuffix = "\(successCount) of \(axes.count) configured"
        }
        let summary = "Running on port \(report.port) · \(summarySuffix)"
        let detailLines = axes.compactMap { axis -> String? in
            switch axis.status {
            case .success:
                return nil
            case .failed(let error):
                return "✗ \(axis.name): \(error.localizedDescription)"
            case .skipped(let reason):
                return "– \(axis.name): \(reason)"
            }
        }
        return ([summary] + detailLines).joined(separator: "\n")
    }

    private static func disabledStatusText(for report: IPCDeactivationReport) -> String {
        let axes = report.config.axes + report.hooks.axes
        let detailLines = axes.compactMap { axis -> String? in
            guard case .failed(let error) = axis.status else { return nil }
            return "✗ \(axis.name): \(error.localizedDescription)"
        }
        return (["Disabled"] + detailLines).joined(separator: "\n")
    }
}
