// DiffLayoutSettingsTests.swift
// CalyxTests
//
// Covers DiffLayoutSettings (plan §3): defaults, round-trips, unknown raw
// value fallback, and the .diffLayoutSettingChanged notification posted by
// every setter. Same isolated-suite shape as GitRefFilterSettingsTests.

import Foundation
import XCTest
@testable import Calyx

final class DiffLayoutSettingsTests: XCTestCase {

    private let suiteName = "com.calyx.tests.DiffLayoutSettingsTests"

    override func setUp() {
        super.setUp()
        DiffLayoutSettings._testUseSuite(named: suiteName)
    }

    override func tearDown() {
        DiffLayoutSettings._testTeardownSuite(named: suiteName)
        super.tearDown()
    }

    private var suite: UserDefaults {
        UserDefaults(suiteName: suiteName)!
    }

    // MARK: - Notification name

    func test_notificationName_rawValue() {
        XCTAssertEqual(Notification.Name.diffLayoutSettingChanged.rawValue, "com.calyx.diffLayoutSettingChanged")
    }

    // MARK: - Defaults

    func test_preference_defaultsToAutomatic() {
        XCTAssertEqual(DiffLayoutSettings.preference, .automatic)
    }

    func test_hideUnchangedRegions_defaultsToFalse() {
        XCTAssertFalse(DiffLayoutSettings.hideUnchangedRegionsEnabled)
    }

    func test_ignoreTrimWhitespace_defaultsToTrue() {
        XCTAssertTrue(DiffLayoutSettings.ignoreTrimWhitespace)
    }

    // MARK: - Round-trips

    func test_preference_roundTripsEveryCase() {
        for pref in [DiffLayoutPreference.inline, .sideBySide, .automatic, .sideBySide, .inline] {
            DiffLayoutSettings.preference = pref
            XCTAssertEqual(DiffLayoutSettings.preference, pref)
        }
    }

    func test_preference_isStoredUnderDocumentedKey() {
        DiffLayoutSettings.preference = .sideBySide
        XCTAssertNotNil(suite.object(forKey: "calyx.diff.layoutPreference"),
                        "preference must be persisted under calyx.diff.layoutPreference")
    }

    func test_preference_unknownRawValue_fallsBackToAutomatic() {
        suite.set("diagonal", forKey: "calyx.diff.layoutPreference")
        XCTAssertEqual(DiffLayoutSettings.preference, .automatic)
    }

    func test_hideUnchangedRegions_roundTrips() {
        DiffLayoutSettings.hideUnchangedRegionsEnabled = true
        XCTAssertTrue(DiffLayoutSettings.hideUnchangedRegionsEnabled)
        XCTAssertEqual(suite.object(forKey: "calyx.diff.hideUnchangedRegions") as? Bool, true)
        DiffLayoutSettings.hideUnchangedRegionsEnabled = false
        XCTAssertFalse(DiffLayoutSettings.hideUnchangedRegionsEnabled)
        XCTAssertEqual(suite.object(forKey: "calyx.diff.hideUnchangedRegions") as? Bool, false)
    }

    func test_ignoreTrimWhitespace_roundTrips() {
        DiffLayoutSettings.ignoreTrimWhitespace = false
        XCTAssertFalse(DiffLayoutSettings.ignoreTrimWhitespace)
        XCTAssertEqual(suite.object(forKey: "calyx.diff.ignoreTrimWhitespace") as? Bool, false)
        DiffLayoutSettings.ignoreTrimWhitespace = true
        XCTAssertTrue(DiffLayoutSettings.ignoreTrimWhitespace)
        XCTAssertEqual(suite.object(forKey: "calyx.diff.ignoreTrimWhitespace") as? Bool, true)
    }

    func test_bools_readFromSuiteKeys() {
        suite.set(true, forKey: "calyx.diff.hideUnchangedRegions")
        suite.set(false, forKey: "calyx.diff.ignoreTrimWhitespace")
        XCTAssertTrue(DiffLayoutSettings.hideUnchangedRegionsEnabled)
        XCTAssertFalse(DiffLayoutSettings.ignoreTrimWhitespace)
    }

    // MARK: - Notifications

    func test_preferenceSetter_postsNotification() {
        let exp = XCTNSNotificationExpectation(name: .diffLayoutSettingChanged)
        DiffLayoutSettings.preference = .inline
        wait(for: [exp], timeout: 1)
    }

    func test_hideUnchangedRegionsSetter_postsNotification() {
        let exp = XCTNSNotificationExpectation(name: .diffLayoutSettingChanged)
        DiffLayoutSettings.hideUnchangedRegionsEnabled = true
        wait(for: [exp], timeout: 1)
    }

    func test_ignoreTrimWhitespaceSetter_postsNotification() {
        let exp = XCTNSNotificationExpectation(name: .diffLayoutSettingChanged)
        DiffLayoutSettings.ignoreTrimWhitespace = false
        wait(for: [exp], timeout: 1)
    }
}
