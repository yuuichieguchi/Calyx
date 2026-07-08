// SessionSettings.swift
// Calyx
//
// UserDefaults-backed store for the persistent-sessions feature toggle.
// Unlike `LSPSettings` (which reads/writes `UserDefaults.standard`
// directly with no test seam), this type routes every read/write
// through `store`, backed by the shared `SettingsStore` resolution
// (`_testStore` — an in-process unit-test seam, swapped to a
// per-test-unique suite via `_testUseSuite(named:)` — then
// `uiTestSuite` — an env-var-driven seam for a SEPARATE `--uitesting`
// app process — then `.standard` in production; see
// `Calyx/Helpers/SettingsStore.swift`'s header comment for the full
// rationale behind each layer). Defaults OFF: when `false`,
// `SessionSpawnPlanner` must always return `.passthrough` for *new*
// surfaces — a session already tracked in `SessionSurfaceMap` (an
// existing persistent pane) is unaffected by this toggle and keeps
// being managed by `SessionReconnectCoordinator` regardless (see that
// type's own gate, which checks `SessionSurfaceMap` presence rather
// than this toggle).

import Foundation

struct SessionSettings: Sendable {

    static let persistentSessionsEnabledKey = "calyx.session.persistentSessionsEnabled"
    static let agentResumeEnabledKey = "calyx.session.agentResumeEnabled"
    static let agentResumeAutoExecuteKey = "calyx.session.agentResumeAutoExecute"
    static let historyPersistenceEnabledKey = "calyx.session.historyPersistenceEnabled"

    private static let settingsStore = SettingsStore()

    /// Test isolation hook: production reads/writes `UserDefaults
    /// .standard`; tests call `_testUseSuite(named:)` with a
    /// per-test-unique suite name so assertions never read or write the
    /// user's real defaults domain, and `_testTeardownSuite(named:)`
    /// restores production behavior afterward.
    static func _testUseSuite(named name: String) {
        settingsStore.testUseSuite(named: name)
    }

    static func _testTeardownSuite(named name: String) {
        settingsStore.testTeardownSuite(named: name)
    }

    private static var store: UserDefaults {
        settingsStore.store
    }

    /// Master switch: when `false` (the documented default),
    /// `SessionSpawnPlanner` must always return `.passthrough` for new
    /// surfaces. Does not affect `SessionReconnectCoordinator`, which
    /// gates on `SessionSurfaceMap` presence instead (see this file's
    /// header comment).
    static var persistentSessionsEnabled: Bool {
        get { store.bool(forKey: persistentSessionsEnabledKey) }
        set { store.set(newValue, forKey: persistentSessionsEnabledKey) }
    }

    /// Whether a reattached persistent-session pane offers to resume
    /// the agent CLI conversation that was running inside it (via
    /// `SessionResumePlanner`, keyed by the meta
    /// `AgentSessionMetaBridge` recorded). Defaults OFF, same
    /// rationale as `persistentSessionsEnabled` — resuming an agent
    /// conversation injects synthesized input into the pane, which
    /// should be opt-in.
    static var agentResumeEnabled: Bool {
        get { store.bool(forKey: agentResumeEnabledKey) }
        set { store.set(newValue, forKey: agentResumeEnabledKey) }
    }

    /// When `agentResumeEnabled` is on: `false` (the default)
    /// "proposes" the resume command — typed into the pane with no
    /// trailing newline, so the user presses Return themselves — while
    /// `true` submits it automatically (trailing newline). See
    /// `SessionResumePlanner.initialInput(agentKind:agentSessionID:autoExecute:)`.
    static var agentResumeAutoExecute: Bool {
        get { store.bool(forKey: agentResumeAutoExecuteKey) }
        set { store.set(newValue, forKey: agentResumeAutoExecuteKey) }
    }

    /// Opt-in switch for on-disk history persistence
    /// (`ControlMsg::SetHistoryEnabled`'s daemon-wide default). Defaults
    /// OFF, same rationale as `persistentSessionsEnabled` and
    /// `agentResumeEnabled` -- capturing pane history to disk should
    /// never start without the user turning it on. Setting this does not
    /// itself reach a running daemon; see
    /// `HistoryPersistenceToggleCoordinator` (propagates a live toggle)
    /// and `AppDelegate.reassertHistoryPersistenceIfNeeded()` (reasserts
    /// it once per launch).
    static var historyPersistenceEnabled: Bool {
        get { store.bool(forKey: historyPersistenceEnabledKey) }
        set { store.set(newValue, forKey: historyPersistenceEnabledKey) }
    }

    static func resetToDefaults() {
        store.removeObject(forKey: persistentSessionsEnabledKey)
        store.removeObject(forKey: agentResumeEnabledKey)
        store.removeObject(forKey: agentResumeAutoExecuteKey)
        store.removeObject(forKey: historyPersistenceEnabledKey)
    }
}
