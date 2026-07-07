//
//  AppDelegateSessionRestoreDiskTimeoutTests.swift
//  CalyxTests
//
//  TDD Red phase (save-reliability C3 -- timeout vs. legitimately-empty
//  at the busy-wait sites). ROOT CAUSE: restoreSession() and
//  preserveDiscardedSessionIfAny() (AppDelegate.swift ~1435-1497) each
//  spin the calling thread via `RunLoop.current.run(...)` for a fixed
//  budget (2.0s each) waiting for a `Task` that calls
//  SessionPersistenceActor.shared, then read a captured local `var`
//  (`snapshot`, `didPreserve`) that ONLY gets written if the Task
//  actually completed in time. If the budget elapses first, that local
//  var is simply left at its INITIAL value (nil / false) -- exactly the
//  same value the actor's own CORRECT, FAST completion would also
//  produce for "nothing was ever saved" / "nothing to preserve". Today's
//  code cannot tell "the actor genuinely said no" apart from "we never
//  found out, the call is still in flight".
//
//  Both hardcode SessionPersistenceActor.shared directly -- confirmed by
//  reading: they are the ONLY two call sites in AppDelegate.swift that do
//  NOT already consult the existing `_sessionPersistenceActorForTesting`
//  seam (every other actor call site in the file does).
//
//  WHY THIS MATTERS BEYOND EACH SITE ALONE: both busy-waits, if the
//  SAME underlying actor is genuinely slow (e.g. disk contention), can
//  EACH silently time out -- restoreSession()'s guard already routes a
//  nil snapshot into preserveDiscardedSessionIfAny() today, but that
//  call ALSO races the same possibly-still-stuck actor with its own
//  independent 2.0s budget and can ALSO silently time out with no
//  observable effect (`guard didPreserve else { return }` where
//  didPreserve never got written). Net effect of a genuinely slow actor:
//  NEITHER a restore NOR a preserve happens, and the caller falls
//  through to createNewWindow(), whose first save (once C1 lands) will
//  eventually overwrite sessions.json -- with the ORIGINAL data never
//  having been protected at all. This is strictly worse than either
//  contract's own doc comment describes in isolation.
//
//  THE FIX: distinguish `timedOut` as its own outcome, separate from
//  "the actor completed and said no", at both sites, and inject the
//  actor + the deadline so the timeout branch is genuinely
//  unit-drivable.
//
//  Held-out compile-RED (see SessionCommandSynthesizerRemoteAttachTests's
//  header for this codebase's convention): SessionRestoreDiskOutcome,
//  AppDelegate.attemptSessionRestoreFromDisk(deadline:),
//  SessionPreserveDiskOutcome, and
//  AppDelegate.attemptPreserveDiscardedSessionOnDisk(deadline:) do not
//  exist yet. This file fails to compile until the Green phase adds all
//  four. That compile failure IS this file's RED evidence.
//
//  Proposed API (AppDelegate.swift additions, extracted from
//  restoreSession()'s crash-loop-check + disk-read preamble and
//  preserveDiscardedSessionIfAny()'s body respectively -- mirrors the
//  already-established "pull the undriveable function's testable core
//  into its own method" pattern used for
//  scheduleRecoveryCounterResetAfterStableLaunch(delay:), see
//  AppDelegateRecoveryCounterResetTests's own header):
//
//    enum SessionRestoreDiskOutcome: Equatable {
//        case snapshot(SessionSnapshot)
//        case empty
//        case timedOut
//    }
//
//    func attemptSessionRestoreFromDisk(deadline: TimeInterval = 2.0) -> SessionRestoreDiskOutcome {
//        let actor = _sessionPersistenceActorForTesting ?? SessionPersistenceActor.shared
//        var recoveryCount = 0
//        var snapshot: SessionSnapshot?
//        var done = false
//        let task = Task {
//            recoveryCount = await actor.incrementRecoveryCounter()
//            if recoveryCount <= SessionPersistenceActor.maxRecoveryAttempts {
//                snapshot = await actor.restore()
//            }
//            done = true
//        }
//        let deadlineDate = Date().addingTimeInterval(deadline)
//        while !done, Date() < deadlineDate {
//            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
//        }
//        guard done else {
//            task.cancel()
//            return .timedOut
//        }
//        guard let snapshot else { return .empty }
//        return .snapshot(snapshot)
//    }
//
//    enum SessionPreserveDiskOutcome: Equatable {
//        case preserved
//        case notPreserved
//        case timedOut
//    }
//
//    func attemptPreserveDiscardedSessionOnDisk(deadline: TimeInterval = 2.0) -> SessionPreserveDiskOutcome {
//        let actor = _sessionPersistenceActorForTesting ?? SessionPersistenceActor.shared
//        var didPreserve = false
//        var done = false
//        let task = Task {
//            didPreserve = await actor.preserveSnapshotForRecovery()
//            done = true
//        }
//        let deadlineDate = Date().addingTimeInterval(deadline)
//        while !done, Date() < deadlineDate {
//            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
//        }
//        guard done else {
//            task.cancel()
//            return .timedOut
//        }
//        return didPreserve ? .preserved : .notPreserved
//    }
//
//  restoreSession()/preserveDiscardedSessionIfAny() must then delegate to
//  these (replacing their own inline Task+busy-wait blocks) and switch on
//  `.timedOut` distinctly: restoreSession() on `.timedOut` must still
//  route to preserve+notify (never silently fall through to
//  createNewWindow() as if disk were confirmed empty), and
//  preserveDiscardedSessionIfAny() on `.timedOut` must not claim a
//  recovery file exists when it does not know that for certain.
//
//  TESTING TECHNIQUE: passing `deadline: 0` deterministically forces the
//  `.timedOut` branch WITHOUT needing an artificially slow actor --
//  `Date().addingTimeInterval(0)` is "now", so by the time the `while`
//  condition is first evaluated a few microseconds later, `Date()` has
//  already passed it; the loop body (the only place the Task gets a
//  chance to run, via RunLoop.current.run) never executes even once, so
//  `done` is deterministically still false regardless of how fast the
//  real, temp-dir-backed actor actually is. This is a faithful
//  simulation from the code's own perspective: the code only ever checks
//  `done`, never why it is false.
//
//  WHAT THIS FILE CAN AND CANNOT PIN (unit level): drives both extracted
//  methods directly against a temp-dir-backed SessionPersistenceActor
//  (mirrors AppDelegateRecoveryCounterResetTests' own pattern), so it CAN
//  pin the timedOut/empty/snapshot(_)/preserved/notPreserved outcomes
//  exactly. It CANNOT pin that restoreSession()/preserveDiscardedSessionIfAny()
//  actually delegate to these methods at their call sites -- both remain
//  private and reach GhosttyAppController.shared/real window creation
//  past this preamble (see AppDelegateRecoveryCounterResetTests' own
//  header for the identical constraint). The Green phase implementer and
//  code review must verify that call-site wiring by reading the diff; no
//  test in this file substitutes for that reading.
//
//  Coverage:
//  - attemptSessionRestoreFromDisk: timedOut (deadline 0) is distinct
//    from empty (generous deadline, nothing on disk) and from
//    snapshot(_) (generous deadline, real content on disk)
//  - attemptPreserveDiscardedSessionOnDisk: timedOut (deadline 0) is
//    distinct from notPreserved (generous deadline, nothing on disk) and
//    from preserved (generous deadline, real content on disk -- and the
//    file actually moves, matching preserveSnapshotForRecovery()'s
//    existing contract)
//

