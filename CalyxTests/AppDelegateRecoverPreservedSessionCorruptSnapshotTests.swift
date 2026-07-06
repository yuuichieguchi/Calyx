//
//  AppDelegateRecoverPreservedSessionCorruptSnapshotTests.swift
//  CalyxTests
//
//  TDD Red phase (recovery-feature code review, CRITICAL F2 -- an
//  undecodable preserved snapshot permanently sticks
//  hasPreservedSessionSnapshot at true with a dead command, APP half).
//  ROOT CAUSE: recoverPreservedSession()'s guard,
//  `guard let snapshot = await actor.loadPreservedSnapshot(), !snapshot
//  .windows.isEmpty else { return }`, takes its no-op `return` branch
//  both when NOTHING is preserved and when something IS preserved but
//  fails to decode (corrupt JSON, unknown future schema version) -- the
//  latter is guaranteed to occur whenever preserveSnapshotForRecovery()
//  preserved a snapshot restore() itself had already failed to decode
//  (see SessionPersistenceActorQuarantineCorruptSnapshotTests's header
//  for the full chain). Either way, the plain `return` never resets
//  hasPreservedSessionSnapshot -- so once it started true (as it does
//  the moment preserveSnapshotForRecovery() preserved the corrupt file
//  in the first place), it is stuck true forever: every future
//  invocation of "Recover Previous Session" silently no-ops, the command
//  stays permanently visible in the palette, and the state persists
//  across relaunches too (initializeHasPreservedSessionSnapshotFlag()
//  re-derives true from hasPreservedSnapshot(), which only checks file
//  existence).
//
//  THE FIX, APP half: split the guard's failure branch so it can tell
//  "nothing preserved" apart from "preserved but undecodable" is
//  unnecessary in practice -- quarantineCorruptPreservedSnapshot() (see
//  the sibling actor-level test file) is itself a safe no-op when there
//  is nothing to quarantine, so it is called unconditionally in the
//  guard's else branch, alongside resetting
//  hasPreservedSessionSnapshot = false unconditionally too (which is
//  already false in the "nothing preserved" sub-case today, so this is
//  never a behavior change there -- only in the "preserved but
//  undecodable" sub-case this file actually targets).
//
//  No NEW symbol is referenced directly by this file (it drives the
//  already-existing recoverPreservedSession() end-to-end and only
//  inspects filesystem side effects), so this file's RED evidence is an
//  assertion FAILURE at runtime against the current guard's plain
//  `return`, not a compile failure. It DOES, however, require the
//  sibling SessionPersistenceActorQuarantineCorruptSnapshotTests' new
//  quarantineCorruptPreservedSnapshot() to exist before the suite as a
//  whole compiles again -- tracked there, not duplicated here.
//
//  Proposed implementation (AppDelegate.swift, replacing the current
//  single combined guard's failure branch):
//
//    func recoverPreservedSession() {
//        let actor = _sessionPersistenceActorForTesting ?? SessionPersistenceActor.shared
//        Task {
//            guard let snapshot = await actor.loadPreservedSnapshot() else {
//                // Nothing preserved, OR preserved but undecodable
//                // (corrupt/unknown schema) -- quarantine is a no-op in
//                // the former sub-case, so calling it unconditionally is
//                // safe and unsticks the latter.
//                await actor.quarantineCorruptPreservedSnapshot()
//                hasPreservedSessionSnapshot = false
//                return
//            }
//            guard !snapshot.windows.isEmpty else { return }
//            var restoredAny = false
//            for windowSnap in snapshot.windows {
//                if restoreWindow(windowSnap) {
//                    restoredAny = true
//                }
//            }
//            await finalizeRecoverPreservedSession(restoredAny: restoredAny)
//        }
//    }
//
//  WHY THIS IS SAFELY DRIVEABLE (unlike F1's restoredAny loop): the
//  corrupt-snapshot guard branch returns BEFORE ever reaching
//  restoreWindow(_:)/GhosttyAppController.shared -- exactly the same
//  reason SessionCommandPaletteRecoverPreviousSessionTests's own
//  "nothing preserved" case is already driveable end-to-end through
//  recoverPreservedSession() itself. This file reuses that exact seam
//  and pattern, substituting a corrupt (not absent) preserved snapshot.
//
//  Coverage:
//  - a corrupt preserved snapshot: after calling recoverPreservedSession()
//    and letting its Task complete, hasPreservedSessionSnapshot is reset
//    to false, hasPreservedSnapshot() reports false, and the corrupt
//    bytes reappear intact at sessions.recovery.json.corrupt (proving the
//    reset went through quarantining, not plain deletion)
//

import XCTest
@testable import Calyx

@MainActor
final class AppDelegateRecoverPreservedSessionCorruptSnapshotTests: XCTestCase {

    private let corruptBytes = Data("not valid json {".utf8)

    private func quarantinePath(for actor: SessionPersistenceActor) async -> URL {
        await actor.sessionSavePath()
            .deletingLastPathComponent()
            .appendingPathComponent("sessions.recovery.json.corrupt")
    }

    func test_recoverPreservedSession_withCorruptPreservedSnapshot_quarantinesAndResetsFlag() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppDelegateRecoverPreservedSessionCorruptSnapshotTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let resolvedDir = dir.resolvingSymlinksInPath()
        setenv("CALYX_UITEST_SESSION_DIR", resolvedDir.path, 1)
        addTeardownBlock {
            unsetenv("CALYX_UITEST_SESSION_DIR")
            try? FileManager.default.removeItem(at: resolvedDir)
        }

        let actor = SessionPersistenceActor()
        let savePath = await actor.sessionSavePath()
        try corruptBytes.write(to: savePath)
        let preserved = await actor.preserveSnapshotForRecovery()
        XCTAssertTrue(preserved, "precondition: the corrupt bytes must actually be moved into the recovery path")
        let loadedBefore = await actor.loadPreservedSnapshot()
        XCTAssertNil(loadedBefore, "precondition: the preserved bytes must fail to decode")

        let appDelegate = AppDelegate()
        appDelegate._sessionPersistenceActorForTesting = actor
        appDelegate._setHasPreservedSessionSnapshotForTesting(true)

        appDelegate.recoverPreservedSession()
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertFalse(appDelegate.hasPreservedSessionSnapshot,
                       "an undecodable preserved snapshot must not leave the recovery command stuck available forever")
        let hasPreservedAfter = await actor.hasPreservedSnapshot()
        XCTAssertFalse(hasPreservedAfter, "the corrupt file must no longer be reported as a preserved snapshot")

        let qPath = await quarantinePath(for: actor)
        XCTAssertTrue(FileManager.default.fileExists(atPath: qPath.path),
                     "the reset must go through quarantining (nothing destroyed), not plain deletion -- " +
                     "the .corrupt file must exist")
        let quarantinedBytes = try Data(contentsOf: qPath)
        XCTAssertEqual(quarantinedBytes, corruptBytes,
                       "the quarantined bytes must be exactly what was originally preserved")
    }
}
