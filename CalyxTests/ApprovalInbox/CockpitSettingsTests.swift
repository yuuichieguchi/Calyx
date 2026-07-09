//
//  CockpitSettingsTests.swift
//  CalyxTests
//
//  TDD Red Phase for CockpitSettings: the Cockpit auto-approve feature
//  toggle, same shape as CommandTrackingSettings.trackingEnabled but
//  defaulting OFF.
//
//  Coverage:
//  - autoApproveEnabled defaults to false when the key has never been
//    written
//  - Setting it persists and round-trips, in an isolated UserDefaults
//    suite (never touches the user's real defaults domain)
//  - _testStore isolation: a fresh suite never leaks state from a
//    previously-used suite, and writes never reach .standard
//

import XCTest
@testable import Calyx

final class CockpitSettingsTests: XCTestCase {

    private let suiteName = "com.calyx.tests.CockpitSettingsTests"

    override func setUp() {
        super.setUp()
        CockpitSettings._testUseSuite(named: suiteName)
    }

    override func tearDown() {
        CockpitSettings._testTeardownSuite(named: suiteName)
        super.tearDown()
    }

    func test_default_isOff() {
        XCTAssertFalse(CockpitSettings.autoApproveEnabled,
                       "autoApproveEnabled must default to false when the key has never been written")
    }

    func test_setAndRead_roundTrip() {
        CockpitSettings.autoApproveEnabled = true
        XCTAssertTrue(CockpitSettings.autoApproveEnabled,
                     "Setting autoApproveEnabled to true must be readable back as true")

        CockpitSettings.autoApproveEnabled = false
        XCTAssertFalse(CockpitSettings.autoApproveEnabled,
                      "Setting autoApproveEnabled to false must be readable back as false")

        // Verify the write actually reached the isolated test suite --
        // otherwise the assertions above would be indistinguishable from a
        // getter that simply ignores any set.
        let rawSuite = UserDefaults(suiteName: suiteName)!
        XCTAssertFalse(rawSuite.bool(forKey: CockpitSettings.autoApproveEnabledKey),
                      "Setting autoApproveEnabled must actually persist the value into the isolated test suite")
    }

    func test_testStoreIsolation() {
        CockpitSettings.autoApproveEnabled = true

        XCTAssertNil(UserDefaults.standard.object(forKey: CockpitSettings.autoApproveEnabledKey),
                     "The real .standard defaults domain must never be touched while using _testStore")

        // A different, never-before-used suite must read the default
        // (off), not leak state from the suite above.
        let otherSuiteName = suiteName + ".other"
        CockpitSettings._testUseSuite(named: otherSuiteName)

        XCTAssertFalse(CockpitSettings.autoApproveEnabled,
                       "A fresh isolated suite must read the default (off), not leak state from a previously-used suite")

        CockpitSettings._testTeardownSuite(named: otherSuiteName)
    }
}
