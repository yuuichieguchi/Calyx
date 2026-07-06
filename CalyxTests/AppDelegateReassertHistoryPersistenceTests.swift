//
//  AppDelegateReassertHistoryPersistenceTests.swift
//  CalyxTests
//
//  TDD Red phase, P6 RED2 (R-B4): the attach-spawned calyx-session
//  daemon always starts with history OFF (DaemonConfig::history_enabled's
//  bind-time default; see ControlMsg::SetHistoryEnabled's own doc
//  comment -- a live, in-memory override, never persisted daemon-side),
//  regardless of any `history on` a previous process lifetime sent it.
//  A user with historyPersistenceEnabled on therefore needs it re-pushed
//  once per launch, against whatever daemon this launch attaches to or
//  spawns.
//
//  PROPOSED HOOK POINT (P6 RED2 investigation note): AppDelegate
//  .reassertHistoryPersistenceIfNeeded(), an async method mirroring
//  fetchSessionsForAgentResume()'s existing shape and its
//  _sessionDaemonClientForTesting seam (see AppDelegate.swift ~1444),
//  called once from applicationDidFinishLaunching right after the
//  restoreSession()/createNewWindow() branch resolves -- NOT piggybacked
//  onto fetchSessionsForAgentResume() itself, which gates on the
//  unrelated agentResumeEnabled setting and would silently skip
//  reassertion for a user who has persistentSessionsEnabled and
//  historyPersistenceEnabled on but agentResumeEnabled off, a plausible
//  real configuration. Gated on persistentSessionsEnabled (no persistent
//  daemon is ever spawned otherwise, so there is nothing to reassert to)
//  AND historyPersistenceEnabled; calls
//  client.setHistoryEnabled(true) exactly once when both are on.
//
//  CAVEAT flagged for the Green phase: the daemon that ends up serving
//  this launch's persistent-session panes is spawned on demand, per
//  pane, by the FIRST `calyx-session attach --create` ghostty actually
//  execs (crates/cli/src/commands/attach.rs's connect_or_spawn) -- a
//  process this reassertion call has no synchronous handle on and does
//  not wait for. `history.rs` (this round's CLI command, see its own
//  header) does not auto-spawn a daemon the way `attach` does, so a
//  reassertion that runs before any pane has actually attached could
//  race a not-yet-running daemon and silently no-op. This file's tests
//  only cover the gating logic (which settings call the client and how
//  many times), not that race; the Green phase should decide whether a
//  bounded retry belongs here or whether best-effort (documented as
//  such) is acceptable given this whole feature is opt-in/experimental.
//
//  Held-out compile-RED (see SessionCommandSynthesizerRemoteAttachTests's
//  header for this codebase's convention):
//  reassertHistoryPersistenceIfNeeded() does not exist yet on
//  AppDelegate, and SessionDaemonClientProtocol.setHistoryEnabled(_:)
//  does not exist yet either (introduced by a sibling RED file this same
//  round), so this file fails to compile until the Green phase adds
//  both. That compile failure IS this file's RED evidence.
//
//  Coverage:
//  - persistentSessionsEnabled AND historyPersistenceEnabled both on:
//    reasserts setHistoryEnabled(true) exactly once
//  - historyPersistenceEnabled off: never calls the daemon at all
//  - persistentSessionsEnabled off: never calls the daemon at all, even
//    if historyPersistenceEnabled is on
//

import XCTest
@testable import Calyx

@MainActor
final class AppDelegateReassertHistoryPersistenceTests: XCTestCase {

    private let settingsSuiteName = "com.calyx.tests.AppDelegateReassertHistoryPersistenceTests"

    override func setUp() {
        super.setUp()
        SessionSettings._testUseSuite(named: settingsSuiteName)
    }

    override func tearDown() {
        SessionSettings.resetToDefaults()
        SessionSettings._testTeardownSuite(named: settingsSuiteName)
        super.tearDown()
    }

    /// Records every value setHistoryEnabled(_:) was called with.
    /// sessionState/kill are never called by
    /// reassertHistoryPersistenceIfNeeded(), so the default
    /// no-op/unreachable implementations from
    /// SessionDaemonClientProtocol's extension are enough for those.
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

    func test_bothSettingsOn_reassertsHistoryEnabledOnceAtLaunch() async {
        SessionSettings.persistentSessionsEnabled = true
        SessionSettings.historyPersistenceEnabled = true
        let appDelegate = AppDelegate()
        let client = RecordingDaemonClient()
        appDelegate._sessionDaemonClientForTesting = client

        await appDelegate.reassertHistoryPersistenceIfNeeded()

        XCTAssertEqual(client.recordedCalls, [true],
                      "with persistentSessionsEnabled and historyPersistenceEnabled both on, launch must " +
                      "reassert history=on to the daemon exactly once")
    }

    func test_historyPersistenceDisabled_neverCallsDaemon() async {
        SessionSettings.persistentSessionsEnabled = true
        SessionSettings.historyPersistenceEnabled = false
        let appDelegate = AppDelegate()
        let client = RecordingDaemonClient()
        appDelegate._sessionDaemonClientForTesting = client

        await appDelegate.reassertHistoryPersistenceIfNeeded()

        XCTAssertTrue(client.recordedCalls.isEmpty,
                     "with historyPersistenceEnabled off, launch must never call setHistoryEnabled at all")
    }

    func test_persistentSessionsDisabled_neverCallsDaemonEvenIfHistoryPersistenceIsOn() async {
        SessionSettings.persistentSessionsEnabled = false
        SessionSettings.historyPersistenceEnabled = true
        let appDelegate = AppDelegate()
        let client = RecordingDaemonClient()
        appDelegate._sessionDaemonClientForTesting = client

        await appDelegate.reassertHistoryPersistenceIfNeeded()

        XCTAssertTrue(client.recordedCalls.isEmpty,
                     "with persistentSessionsEnabled off, no persistent-session daemon is ever spawned, so " +
                     "there is nothing to reassert history state to")
    }
}