import XCTest
@testable import Calyx

@MainActor
final class AppDelegateSessionRestoreDiskTimeoutTests: XCTestCase {

    // MARK: - Fixtures / Helpers

    /// Mirrors AppDelegateRecoveryCounterResetTests.makeSessionDirActor()'s
    /// per-test-method teardown-block convention.
    private func makeSessionDirActor() throws -> SessionPersistenceActor {
        let raw = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppDelegateSessionRestoreDiskTimeoutTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        let dir = raw.resolvingSymlinksInPath()
        setenv("CALYX_UITEST_SESSION_DIR", dir.path, 1)
        addTeardownBlock {
            unsetenv("CALYX_UITEST_SESSION_DIR")
            try? FileManager.default.removeItem(at: dir)
        }
        return SessionPersistenceActor()
    }

    // MARK: - attemptSessionRestoreFromDisk

    func test_attemptSessionRestoreFromDisk_zeroDeadline_returnsTimedOut() throws {
        let actor = try makeSessionDirActor()
        let appDelegate = AppDelegate()
        appDelegate._sessionPersistenceActorForTesting = actor

        let outcome = appDelegate.attemptSessionRestoreFromDisk(deadline: 0)

        XCTAssertEqual(outcome, .timedOut,
                       "a zero deadline must never be reported as .empty -- the actor call never " +
                       "had a chance to complete, so the caller must not treat this as confirmation " +
                       "that disk genuinely holds nothing")
    }

