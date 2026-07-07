//
//  RecoveryBarModelTests.swift
//  CalyxTests
//
//  TDD Red phase for the Chrome-style in-app session-recovery bar
//  (team-lead task: "in-app recovery bar + E2E"). WHY THIS FEATURE
//  EXISTS: the only PRE-EXISTING signal that a previous session was
//  preserved-but-not-restored is AppDelegate.notifyPreviousSessionNotRestored(),
//  a macOS system notification. That notification is silently dropped
//  whenever notification permission hasn't resolved yet (launch-time
//  race: NotificationManager's own permissionGranted starts false,
//  requestAuthorization is async) or was never granted (unsigned debug
//  builds). The user never saw it. This bar must be visible IN-APP and
//  permission-independent.
//
//  INVESTIGATION -- A SECOND, DISTINCT LAUNCH-TIME RACE (not just the
//  notification-permission one above): AppDelegate.applicationDidFinishLaunching
//  calls restoreSession()/createNewWindow() SYNCHRONOUSLY (creating this
//  launch's first window[s] on the spot), and only AFTER that kicks off
//  `Task { await initializeHasPreservedSessionSnapshotFlag() }` --
//  fire-and-forget, never awaited before window creation. So at the
//  exact moment a launch-time window's content is first built,
//  AppDelegate.hasPreservedSessionSnapshot is STILL its initial `false`,
//  even in the exact scenario this bar exists for (a previous run's
//  restoreSession() failed/skipped and preserved a snapshot). A
//  recovery-bar view-model that only reads the flag ONCE, at window-
//  construction time, would show nothing on a real launch -- the race
//  would defeat the very feature meant to fix a race. This model is
//  therefore designed to be updated AFTER construction
//  (updateHasPreservedSessionSnapshot(_:)), which the window-creation
//  call sites must invoke once initializeHasPreservedSessionSnapshotFlag()'s
//  Task actually resolves -- see this file's "Proposed API" section.
//
//  SEAM CHOSEN (mirrors SessionBrowserModel's own "UI-independent logic
//  layer, directly unit-testable, no window" precedent): a small
//  `@Observable` view-model, one instance owned per CalyxWindowController,
//  fed by (not fetching) AppDelegate's `hasPreservedSessionSnapshot`, with
//  an injectable `onRestore` closure -- the model itself has zero
//  dependency on AppDelegate/SessionPersistenceActor/GhosttyAppController,
//  exactly like SessionBrowserModel.onAttachRequested/onRemoteSessionRequested
//  keep IT independent of CalyxWindowController.
//
//  DESIGN DECISION TO DOCUMENT (per task instructions): "Dismiss" only
//  ever sets this ONE model instance's own `isDismissed`, scoped to the
//  window whose bar was dismissed -- it is NOT a global, app-wide
//  dismissal shared across every window's model. In practice this
//  distinction rarely matters: hasPreservedSessionSnapshot only starts
//  true immediately after a launch whose own restoreSession() already
//  failed, which is exactly the case where createNewWindow() produces a
//  SINGLE window, so there is normally only one bar to begin with. The
//  command palette's "Recover Previous Session" (session.recoverPreviousSession,
//  already shipped) remains available app-wide regardless of any given
//  window's dismissal, so a dismissed bar never strands the user without
//  a recovery path -- it only removes the launch-time nudge, matching
//  Chrome's own "restore pages?" infobar, which is similarly per-window
//  and dismissable without discarding the underlying saved-tabs data.
//
//  Held-out compile-RED (this codebase's established convention for a
//  net-new type -- see AppDelegateRecoverPreservedSessionFinalizeTests's
//  own header, and SessionCommandPaletteRecoverPreviousSessionTests's):
//  `RecoveryBarModel` does not exist yet anywhere in the app target.
//  This file fails to COMPILE until the Green phase adds it. That
//  compile failure IS this file's RED evidence -- there is no runtime
//  failure message to report because the build never reaches that
//  stage.
//
//  Proposed API (new file, Calyx/Features/Persistence/RecoveryBarModel.swift,
//  alongside SessionPersistenceActor.swift/SessionSnapshot.swift -- this
//  is a persistence-recovery concern, not a Sessions/calyx-session-daemon
//  one, despite living conceptually next to GiveUpOverlayView's in-window
//  affordance precedent):
//
//    @MainActor
//    @Observable
//    final class RecoveryBarModel {
//        private(set) var hasPreservedSessionSnapshot: Bool
//        private(set) var isDismissed: Bool = false
//        var onRestore: (() -> Void)?
//
//        init(hasPreservedSessionSnapshot: Bool = false, onRestore: (() -> Void)? = nil) {
//            self.hasPreservedSessionSnapshot = hasPreservedSessionSnapshot
//            self.onRestore = onRestore
//        }
//
//        var showRecoveryBar: Bool {
//            hasPreservedSessionSnapshot && !isDismissed
//        }
//
//        func updateHasPreservedSessionSnapshot(_ value: Bool) {
//            hasPreservedSessionSnapshot = value
//        }
//
//        func dismiss() {
//            isDismissed = true
//        }
//
//        func restore() {
//            onRestore?()
//        }
//    }
//
//  Wiring this needs at the AppDelegate/CalyxWindowController level
//  (investigated, not implemented here -- out of scope for this
//  unit-level file, called out for the Green-phase implementer):
//  - Every window-controller construction site (openNewWindow(initialHost:),
//    openWindowAtPath(_:), makeRestoringWindowController(contentRect:windowSession:))
//    must hand its new CalyxWindowController a RecoveryBarModel seeded
//    from the CURRENT `hasPreservedSessionSnapshot` and an `onRestore`
//    closure that calls `self.recoverPreservedSession()`.
//  - `initializeHasPreservedSessionSnapshotFlag()`, after setting
//    `hasPreservedSessionSnapshot`, must push the resolved value into
//    every currently-tracked window controller's model via
//    `updateHasPreservedSessionSnapshot(_:)` (fixing the launch-time
//    race documented above).
//  - `finalizeRecoverPreservedSession(restoredAny:)`'s `restoredAny ==
//    true` branch (which already sets `hasPreservedSessionSnapshot =
//    false`) must likewise push `false` to every tracked window
//    controller's model, so every bar disappears once recovery actually
//    succeeds (contract point 2), and the `recoverPreservedSession()`
//    corrupt-snapshot guard branch (which also resets the flag to
//    false) should do the same for consistency.
//
//  Coverage (this file, view-model level only -- no window, no
//  AppDelegate, no GhosttyAppController; mirrors SessionBrowserModelTests'
//  own "UI-independent logic layer" scope):
//  - showRecoveryBar is true exactly when hasPreservedSessionSnapshot is
//    true AND not dismissed; false in every other combination
//  - a plain/default-initialized model (mirrors "a normal launch with no
//    preserved snapshot shows no bar", contract point 4) never shows the bar
//  - updateHasPreservedSessionSnapshot(_:) flips visibility in BOTH
//    directions after construction -- this is the race-fix seam itself,
//    not just a getter/setter round-trip
//  - dismiss() hides the bar WITHOUT mutating hasPreservedSessionSnapshot
//    (contract point 3: the preserved snapshot itself must survive a
//    dismiss) and the dismissal is sticky -- a later
//    updateHasPreservedSessionSnapshot(true) must not un-hide it
//  - restore() invokes the injected onRestore closure exactly once, and
//    is a safe no-op when onRestore is nil
//  - the bar hiding "once hasPreservedSessionSnapshot becomes false"
//    (contract point 2) is exactly updateHasPreservedSessionSnapshot(false)
//    turning showRecoveryBar false again, asserted end-to-end from a
//    true+shown starting state
//

