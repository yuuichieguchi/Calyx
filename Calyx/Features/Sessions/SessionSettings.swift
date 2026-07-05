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

    static func resetToDefaults() {
        (_testStore ?? .standard).removeObject(forKey: persistentSessionsEnabledKey)
    }
}
