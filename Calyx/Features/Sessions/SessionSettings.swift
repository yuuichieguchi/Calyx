// SessionSettings.swift
// Calyx
//
// UserDefaults-backed store for the persistent-sessions feature toggle.
// Unlike `LSPSettings` (which reads/writes `UserDefaults.standard`
// directly with no test seam), this type routes every read/write
// through `store`, which resolves (in order): `_testStore` — an
// in-process unit-test seam, swapped to a per-test-unique suite via
// `_testUseSuite(named:)` so assertions never touch the user's real
// defaults domain; then `uiTestSuite` — an env-var-driven seam for a
// SEPARATE `--uitesting` app process, which `_testStore` can never
// reach (see that property's own doc comment); then `.standard` in
// production. Defaults OFF: when `false`, `SessionSpawnPlanner`
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

    /// UI-test isolation hook, for a SEPARATE `--uitesting` app process
    /// that `_testStore` (an in-process-only seam driven by
    /// `@testable import Calyx`) can never reach: mirrors
    /// `SessionPersistenceActor`'s own `CALYX_UITEST_SESSION_DIR`
    /// environment-variable convention for isolating the session
    /// daemon's on-disk state. When an E2E test launches the app with
    /// `CALYX_UITEST_DEFAULTS_SUITE` set, every read/write here targets
    /// that named `UserDefaults` suite instead of `.standard`, so the
    /// separately-launched app process never mutates the developer's
    /// real `com.calyx.terminal.e2e` defaults domain. Resolved once per
    /// process lifetime -- a launched process's environment never
    /// changes after launch.
    /// `nonisolated(unsafe)` for the same reason as `_testStore` above:
    /// `UserDefaults` isn't `Sendable` in this SDK, but this value is
    /// written exactly once, in this initializer, before any other code
    /// can observe it, and `UserDefaults` itself is safe for concurrent
    /// reads/writes.
    private nonisolated(unsafe) static let uiTestSuite: UserDefaults? = {
        guard let name = ProcessInfo.processInfo.environment["CALYX_UITEST_DEFAULTS_SUITE"] else { return nil }
        return UserDefaults(suiteName: name)
    }()

    private static var store: UserDefaults {
        _testStore ?? uiTestSuite ?? .standard
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
