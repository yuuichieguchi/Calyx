//
//  IPCSettingsTests.swift
//  CalyxTests
//
//  Covers IPCSettings: the master persistence switch for AI Agent IPC
//  (Settings > Agents). Same shape as CockpitSettings -- a dedicated
//  `SettingsStore()`, `_testUseSuite`/`_testTeardownSuite` isolation
//  hooks, `store.bool(forKey:)`'s native absent-key default -- except
//  the default here is load-bearing for a different reason: ON by
//  default would bind a loopback listener and rewrite agent CLI config
//  files for every first-launch user without consent.
//
//  Coverage:
//  - enabled defaults to false when the key has never been written
//  - Setting it persists and round-trips, in an isolated UserDefaults
//    suite (never touches the user's real defaults domain)
//  - _testStore isolation: a fresh suite never leaks state from a
//    previously-used suite, and writes never reach .standard
//

import XCTest
@testable import Calyx

final class IPCSettingsTests: XCTestCase {

    private let suiteName = "com.calyx.tests.IPCSettingsTests"

    override func setUp() {
        super.setUp()
        IPCSettings._testUseSuite(named: suiteName)
    }

    override func tearDown() {
        IPCSettings._testTeardownSuite(named: suiteName)
        super.tearDown()
    }

    func test_enabledKey_isExactLiteral() {
        XCTAssertEqual(IPCSettings.enabledKey, "calyx.ipc.enabled",
                       "the UserDefaults key must match the spec'd literal exactly")
    }

    func test_default_isOff() {
        XCTAssertFalse(IPCSettings.enabled,
                       "enabled must default to false when the key has never been written -- ON by default " +
                       "would bind a loopback listener and rewrite agent CLI config files without consent")
    }

    func test_setAndRead_roundTrip() {
        IPCSettings.enabled = true
        XCTAssertTrue(IPCSettings.enabled, "Setting enabled to true must be readable back as true")

        IPCSettings.enabled = false
        XCTAssertFalse(IPCSettings.enabled, "Setting enabled to false must be readable back as false")

        // Verify the write actually reached the isolated test suite --
        // otherwise the assertions above would be indistinguishable from a
        // getter that simply ignores any set.
        IPCSettings.enabled = true
        let rawSuite = UserDefaults(suiteName: suiteName)!
        XCTAssertTrue(rawSuite.bool(forKey: IPCSettings.enabledKey),
                      "Setting enabled must actually persist the value into the isolated test suite")
    }

    func test_testStoreIsolation() {
        IPCSettings.enabled = true

        XCTAssertNil(UserDefaults.standard.object(forKey: IPCSettings.enabledKey),
                     "The real .standard defaults domain must never be touched while using _testStore")

        // A different, never-before-used suite must read the default
        // (off), not leak state from the suite above.
        let otherSuiteName = suiteName + ".other"
        IPCSettings._testUseSuite(named: otherSuiteName)

        XCTAssertFalse(IPCSettings.enabled,
                       "A fresh isolated suite must read the default (off), not leak state from a previously-used suite")

        IPCSettings._testTeardownSuite(named: otherSuiteName)
    }
}
