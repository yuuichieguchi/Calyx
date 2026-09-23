//
//  CommandTrackingSettingsTests.swift
//  CalyxTests
//
//  Covers CommandTrackingSettings: the command-tracking feature
//  toggle, same shape as SessionSettings.persistentSessionsEnabled but
//  defaulting ON.
//
//  Coverage:
//  - trackingEnabled defaults to true when the key has never been written
//  - Writing it persists, in an isolated UserDefaults suite (never touches
//    the user's real defaults domain)
//

import XCTest
@testable import Calyx

final class CommandTrackingSettingsTests: XCTestCase {

    private let suiteName = "com.calyx.tests.CommandTrackingSettingsTests"
    private var standardDefaultsTripwire: StandardDefaultsTripwire!

    override func setUp() {
        super.setUp()
        standardDefaultsTripwire = StandardDefaultsTripwire(key: CommandTrackingSettings.trackingEnabledKey)
        CommandTrackingSettings._testUseSuite(named: suiteName)
    }

    override func tearDown() {
        CommandTrackingSettings._testTeardownSuite(named: suiteName)
        standardDefaultsTripwire.assertUnchanged()
        super.tearDown()
    }

    func test_trackingEnabled_defaultsToTrueWhenKeyAbsent() {
        XCTAssertTrue(CommandTrackingSettings.trackingEnabled,
                     "trackingEnabled must default to true when the key has never been written -- " +
                     "command tracking ships on")
    }

    func test_trackingEnabled_write_persistsInIsolatedSuiteOnly() {
        // Write the non-default value and verify both the typed getter
        // and the raw isolated suite reflect a value, not merely absence.
        CommandTrackingSettings.trackingEnabled = false

        XCTAssertFalse(CommandTrackingSettings.trackingEnabled,
                      "Setting trackingEnabled must be readable back as the value written")

        let rawSuite = UserDefaults(suiteName: suiteName)!
        XCTAssertEqual(rawSuite.object(forKey: CommandTrackingSettings.trackingEnabledKey) as? Bool, false,
                        "Setting trackingEnabled must actually persist a value into the isolated test suite")

        assertStandardDefaultsUntouched(key: CommandTrackingSettings.trackingEnabledKey) { before in
            CommandTrackingSettings.trackingEnabled = !(before ?? true)
        }
    }
}
