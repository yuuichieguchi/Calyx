// HistoryPersistenceToggleCoordinator.swift
// Calyx
//
// Propagation seam for the Sessions settings "History Persistence"
// toggle. Unlike `persistentSessionsDidChange`/`agentResumeDidChange`
// (SettingsWindowController's existing toggle handlers, which write
// straight to SessionSettings with no controller/model layer beneath
// them), this toggle also needs to reach a daemon that may already be
// running: `ControlMsg::SetHistoryEnabled` is a live, in-memory daemon
// override (see that message's own doc comment), never persisted
// daemon-side, so flipping the setting while a persistent-session
// daemon is already up needs it pushed immediately, not just applied on
// the next daemon start. A free, stateless enum (rather than an
// instance the settings window would need to own) taking its daemon
// client via default-parameter injection, mirroring
// `SessionDaemonClient`'s own initializer DI shape.

import Foundation

@MainActor
enum HistoryPersistenceToggleCoordinator {

    /// Persists `enabled` to `SessionSettings.historyPersistenceEnabled`
    /// and propagates it live to `daemonClient` via
    /// `setHistoryEnabled(_:)`. Called from
    /// `SettingsWindowController.historyPersistenceDidChange(_:)`'s
    /// fire-and-forget `Task`, mirroring every other write-op call site
    /// in this codebase.
    static func historyPersistenceEnabledDidChange(
        _ enabled: Bool,
        daemonClient: SessionDaemonClientProtocol = SessionDaemonClient.shared
    ) async {
        SessionSettings.historyPersistenceEnabled = enabled
        await daemonClient.setHistoryEnabled(enabled)
    }
}
