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

    // MARK: - P4: agentResumeEnabled / agentResumeAutoExecute

    func test_agentResumeEnabled_defaultsToFalse() {
        XCTAssertFalse(SessionSettings.agentResumeEnabled,
                      "agentResumeEnabled must default to false — resume is opt-in")
    }

    func test_agentResumeEnabled_setTrue_persistsAcrossReads() {
        SessionSettings.agentResumeEnabled = true

        XCTAssertTrue(SessionSettings.agentResumeEnabled)
    }

    func test_agentResumeAutoExecute_defaultsToFalse() {
        XCTAssertFalse(SessionSettings.agentResumeAutoExecute,
                      "agentResumeAutoExecute must default to false — resume proposes, it does not " +
                      "auto-submit, until the user opts in")
    }

    func test_agentResumeAutoExecute_setTrue_persistsAcrossReads() {
        SessionSettings.agentResumeAutoExecute = true

        XCTAssertTrue(SessionSettings.agentResumeAutoExecute)
    }

    func test_resetToDefaults_alsoRestoresAgentResumeSettings() {
        SessionSettings.agentResumeEnabled = true
        SessionSettings.agentResumeAutoExecute = true

        SessionSettings.resetToDefaults()

        XCTAssertFalse(SessionSettings.agentResumeEnabled)
        XCTAssertFalse(SessionSettings.agentResumeAutoExecute)
    }

    // MARK: - P6 RED2: historyPersistenceEnabled
    //
    // Held-out compile-RED (see SessionCommandSynthesizerRemoteAttachTests's
    // header for this codebase's convention): historyPersistenceEnabled
    // does not exist yet on SessionSettings, so these three cases fail
    // to compile -- together with the rest of this round's new Swift
    // API -- until the Green phase adds it, mirroring
    // persistentSessionsEnabled's own shape exactly (UserDefaults-backed,
    // routed through _testStore, defaults off).

    func test_historyPersistenceEnabled_defaultsToFalse() {
        XCTAssertFalse(SessionSettings.historyPersistenceEnabled,
                       "historyPersistenceEnabled must default to false -- on-disk history capture is opt-in")
    }

    func test_historyPersistenceEnabled_setTrue_persistsAcrossReads() {
        SessionSettings.historyPersistenceEnabled = true

        XCTAssertTrue(SessionSettings.historyPersistenceEnabled,
                     "Setting historyPersistenceEnabled to true must be readable back as true, in the " +
                     "isolated test suite")
    }

    func test_resetToDefaults_alsoRestoresHistoryPersistenceEnabled() {
        SessionSettings.historyPersistenceEnabled = true

        SessionSettings.resetToDefaults()

        XCTAssertFalse(SessionSettings.historyPersistenceEnabled,
                      "resetToDefaults() must strip the persisted value, restoring the documented default")
    }
}
