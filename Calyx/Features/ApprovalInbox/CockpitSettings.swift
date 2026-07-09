// CockpitSettings.swift
// Calyx
//
// UserDefaults-backed store for the Cockpit auto-approve toggle. Same
// shared `SettingsStore` resolution as CommandTrackingSettings (see
// `Calyx/Helpers/SettingsStore.swift`'s header comment for the full
// rationale): `_testStore` (in-process unit-test isolation) then
// `uiTestSuite` (separate --uitesting process isolation) then
// `.standard` in production. Always compiled, not `#if DEBUG`-gated --
// a prior divergence here risked a Release test-build configuration
// silently falling through to `.standard`, leaking test state into the
// user's real defaults domain. Defaults OFF -- approval is required
// unless explicitly opted out.

import Foundation

struct CockpitSettings: Sendable {

    static let autoApproveEnabledKey = "calyx.cockpit.autoApproveEnabled"

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

    /// Master switch for auto-approving gated Cockpit actions.
    /// Documented default: `false` when the key has never been written.
    static var autoApproveEnabled: Bool {
        get {
            // Default OFF matches UserDefaults.bool(forKey:)'s native
            // absent-key behavior, so no explicit object(forKey:) == nil
            // check is needed here (unlike CommandTrackingSettings, whose
            // documented default is `true`).
            store.bool(forKey: autoApproveEnabledKey)
        }
        set {
            store.set(newValue, forKey: autoApproveEnabledKey)
        }
    }
}