import XCTest
@testable import Calyx

@MainActor
final class RecoveryBarModelTests: XCTestCase {

    // MARK: - Default (no preserved snapshot) -- contract point 4

    func test_defaultInit_hasPreservedSessionSnapshotFalse_showRecoveryBarFalse() {
        let model = RecoveryBarModel()

        XCTAssertFalse(model.hasPreservedSessionSnapshot,
                       "a model with no explicit flag must default to false, matching a normal launch")
        XCTAssertFalse(model.showRecoveryBar,
                       "a normal launch with no preserved snapshot must show no bar")
    }

    // MARK: - Shown when flag true and not dismissed

    func test_initWithFlagTrue_showRecoveryBarTrue() {
        let model = RecoveryBarModel(hasPreservedSessionSnapshot: true)

        XCTAssertTrue(model.showRecoveryBar,
                      "a preserved snapshot with no dismissal yet must show the bar")
    }

    // MARK: - Hidden when flag false

    func test_initWithFlagFalse_showRecoveryBarFalse() {
        let model = RecoveryBarModel(hasPreservedSessionSnapshot: false)

        XCTAssertFalse(model.showRecoveryBar)
    }

    // MARK: - The launch-time race fix: flag flips AFTER construction

    func test_updateHasPreservedSessionSnapshotTrue_afterFalseInit_makesBarAppear() {
        // Mirrors the real race: a launch-time window is always
        // constructed with the flag still false (initializeHasPreservedSessionSnapshotFlag()'s
        // Task hasn't resolved yet), and only later told the real value.
        let model = RecoveryBarModel(hasPreservedSessionSnapshot: false)
        XCTAssertFalse(model.showRecoveryBar, "precondition: must start hidden, matching the real race")

        model.updateHasPreservedSessionSnapshot(true)

        XCTAssertTrue(model.showRecoveryBar,
                      "once the async flag resolves true, an already-constructed window's bar must appear")
    }

    func test_updateHasPreservedSessionSnapshotFalse_afterTrueInit_hidesBar() {
        // Mirrors contract point 2: the bar disappears once
        // hasPreservedSessionSnapshot becomes false (successful restore).
        let model = RecoveryBarModel(hasPreservedSessionSnapshot: true)
        XCTAssertTrue(model.showRecoveryBar, "precondition: must start shown")

        model.updateHasPreservedSessionSnapshot(false)

        XCTAssertFalse(model.showRecoveryBar,
                       "once hasPreservedSessionSnapshot clears, the bar must hide even without a dismiss")
    }

