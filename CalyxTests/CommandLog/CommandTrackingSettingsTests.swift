//
//  CommandTrackingSettingsTests.swift
//  CalyxTests
//
//  TDD Red Phase for CommandTrackingSettings: the command-tracking feature
//  toggle, same shape as SessionSettings.persistentSessionsEnabled but
//  defaulting ON.
//
//  Coverage:
//  - trackingEnabled defaults to true when the key has never been written
//  - Setting it false persists, in an isolated UserDefaults suite (never
//    touches the user's real defaults domain)
//

import XCTest
@testable import Calyx

final class CommandTrackingSettingsTests: XCTestCase {

    private let suiteName = "com.calyx.tests.CommandTrackingSettingsTests"

    override func setUp() {
        super.setUp()
        CommandTrackingSettings._testUseSuite(named: suiteName)
    }

    override func tearDown() {
        CommandTrackingSettings._testTeardownSuite(named: suiteName)
        super.tearDown()
    }

    func test_trackingEnabled_defaultsToTrueWhenKeyAbsent() {
        XCTAssertTrue(CommandTrackingSettings.trackingEnabled,
                     "trackingEnabled must default to true when the key has never been written -- " +
                     "command tracking ships on")
    }

    func test_trackingEnabled_setFalse_persistsInIsolatedSuiteOnly() {
        CommandTrackingSettings.trackingEnabled = false

        XCTAssertFalse(CommandTrackingSettings.trackingEnabled,
                      "Setting trackingEnabled to false must be readable back as false")

        // Verify the write actually reached the isolated test suite --
        // otherwise the assertion above would be indistinguishable from a
        // getter that simply always returns false regardless of any set.
        let rawSuite = UserDefaults(suiteName: suiteName)!
        XCTAssertNotNil(rawSuite.object(forKey: CommandTrackingSettings.trackingEnabledKey),
                        "Setting trackingEnabled must actually persist a value into the isolated test suite")

        XCTAssertNil(UserDefaults.standard.object(forKey: CommandTrackingSettings.trackingEnabledKey),
                     "The real .standard defaults domain must never be touched while using _testUseSuite")
    }
}
