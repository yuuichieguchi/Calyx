// CommandTrackingSettings.swift
// Calyx
//
// UserDefaults-backed store for the command-tracking feature toggle. Same
// shared `SettingsStore` resolution as SessionSettings (see
// `Calyx/Helpers/SettingsStore.swift`'s header comment for the full
// rationale): `_testStore` (in-process unit-test isolation) then
// `uiTestSuite` (separate --uitesting process isolation) then
// `.standard` in production. Defaults ON -- unlike SessionSettings'
// opt-in toggles, command tracking is meant to be on by default once the
// shell integration is installed.

import Foundation

struct CommandTrackingSettings: Sendable {

    static let trackingEnabledKey = "calyx.commandlog.trackingEnabled"

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

    /// Master switch for command tracking. Documented default: `true`
    /// when the key has never been written -- same
    /// `object(forKey:) == nil` absence check as LSPSettings.autoInstallEnabled.
    static var trackingEnabled: Bool {
        get {
            if store.object(forKey: trackingEnabledKey) == nil {
                return true
            }
            return store.bool(forKey: trackingEnabledKey)
        }
        set {
            store.set(newValue, forKey: trackingEnabledKey)
        }
    }
}
