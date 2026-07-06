//
//  HistoryPersistenceToggleCoordinatorTests.swift
//  CalyxTests
//
//  TDD Red phase, P6 RED2 (R-B3): the Sessions settings toggle for
//  historyPersistenceEnabled has no existing testable propagation seam
//  to follow -- SettingsWindowController's existing toggle handlers
//  (persistentSessionsDidChange, agentResumeDidChange, ...) each write
//  straight to SessionSettings from a private @objc method on an AppKit
//  singleton, with no controller/model layer beneath them a test could
//  drive (see that file's handlers around line 330). The smallest seam
//  consistent with this codebase's own idiom is a free, stateless
//  MainActor coordinator taking its daemon client via default-parameter
//  injection -- the same DI shape SessionDaemonClient's own initializer
//  already uses (resolver:commandRunner:rootResolver:...), rather than
//  retrofitting a #if DEBUG singleton-override property onto
//  SettingsWindowController itself.
//
//  PROPOSED API (P6 RED2 investigation note): HistoryPersistenceToggleCoordinator
//  .historyPersistenceEnabledDidChange(_:daemonClient:) persists the new
//  value to SessionSettings.historyPersistenceEnabled AND propagates it
//  live to whatever daemon is currently running via
//  daemonClient.setHistoryEnabled(_:) (ControlMsg::SetHistoryEnabled is a
//  live, in-memory daemon override -- see that message's own doc comment
//  -- so a user flipping this setting while a persistent-session daemon
//  is already up needs it to take effect immediately, not just on the
//  next daemon start). SettingsWindowController's new
//  historyPersistenceDidChange(_:) action handler is expected to call
//  this from a fire-and-forget Task, mirroring every other write-op
//  call site in this codebase.
//
//  Held-out compile-RED (see SessionCommandSynthesizerRemoteAttachTests's
//  header for this codebase's convention): HistoryPersistenceToggleCoordinator
//  does not exist yet anywhere in the codebase, so this file fails to
//  compile until the Green phase adds it (together with
//  SessionSettings.historyPersistenceEnabled and
//  SessionDaemonClientProtocol.setHistoryEnabled(_:), both introduced by
//  sibling RED files this same round). That compile failure IS this
//  file's RED evidence.
//
//  Coverage:
//  - Flipping the setting on persists historyPersistenceEnabled = true
//    AND propagates setHistoryEnabled(true) to the injected daemon client
//  - Flipping it off mirrors the above with false
//

import XCTest
@testable import Calyx

final class HistoryPersistenceToggleCoordinatorTests: XCTestCase {

    private let suiteName = "com.calyx.tests.HistoryPersistenceToggleCoordinatorTests"

    override func setUp() {
        super.setUp()
        SessionSettings._testUseSuite(named: suiteName)
    }

    override func tearDown() {
        SessionSettings._testTeardownSuite(named: suiteName)
        super.tearDown()
    }

    /// Records every value setHistoryEnabled(_:) was called with.
    private final class RecordingDaemonClient: SessionDaemonClientProtocol, @unchecked Sendable {
        private let lock = NSLock()
        private var _recordedCalls: [Bool] = []
        var recordedCalls: [Bool] {
            lock.lock(); defer { lock.unlock() }
            return _recordedCalls
        }

        func sessionState(id: String) async -> SessionQueryResult { .unreachable }
        func kill(id: String) async {}
        func setHistoryEnabled(_ enabled: Bool) async {
            record(enabled)
        }

        /// `lock.lock()`/`.unlock()` are unavailable directly inside an
        /// `async` function body; this plain synchronous helper is the
        /// same indirection `CancellationRecordingCommandRunner`
        /// (SessionDaemonClientWriteOpCancellationShieldTests) already
        /// uses for its own `mark*()` methods.
        private func record(_ enabled: Bool) {
            lock.lock(); _recordedCalls.append(enabled); lock.unlock()
        }
    }

    func test_flippingOn_persistsSettingAndPropagatesToDaemon() async {
        let client = RecordingDaemonClient()

        await HistoryPersistenceToggleCoordinator.historyPersistenceEnabledDidChange(
            true, daemonClient: client
        )

        XCTAssertTrue(SessionSettings.historyPersistenceEnabled,
                     "flipping the toggle on must persist historyPersistenceEnabled = true")
        XCTAssertEqual(client.recordedCalls, [true],
                      "flipping the toggle on must propagate to the daemon via setHistoryEnabled(true)")
    }

    func test_flippingOff_persistsSettingAndPropagatesToDaemon() async {
        let client = RecordingDaemonClient()
        SessionSettings.historyPersistenceEnabled = true

        await HistoryPersistenceToggleCoordinator.historyPersistenceEnabledDidChange(
            false, daemonClient: client
        )

        XCTAssertFalse(SessionSettings.historyPersistenceEnabled,
                       "flipping the toggle off must persist historyPersistenceEnabled = false")
        XCTAssertEqual(client.recordedCalls, [false],
                      "flipping the toggle off must propagate to the daemon via setHistoryEnabled(false)")
    }
}
