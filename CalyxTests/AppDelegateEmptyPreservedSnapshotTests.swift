//
//  AppDelegateEmptyPreservedSnapshotTests.swift
//  CalyxTests
//
//  TDD Red phase (team-lead scope addition, live defect found during the
//  recovery-bar task: an EMPTY preserved snapshot -- e.g. a 32-byte
//  `{"windows":[]}` preserved from an already-damaged sessions.json --
//  is decodable but has NOTHING to recover, yet today's code treats it
//  as if it were a real preserved session).
//
//  ROOT CAUSE #1 (initializeHasPreservedSessionSnapshotFlag(), :1428):
//
//    private func initializeHasPreservedSessionSnapshotFlag() async {
//        let actor = _sessionPersistenceActorForTesting ?? SessionPersistenceActor.shared
//        hasPreservedSessionSnapshot = await actor.hasPreservedSnapshot()
//    }
//
//  `hasPreservedSnapshot()` is a PURE FILE-EXISTENCE check (see
//  SessionPersistenceActor.swift) -- it has no idea whether the file's
//  content actually has any windows in it. An empty-but-decodable
//  preserved file makes this flip `hasPreservedSessionSnapshot` true
//  forever (every future launch re-derives the same true from the same
//  still-present file), permanently showing the recovery bar
//  (RecoveryBarModelTests.swift) and permanently enabling the palette's
//  "Recover Previous Session" -- both with nothing to actually recover.
//
//  ROOT CAUSE #2 (recoverPreservedSession(), :1466):
//
//    func recoverPreservedSession() {
//        let actor = _sessionPersistenceActorForTesting ?? SessionPersistenceActor.shared
//        Task {
//            guard let snapshot = await actor.loadPreservedSnapshot() else {
//                await actor.quarantineCorruptPreservedSnapshot()
//                hasPreservedSessionSnapshot = false
//                return
//            }
//            guard !snapshot.windows.isEmpty else { return }   // <-- BUG: silent no-op
//            ...
//        }
//    }
//
//  The empty-`windows` guard's plain `return` leaves BOTH the preserved
//  file AND `hasPreservedSessionSnapshot` completely untouched -- a
//  visible dead button exactly as the corrupt-snapshot bug
//  (AppDelegateRecoverPreservedSessionCorruptSnapshotTests.swift, fixed
//  earlier this same feature) looked before its own fix, except this
//  time the guard is reached via a DIFFERENT branch (well-formed JSON,
//  zero windows) than that file's undecodable-bytes branch.
//
//  THE FIX (contract, all three parts driven/covered here except (c),
//  which is a RecoveryBarModelTests.swift corollary -- see its own new
//  case):
//  (a) initializeHasPreservedSessionSnapshotFlag() must treat a
//      decodable-but-empty preserved file as ABSENT: load it, and if
//      `windows.isEmpty`, retire the useless file (clear or quarantine
//      -- either satisfies the observable contract this file actually
//      asserts: hasPreservedSnapshot() reports false afterward) and
//      leave/set the flag false, instead of trusting bare file
//      existence.
//  (b) recoverPreservedSession()'s empty-windows guard must clear the
//      file and reset the flag (mirroring finalizeRecoverPreservedSession
//      (restoredAny: true)'s own two-step "clear + reset" shape) instead
//      of a bare `return`.
//  (c) Because (a) means AppDelegate never sets `hasPreservedSessionSnapshot
//      = true` for an empty preserved snapshot in the first place, the
//      recovery bar (whose visibility is driven ENTIRELY by that flag,
//      see RecoveryBarModelTests.swift's `showRecoveryBar` contract)
//      never shows for one either -- no additional AppDelegate-level
//      wiring is needed for (c) beyond correctly fixing (a).
//
//  Held-out compile-RED, part (a) specifically: `initializeHasPreservedSessionSnapshotFlag()`
//  is declared `private` today (AppDelegate.swift :1428), so this file
//  cannot call it at all, even via `@testable import Calyx` (private
//  members stay private under @testable, unlike internal ones). Proposed
//  API change: drop `private` from its declaration -- mirrors
//  `finalizeRecoverPreservedSession(restoredAny:)`'s own identical
//  extraction-for-testability precedent
//  (AppDelegateRecoverPreservedSessionFinalizeTests.swift). Today this
//  file fails to compile with "'initializeHasPreservedSessionSnapshotFlag'
//  is inaccessible due to 'private' protection level" -- that IS this
//  file's part-(a) RED evidence.
//
//  Part (b) needs NO new symbol (recoverPreservedSession() is already
//  internal and already exercised end-to-end by
//  AppDelegateRecoverPreservedSessionCorruptSnapshotTests.swift's
//  identical pattern) -- its RED evidence is a runtime ASSERTION FAILURE
//  against the current silent-`return` guard, not a compile failure.
//
//  WHY THIS IS SAFELY DRIVEABLE (same reachability argument as the
//  corrupt-snapshot sibling file): both the empty-preserved-file guard
//  in recoverPreservedSession() and the whole body of
//  initializeHasPreservedSessionSnapshotFlag() return/complete BEFORE
//  ever reaching restoreWindow(_:)'s real GhosttyAppController/window-
//  creation path, so neither hangs the XCTest process.
//
//  Coverage:
//  - initializeHasPreservedSessionSnapshotFlag(), empty preserved
//    snapshot: flag stays false, file no longer reported as preserved
//  - initializeHasPreservedSessionSnapshotFlag(), non-empty preserved
//    snapshot: flag becomes true, file survives untouched (regression
//    guard -- the fix must not break the legitimate case)
//  - initializeHasPreservedSessionSnapshotFlag(), nothing preserved at
//    all: flag stays false (regression guard, today's existing behavior)
//  - recoverPreservedSession(), empty preserved snapshot: clears the
//    file and resets the flag, instead of leaving both untouched
//

