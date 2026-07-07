// CommandTrackingSettings.swift
// Calyx
//
// UserDefaults-backed store for the command-tracking feature toggle. Same
// store-resolution seam as SessionSettings (see that file's header comment
// for the full rationale): `_testStore` (in-process unit-test isolation)
// then `uiTestSuite` (separate --uitesting process isolation) then
// `.standard` in production. Defaults ON -- unlike SessionSettings'
// opt-in toggles, command tracking is meant to be on by default once the
// shell integration is installed.

import Foundation

struct CommandTrackingSettings: Sendable {

    static let trackingEnabledKey = "calyx.commandlog.trackingEnabled"

    /// Test isolation hook -- see SessionSettings._testStore's doc comment
    /// for the concurrency-safety rationale of `nonisolated(unsafe)` here.
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

    /// UI-test isolation hook -- see SessionSettings.uiTestSuite's doc
    /// comment.
    private nonisolated(unsafe) static let uiTestSuite: UserDefaults? = {
        guard let name = ProcessInfo.processInfo.environment["CALYX_UITEST_DEFAULTS_SUITE"] else { return nil }
        return UserDefaults(suiteName: name)
    }()

    private static var store: UserDefaults {
        _testStore ?? uiTestSuite ?? .standard
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
