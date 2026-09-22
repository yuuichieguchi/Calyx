// AgentIPCRowResolver.swift
// Calyx
//
// Pure state resolver for the Settings > Agents "AI Agent IPC" row
// (SettingsRow.agentIPC). Never touches IPCSettings, IPCActivationChain,
// or AppKit directly -- every input is a value the caller already
// resolved, so this stays testable without a live server, a real
// UserDefaults suite, or a mounted window.

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
    /// status text renders the last activation report verbatim when
    /// idle.
    struct State: Sendable, Equatable {
        let switchOn: Bool
        let switchEnabled: Bool
        let refreshEnabled: Bool
        let statusText: String
    }

    static func resolve(
        settingEnabled: Bool,
        inFlight: InFlight,
        lastReport: IPCActivationPresenter.AlertContent?
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
            statusText: statusText(inFlight: inFlight, lastReport: lastReport)
        )
    }

    private static func statusText(inFlight: InFlight, lastReport: IPCActivationPresenter.AlertContent?) -> String {
        switch inFlight {
        case .enabling:
            return "Starting…"
        case .disabling:
            return "Stopping…"
        case .none:
            guard let lastReport else { return "" }
            return "\(lastReport.title)\n\(lastReport.message)"
        }
    }
}