import XCTest
@testable import Calyx

@MainActor
final class AppDelegateEmptyPreservedSnapshotTests: XCTestCase {

    /// Mirrors AppDelegateRecoverPreservedSessionFinalizeTests.makeSessionDirActor():
    /// a fresh temp-dir-backed SessionPersistenceActor, isolated per test
    /// method via addTeardownBlock.
    private func makeSessionDirActor() throws -> SessionPersistenceActor {
        let raw = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppDelegateEmptyPreservedSnapshotTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        let dir = raw.resolvingSymlinksInPath()
        setenv("CALYX_UITEST_SESSION_DIR", dir.path, 1)
        addTeardownBlock {
            unsetenv("CALYX_UITEST_SESSION_DIR")
            try? FileManager.default.removeItem(at: dir)
        }
        return SessionPersistenceActor()
    }

    private func makeNonEmptySnapshot(windowID: UUID = UUID()) -> SessionSnapshot {
        SessionSnapshot(windows: [WindowSnapshot(id: windowID, frame: CGRect(x: 0, y: 0, width: 800, height: 600))])
    }

    // MARK: - (a) initializeHasPreservedSessionSnapshotFlag()

    func test_initializeFlag_withEmptyPreservedSnapshot_flagStaysFalse_andUselessFileIsRetired() async throws {
        let actor = try makeSessionDirActor()
        await actor.saveImmediately(SessionSnapshot(windows: []))
        let preserved = await actor.preserveSnapshotForRecovery()
        XCTAssertTrue(preserved, "precondition: an empty-but-decodable snapshot must still get moved aside")
        let loadedBefore = await actor.loadPreservedSnapshot()
        XCTAssertEqual(loadedBefore?.windows, [], "precondition: the preserved file must decode with zero windows")

        let appDelegate = AppDelegate()
        appDelegate._sessionPersistenceActorForTesting = actor

        await appDelegate.initializeHasPreservedSessionSnapshotFlag()

        XCTAssertFalse(
            appDelegate.hasPreservedSessionSnapshot,
            "an empty preserved snapshot has nothing to recover and must not flip the flag true, " +
            "permanently showing a recovery bar / enabling a palette command for nothing"
        )
        let hasPreservedAfter = await actor.hasPreservedSnapshot()
        XCTAssertFalse(
            hasPreservedAfter,
            "the useless empty preserved file must be retired (cleared or quarantined), not left on " +
            "disk forever re-triggering the same dead state on every future launch"
        )
    }

    func test_initializeFlag_withNonEmptyPreservedSnapshot_flagBecomesTrue_fileSurvives() async throws {
        let actor = try makeSessionDirActor()
        let windowID = UUID()
        await actor.saveImmediately(makeNonEmptySnapshot(windowID: windowID))
        await actor.preserveSnapshotForRecovery()

        let appDelegate = AppDelegate()
        appDelegate._sessionPersistenceActorForTesting = actor

        await appDelegate.initializeHasPreservedSessionSnapshotFlag()

        XCTAssertTrue(
            appDelegate.hasPreservedSessionSnapshot,
            "a real, non-empty preserved snapshot must still flip the flag true -- the empty-snapshot " +
            "fix must not regress the legitimate recovery case"
        )
        let preservedAfter = await actor.loadPreservedSnapshot()
        XCTAssertEqual(
            preservedAfter?.windows.first?.id, windowID,
            "a real preserved snapshot's content must survive merely initializing the flag untouched"
        )
    }

    func test_initializeFlag_withNothingPreserved_flagStaysFalse() async throws {
        let actor = try makeSessionDirActor()
        let hasPreservedBefore = await actor.hasPreservedSnapshot()
        XCTAssertFalse(hasPreservedBefore, "precondition: nothing preserved at all")

        let appDelegate = AppDelegate()
        appDelegate._sessionPersistenceActorForTesting = actor

        await appDelegate.initializeHasPreservedSessionSnapshotFlag()

        XCTAssertFalse(appDelegate.hasPreservedSessionSnapshot,
                       "regression guard: with nothing preserved, the flag must stay false exactly as today")
    }

    // MARK: - (b) recoverPreservedSession()'s empty-windows branch

    func test_recoverPreservedSession_withEmptyPreservedSnapshot_clearsFileAndResetsFlag() async throws {
        let actor = try makeSessionDirActor()
        await actor.saveImmediately(SessionSnapshot(windows: []))
        await actor.preserveSnapshotForRecovery()
        let hasPreservedBefore = await actor.hasPreservedSnapshot()
        XCTAssertTrue(hasPreservedBefore, "precondition: an empty snapshot must still be a preserved file on disk")

        let appDelegate = AppDelegate()
        appDelegate._sessionPersistenceActorForTesting = actor
        // Mirrors the buggy real-world state this file targets: a prior
        // initializeHasPreservedSessionSnapshotFlag() (or today's
        // unfixed one) already flipped this true from bare file
        // existence, with the empty snapshot already sitting on disk.
        appDelegate._setHasPreservedSessionSnapshotForTesting(true)

        appDelegate.recoverPreservedSession()
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertFalse(
            appDelegate.hasPreservedSessionSnapshot,
            "invoking recovery against an empty preserved snapshot must retire the now-proven-dead " +
            "command, not silently no-op and leave it permanently enabled"
        )
        let hasPreservedAfter = await actor.hasPreservedSnapshot()
        XCTAssertFalse(
            hasPreservedAfter,
            "the useless empty preserved file must be cleared, not left on disk to keep re-triggering " +
            "the exact same dead recovery attempt indefinitely"
        )
    }
}
