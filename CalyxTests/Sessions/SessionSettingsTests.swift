//
//  SessionSettingsTests.swift
//  CalyxTests
//
//  TDD Red Phase for SessionSettings: the persistent-sessions feature
//  toggle, same shape as LSPSettings.
//
//  Coverage:
//  - persistentSessionsEnabled defaults to false
//  - Setting it true and reading it back persists, in an isolated
//    UserDefaults suite (never touches the user's real defaults domain)
//  - resetToDefaults() restores the documented default
//

import XCTest
@testable import Calyx

final class SessionSettingsTests: XCTestCase {

    private let suiteName = "com.calyx.tests.SessionSettingsTests"

    override func setUp() {
        super.setUp()
        SessionSettings._testUseSuite(named: suiteName)
    }

    override func tearDown() {
        SessionSettings._testTeardownSuite(named: suiteName)
        super.tearDown()
    }

    func test_persistentSessionsEnabled_defaultsToFalse() {
        XCTAssertFalse(SessionSettings.persistentSessionsEnabled,
                      "persistentSessionsEnabled must default to false — the feature ships off")
    }

    func test_persistentSessionsEnabled_setTrue_persistsAcrossReads() {
        SessionSettings.persistentSessionsEnabled = true

        XCTAssertTrue(SessionSettings.persistentSessionsEnabled,
                     "Setting persistentSessionsEnabled to true must be readable back as true, " +
                     "in the isolated test suite")
    }

    func test_persistentSessionsEnabled_setFalseAfterTrue_persists() {
        SessionSettings.persistentSessionsEnabled = true
        SessionSettings.persistentSessionsEnabled = false

        XCTAssertFalse(SessionSettings.persistentSessionsEnabled)
    }

    func test_resetToDefaults_restoresFalse() {
        SessionSettings.persistentSessionsEnabled = true

        SessionSettings.resetToDefaults()

        XCTAssertFalse(SessionSettings.persistentSessionsEnabled,
                      "resetToDefaults() must strip the persisted value, restoring the documented default")
    }
}
