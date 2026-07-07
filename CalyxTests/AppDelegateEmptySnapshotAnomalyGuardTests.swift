//
//  AppDelegateEmptySnapshotAnomalyGuardTests.swift
//  CalyxTests
//
//  TDD Red phase (save-reliability C4 -- empty-snapshot-plus-running-
//  sessions anomaly guard). CONTEXT: with close=kill semantics
//  (CalyxWindowController.killSessionIfPersistent, wired from
//  windowWillClose's non-terminating teardown path), a user who
//  deliberately closes every window before quitting has already killed
//  every persistent session by the time the app actually terminates --
//  so a genuinely empty on-disk snapshot from a DELIBERATE all-closed
//  quit should never coexist with the daemon still reporting a RUNNING
//  persistent session. If it does, the empty snapshot is much more
//  likely the product of a bug/race (this cycle's own live incident: 3
//  windows genuinely open, sessions.json read back as {"windows":[]})
//  than a deliberate close-everything-then-quit. restoreSession()'s
//  existing empty-snapshot branch (AppDelegate.swift ~1485-1491) treats
//  every decoded-empty snapshot identically ("the user deliberately
//  closed every window... not a loss to recover from") and neither
//  preserves nor notifies -- it has no way to distinguish the anomalous
//  case at all today.
//
//  THE FIX: give restoreSession() a way to check whether the daemon's
//  ledger currently shows a running persistent session, so its
//  empty-snapshot branch can route through preserve+notify instead of
//  silently accepting the empty snapshot when that combination is
//  detected.
//
//  SCOPE BOUNDARY (do not re-litigate): this file does NOT touch
//  SessionDaemonClientProtocol.listAllBounded()'s own bounded/timeout
//  machinery, nor AppDelegate.listAllSessionsBounded(client:) itself --
//  both stay exactly as they are today. The new method below only CALLS
//  listAllSessionsBounded(client:), exactly the same way
//  fetchSessionsForAgentResume() already does, reusing its existing
//  bounded, best-effort, non-blocking contract as-is: a probe failure
//  (daemon unreachable, timeout) surfaces as an empty ledger from that
//  existing method, which this file's method already treats as "no
//  evidence of an anomaly" -- current, unchanged behavior for that case,
//  not a new failure mode requiring its own test.
//
//  Held-out compile-RED (see SessionCommandSynthesizerRemoteAttachTests's
//  header for this codebase's convention):
//  AppDelegate.hasRunningPersistentSessions() does not exist yet. This
//  file fails to compile until the Green phase adds it. That compile
//  failure IS this file's RED evidence.
//
//  Proposed API (AppDelegate.swift addition, alongside
//  fetchSessionsForAgentResume()'s existing
//  `_sessionDaemonClientForTesting ?? SessionDaemonClient.shared` seam):
//
//    /// True when the daemon's ledger currently reports at least one
//    /// RUNNING persistent session. Reuses listAllSessionsBounded(client:)
//    /// exactly as fetchSessionsForAgentResume() already does -- bounded,
//    /// best-effort; a probe failure (daemon unreachable/timeout)
//    /// surfaces as an empty ledger, which this method treats as "no
//    /// evidence of any anomaly" (current, unchanged behavior for that
//    /// case). Consulted by restoreSession()'s empty-snapshot branch: with
//    /// close=kill semantics, a genuinely empty snapshot from a
//    /// deliberate "closed every window" quit should never coexist with
//    /// a still-running persistent session.
//    func hasRunningPersistentSessions() async -> Bool {
//        #if DEBUG
//        let client = _sessionDaemonClientForTesting ?? SessionDaemonClient.shared
//        #else
//        let client = SessionDaemonClient.shared
//        #endif
//        let sessions = await AppDelegate.listAllSessionsBounded(client: client)
//        return sessions.values.contains { session in
//            if case .running = session.state { return true }
//            return false
//        }
//    }
//
//  restoreSession()'s empty-snapshot branch (~1485-1491) must then
//  consult this (necessarily via its own busy-wait treatment, since
//  restoreSession() itself is synchronous -- mirrors this file's sibling
//  C3 fix's exact shape) and route to preserveDiscardedSessionIfAny() +
//  notifyPreviousSessionNotRestored() when true, instead of silently
//  returning false. restoreSession() itself remains private and reaches
//  GhosttyAppController.shared/real window creation past this preamble
//  (see AppDelegateRecoveryCounterResetTests' own header for the
//  identical constraint), so that wiring is Green-phase-only, verified by
//  code review, exactly like this cycle's other three contracts.
//
//  Coverage:
//  - a ledger containing a Running session reports true
//  - a ledger containing only Exited sessions reports false (Exited
//    entries never get pruned from the daemon's own ledger -- see
//    SessionBrowserModelTests' own header -- so this distinction must
//    hold even when Exited entries are mixed in)
//  - an empty ledger (nothing returned, or client unreachable) reports
//    false -- the "no evidence of an anomaly" default this method must
//    NOT confuse with "confirmed no running sessions"; both currently
//    resolve to `false` here (see the SCOPE BOUNDARY note above for why
//    this file does not attempt to distinguish them further)
//

