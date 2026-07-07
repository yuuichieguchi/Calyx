//
//  AppDelegateRecoverPreservedSessionReentrancyGuardTests.swift
//  CalyxTests
//
//  TDD Red phase (session-UI defect review, DEFECT 4, LOW priority):
//  recoverPreservedSession() (AppDelegate.swift:1466) has no reentrancy
//  guard. Two back-to-back invocations (e.g. a user double-clicking
//  "Recover Previous Session" in the command palette, or triggering it
//  twice in quick succession some other way) each independently load
//  the SAME preserved snapshot and each run their OWN restoreWindow(_:)
//  loop over its windows -- a non-empty preserved snapshot recovered
//  twice restores every one of its windows TWICE, a visible
//  duplicate-window bug. Mirrors SessionBrowserModel.refresh()'s
//  existing `isRefreshing` guard (SessionBrowserModel.swift), which
//  this file's fix is modeled on.
//
//  WHY DRIVEN VIA A PRE-SEEDED FLAG, NOT A REAL RACE (investigated, not
//  assumed): actually reproducing "a second call while the first is
//  genuinely still in flight" end to end needs a NON-EMPTY preserved
//  snapshot to reach restoreWindow(_:)'s real
//  GhosttyAppController.shared.app/window-creation path at all -- an
//  empty or absent snapshot's own branch returns before doing anything
//  worth double-invoking in the first place. That path is exactly what
//  AppDelegateRecoverPreservedSessionFinalizeTests's own header already
//  documents as hanging the XCTest process indefinitely -- the same
//  reachability limit AppDelegateRecoveryCounterResetTests and
//  SessionCommandPaletteRecoverPreviousSessionTests both cite for why
//  restoreSession()/recoverPreservedSession()'s own restore LOOP is
//  undriveable here. Racing two real Task-backed invocations against
//  each other via sleep-based timing would also be inherently
//  non-deterministic (this codebase's own determinism convention --
//  e.g. SessionBrowserModelRefreshCancellationGuardTests -- always
//  prefers an explicit synchronization point over wall-clock timing,
//  and there is no such point exposed here to synchronize on). Instead,
//  this file drives the guard directly: pre-seeds the new
//  `isRecovering` flag true via a new test setter (modeling "a recovery
//  is already in flight" as a given fact, not a race outcome) against a
//  preserved-snapshot state that resolves through the SAFE (never
//  reaching restoreWindow(_:)) "nothing preserved" branch, and asserts
//  the guarded call makes ZERO observable changes at all. This is
//  genuine RED, not a vacuous pass: today, with NO guard at all, that
//  same "nothing preserved" branch still unconditionally resets
//  hasPreservedSessionSnapshot to false regardless of `isRecovering`'s
//  value (quarantineCorruptPreservedSnapshot() is a safe no-op on an
//  absent file, but the flag reset that follows it is not gated on
//  anything today) -- so a correct guard is the only thing that can
//  make this file's first test pass.
//
//  Held-out compile-RED: `isRecovering` / `_setIsRecoveringForTesting(_:)`
//  do not exist on AppDelegate yet -- mirrors
//  `_setHasPreservedSessionSnapshotForTesting`'s own existing
//  private(set)-Bool test-seam precedent. This file fails to compile
//  until the Green phase adds them.
//
//  Proposed API (AppDelegate.swift):
//
//    private(set) var isRecovering = false
//
//    #if DEBUG
//    /// Test seam: mirrors _setHasPreservedSessionSnapshotForTesting's
//    /// convention for a private(set) Bool. DO NOT use from production code.
//    func _setIsRecoveringForTesting(_ value: Bool) {
//        isRecovering = value
//    }
//    #endif
//
//    func recoverPreservedSession() {
//        guard !isRecovering else { return }
//        isRecovering = true
//        let actor = _sessionPersistenceActorForTesting ?? SessionPersistenceActor.shared
//        Task {
//            defer { isRecovering = false }
//            guard let snapshot = await actor.loadPreservedSnapshot() else {
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
//  (The empty-snapshot guard's own body may differ slightly depending
//  on how the concurrent DEFECT-2-adjacent empty-preserved-snapshot fix
//  -- AppDelegateEmptyPreservedSnapshotTests, a DIFFERENT teammate's
//  file, not touched here -- lands; this file's own coverage never
//  depends on that branch's exact body, only on the "nothing preserved
//  at all" branch above it, which is unchanged by that other fix.)
//
//  Coverage:
//  - isRecovering pre-seeded true: a second recoverPreservedSession()
//    call is a no-op -- hasPreservedSessionSnapshot and the actor's own
//    on-disk state are both left exactly as they started
//  - isRecovering NOT pre-seeded (starts false, the normal case):
//    regression guard -- recoverPreservedSession() still runs normally
//    and resets hasPreservedSessionSnapshot, exactly as
//    AppDelegateRecoverPreservedSessionCorruptSnapshotTests' own
//    "nothing preserved" sibling case already established
//  - recoverPreservedSession() sets isRecovering true SYNCHRONOUSLY
//    (before any suspension point) and resets it back to false once
//    the in-flight Task completes
//

