// IPCSettings.swift
// Calyx
//
// UserDefaults-backed store for the AI Agent IPC master switch (Settings >
// Agents). Same shape as CockpitSettings (see that type's own header
// comment for the full rationale): `_testStore` (in-process unit-test
// isolation) then `uiTestSuite` (separate --uitesting process isolation)
// then `.standard` in production. Always compiled, not `#if DEBUG`-gated --
// a prior divergence here risked a Release test-build configuration
// silently falling through to `.standard`, leaking test state into the
// user's real defaults domain.
//
// Default OFF is load-bearing, not a stylistic choice: ON by default would
// bind a loopback listener and rewrite every supported agent CLI's config
// file for every first-launch user without their consent.

import Foundation

struct IPCSettings: Sendable {

    static let enabledKey = "calyx.ipc.enabled"

    private static let settingsStore = SettingsStore()

    static func _testUseSuite(named name: String) {
        settingsStore.testUseSuite(named: name)
    }

    static func _testTeardownSuite(named name: String) {
        settingsStore.testTeardownSuite(named: name)
    }

    private static var store: UserDefaults {
        settingsStore.store
    }

    /// Master switch for AI Agent IPC. Documented default: `false` when
    /// the key has never been written.
    static var enabled: Bool {
        get {
            // Default OFF matches UserDefaults.bool(forKey:)'s native
            // absent-key behavior, so no explicit object(forKey:) == nil
            // check is needed here.
            store.bool(forKey: enabledKey)
        }
        set {
            store.set(newValue, forKey: enabledKey)
        }
    }
}
