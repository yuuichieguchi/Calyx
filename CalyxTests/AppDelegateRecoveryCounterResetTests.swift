//
//  AppDelegateRecoveryCounterResetTests.swift
//  CalyxTests
//
//  TDD Red phase (session-restore fix, Bug 1 -- crash-loop counter never
//  resets on a healthy "nothing to restore" launch). ROOT CAUSE:
//  AppDelegate.restoreSession() (AppDelegate.swift ~1059-1112) increments
//  SessionPersistenceActor's on-disk recovery counter on EVERY launch
//  (incrementRecoveryCounter()), but only schedules the delayed 5s reset
//  (resetRecoveryCounter(), confirming the launch was actually stable) on
//  the FULL-SUCCESS tail of the function, right before `return true`. A
//  launch with nothing to restore (`guard let snapshot, !snapshot.windows
//  .isEmpty else { ... return false }`) takes an early return and never
//  reaches that reset scheduling. Every healthy "no session yet" launch
//  therefore leaves the counter incremented forever; it accumulates
//  across ordinary daily use until it exceeds
//  SessionPersistenceActor.maxRecoveryAttempts (3), and the very next
//  launch that DOES have a real session to restore is misclassified as
//  a crash loop and silently discards it (the snapshot is read, but
//  restoreSession() refuses to act on it) -- the user's tabs become
//  orphaned daemon sessions with no window ever attaching to them.
//
//  THE FIX: any launch that survives the post-launch stability window
//  must reset the counter, regardless of what restoreSession() actually
//  found or did (nothing to restore, full restore, partial restore, or
//  even the crash-loop-detected branch itself -- letting the counter
//  self-heal from a false-positive detection). A genuinely crashing app
//  never lives past the delay, so crash-loop protection is unaffected.
//  This requires extracting the reset scheduling out of restoreSession()'s
//  success-only tail into its own method, called unconditionally once
//  per restoreSession() invocation.
//
//  Held-out compile-RED (see SessionCommandSynthesizerRemoteAttachTests's
//  header for this codebase's convention): AppDelegate
//  .scheduleRecoveryCounterResetAfterStableLaunch(delay:) and the
//  DEBUG-only test seam _sessionPersistenceActorForTesting do not exist
//  yet. This file fails to compile until the Green phase adds both. That
//  compile failure IS this file's RED evidence.
//
//  Proposed API (AppDelegate.swift additions):
//
//    #if DEBUG
//    /// Test seam: overrides the SessionPersistenceActor instance
//    /// scheduleRecoveryCounterResetAfterStableLaunch(delay:) resets,
//    /// instead of SessionPersistenceActor.shared. DO NOT use from
//    /// production code.
//    var _sessionPersistenceActorForTesting: SessionPersistenceActor?
//    #endif
//
//    /// Schedules a delayed reset of the crash-loop recovery counter,
//    /// confirming this launch survived `delay` before declaring it
//    /// stable. Called exactly once per restoreSession() invocation,
//    /// unconditionally -- independent of whether anything was restored
//    /// -- so every launch that stays up long enough eventually resets
//    /// the counter. A launch that crashes before `delay` elapses never
//    /// runs this Task's body, so the counter is left incremented for
//    /// the crash-loop detector exactly as today.
//    func scheduleRecoveryCounterResetAfterStableLaunch(delay: Duration = .seconds(5)) {
//        let actor = _sessionPersistenceActorForTesting ?? SessionPersistenceActor.shared
//        Task {
//            try? await Task.sleep(for: delay)
//            await actor.resetRecoveryCounter()
//        }
//    }
//
//  restoreSession() itself must then call this once, unconditionally,
//  right after the crash-loop increment/restore-attempt Task completes
//  (replacing the existing reset-scheduling block currently inlined only
//  in the success tail at AppDelegate.swift ~1105-1109).
//
//  WHAT THIS FILE CAN AND CANNOT PIN (unit level): this file drives
//  scheduleRecoveryCounterResetAfterStableLaunch(delay:) directly against
//  a fresh SessionPersistenceActor pointed at a temp dir
//  (CALYX_UITEST_SESSION_DIR, this codebase's existing actor-init test
//  seam -- see SessionPersistenceTests.test_persistence_actor_save_path's
//  identical pattern), with a short injected delay so it CAN pin that the
//  extracted method itself correctly performs a DELAYED (not immediate)
//  reset regardless of the counter's starting value, including a value
//  already past maxRecoveryAttempts. It CANNOT pin that restoreSession()
//  actually calls this method on every one of its return paths --
//  restoreSession() is private and, once past its own crash-loop guard,
//  reaches GhosttyAppController.shared and real window/surface creation
//  (per AppDelegateApplyGhosttyResourcesDirEnvironmentTests's own
//  precedent for why that hangs this test host). The Green phase
//  implementer and code review must verify restoreSession()'s call-site
//  wiring by reading the diff; no test in this file substitutes for that
//  reading.
//
//  Coverage:
//  - reset does not happen before the injected delay elapses (rules out
//    an implementation that resets synchronously/immediately)
//  - reset happens after the injected delay elapses, from a counter value
//    below maxRecoveryAttempts
//  - reset happens after the injected delay elapses, from a counter value
//    ALREADY past maxRecoveryAttempts (the self-healing case a
//    misclassified crash loop needs)
//