import XCTest
@testable import Calyx

@MainActor
final class AppDelegateRecoverPreservedSessionReentrancyGuardTests: XCTestCase {

    /// Mirrors AppDelegateRecoverPreservedSessionFinalizeTests
    /// .makeSessionDirActor(): a fresh temp-dir-backed
    /// SessionPersistenceActor, isolated per test method via
    /// addTeardownBlock.
    private func makeSessionDirActor() throws -> SessionPersistenceActor {
        let raw = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppDelegateRecoverPreservedSessionReentrancyGuardTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        let dir = raw.resolvingSymlinksInPath()
        setenv("CALYX_UITEST_SESSION_DIR", dir.path, 1)
        addTeardownBlock {
            unsetenv("CALYX_UITEST_SESSION_DIR")
            try? FileManager.default.removeItem(at: dir)
        }
        return SessionPersistenceActor()
    }

    // MARK: - Reentrancy: a second call while isRecovering is already true is a no-op

    func test_recoverPreservedSession_whileAlreadyRecovering_isANoOp() async throws {
        let actor = try makeSessionDirActor()
        let hasPreservedBefore = await actor.hasPreservedSnapshot()
        XCTAssertFalse(hasPreservedBefore, "precondition: nothing preserved at all in this fresh temp dir")

        let appDelegate = AppDelegate()
        appDelegate._sessionPersistenceActorForTesting = actor
        appDelegate._setHasPreservedSessionSnapshotForTesting(true)
        appDelegate._setIsRecoveringForTesting(true)

        appDelegate.recoverPreservedSession()
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertTrue(
            appDelegate.hasPreservedSessionSnapshot,
            "While isRecovering is already true, a second recoverPreservedSession() call must be a total " +
            "no-op -- it must not even reach the \"nothing preserved\" branch's own " +
            "hasPreservedSessionSnapshot = false reset, which an UNGUARDED call would still hit regardless " +
            "of there being nothing to actually recover"
        )
    }

    // MARK: - Regression guard: the normal (non-reentrant) call still works

    func test_recoverPreservedSession_notAlreadyRecovering_stillRunsNormally() async throws {
        let actor = try makeSessionDirActor()
        let appDelegate = AppDelegate()
        appDelegate._sessionPersistenceActorForTesting = actor
        appDelegate._setHasPreservedSessionSnapshotForTesting(true)

        appDelegate.recoverPreservedSession()
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertFalse(
            appDelegate.hasPreservedSessionSnapshot,
            "Regression guard: the guard must not block the NORMAL, non-reentrant call -- with nothing " +
            "preserved, it must still reset hasPreservedSessionSnapshot exactly as " +
            "AppDelegateRecoverPreservedSessionCorruptSnapshotTests' own sibling case already established"
        )
    }

    // MARK: - isRecovering's own set/reset lifecycle

    func test_recoverPreservedSession_setsIsRecoveringSynchronously_andResetsAfterCompletion() async throws {
        let actor = try makeSessionDirActor()
        let appDelegate = AppDelegate()
        appDelegate._sessionPersistenceActorForTesting = actor

        XCTAssertFalse(appDelegate.isRecovering, "precondition: not recovering before the first call")

        appDelegate.recoverPreservedSession()

        XCTAssertTrue(
            appDelegate.isRecovering,
            "isRecovering must be set to true SYNCHRONOUSLY, before recoverPreservedSession() returns -- not " +
            "lazily inside its Task -- otherwise a second call arriving before the Task gets its first " +
            "chance to run would race straight past the guard"
        )

        try await Task.sleep(for: .milliseconds(300))

        XCTAssertFalse(
            appDelegate.isRecovering,
            "Once the in-flight recovery attempt completes, isRecovering must reset to false so a LATER, " +
            "genuinely sequential recovery attempt is not permanently blocked"
        )
    }
}
