//
//  SessionBrowserModelRefreshCancellationGuardTests.swift
//  CalyxTests
//
//  TDD Red phase, round 14 (r14-fix-spec.md SWEEP ADDENDA item 1, "RED-F"
//  per the team-lead's round-14 addendum message): SessionBrowserModel
//  .refresh() awaits `daemonClient.listAllBounded()` and then
//  unconditionally overwrites `rows` with whatever it returns -- there
//  is no `Task.isCancelled` guard before that assignment (mirroring the
//  guard AppDelegate.listAllSessionsBounded already has, R12-A item 4).
//  A closed-window poll cancellation racing a still-in-flight daemon
//  round-trip therefore wipes the SHARED model's rows with a stale
//  result the instant that round-trip eventually resolves -- an empty
//  flash on reopen. This reproduces TODAY, independent of whether R14-A
//  has landed yet: cooperative cancellation never stops an async
//  function's execution by itself, so once the fake's listAll() call
//  resolves (here, via this test's own explicit resume -- the exact
//  mechanism `bounded()`'s internal race already uses to let the winning
//  arm complete regardless of what the OUTER caller's Task does), a
//  cancelled refresh() keeps running to completion and reaches the
//  unconditional `rows = ...` assignment exactly as if it had never been
//  cancelled. R14-A's propagation (once landed) only changes how SOON a
//  cancelled refresh's daemon round-trip resolves, not whether the
//  missing guard here lets a late one still land -- so this guard is
//  needed regardless of R14-A's landing order.
//
//  Populates `rows` with a real, distinguishable baseline via a first,
//  fully-resolved refresh() call, starts a SECOND refresh() whose Task
//  is cancelled while its daemon round-trip is confirmed in flight, then
//  resolves that round-trip with a different ([]) payload -- mirroring
//  SessionBrowserModelRefreshDedupeTests' suspend-then-resume-explicitly
//  fixture style (duplicated here per this codebase's established
//  per-file fixture-duplication convention).
//
//  Coverage:
//  - A cancelled refresh() must not overwrite rows with a result that
//    arrives after cancellation (RED today: rows is wiped to [] anyway)
//

import XCTest
@testable import Calyx

/// Suspends every `listAll()` call on a continuation this test resumes
/// explicitly via `resumeAllPending(with:)`, letting the assertion
/// control exactly when (and with what payload) each in-flight refresh()
/// resolves -- no reliance on wall-clock timing.
private final class SuspendingSessionDaemonClient: SessionDaemonClientProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var pendingContinuations: [CheckedContinuation<[SessionInfo], Never>] = []

    var pendingCount: Int {
        lock.lock(); defer { lock.unlock() }
        return pendingContinuations.count
    }

    func sessionState(id: String) async -> SessionQueryResult { .unreachable }
    func kill(id: String) async {}

    func listAll() async -> [SessionInfo] {
        await withCheckedContinuation { (continuation: CheckedContinuation<[SessionInfo], Never>) in
            self.lock.lock()
            self.pendingContinuations.append(continuation)
            self.lock.unlock()
        }
    }

    /// Resumes every currently-suspended `listAll()` call with `sessions`.
    func resumeAllPending(with sessions: [SessionInfo]) {
        lock.lock()
        let pending = pendingContinuations
        pendingContinuations.removeAll()
        lock.unlock()
        for continuation in pending {
            continuation.resume(returning: sessions)
        }
    }
}

@MainActor
final class SessionBrowserModelRefreshCancellationGuardTests: XCTestCase {

    /// Cooperatively yields until `condition()` is true, bounded by
    /// `maxYields` as a safety valve, mirroring
    /// SessionBrowserModelRefreshDedupeTests' own `waitUntil` helper.
    private func waitUntil(maxYields: Int = 10_000, _ condition: () -> Bool) async {
        var iterations = 0
        while !condition(), iterations < maxYields {
            await Task.yield()
            iterations += 1
        }
    }

    private func makeInfo(id: String, state: SessionLifecycleState) -> SessionInfo {
        SessionInfo(
            id: id, name: nil, cwd: nil, state: state,
            createdAtMs: 0, attachedClients: state == .running ? 1 : 0, pid: 0, meta: [:]
        )
    }

    /// RED (R14-A sweep addendum item 1 / "RED-F"): a refresh() whose
    /// Task is cancelled while its daemon round-trip is still in flight
    /// must not let that round-trip's eventual result overwrite rows --
    /// today it does, because refresh() never checks Task.isCancelled
    /// before assigning to `rows`.
    func test_cancelledRefresh_doesNotOverwriteRows() async {
        let client = SuspendingSessionDaemonClient()
        let surfaceMap = SessionSurfaceMap()
        let model = SessionBrowserModel(daemonClient: client, surfaceMap: surfaceMap)

        // Establish a known, non-empty baseline via a first refresh()
        // that resolves normally (never cancelled).
        let baseline = [makeInfo(id: "existing-session", state: .running)]
        let firstRefresh = Task { await model.refresh() }
        await waitUntil { client.pendingCount >= 1 }
        client.resumeAllPending(with: baseline)
        _ = await firstRefresh.value

        XCTAssertEqual(
            model.rows.map(\.id), ["existing-session"],
            "Precondition: rows must be populated with the baseline before the cancellation below"
        )

        // A second refresh() -- e.g. the browser's 1s poll timer, or a
        // just-closed window's final tick -- whose Task is cancelled
        // while its own daemon round-trip is confirmed in flight.
        let secondRefresh = Task { await model.refresh() }
        await waitUntil { client.pendingCount >= 1 }
        secondRefresh.cancel()

        // Let that round-trip resolve anyway, with a DIFFERENT ([])
        // payload -- reproducing the "result arrives after the caller
        // gave up" race regardless of how soon cancellation propagates.
        client.resumeAllPending(with: [])
        _ = await secondRefresh.value

        XCTAssertEqual(
            model.rows.map(\.id), ["existing-session"],
            "A cancelled refresh() must not overwrite rows with a stale result that arrives after cancellation"
        )
    }
}
