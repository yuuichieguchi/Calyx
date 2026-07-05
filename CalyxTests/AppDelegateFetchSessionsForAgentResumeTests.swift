//
//  AppDelegateFetchSessionsForAgentResumeTests.swift
//  CalyxTests
//
//  TDD Red phase for round-6 fix R6-C (r6-fix-spec.md; CONFIRMED
//  regression evidence in r5-verdicts.md's "R5-blocking" entry):
//  `AppDelegate.fetchSessionsForAgentResume()` spins
//  `RunLoop.current.run` in 10ms steps for up to 2.0s, synchronously,
//  on the calling (main) thread, whenever `SessionSettings
//  .agentResumeEnabled` is on. The intended fix makes this genuinely
//  non-blocking (an async fetch task callers await only where they
//  actually need the result), so `restoreSession`/`attachWindow` never
//  wait on the daemon just to show a window.
//
//  Drives `fetchSessionsForAgentResume()` directly (made non-private for
//  this purpose, see its own doc comment) with a fake
//  `SessionDaemonClientProtocol` injected via
//  `AppDelegate._sessionDaemonClientForTesting` (also new, see that
//  seam's doc comment; `SessionDaemonClient.shared` itself is a
//  non-swappable `let`, unlike `NotificationManager.shared`), rather
//  than a live `calyx-session` subprocess, matching this codebase's
//  `SessionBrowserModelTests`/`SessionReconnectCoordinatorTests` fake-
//  daemon convention. The fake's `listAll()` never resolves within the
//  test's timeout window, standing in for an unreachable/slow daemon,
//  so any observed delay in `fetchSessionsForAgentResume()` returning
//  is directly attributable to ITS OWN blocking spin, not real network/
//  process latency.
//
//  Coverage:
//  - `fetchSessionsForAgentResume()` must return promptly (well under
//    its own 2.0s spin deadline) even when the injected daemon client's
//    `listAll()` never completes.
//

import XCTest
@testable import Calyx

@MainActor
final class AppDelegateFetchSessionsForAgentResumeTests: XCTestCase {

    private let settingsSuiteName = "com.calyx.tests.AppDelegateFetchSessionsForAgentResumeTests"

    override func setUp() {
        super.setUp()
        SessionSettings._testUseSuite(named: settingsSuiteName)
    }

    override func tearDown() {
        SessionSettings.resetToDefaults()
        SessionSettings._testTeardownSuite(named: settingsSuiteName)
        super.tearDown()
    }

    /// A fake daemon whose `listAll()` awaits a continuation this test
    /// never resumes, standing in for a daemon that is slow or
    /// unreachable for the whole test run. `sessionState`/`kill`/
    /// `setMeta` are never called by `fetchSessionsForAgentResume`, so
    /// the default no-op/empty implementations from
    /// `SessionDaemonClientProtocol`'s extension are enough for
    /// `sessionState`; `listAll()` must be overridden explicitly since
    /// its default (also empty, immediate) would defeat this test's
    /// entire premise.
    private final class NeverRespondingDaemonClient: SessionDaemonClientProtocol, @unchecked Sendable {
        func sessionState(id: String) async -> SessionQueryResult { .unreachable }

        func kill(id: String) async {}

        func listAll() async -> [SessionInfo] {
            await withCheckedContinuation { (_: CheckedContinuation<[SessionInfo], Never>) in
                // Deliberately never resumed: this Task hangs for the
                // rest of the process's life. Harmless here because
                // `fetchSessionsForAgentResume`'s own spin loop is
                // bounded by its own 2.0s deadline and gives up on it
                // regardless (that bounded give-up is exactly the
                // blocking behavior this test measures).
            }
        }
    }

    /// Primary RED-proving assertion (R6-C, r5-verdicts.md R5-blocking):
    /// against the CURRENT code, `fetchSessionsForAgentResume()`'s
    /// `RunLoop.current.run` spin blocks the calling thread for its full
    /// ~2.0s deadline before giving up and returning `[:]`, since the
    /// injected daemon's `listAll()` never resolves. A safety threshold
    /// well below that deadline (0.5s) distinguishes "returned promptly,
    /// not waiting on the daemon at all" (the fix) from "blocked, then
    /// gave up" (today).
    func test_fetchSessionsForAgentResume_doesNotBlockOnUnresponsiveDaemon() {
        SessionSettings.agentResumeEnabled = true

        let appDelegate = AppDelegate()
        appDelegate._sessionDaemonClientForTesting = NeverRespondingDaemonClient()

        let start = Date()
        let result = appDelegate.fetchSessionsForAgentResume()
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertLessThan(elapsed, 0.5,
                          "fetchSessionsForAgentResume must not block the calling thread waiting on the " +
                          "daemon round-trip, it took \(elapsed)s against an unresponsive fake daemon, " +
                          "which only happens if it is still synchronously spinning the run loop waiting " +
                          "for a result it should instead be awaiting asynchronously")
        XCTAssertEqual(result, [:],
                       "With no daemon response available synchronously, the immediate return value must " +
                       "be empty, this method must not fabricate session info")
    }
}