    func test_attemptSessionRestoreFromDisk_generousDeadline_nothingOnDisk_returnsEmpty() throws {
        let actor = try makeSessionDirActor()
        let appDelegate = AppDelegate()
        appDelegate._sessionPersistenceActorForTesting = actor

        let outcome = appDelegate.attemptSessionRestoreFromDisk(deadline: 2.0)

        XCTAssertEqual(outcome, .empty,
                       "a fast actor with nothing ever saved must report .empty, distinct from " +
                       ".timedOut")
    }

    func test_attemptSessionRestoreFromDisk_generousDeadline_realSnapshotOnDisk_returnsSnapshot() async throws {
        let actor = try makeSessionDirActor()
        let windowID = UUID()
        let saved = SessionSnapshot(windows: [WindowSnapshot(id: windowID, frame: CGRect(x: 0, y: 0, width: 800, height: 600))])
        await actor.saveImmediately(saved)

        let appDelegate = AppDelegate()
        appDelegate._sessionPersistenceActorForTesting = actor

        let outcome = appDelegate.attemptSessionRestoreFromDisk(deadline: 2.0)

        XCTAssertEqual(outcome, .snapshot(SessionSnapshot.migrate(saved)),
                       "a fast actor with real content on disk must report .snapshot(_) with that " +
                       "exact content")
    }

    // MARK: - attemptPreserveDiscardedSessionOnDisk

    func test_attemptPreserveDiscardedSessionOnDisk_zeroDeadline_returnsTimedOut() throws {
        let actor = try makeSessionDirActor()
        let appDelegate = AppDelegate()
        appDelegate._sessionPersistenceActorForTesting = actor

        let outcome = appDelegate.attemptPreserveDiscardedSessionOnDisk(deadline: 0)

        XCTAssertEqual(outcome, .timedOut,
                       "a zero deadline must never be reported as .notPreserved -- the actor call " +
                       "never had a chance to complete, so the caller must not claim to know disk " +
                       "held nothing worth preserving")
    }

    func test_attemptPreserveDiscardedSessionOnDisk_generousDeadline_nothingOnDisk_returnsNotPreserved() throws {
        let actor = try makeSessionDirActor()
        let appDelegate = AppDelegate()
        appDelegate._sessionPersistenceActorForTesting = actor

        let outcome = appDelegate.attemptPreserveDiscardedSessionOnDisk(deadline: 2.0)

        XCTAssertEqual(outcome, .notPreserved,
                       "a fast actor with nothing on disk to preserve must report .notPreserved, " +
                       "distinct from .timedOut")
    }

    func test_attemptPreserveDiscardedSessionOnDisk_generousDeadline_realSnapshotOnDisk_returnsPreservedAndMovesFile() async throws {
        let actor = try makeSessionDirActor()
        let windowID = UUID()
        let saved = SessionSnapshot(windows: [WindowSnapshot(id: windowID, frame: CGRect(x: 0, y: 0, width: 800, height: 600))])
        await actor.saveImmediately(saved)
        let savePath = await actor.sessionSavePath()
        XCTAssertTrue(FileManager.default.fileExists(atPath: savePath.path),
                     "precondition: the snapshot must actually be on disk before attempting to preserve it")

        let appDelegate = AppDelegate()
        appDelegate._sessionPersistenceActorForTesting = actor

        let outcome = appDelegate.attemptPreserveDiscardedSessionOnDisk(deadline: 2.0)

        XCTAssertEqual(outcome, .preserved,
                       "a fast actor with real content on disk must report .preserved")
        let hasPreserved = await actor.hasPreservedSnapshot()
        XCTAssertTrue(hasPreserved, "a .preserved outcome must correspond to an actual recovery file on disk")
        XCTAssertFalse(FileManager.default.fileExists(atPath: savePath.path),
                       "preserving must move the original file away from savePath, matching " +
                       "preserveSnapshotForRecovery()'s existing contract")
    }
}