    // MARK: - Dismiss hides the bar WITHOUT clearing the preserved snapshot

    func test_dismiss_hidesBar_butDoesNotClearHasPreservedSessionSnapshot() {
        let model = RecoveryBarModel(hasPreservedSessionSnapshot: true)

        model.dismiss()

        XCTAssertFalse(model.showRecoveryBar, "dismiss must hide the bar")
        XCTAssertTrue(model.hasPreservedSessionSnapshot,
                     "dismiss must NOT clear the underlying preserved-snapshot flag -- the command " +
                     "palette's \"Recover Previous Session\" must remain available as the non-time-critical fallback")
    }

    func test_dismiss_isSticky_laterFlagUpdateToTrueDoesNotUnhideBar() {
        let model = RecoveryBarModel(hasPreservedSessionSnapshot: true)
        model.dismiss()
        XCTAssertFalse(model.showRecoveryBar, "precondition: dismissed and hidden")

        // A later broadcast of the same/already-true value (or a
        // hypothetical future re-preservation within the same run) must
        // not resurrect a bar the user already dismissed this run.
        model.updateHasPreservedSessionSnapshot(true)

        XCTAssertFalse(model.showRecoveryBar,
                       "a dismissed bar must stay hidden for the rest of this app run, per contract point 3")
    }

    func test_dismiss_whenFlagAlreadyFalse_isNoOp_stillHidden() {
        let model = RecoveryBarModel(hasPreservedSessionSnapshot: false)

        model.dismiss()

        XCTAssertFalse(model.showRecoveryBar)
        XCTAssertFalse(model.hasPreservedSessionSnapshot)
    }

    // MARK: - Restore invokes the injected closure

    func test_restore_invokesOnRestoreClosureExactlyOnce() {
        var invocationCount = 0
        let model = RecoveryBarModel(hasPreservedSessionSnapshot: true, onRestore: {
            invocationCount += 1
        })

        model.restore()

        XCTAssertEqual(invocationCount, 1,
                       "restore() must invoke the injected recovery closure exactly once")
    }

    func test_restore_withNoOnRestoreClosure_isSafeNoOp() {
        let model = RecoveryBarModel(hasPreservedSessionSnapshot: true)

        // Must not crash/trap when no closure was injected.
        model.restore()

        XCTAssertTrue(model.showRecoveryBar,
                     "calling restore() with no closure must not, by itself, change visibility -- only " +
                     "a subsequent updateHasPreservedSessionSnapshot(false) (driven by the real " +
                     "recoverPreservedSession() completing) does that, exercised separately above")
    }

    func test_restore_doesNotItselfClearHasPreservedSessionSnapshot() {
        // The model has no knowledge of whether the closure's real work
        // (AppDelegate.recoverPreservedSession()) succeeded -- clearing
        // the flag is exclusively updateHasPreservedSessionSnapshot(_:)'s
        // job, driven by the caller once the real async recovery
        // actually finishes (see this file's header wiring note).
        var invoked = false
        let model = RecoveryBarModel(hasPreservedSessionSnapshot: true, onRestore: { invoked = true })

        model.restore()

        XCTAssertTrue(invoked)
        XCTAssertTrue(model.hasPreservedSessionSnapshot,
                     "restore() alone (before the async recovery completes and calls back) must not " +
                     "have already cleared the flag itself")
    }

    // MARK: - Team-lead scope addition: an EMPTY preserved snapshot must never show a bar

    /// Corollary of AppDelegateEmptyPreservedSnapshotTests.swift's
    /// contract (a): once initializeHasPreservedSessionSnapshotFlag()
    /// correctly treats a decodable-but-empty preserved snapshot as
    /// ABSENT, it never sets `hasPreservedSessionSnapshot = true` for
    /// one in the first place -- every window controller's
    /// RecoveryBarModel is therefore seeded/updated with `false` for
    /// this case, exactly the plain "nothing preserved" path already
    /// covered above. No new model-level API is needed for this case;
    /// this test exists only to make that traceability explicit for
    /// the empty-snapshot contract's part (c), alongside its AppDelegate-
    /// level siblings in AppDelegateEmptyPreservedSnapshotTests.swift.
    func test_emptyPreservedSnapshot_neverShowsBar_sameAsNothingPreserved() {
        // AppDelegate must feed this model `false` (not `true`) for an
        // empty preserved snapshot -- there is no separate "empty" state
        // at the model level, only the same boolean an absent snapshot
        // already produces.
        let model = RecoveryBarModel(hasPreservedSessionSnapshot: false)

        XCTAssertFalse(model.showRecoveryBar,
                       "an empty preserved snapshot has nothing to recover and must never show the bar")

        // Even if some future caller mistakenly re-broadcasts `true` for
        // an empty snapshot, dismiss remains available as the user's own
        // last-resort escape hatch -- but the CORRECT fix is AppDelegate
        // never sending `true` for this case at all (see the sibling
        // AppDelegate-level tests), not relying on this.
    }
}
