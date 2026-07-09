// SettingsStore.swift
// Calyx
//
// Consolidates the `_testStore ?? uiTestSuite ?? .standard` UserDefaults
// resolution and its `_testUseSuite(named:)`/`_testTeardownSuite(named:)`
// test-isolation hooks -- previously three near-identical copies across
// SessionSettings, CommandTrackingSettings, and CockpitSettings (the
// last of which had also drifted to gate `_testStore` behind `#if
// DEBUG`, a real risk: a Release test-build configuration would then
// silently fall through to `.standard`, leaking test state into the
// user's real defaults domain). Each settings type owns its own private
// `SettingsStore` instance, so one type's test-suite swap can never leak
// into another's -- there is deliberately no shared/global instance.

import Foundation

/// Owned one-per-settings-type (each settings type declares its own
/// `private static let settingsStore = SettingsStore()`). `_testStore`
/// resolves first (in-process unit-test isolation, swapped via
/// `testUseSuite(named:)`), then `uiTestSuite` (a SEPARATE
/// `--uitesting` app process, driven by the `CALYX_UITEST_DEFAULTS_SUITE`
/// environment variable -- see that property's own doc comment), then
/// `.standard` in production. `@unchecked Sendable`: `UserDefaults`
/// isn't `Sendable` in this SDK, and `_testStore` (mutated after `init`,
/// only ever from test setUp/tearDown) mirrors the exact same trade-off
/// each settings type accepted individually before this consolidation
/// (via `nonisolated(unsafe) static var`) -- XCTest runs one test
/// class's methods serially, and `_testStore` is never touched from a
/// production code path.
final class SettingsStore: @unchecked Sendable {
    private var _testStore: UserDefaults?

    /// UI-test isolation hook -- see this type's header comment for the
    /// full `CALYX_UITEST_DEFAULTS_SUITE` rationale. A `let` resolved
    /// once in `init()`, before any other code can observe this
    /// instance, needs no synchronization for concurrent first access --
    /// unlike a `lazy var`, which Swift explicitly does NOT guarantee is
    /// initialized only once under concurrent access (*The Swift
    /// Programming Language*, Properties -> Lazy Stored Properties).
    /// `CALYX_UITEST_DEFAULTS_SUITE` is fixed for the process's entire
    /// lifetime, so resolving it eagerly here changes no observable
    /// behavior versus the former per-settings-type `static let`.
    private let uiTestSuite: UserDefaults?

    init() {
        if let name = ProcessInfo.processInfo.environment["CALYX_UITEST_DEFAULTS_SUITE"] {
            uiTestSuite = UserDefaults(suiteName: name)
        } else {
            uiTestSuite = nil
        }
    }

    var store: UserDefaults {
        _testStore ?? uiTestSuite ?? .standard
    }

    func testUseSuite(named name: String) {
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        _testStore = defaults
    }

    func testTeardownSuite(named name: String) {
        UserDefaults().removePersistentDomain(forName: name)
        _testStore = nil
    }
}