import XCTest
@testable import Calyx

@MainActor
final class AppDelegateRecoveryCounterResetTests: XCTestCase {

    /// Creates a fresh temp-dir-backed SessionPersistenceActor, isolated
    /// from any other test/actor instance. Mirrors
    /// AppDelegateApplyGhosttyResourcesDirEnvironmentTests.makeTempDir()'s
    /// per-test-method (not setUp/tearDown) teardown-block convention --
    /// setUpWithError/tearDownWithError override XCTestCase's nonisolated
    /// requirements and so cannot touch this @MainActor class's isolated
    /// state directly.
    private func makeSessionDirActor() throws -> SessionPersistenceActor {
        let raw = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppDelegateRecoveryCounterResetTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        let dir = raw.resolvingSymlinksInPath()
        setenv("CALYX_UITEST_SESSION_DIR", dir.path, 1)
        addTeardownBlock {
            unsetenv("CALYX_UITEST_SESSION_DIR")
            try? FileManager.default.removeItem(at: dir)
        }
        return SessionPersistenceActor()
    }

    private func incrementCounter(_ actor: SessionPersistenceActor, times: Int) async {
        for _ in 0..<times {
            _ = await actor.incrementRecoveryCounter()
        }
    }

    func test_scheduleReset_doesNotResetBeforeDelayElapses() async throws {
        let actor = try makeSessionDirActor()
        await incrementCounter(actor, times: 1)
        let appDelegate = AppDelegate()
        appDelegate._sessionPersistenceActorForTesting = actor

        appDelegate.scheduleRecoveryCounterResetAfterStableLaunch(delay: .milliseconds(300))

        try await Task.sleep(for: .milliseconds(50))
        let countBeforeDelayElapses = await actor.currentRecoveryCount()
        XCTAssertEqual(countBeforeDelayElapses, 1,
                      "the reset must not fire before the injected delay has actually elapsed")
    }

    func test_scheduleReset_resetsAfterDelay_fromBelowMaxAttempts() async throws {
        let actor = try makeSessionDirActor()
        await incrementCounter(actor, times: 1)
        let appDelegate = AppDelegate()
        appDelegate._sessionPersistenceActorForTesting = actor

        appDelegate.scheduleRecoveryCounterResetAfterStableLaunch(delay: .milliseconds(50))

        try await Task.sleep(for: .milliseconds(400))
        let countAfterDelayElapses = await actor.currentRecoveryCount()
        XCTAssertEqual(countAfterDelayElapses, 0,
                      "a launch stable past the delay must reset the counter even when nothing needed restoring")
    }

    func test_scheduleReset_resetsAfterDelay_evenWhenAlreadyPastMaxAttempts() async throws {
        let actor = try makeSessionDirActor()
        // Simulate the exact bug scenario: several healthy no-op launches
        // already pushed the counter past maxRecoveryAttempts.
        await incrementCounter(actor, times: SessionPersistenceActor.maxRecoveryAttempts + 2)
        let stuckCount = await actor.currentRecoveryCount()
        XCTAssertGreaterThan(stuckCount, SessionPersistenceActor.maxRecoveryAttempts,
                            "precondition: the counter must actually be past the crash-loop threshold")

        let appDelegate = AppDelegate()
        appDelegate._sessionPersistenceActorForTesting = actor

        appDelegate.scheduleRecoveryCounterResetAfterStableLaunch(delay: .milliseconds(50))

        try await Task.sleep(for: .milliseconds(400))
        let countAfterDelayElapses = await actor.currentRecoveryCount()
        XCTAssertEqual(countAfterDelayElapses, 0,
                      "a stable launch must self-heal the counter even from a value already past maxRecoveryAttempts")
    }
}
