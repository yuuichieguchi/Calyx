//
//  AppDelegateRecoverPreservedSessionFinalizeTests.swift
//  CalyxTests
//
//  TDD Red phase (recovery-feature code review, CRITICAL F1 --
//  recoverPreservedSession() destroys the preserved backup even when
//  nothing was actually recovered). ROOT CAUSE: the recovery loop
//  discards restoreWindow(_:)'s return value (`_ =
//  restoreWindow(windowSnap)`) and then UNCONDITIONALLY calls
//  actor.clearPreservedSnapshot() and sets hasPreservedSessionSnapshot =
//  false, regardless of whether any window actually restored.
//  restoreWindow(_:) can return false for every window in the preserved
//  snapshot (e.g. every tab fails both restoreTabSurfaces and
//  fallbackCreateSurface, see cleanupFailedWindow's branch,
//  AppDelegate.swift ~1288-1291). If that happens, the command silently
//  deletes the user's last-resort backup and reports nothing -- the
//  exact permanent data loss this whole "Chrome-style recovery" feature
//  exists to prevent.
//
//  THE FIX: track whether at least one window actually restored
//  (mirroring restoreSession()'s own restoredAny pattern) and only
//  clear/reset on that condition; otherwise leave the preserved file in
//  place, so a total-failure recovery attempt never destroys the backup.
//
//  WHY THIS IS DECOMPOSED (investigated, not assumed): restoreWindow(_:)
//  itself cannot be safely driven from this test host -- it reaches
//  GhosttyAppController.shared.app and (when non-nil) real window/surface
//  creation, which AppDelegateApplyGhosttyResourcesDirEnvironmentTests's
//  own header already documents as hanging the XCTest process
//  indefinitely (the same reachability limit
//  AppDelegateRecoveryCounterResetTests and
//  SessionCommandPaletteRecoverPreviousSessionTests both cite for why
//  restoreSession()/recoverPreservedSession()'s own restore LOOP is
//  undriveable). Driving `restoredAny == false` end-to-end through the
//  real loop is therefore not exercisable here. Instead, this file pins
//  the POST-LOOP bookkeeping in isolation, via a new extracted method
//  that recoverPreservedSession() must call with whatever restoredAny it
//  computed -- exactly the same "extract the untestable wiring's tail
//  into a directly-callable method" shape
//  AppDelegateRecoveryCounterResetTests already established for
//  scheduleRecoveryCounterResetAfterStableLaunch(delay:).
//
//  Held-out compile-RED (see SessionCommandSynthesizerRemoteAttachTests's
//  header for this codebase's convention): AppDelegate
//  .finalizeRecoverPreservedSession(restoredAny:) does not exist yet.
//  This file fails to compile until the Green phase adds it. That
//  compile failure IS this file's RED evidence.
//
//  Proposed API (AppDelegate.swift addition):
//
//    /// Extracted from recoverPreservedSession() so the "was anything
//    /// actually recovered" bookkeeping is unit-testable without
//    /// reaching restoreWindow(_:)'s real GhosttyAppController/window-
//    /// creation path (see this file's own reachability note). Mirrors
//    /// scheduleRecoveryCounterResetAfterStableLaunch(delay:)'s
//    /// actor-seam resolution. Clears the preserved snapshot and resets
//    /// hasPreservedSessionSnapshot ONLY when restoredAny is true;
//    /// otherwise leaves both untouched, so a recovery attempt that
//    /// restored NOTHING never destroys the user's last-resort backup.
//    func finalizeRecoverPreservedSession(restoredAny: Bool) async {
//        guard restoredAny else { return }
//        let actor = _sessionPersistenceActorForTesting ?? SessionPersistenceActor.shared
//        await actor.clearPreservedSnapshot()
//        hasPreservedSessionSnapshot = false
//    }
//
//  recoverPreservedSession() itself must then track restoredAny across
//  its restoreWindow(_:) loop (mirroring restoreSession()'s own
//  identical pattern) and call
//  `await finalizeRecoverPreservedSession(restoredAny: restoredAny)` in
//  place of its current unconditional clear+reset tail.
//
//  WHAT THIS FILE CAN AND CANNOT PIN (unit level): this file drives
//  finalizeRecoverPreservedSession(restoredAny:) directly against a
//  fresh SessionPersistenceActor pointed at a temp dir (this codebase's
//  existing actor-init test seam), so it CAN pin that the extracted
//  method itself correctly gates clearing/resetting on restoredAny, in
//  both directions. It CANNOT pin that recoverPreservedSession() (a)
//  actually computes restoredAny from restoreWindow(_:)'s real return
//  values rather than a hardcoded true, or (b) calls this method at all
//  in place of its current inline tail. Both are properties of
//  recoverPreservedSession()'s own body, which has no safe unit-level
//  seam to observe against restoreWindow(_:)'s real (hang-prone)
//  execution. The Green phase implementer and code review must verify
//  (a)/(b) by reading the diff; no test in this file substitutes for
//  that reading.
//
//  Coverage:
//  - restoredAny == false: the preserved snapshot is left in place
//    (hasPreservedSnapshot still true, content unchanged) and
//    hasPreservedSessionSnapshot stays true
//  - restoredAny == true: the preserved snapshot is cleared
//    (hasPreservedSnapshot becomes false) and hasPreservedSessionSnapshot
//    becomes false
//

