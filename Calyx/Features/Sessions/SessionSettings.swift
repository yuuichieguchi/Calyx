// SessionSettings.swift
// Calyx
//
// UserDefaults-backed store for the persistent-sessions feature toggle.
// Unlike `LSPSettings` (which reads/writes `UserDefaults.standard`
// directly with no test seam), this type routes every read/write
// through `_testStore` — `nil` in production (falling back to
// `.standard`), swapped to a per-test-unique suite via
// `_testUseSuite(named:)` so assertions never touch the user's real
// defaults domain. Defaults OFF: when `false`, `SessionSpawnPlanner`
// must always return `.passthrough` for *new* surfaces — a session
// already tracked in `SessionSurfaceMap` (an existing persistent pane)
// is unaffected by this toggle and keeps being managed by
// `SessionReconnectCoordinator` regardless (see that type's own gate,
// which checks `SessionSurfaceMap` presence rather than this toggle).

import Foundation

struct SessionSettings: Sendable {

    static let persistentSessionsEnabledKey = "calyx.session.persistentSessionsEnabled"
    static let agentResumeEnabledKey = "calyx.session.agentResumeEnabled"
    static let agentResumeAutoExecuteKey = "calyx.session.agentResumeAutoExecute"
    static let historyPersistenceEnabledKey = "calyx.session.historyPersistenceEnabled"

    /// Test isolation hook: production reads/writes `UserDefaults
    /// .standard`; tests call `_testUseSuite(named:)` with a
    /// per-test-unique suite name so assertions never read or write the
    /// user's real defaults domain, and `_testTeardownSuite(named:)`
    /// restores production behavior afterward. `nonisolated(unsafe)` is
    /// sound here the same way it is for test-only global state
    /// elsewhere in this codebase: XCTest runs one test class's methods
    /// serially, and this is never touched from production code paths.
    private nonisolated(unsafe) static var _testStore: UserDefaults?

    static func _testUseSuite(named name: String) {
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        _testStore = defaults
    }

    static func _testTeardownSuite(named name: String) {
        UserDefaults().removePersistentDomain(forName: name)
        _testStore = nil
    }

    /// Master switch: when `false` (the documented default),
    /// `SessionSpawnPlanner` must always return `.passthrough` for new
    /// surfaces. Does not affect `SessionReconnectCoordinator`, which
    /// gates on `SessionSurfaceMap` presence instead (see this file's
    /// header comment).
    static var persistentSessionsEnabled: Bool {
        get { (_testStore ?? .standard).bool(forKey: persistentSessionsEnabledKey) }
        set { (_testStore ?? .standard).set(newValue, forKey: persistentSessionsEnabledKey) }
    }

    /// Whether a reattached persistent-session pane offers to resume
    /// the agent CLI conversation that was running inside it (via
    /// `SessionResumePlanner`, keyed by the meta
    /// `AgentSessionMetaBridge` recorded). Defaults OFF, same
    /// rationale as `persistentSessionsEnabled` — resuming an agent
    /// conversation injects synthesized input into the pane, which
    /// should be opt-in.
    static var agentResumeEnabled: Bool {
        get { (_testStore ?? .standard).bool(forKey: agentResumeEnabledKey) }
        set { (_testStore ?? .standard).set(newValue, forKey: agentResumeEnabledKey) }
    }

    /// When `agentResumeEnabled` is on: `false` (the default)
    /// "proposes" the resume command — typed into the pane with no
    /// trailing newline, so the user presses Return themselves — while
    /// `true` submits it automatically (trailing newline). See
    /// `SessionResumePlanner.initialInput(agentKind:agentSessionID:autoExecute:)`.
    static var agentResumeAutoExecute: Bool {
        get { (_testStore ?? .standard).bool(forKey: agentResumeAutoExecuteKey) }
        set { (_testStore ?? .standard).set(newValue, forKey: agentResumeAutoExecuteKey) }
    }

    /// Opt-in switch for on-disk history persistence
    /// (`ControlMsg::SetHistoryEnabled`'s daemon-wide default). Defaults
    /// OFF, same rationale as `persistentSessionsEnabled` and
    /// `agentResumeEnabled` — capturing pane history to disk should
    /// never start without the user turning it on. Setting this does not
    /// itself reach a running daemon; see
    /// `HistoryPersistenceToggleCoordinator` (propagates a live toggle)
    /// and `AppDelegate.reassertHistoryPersistenceIfNeeded()` (reasserts
    /// it once per launch).
    static var historyPersistenceEnabled: Bool {
        get { (_testStore ?? .standard).bool(forKey: historyPersistenceEnabledKey) }
        set { (_testStore ?? .standard).set(newValue, forKey: historyPersistenceEnabledKey) }
    }

    static func resetToDefaults() {
        (_testStore ?? .standard).removeObject(forKey: persistentSessionsEnabledKey)
        (_testStore ?? .standard).removeObject(forKey: agentResumeEnabledKey)
        (_testStore ?? .standard).removeObject(forKey: agentResumeAutoExecuteKey)
        (_testStore ?? .standard).removeObject(forKey: historyPersistenceEnabledKey)
    }
}
