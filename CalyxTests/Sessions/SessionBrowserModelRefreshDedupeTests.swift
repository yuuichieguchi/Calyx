//
//  SessionBrowserModelRefreshDedupeTests.swift
//  CalyxTests
//
//  TDD Red phase, round 12 (r12-fix-spec.md, R12-A item 3):
//  SessionBrowserModel.refresh() has no in-flight guard, so a second
//  refresh() issued while a previous one is still awaiting the daemon
//  round-trip (listAllBounded()) starts a second, fully overlapping
//  daemon call instead of reusing the first's outstanding one. On the
//  session browser's 1s poll timer this stacks an unbounded number of
//  concurrent daemon round-trips behind a slow/hung calyx-session
//  daemon instead of naturally backing off to the bound's own cadence.
//
//  Drives SessionBrowserModel.refresh() directly against a fake
//  SessionDaemonClientProtocol whose listAll() suspends on a
//  continuation this test controls explicitly, letting the assertion
//  observe the in-flight call count deterministically -- no reliance on
//  wall-clock timing. Note listAllBounded() (the method refresh() calls
//  the daemon through) is a SessionDaemonClientProtocol extension
//  default, so it always races the fake's listAll() against its own
//  5s bound rather than being independently overridable per fake; as
//  long as the fake's listAll() resolves well inside 5s (which
//  resumeAllPending() below drives explicitly), the daemon arm wins the
//  race and this test never depends on that bound actually elapsing.
//
//  Coverage:
//  - Two refresh() calls issued back-to-back, the second while the
//    first is still awaiting the daemon, must collapse to exactly ONE
//    in-flight daemon round-trip (RED: today each call fires its own,
//    so the count reaches 2)
//

import XCTest
@testable import Calyx

/// Records every `listAll()` invocation and suspends each one on a
/// continuation the test resumes explicitly via `resumeAllPending()` --
/// a process boundary stand-in, no real `calyx-session` binary
/// involved. Not shared with `SessionBrowserModelTests`' own fake,
/// matching this codebase's established per-file fixture-duplication
/// convention (see `AppDelegateAgentResumeStalenessTests`).
private final class SuspendingCountingDaemonClient: SessionDaemonClientProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var _callCount = 0
    private var pendingContinuations: [CheckedContinuation<[SessionInfo], Never>] = []

    var callCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _callCount
    }

    func sessionState(id: String) async -> SessionQueryResult { .unreachable }
    func kill(id: String) async {}

    /// `NSLock.lock()`/`unlock()` are unavailable at the top level of an
    /// `async` function body under this toolchain's Swift 6 diagnostics
    /// (async-unsafe scoped locking), so the increment is a plain
    /// synchronous helper `listAll()` calls into instead of locking
    /// inline.
    private func incrementCallCount() {
        lock.lock(); defer { lock.unlock() }
        _callCount += 1
    }

    private func addPendingContinuation(_ continuation: CheckedContinuation<[SessionInfo], Never>) {
        lock.lock(); defer { lock.unlock() }
        pendingContinuations.append(continuation)
    }

    func listAll() async -> [SessionInfo] {
        incrementCallCount()
        return await withCheckedContinuation { (continuation: CheckedContinuation<[SessionInfo], Never>) in
            addPendingContinuation(continuation)
        }
    }

    /// Resumes every `listAll()` call currently suspended with an empty
    /// ledger, unblocking any in-flight `refresh()`'s awaited daemon
    /// round-trip so the test can drain both Tasks to completion.
    func resumeAllPending() {
        lock.lock()
        let pending = pendingContinuations
        pendingContinuations.removeAll()
        lock.unlock()
        for continuation in pending {
            continuation.resume(returning: [])
        }
    }
}

@MainActor
final class SessionBrowserModelRefreshDedupeTests: XCTestCase {

    /// Cooperatively yields until `condition()` is true, bounded by
    /// `maxYields` as a safety valve against a genuinely stuck
    /// condition -- not a wall-clock wait, just an upper bound on how
    /// many scheduler turns we're willing to hand back before giving up
    /// and letting the assertion below fail with the real count.
    private func waitUntil(maxYields: Int = 10_000, _ condition: () -> Bool) async {
        var iterations = 0
        while !condition(), iterations < maxYields {
            await Task.yield()
            iterations += 1
        }
    }

    /// Primary RED-proving assertion (R12-A item 3): against the
    /// CURRENT code, `refresh()` has no in-flight guard, so a second
    /// call issued while the first is still awaiting the daemon starts
    /// its own, fully overlapping `listAll()` round-trip.
    func test_refresh_secondCallWhileFirstInFlight_dedupesToOneDaemonCall() async {
        let client = SuspendingCountingDaemonClient()
        let surfaceMap = SessionSurfaceMap()
        let model = SessionBrowserModel(daemonClient: client, surfaceMap: surfaceMap)

        let firstRefresh = Task { await model.refresh() }
        // Let the first refresh() actually reach the daemon call before
        // firing the second, so the second call is provably issued
        // while the first is in flight, not merely racing its start.
        await waitUntil { client.callCount >= 1 }

        let secondRefresh = Task { await model.refresh() }
        // Give the second refresh() every opportunity to reach its own
        // daemon call too, so a would-be second round-trip has had a
        // fair chance to fire before we assert.
        for _ in 0..<50 { await Task.yield() }

        XCTAssertEqual(
            client.callCount, 1,
            "A second refresh() issued while the first is still awaiting the daemon must not start an " +
            "overlapping round-trip -- refresh() needs an in-flight guard"
        )

        client.resumeAllPending()
        _ = await firstRefresh.value
        _ = await secondRefresh.value
    }
}