import XCTest
@testable import Calyx

@MainActor
final class AppDelegateRecoverPreservedSessionFinalizeTests: XCTestCase {

    /// Mirrors AppDelegateRecoveryCounterResetTests.makeSessionDirActor():
    /// a fresh temp-dir-backed SessionPersistenceActor, isolated per test
    /// method via addTeardownBlock (not setUp/tearDown, since
    /// setUpWithError/tearDownWithError cannot touch this @MainActor
    /// class's isolated state directly).
    private func makeSessionDirActor() throws -> SessionPersistenceActor {
        let raw = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppDelegateRecoverPreservedSessionFinalizeTests-\(UUID().uuidString)")
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

    // MARK: - restoredAny == false: the backup must survive

    func test_finalize_restoredAnyFalse_leavesPreservedSnapshotAndFlagUntouched() async throws {
        let actor = try makeSessionDirActor()
        let windowID = UUID()
        await actor.saveImmediately(makeNonEmptySnapshot(windowID: windowID))
        await actor.preserveSnapshotForRecovery()
        let preservedBefore = await actor.loadPreservedSnapshot()
        XCTAssertEqual(preservedBefore?.windows.first?.id, windowID,
                       "precondition: a real preserved snapshot must exist before finalizing")

        let appDelegate = AppDelegate()
        appDelegate._sessionPersistenceActorForTesting = actor
        appDelegate._setHasPreservedSessionSnapshotForTesting(true)

        await appDelegate.finalizeRecoverPreservedSession(restoredAny: false)

        let hasPreservedAfter = await actor.hasPreservedSnapshot()
        XCTAssertTrue(hasPreservedAfter,
                     "a recovery attempt that restored NOTHING must not destroy the preserved backup")
        let preservedAfter = await actor.loadPreservedSnapshot()
        XCTAssertEqual(preservedAfter?.windows.first?.id, windowID,
                       "the preserved content itself must be exactly unchanged")
        XCTAssertTrue(appDelegate.hasPreservedSessionSnapshot,
                     "the recovery command must stay available so the user can try again or investigate")
    }

    // MARK: - restoredAny == true: the backup is retired

    func test_finalize_restoredAnyTrue_clearsPreservedSnapshotAndResetsFlag() async throws {
        let actor = try makeSessionDirActor()
        await actor.saveImmediately(makeNonEmptySnapshot())
        await actor.preserveSnapshotForRecovery()
        let hasPreservedBefore = await actor.hasPreservedSnapshot()
        XCTAssertTrue(hasPreservedBefore, "precondition: a preserved snapshot must exist before finalizing")

        let appDelegate = AppDelegate()
        appDelegate._sessionPersistenceActorForTesting = actor
        appDelegate._setHasPreservedSessionSnapshotForTesting(true)

        await appDelegate.finalizeRecoverPreservedSession(restoredAny: true)

        let hasPreservedAfter = await actor.hasPreservedSnapshot()
        XCTAssertFalse(hasPreservedAfter,
                       "once at least one window actually restored, the now-redundant backup must be cleared")
        XCTAssertFalse(appDelegate.hasPreservedSessionSnapshot,
                       "the recovery command must retire once recovery actually succeeded")
    }
}
