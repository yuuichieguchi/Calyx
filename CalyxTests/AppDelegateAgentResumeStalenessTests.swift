//
//  AppDelegateAgentResumeStalenessTests.swift
//  CalyxTests
//
//  TDD Red phase, round 10 (r10-fix-spec.md, R10-B): AppDelegate
//  .fetchSessionsForAgentResume()'s `agentResumeSessionsTask == nil`
//  reuse guard (R8-D item 2, added so overlapping restore/attach passes
//  share one in-flight daemon round-trip) never resets the task back to
//  nil once it COMPLETES. Every fetch after the very first one therefore
//  reuses the launch-time task's already-resolved value forever, and a
//  first fetch that timed out (listAllSessionsBounded's own ~5s bound)
//  permanently pins an empty `[:]` result, so agent resume silently
//  never triggers again for the rest of the process's life.
//
//  Drives fetchSessionsForAgentResume() directly against a fake
//  SessionDaemonClientProtocol injected via
//  AppDelegate._sessionDaemonClientForTesting (the same seam
//  AppDelegateFetchSessionsForAgentResumeTests / round-6/8 RED phases
//  established), counting real daemon round-trips instead of spawning
//  a live calyx-session process. Pumps the shared agentResumeSessionsTask
//  by awaiting its `.value` between fetches (rather than sleeping) so
//  the first fetch is provably fully resolved before the second one is
//  issued -- no reliance on wall-clock timing.
//
//  Coverage:
//  - A second fetchSessionsForAgentResume() issued AFTER the first has
//    fully completed must start a fresh daemon round-trip (RED: today
//    it reuses the completed task and never calls the daemon again)
//  - Regression guard: two fetchSessionsForAgentResume() calls issued
//    back-to-back WHILE the first is still unresolved must still
//    collapse into exactly one daemon round-trip (already true today,
//    via the synchronous `agentResumeSessionsTask == nil` guard itself;
//    must remain true after the fix)
//

import XCTest
@testable import Calyx

/// Records every listAll() invocation and replays an empty ledger --
/// a process boundary stand-in, no real calyx-session binary involved.
/// Mirrors SessionBrowserModelTests' FakeBrowserDaemonClient shape (not
/// shared across files, matching this codebase's established per-file
/// fixture-duplication convention).
private final class CountingDaemonClient: SessionDaemonClientProtocol, @unchecked Sendable {
    private(set) var callCount = 0

    func sessionState(id: String) async -> SessionQueryResult { .unreachable }
    func kill(id: String) async {}

    func listAll() async -> [SessionInfo] {
        callCount += 1
        return []
    }
}

@MainActor
final class AppDelegateAgentResumeStalenessTests: XCTestCase {

    private let settingsSuiteName = "com.calyx.tests.AppDelegateAgentResumeStalenessTests"

    override func setUp() {
        super.setUp()
        SessionSettings._testUseSuite(named: settingsSuiteName)
    }

    override func tearDown() {
        SessionSettings.resetToDefaults()
        SessionSettings._testTeardownSuite(named: settingsSuiteName)
        super.tearDown()
    }

    /// Primary RED-proving assertion (R10-B): against the CURRENT code,
    /// the reuse guard never clears agentResumeSessionsTask on
    /// completion, so a second fetch issued after the first fully
    /// resolved is silently swallowed instead of reaching the daemon
    /// again.
    func test_fetchSessionsForAgentResume_secondFetchAfterCompletion_startsFreshDaemonCall() async throws {
        SessionSettings.agentResumeEnabled = true
        let client = CountingDaemonClient()
        let appDelegate = AppDelegate()
        appDelegate._sessionDaemonClientForTesting = client

        appDelegate.fetchSessionsForAgentResume()
        _ = await appDelegate.agentResumeSessionsTask?.value
        XCTAssertEqual(client.callCount, 1, "Precondition: the first fetch must reach the daemon exactly once")

        appDelegate.fetchSessionsForAgentResume()
        _ = await appDelegate.agentResumeSessionsTask?.value

        XCTAssertEqual(
            client.callCount, 2,
            "A SECOND fetchSessionsForAgentResume() issued after the first has fully completed must start a " +
            "fresh daemon round-trip, not reuse the launch-time snapshot forever"
        )
    }

    /// Companion regression guard (R10-B item 3): unaffected by the
    /// staleness fix above -- the synchronous `agentResumeSessionsTask
    /// == nil` guard inside fetchSessionsForAgentResume already
    /// prevents a second daemon call while the first is still
    /// in-flight, since both calls happen back-to-back with no `await`
    /// between them, before either Task's body has had a chance to
    /// resolve. Passes both BEFORE and AFTER the R10-B fix; included so
    /// a future change to the dedupe guard cannot silently regress it.
    func test_fetchSessionsForAgentResume_twoCallsWhileUnresolved_dedupeToOneDaemonCall() async {
        SessionSettings.agentResumeEnabled = true
        let client = CountingDaemonClient()
        let appDelegate = AppDelegate()
        appDelegate._sessionDaemonClientForTesting = client

        appDelegate.fetchSessionsForAgentResume()
        appDelegate.fetchSessionsForAgentResume()
        _ = await appDelegate.agentResumeSessionsTask?.value

        XCTAssertEqual(
            client.callCount, 1,
            "Two fetchSessionsForAgentResume() calls issued while the first is still unresolved must collapse " +
            "into exactly one daemon round-trip"
        )
    }
}