import XCTest
@testable import Calyx

/// Records the canned ledger this fake replays for listAll() -- mirrors
/// SessionBrowserModelTests' FakeBrowserDaemonClient exactly (only
/// listAll()/sessionState(id:)/kill(id:) need real bodies; every other
/// SessionDaemonClientProtocol requirement, including listAllBounded()
/// itself, comes from the untouched protocol extension default).
private final class FakeAnomalyGuardDaemonClient: SessionDaemonClientProtocol, @unchecked Sendable {
    var sessionsToReturn: [SessionInfo] = []

    func sessionState(id: String) async -> SessionQueryResult { .unreachable }
    func kill(id: String) async {}
    func listAll() async -> [SessionInfo] { sessionsToReturn }
}

@MainActor
final class AppDelegateEmptySnapshotAnomalyGuardTests: XCTestCase {

    private func makeInfo(id: String, state: SessionLifecycleState) -> SessionInfo {
        SessionInfo(
            id: id, name: nil, cwd: nil, state: state,
            createdAtMs: 0, attachedClients: 0, pid: 0, meta: [:]
        )
    }

    // MARK: - Running session present

    func test_hasRunningPersistentSessions_ledgerHasARunningSession_returnsTrue() async {
        let client = FakeAnomalyGuardDaemonClient()
        client.sessionsToReturn = [makeInfo(id: "s1", state: .running)]
        let appDelegate = AppDelegate()
        appDelegate._sessionDaemonClientForTesting = client

        let result = await appDelegate.hasRunningPersistentSessions()

        XCTAssertTrue(result,
                     "a ledger containing a Running session must report true -- this is the exact " +
                     "anomaly (empty on-disk snapshot alongside a still-running persistent session) " +
                     "restoreSession()'s empty-snapshot branch must detect")
    }

    // MARK: - Only exited sessions present

    func test_hasRunningPersistentSessions_ledgerHasOnlyExitedSessions_returnsFalse() async {
        let client = FakeAnomalyGuardDaemonClient()
        client.sessionsToReturn = [
            makeInfo(id: "s1", state: .exited(code: 0)),
            makeInfo(id: "s2", state: .exited(code: 1)),
        ]
        let appDelegate = AppDelegate()
        appDelegate._sessionDaemonClientForTesting = client

        let result = await appDelegate.hasRunningPersistentSessions()

        XCTAssertFalse(result,
                       "a ledger containing only Exited sessions must report false, even though the " +
                       "daemon's ledger never prunes Exited entries on its own -- a genuinely all-closed " +
                       "quit leaves exactly this shape (every session it once ran, none of them Running)")
    }

    // MARK: - Empty ledger

    func test_hasRunningPersistentSessions_emptyLedger_returnsFalse() async {
        let client = FakeAnomalyGuardDaemonClient()
        client.sessionsToReturn = []
        let appDelegate = AppDelegate()
        appDelegate._sessionDaemonClientForTesting = client

        let result = await appDelegate.hasRunningPersistentSessions()

        XCTAssertFalse(result,
                       "an empty ledger (nothing ever recorded, or the probe otherwise came back " +
                       "empty) must report false -- no evidence of an anomaly")
    }
}
