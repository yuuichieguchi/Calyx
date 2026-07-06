//
//  SessionPersistenceActorPreserveFirstWinsTests.swift
//  CalyxTests
//
//  TDD Red phase (recovery-feature code review, WARNING F3 -- a second
//  consecutive bad launch silently discards the still-unrecovered
//  earlier preserved session). ROOT CAUSE:
//  SessionPersistenceActor.preserveSnapshotForRecovery() unconditionally
//  does `try? FileManager.default.removeItem(at: recoverySnapshotPath)`
//  before moving the new on-disk file in, with no check for whether a
//  preserved file is already there. If the user never acted on the
//  first preserved snapshot (missed/ignored the notification) and a
//  second skipped/failed restore happens on the next launch, the first
//  preserved session is permanently destroyed -- only the MOST RECENT
//  bad launch is ever recoverable, even though the FIRST one is the
//  more valuable session (it is the last snapshot taken before whatever
//  started going wrong; everything preserved after it is a state of an
//  already-broken run).
//
//  THE FIX: preserveSnapshotForRecovery() becomes first-wins. When
//  recoverySnapshotPath already holds a file, KEEP it untouched instead
//  of overwriting -- do not move the new savePath content in at all.
//  savePath itself is deliberately left as-is in that branch (not
//  deleted): it holds nothing that is preserved anywhere else, but this
//  run's own subsequent saves will rewrite it regardless, so removing it
//  here would be gratuitous file I/O with no data-safety benefit. The
//  method's Bool return must stay true whenever a preserved file exists
//  after the call -- whether newly moved in THIS call or already present
//  from an earlier one -- so the existing AppDelegate caller
//  (preserveDiscardedSessionIfAny(), which gates
//  hasPreservedSessionSnapshot = true and the user notification on this
//  return value) keeps firing exactly as before; only the FILE CONTENT
//  behavior changes, not the caller-visible signal.
//
//  No new API surface: preserveSnapshotForRecovery() already exists and
//  already returns Bool (SessionPersistenceActorRecoveryPreservationTests,
//  this same round). This file's RED evidence is therefore an assertion
//  FAILURE at runtime (the second preserve currently overwrites the
//  first), not a compile failure.
//
//  Proposed implementation (SessionPersistenceActor.swift, replacing the
//  current unconditional remove-then-move body):
//
//    @discardableResult
//    func preserveSnapshotForRecovery() -> Bool {
//        guard FileManager.default.fileExists(atPath: savePath.path) else { return false }
//        guard !FileManager.default.fileExists(atPath: recoverySnapshotPath.path) else {
//            // First-wins (F3): an earlier, still-unrecovered preserved
//            // session is more valuable than this run's own (also
//            // broken) on-disk state. savePath is left as-is; this run's
//            // own subsequent saves will rewrite it regardless.
//            return true
//        }
//        try? FileManager.default.moveItem(at: savePath, to: recoverySnapshotPath)
//        return true
//    }
//
//  Coverage:
//  - two consecutive preserves with different on-disk contents: the
//    preserved file still holds the FIRST call's content after the
//    second call, and the second call's Bool return is still true
//  - the second call's on-disk savePath content is left in place (not
//    deleted), matching the "no data-safety benefit to removing it"
//    rationale above
//  - the ordinary single-preserve path (nothing preserved yet) is
//    unaffected: still moves the file and returns true (regression guard
//    against this file's fix accidentally changing the happy path
//    already pinned by SessionPersistenceActorRecoveryPreservationTests)
//

import XCTest
@testable import Calyx

final class SessionPersistenceActorPreserveFirstWinsTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionPersistenceActorPreserveFirstWinsTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDir = dir.resolvingSymlinksInPath()
        setenv("CALYX_UITEST_SESSION_DIR", tempDir.path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("CALYX_UITEST_SESSION_DIR")
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        tempDir = nil
        try super.tearDownWithError()
    }

    private func makeNonEmptySnapshot(windowID: UUID = UUID()) -> SessionSnapshot {
        SessionSnapshot(windows: [WindowSnapshot(id: windowID, frame: CGRect(x: 0, y: 0, width: 800, height: 600))])
    }

    // MARK: - First-wins: the second preserve must not destroy the first

    func test_secondPreserve_withExistingPreservedSnapshot_keepsFirstContent_returnsTrueBothTimes() async throws {
        let actor = SessionPersistenceActor()
        let firstWindowID = UUID()
        await actor.saveImmediately(makeNonEmptySnapshot(windowID: firstWindowID))

        let firstReturn = await actor.preserveSnapshotForRecovery()
        XCTAssertTrue(firstReturn, "the first preserve must report a preserved file now exists")
        let preservedAfterFirst = await actor.loadPreservedSnapshot()
        XCTAssertEqual(preservedAfterFirst?.windows.first?.id, firstWindowID,
                       "precondition: the first preserve must actually hold the first snapshot's content")

        // Simulate a second, later bad launch: a different snapshot ends
        // up on disk before THIS launch's own preserve call fires.
        let secondWindowID = UUID()
        await actor.saveImmediately(makeNonEmptySnapshot(windowID: secondWindowID))

        let secondReturn = await actor.preserveSnapshotForRecovery()
        XCTAssertTrue(secondReturn,
                      "the Bool must stay true whenever a preserved file exists after the call, even when " +
                      "nothing was newly moved -- the caller's notify+flag wiring must keep firing")

        let preservedAfterSecond = await actor.loadPreservedSnapshot()
        XCTAssertEqual(preservedAfterSecond?.windows.first?.id, firstWindowID,
                       "first-wins: the SECOND preserve must not overwrite the still-unrecovered FIRST " +
                       "preserved session with the second (also broken) run's content")
    }

    func test_secondPreserve_withExistingPreservedSnapshot_leavesSecondRunsSavePathInPlace() async throws {
        let actor = SessionPersistenceActor()
        await actor.saveImmediately(makeNonEmptySnapshot())
        await actor.preserveSnapshotForRecovery()

        let secondWindowID = UUID()
        await actor.saveImmediately(makeNonEmptySnapshot(windowID: secondWindowID))
        let savePath = await actor.sessionSavePath()
        XCTAssertTrue(FileManager.default.fileExists(atPath: savePath.path),
                     "precondition: the second run's own snapshot must actually be on disk before preserving")

        await actor.preserveSnapshotForRecovery()

        XCTAssertTrue(FileManager.default.fileExists(atPath: savePath.path),
                      "the kept-first-wins branch must not delete the second run's on-disk savePath content; " +
                      "it is not preserved anywhere, but that run's own subsequent saves will rewrite it regardless")
    }

    // MARK: - Regression guard: the ordinary single-preserve path is unaffected

    func test_singlePreserve_withNothingPreservedYet_stillMovesFileAndReturnsTrue() async throws {
        let actor = SessionPersistenceActor()
        let windowID = UUID()
        await actor.saveImmediately(makeNonEmptySnapshot(windowID: windowID))
        let savePath = await actor.sessionSavePath()

        let returned = await actor.preserveSnapshotForRecovery()

        XCTAssertTrue(returned)
        XCTAssertFalse(FileManager.default.fileExists(atPath: savePath.path),
                       "with nothing preserved yet, the ordinary happy path must still MOVE the file away")
        let preserved = await actor.loadPreservedSnapshot()
        XCTAssertEqual(preserved?.windows.first?.id, windowID)
    }
}
