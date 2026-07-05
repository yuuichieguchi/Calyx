//
//  SessionReconnectGiveUpTests.swift
//  CalyxTests
//
//  Controller-level coverage for the give-up redesign (review
//  findings): `SessionReconnectDecision.giveUp` now closes the pane
//  DETERMINISTICALLY, with DETACH (not kill) semantics, instead of
//  being left dangling for a later keypress to close.
//
//  Drives `CalyxWindowController.handleSessionReconnectDecision
//  (surfaceID:decision:)` directly (made non-private for this purpose
//  — see its P4 review-fix doc comment) with `.giveUp`, rather than
//  exhausting `maxReconnectAttempts` through a live
//  `SessionReconnectCoordinator` + daemon round-trip:
//  `SessionReconnectCoordinatorTests` already fully covers the
//  coordinator's own contract (repeated `.unreachable` -> `.giveUp`
//  after the cap). This file covers only what `CalyxWindowController`
//  does once that decision is delivered.
//
//  Coverage:
//  - `.giveUp` removes the given-up leaf from the split tree (the pane
//    actually closes, right now — not deferred to a later keypress)
//  - `.giveUp` clears `tab.sessionRefs` for that leaf
//  - `.giveUp` clears `SessionSurfaceMap.shared`'s entry for that leaf
//    (detach semantics — see `detachSessionIfPersistent`'s doc
//    comment; unlike `killSessionIfPersistent`, that method never
//    calls `SessionDaemonClient.kill`, which has no injectable seam at
//    this call site to spy on directly)
//  - A stale surfaceID (the pane was already closed some other way) is
//    a safe no-op
//
//  ROUND-4 FIX ADDITIONS (RED phase, r4-fix-spec.md F1/F2/F4/F5):
//  everything below this point is new coverage added for the round-4
//  fix batch. The tests above (two-pane fixture) are untouched and
//  their coverage/behavior is unchanged.
//
//  - F1/T1: `.giveUp` on a pane that is last-pane-everywhere AND
//    `closingWouldTerminate` must NOT close the pane and must NOT
//    consult the confirm-quit gate at all, detach bookkeeping only,
//    leaving the leaf in the split tree (contrast with the two-pane
//    tests above, whose `.giveUp` DOES close the pane, that multi-pane
//    behavior is explicitly unchanged by F1).
//  - F2/T2 (`handleReconnectGiveUp`'s own insert, not
//    `closeFocusedSessionSurface`'s, see `SessionCommandPaletteTests`
//    for that one): the multi-pane close branch must insert `tab.id`
//    into `closingTabIDs` before tearing the surface down, observed via
//    a `NotificationManager` spy (the call already happens before
//    `closeSurfaceAndCleanUp` in the current code, giving a convenient,
//    already-present mid-sequence checkpoint, no new seam beyond the
//    `_closingTabIDsForTesting` read-only accessor and the
//    `NotificationManager.shared` swap seam was needed for this one).
//  - F4/T4: while `AppDelegate.isConfirmingQuit` is true (driven via
//    the `_setConfirmingQuitForTesting` test seam, since a real
//    `NSAlert.runModal()` would block the test run and the gate is
//    otherwise unreachable in this fixture, which has no live ghostty
//    surfaces to make `ghostty_app_needs_confirm_quit` true),
//    `handleSessionReconnectDecision` must defer the decision instead
//    of dropping it, and replay it once the gate clears. RESIDUAL GAP:
//    only `handleSessionReconnectDecision` is covered here.
//    `handleShowChildExitedNotification`'s identical guard is NOT
//    separately covered, it kicks off an async `Task` into
//    `sessionReconnectCoordinator.childExited(surfaceID:)`, which has
//    no injection seam at this call site (the coordinator is
//    constructed internally with the real `SessionDaemonClient.shared`)
//    and would require a live daemon round-trip to observe
//    deterministically. Uses `.giveUp` (detach semantics), not
//    `.closePane`, so this test never triggers
//    `killSessionIfPersistent`'s real `SessionDaemonClient.shared.kill`
//    subprocess call for a fake test session ID, the gate itself is
//    decision-agnostic (checked once, before the `switch`), so `.giveUp`
//    exercises the identical guard `.closePane` would.
//  - F5/T5: the give-up notification body must no longer claim
//    scrollback/commands are "lost", and must tell the user the session
//    may still be running, observed via the same `NotificationManager`
//    spy as F2/T2 above (`NotificationManager.shared` is swappable and
//    `sendNotification` overridable specifically for this, see that
//    file's own test-seam doc comment; production `sendNotification` is
//    otherwise unobservable in the test host, since `permissionGranted`
//    is never set `true` under `XCTestCase`).
//
//  ROUND-6 FIX ADDITIONS (RED phase, r6-fix-spec.md R6-A): round-4's F4
//  defer mechanism above is itself unsafe (r5-verdicts.md V1/V5):
//  synchronous, nested replay with no shutdown awareness. Covers the
//  unified, asynchronous-drain redesign: a decision deferred mid-modal
//  during a CANCELLED close must still be applied once the caller's own
//  post-modal bookkeeping has run, not lost (V1 cancel path); a deferred
//  event must NOT be replayed while the app is actually terminating (V5);
//  a replay landing during a second, already-active modal must re-defer,
//  not apply early (item 4); and `handleCloseSurfaceNotification` must
//  defer (not immediately tear down) a close_surface notification the
//  same way (items 1/2, V2/V3). See each test's own doc comment for its
//  specific CURRENT-code failure mode.
//

import XCTest
import AppKit
@testable import Calyx

@MainActor
final class SessionReconnectGiveUpTests: XCTestCase {

    /// sessionIDs registered with `SessionSurfaceMap.shared` by
    /// `makeFixture()`, so `tearDown` can unregister exactly those
    /// entries rather than nuking the whole shared singleton (review
    /// finding: fixtures registered sessions here but never
    /// unregistered them, leaking entries into other tests that share
    /// the same process-wide singleton).
    private var registeredSessionIDs: [String] = []

    override func tearDown() {
        for sessionID in registeredSessionIDs {
            SessionSurfaceMap.shared.unregister(sessionID: sessionID)
        }
        registeredSessionIDs.removeAll()
        super.tearDown()
    }

    /// Two-pane fixture (R8-G item G2, r8-fix-spec.md: shared with
    /// `CalyxWindowControllerNonLastWindowCloseTests`, see
    /// `TwoPaneSessionFixture`'s own header comment): `trackedLeafID`
    /// carries a `SessionRef` (both in `tab.sessionRefs` and
    /// `SessionSurfaceMap.shared`); `siblingLeafID` is an ordinary,
    /// untracked pane. Two panes (rather than a single-leaf tab) keep
    /// `closeSurfaceAndCleanUp`'s tab/window-removal branch out of play,
    /// that cascade is normal, pre-existing behavior exercised
    /// elsewhere, not this test's concern, and it would otherwise invoke
    /// `window.close()`.
    private func makeFixture() -> TwoPaneSessionFixture {
        let fixture = makeTwoPaneSessionFixture()
        registeredSessionIDs.append(fixture.sessionID)
        return fixture
    }

    func test_giveUp_closesPaneDeterministically_leavesSiblingPaneIntact() {
        let fixture = makeFixture()

        fixture.controller.handleSessionReconnectDecision(surfaceID: fixture.trackedLeafID, decision: .giveUp)

        XCTAssertEqual(fixture.tab.splitTree.allLeafIDs(), [fixture.siblingLeafID],
                       "giveUp must close the pane right now (remove its leaf from the split tree), not " +
                       "leave it dangling for a later keypress to close")
    }

    func test_giveUp_detachesRatherThanLeaksSessionTracking() {
        let fixture = makeFixture()

        fixture.controller.handleSessionReconnectDecision(surfaceID: fixture.trackedLeafID, decision: .giveUp)

        XCTAssertNil(fixture.tab.sessionRefs[fixture.trackedLeafID],
                    "giveUp must clear tab.sessionRefs for the given-up leaf, not leak it into the next " +
                    "snapshot (a review finding: the prior 'leave the pane dangling' design never cleared " +
                    "this)")
        XCTAssertNil(SessionSurfaceMap.shared.sessionID(for: fixture.trackedLeafID),
                    "giveUp must clear SessionSurfaceMap's entry for the given-up leaf")
    }

    /// The pane was already closed some other way before the decision
    /// arrived — `findTabAndGroup` finds nothing, so this must be a
    /// safe no-op, not a crash, and must not touch any real tab.
    func test_giveUp_staleSurfaceID_isSafeNoOp() {
        let fixture = makeFixture()
        let staleSurfaceID = UUID()

        fixture.controller.handleSessionReconnectDecision(surfaceID: staleSurfaceID, decision: .giveUp)

        XCTAssertEqual(
            Set(fixture.tab.splitTree.allLeafIDs()),
            Set([fixture.trackedLeafID, fixture.siblingLeafID]),
            "A stale surfaceID must not affect any real tab's split tree"
        )
        XCTAssertNotNil(SessionSurfaceMap.shared.sessionID(for: fixture.trackedLeafID),
                        "A stale surfaceID must not detach an unrelated, still-live session")
    }

    // MARK: - F1/T1: last-pane-everywhere give-up must not close/terminate

    /// Single-pane/single-tab/single-group fixture: the sole leaf
    /// carries a `SessionRef`, tracked in both `tab.sessionRefs` and
    /// `SessionSurfaceMap.shared`, the "closing this pane empties the
    /// window" case `isLastPaneEverywhere` gates on. Mirrors
    /// `SessionCommandPaletteTests.makeSinglePaneFixture()`.
    private struct SinglePaneFixture {
        let controller: CalyxWindowController
        let tab: Tab
        let leafID: UUID
        let sessionID: String
    }

    private func makeSinglePaneFixture() -> SinglePaneFixture {
        let registry = SurfaceRegistry()
        let leafID = UUID()
        registry._testInsert(view: SurfaceView(frame: .zero), id: leafID)

        let sessionID = "test-session-\(UUID().uuidString)"
        let tab = Tab(
            splitTree: SplitTree(leafID: leafID),
            registry: registry,
            sessionRefs: [leafID: SessionRef(sessionID: sessionID)]
        )
        SessionSurfaceMap.shared.register(sessionID: sessionID, surfaceID: leafID)
        registeredSessionIDs.append(sessionID)

        let group = TabGroup(name: "Default", tabs: [tab], activeTabID: tab.id)
        let session = WindowSession(groups: [group], activeGroupID: group.id)
        let window = CalyxWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        let controller = CalyxWindowController(window: window, windowSession: session, restoring: true)
        return SinglePaneFixture(controller: controller, tab: tab, leafID: leafID, sessionID: sessionID)
    }

    /// `AppDelegate` subclass reporting `closingWouldTerminate == true`
    /// unconditionally (so `isLastPaneEverywhere && closingWouldTerminate`
    /// is satisfied for `SinglePaneFixture`) and counting
    /// `confirmQuitIfNeeded` calls, F1's redesigned last-pane-everywhere
    /// `.giveUp` branch must never reach it at all. `removeWindowController`
    /// is a no-op purely as test-process safety, matching
    /// `SessionCommandPaletteTests.MockConfirmQuitAppDelegate`'s reasoning:
    /// if F1 is NOT yet implemented, `.giveUp` still closes the pane here
    /// (the current, pre-fix behavior), which empties the window and
    /// calls `window?.close()` -> `windowWillClose` -> `removeWindowController`.
    private final class LastPaneGiveUpMockAppDelegate: AppDelegate {
        private(set) var confirmQuitCallCount = 0

        override func closingWouldTerminate(_ controller: CalyxWindowController) -> Bool {
            true
        }

        override func confirmQuitIfNeeded(_ mode: ConfirmQuitMode = .killProcesses) -> Bool {
            confirmQuitCallCount += 1
            return true
        }

        override func removeWindowController(_ controller: CalyxWindowController) {}
    }

    /// F1 (V01, CRITICAL): the last-pane-everywhere `.giveUp` branch
    /// must switch from "close the pane" to "detach bookkeeping only,
    /// leave the leaf in place", no modal, no window close, no app
    /// termination. Against the CURRENT code, this fails because
    /// `handleReconnectGiveUp` still gates on and calls
    /// `confirmQuitBeforeCloseIfWouldTerminate`, then closes the pane
    /// once confirmed (mirroring the existing two-pane tests above),
    /// emptying the tab/group.
    func test_giveUp_lastPaneEverywhere_doesNotCloseOrConsultConfirmQuitGate() {
        let fixture = makeSinglePaneFixture()
        let mock = LastPaneGiveUpMockAppDelegate()
        let originalDelegate = NSApp.delegate
        NSApp.delegate = mock
        defer { NSApp.delegate = originalDelegate }

        withExtendedLifetime(mock) {
            fixture.controller.handleSessionReconnectDecision(surfaceID: fixture.leafID, decision: .giveUp)
        }

        XCTAssertEqual(mock.confirmQuitCallCount, 0,
                       "The redesigned last-pane-everywhere .giveUp branch must never consult the " +
                       "confirm-quit gate at all, no modal, since the pane isn't being closed")
        XCTAssertEqual(fixture.tab.splitTree.allLeafIDs(), [fixture.leafID],
                       "The pane must remain in the split tree, .giveUp must leave the leaf in place, " +
                       "not close it")
        XCTAssertNil(fixture.tab.sessionRefs[fixture.leafID],
                    "Detach bookkeeping must still clear tab.sessionRefs for the given-up leaf")
        XCTAssertNil(SessionSurfaceMap.shared.sessionID(for: fixture.leafID),
                    "Detach bookkeeping must still clear SessionSurfaceMap's entry for the given-up leaf")
        XCTAssertEqual(fixture.controller.windowSession.groups.count, 1,
                       "The group/tab must remain in place, the window must not be emptied or closed")
    }

    // MARK: - F2/T2 & F5/T5: closingTabIDs insertion + corrected notification text

    /// `NotificationManager` subclass spying on `sendNotification`
    /// instead of going through `UNUserNotificationCenter` (a no-op in
    /// the test host regardless, see `NotificationManager`'s own
    /// test-seam doc comment). Also captures
    /// `CalyxWindowController._closingTabIDsForTesting` AT THE MOMENT
    /// `sendNotification` fires, `handleReconnectGiveUp` calls
    /// `NotificationManager.shared.sendNotification` before
    /// `closeSurfaceAndCleanUp` in the current code, giving a
    /// conveniently-already-present mid-sequence checkpoint for F2's
    /// "insert into closingTabIDs before tearing the surface down"
    /// contract, without needing to simulate real ghostty reentrancy.
    private final class GiveUpNotificationSpy: NotificationManager {
        weak var controller: CalyxWindowController?
        private(set) var observedClosingTabIDs: Set<UUID>?
        private(set) var lastBody: String?

        override func sendNotification(title: String, body: String, tabID: UUID) {
            lastBody = body
            observedClosingTabIDs = controller?._closingTabIDsForTesting
        }
    }

    /// F2 (V02, CRITICAL): `handleReconnectGiveUp`'s multi-pane close
    /// branch (the one that survives F1's last-pane-everywhere carve-out
    /// unchanged) must insert `tab.id` into `closingTabIDs` BEFORE
    /// tearing the surface down, mirroring `closeTab`'s insert-then-
    /// teardown ordering. Against the CURRENT code, `closingTabIDs` is
    /// never touched by this method at all, so the observed set is
    /// empty at notification time.
    func test_giveUp_multiPane_insertsTabIntoClosingTabIDs_beforeTeardown() {
        let fixture = makeFixture()
        let spy = GiveUpNotificationSpy()
        spy.controller = fixture.controller
        let originalManager = NotificationManager.shared
        NotificationManager.shared = spy
        defer { NotificationManager.shared = originalManager }

        fixture.controller.handleSessionReconnectDecision(surfaceID: fixture.trackedLeafID, decision: .giveUp)

        XCTAssertEqual(spy.observedClosingTabIDs, [fixture.tab.id],
                       "handleReconnectGiveUp's remaining (multi-pane) close branch must insert tab.id " +
                       "into closingTabIDs before tearing the surface down, mirroring closeTab's ordering")
    }

    /// F5 (V06, MEDIUM): the give-up notification text must no longer
    /// claim scrollback/commands are lost (false in the reachable
    /// `.running`/`.unreachable` cases this branch fires for, the
    /// daemon-side PTY is setsid'd and browser attach() reattaches the
    /// SAME session), and must no longer frame reattachment as only
    /// possible via a brand-new session with the same ID (the current
    /// text's "start a new session with the same ID" implies the old
    /// one is gone, which is false here). Against the CURRENT text,
    /// both assertions fail: it says "...are lost" and "start a new
    /// session with the same ID".
    ///
    /// NOTE: deliberately does NOT assert `body.contains("running")` as
    /// a stand-in for "tells the user the session may still be running",
    /// the CURRENT text already contains that substring incidentally
    /// (as part of "...scrollback and running commands... are lost"),
    /// which would make that assertion pass today for the wrong reason
    /// (a test that can't fail proves nothing, see this project's test
    /// authoring rules). "new session" is the substring that actually
    /// distinguishes the false "only a new session is possible" framing
    /// from the corrected text.
    func test_giveUp_notificationText_noLongerClaimsSessionIsLostOrOnlyRecoverableAsNew() {
        let fixture = makeFixture()
        let spy = GiveUpNotificationSpy()
        spy.controller = fixture.controller
        let originalManager = NotificationManager.shared
        NotificationManager.shared = spy
        defer { NotificationManager.shared = originalManager }

        fixture.controller.handleSessionReconnectDecision(surfaceID: fixture.trackedLeafID, decision: .giveUp)

        let body = spy.lastBody?.lowercased() ?? ""
        XCTAssertFalse(body.contains("lost"),
                       "The notification must not claim scrollback/commands are lost, the session may " +
                       "still be fully intact and reattachable from the session browser")
        XCTAssertFalse(body.contains("new session"),
                       "The notification must not frame recovery as only possible via a brand-new " +
                       "session, the daemon session itself may still be reattachable as-is")
    }

    // MARK: - F4/T4: defer, don't drop, a decision gated on isConfirmingQuit

    /// F4 (V05, HIGH): while `AppDelegate.isConfirmingQuit` is true,
    /// `handleSessionReconnectDecision` must defer the decision instead
    /// of dropping it, and replay it once the gate clears, a dropped
    /// `.giveUp` currently has no recovery path (see r4-verdicts.md V05).
    /// `isConfirmingQuit` is driven via the `_setConfirmingQuitForTesting`
    /// test seam rather than a real `confirmQuitIfNeeded`/`NSAlert
    /// .runModal()`: this fixture has no live ghostty surfaces, so
    /// `ghostty_app_needs_confirm_quit` is always false and the real
    /// gate is unreachable here regardless of mocking.
    ///
    /// Uses `.giveUp` (detach semantics) rather than `.closePane`
    /// (kill semantics) so this test never triggers
    /// `killSessionIfPersistent`'s real `SessionDaemonClient.shared.kill`
    /// subprocess call for a fake test session ID, the
    /// `isConfirmingQuit` guard is checked once, before the `switch` on
    /// `decision`, so it is exercised identically regardless of which
    /// case follows.
    ///
    /// RESIDUAL GAP: only `handleSessionReconnectDecision` is exercised
    /// here. `handleShowChildExitedNotification`'s identical guard is
    /// NOT separately covered (see this file's header comment), no
    /// injection seam exists for `sessionReconnectCoordinator`'s async
    /// daemon round-trip without a larger, invasive refactor.
    func test_handleSessionReconnectDecision_deferredWhileConfirmingQuit_thenReplayedAfterGateClears() {
        let fixture = makeFixture()
        let appDelegate = AppDelegate()
        let originalDelegate = NSApp.delegate
        NSApp.delegate = appDelegate
        defer { NSApp.delegate = originalDelegate }

        appDelegate._setConfirmingQuitForTesting(true)
        fixture.controller.handleSessionReconnectDecision(surfaceID: fixture.trackedLeafID, decision: .giveUp)

        XCTAssertEqual(
            Set(fixture.tab.splitTree.allLeafIDs()),
            Set([fixture.trackedLeafID, fixture.siblingLeafID]),
            "While isConfirmingQuit is true, a .giveUp decision must be deferred, not dropped or applied " +
            "immediately"
        )

        appDelegate._setConfirmingQuitForTesting(false)

        // R6-A (r6-fix-spec.md, r5-verdicts.md V1/V5): the drain is now
        // scheduled on a fresh MainActor turn rather than replaying
        // synchronously inside the didSet, so the replay's effect must
        // be observed after pumping (via `pumpRunLoop`, defined further
        // down in this file's ROUND-6 section, called directly since
        // Swift methods are visible throughout their enclosing type
        // regardless of declaration order), not immediately. The
        // CONTRACT under test (a decision deferred while confirming quit
        // is eventually replayed once the gate clears, not permanently
        // lost) is unchanged; only the synchronization needed to observe
        // it is updated to match the now-intentionally-asynchronous
        // timing.
        pumpRunLoop(timeout: 1.0) {
            !fixture.tab.splitTree.allLeafIDs().contains(fixture.trackedLeafID)
        }

        XCTAssertEqual(fixture.tab.splitTree.allLeafIDs(), [fixture.siblingLeafID],
                       "Once isConfirmingQuit clears, the deferred .giveUp decision must be replayed, not " +
                       "permanently lost")
    }

    // MARK: - ROUND-6 FIX ADDITIONS (RED phase, r6-fix-spec.md R6-A)
    //
    // r5-verdicts.md's V1/V5 CONFIRMED the round-4 defer mechanism above
    // (F4) is itself unsafe: the `isConfirmingQuit` didSet replays
    // deferred events SYNCHRONOUSLY, nested inside whatever call flipped
    // the flag back to false (`confirmQuitIfNeeded`'s own bracket),
    // BEFORE that caller's own post-modal bookkeeping (e.g.
    // `windowShouldClose`'s cancel-path `closingTabIDs.subtract`) has run,
    // and with no awareness of real app termination. R6-A's fix is an
    // asynchronous drain (a fresh MainActor turn, so the caller's stack
    // unwinds first) plus a shutdown-suppression check. Tests below pump
    // the main run loop with a bounded deadline rather than assuming a
    // synchronous effect, since the fix is expected to make the drain
    // genuinely asynchronous.

    /// Spins the run loop in short steps, checking `condition()` after
    /// each, until it returns `true` or `timeout` elapses. Lets a test
    /// observe an asynchronously-scheduled MainActor `Task`'s effect
    /// deterministically (bounded wait, no fixed `sleep`) rather than
    /// assuming any particular synchronous timing. Mirrors this
    /// codebase's own `AppDelegate.saveImmediately`/`restoreSession`
    /// bounded-spin style.
    private func pumpRunLoop(timeout: TimeInterval, until condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        }
    }

    /// `AppDelegate` subclass simulating a red-button/last-window close
    /// that the user CANCELS, with a `.giveUp` decision arriving mid-modal
    /// (e.g. from `SessionReconnectCoordinator`'s background `Task`):
    /// the exact CONFIRMED collision in r5-verdicts.md V1's cancel-path
    /// sub-claim. `confirmQuitIfNeeded` here stands in for the real
    /// method's `isConfirmingQuit = true; alert.runModal(); isConfirmingQuit
    /// = false` bracket (driven via the `_setConfirmingQuitForTesting` seam,
    /// since a real blocking `NSAlert.runModal()` can't run in this test
    /// host; same reasoning as F4's test above), firing the deferred
    /// decision partway through, then returning `false` (Cancel) exactly
    /// like `windowShouldClose`'s own cancel path expects.
    private final class CancelPathReplayAppDelegate: AppDelegate {
        weak var controller: CalyxWindowController?
        var surfaceIDToDefer: UUID?

        override func closingWouldTerminate(_ controller: CalyxWindowController) -> Bool { true }

        override func confirmQuitIfNeeded(_ mode: ConfirmQuitMode = .killProcesses) -> Bool {
            _setConfirmingQuitForTesting(true)
            if let surfaceIDToDefer {
                controller?.handleSessionReconnectDecision(surfaceID: surfaceIDToDefer, decision: .giveUp)
            }
            _setConfirmingQuitForTesting(false)
            return false
        }

        override func removeWindowController(_ controller: CalyxWindowController) {}
    }

    /// R6-A item 6, first bullet (r5-verdicts.md V1 cancel-path): drives
    /// the REAL `windowShouldClose(_:)`, which pre-populates
    /// `closingTabIDs` with every tab in the window (F3) BEFORE calling
    /// `confirmQuitIfNeeded`, our mock fires the deferred `.giveUp`
    /// WHILE `closingTabIDs` still contains this tab (mid-modal), then
    /// cancels. `windowShouldClose` only subtracts `closingTabIDs` AFTER
    /// `confirmQuitIfNeeded` returns.
    ///
    /// Against the CURRENT code, the drain runs SYNCHRONOUSLY inside the
    /// mock's `confirmQuitIfNeeded` (nested inside the `isConfirmingQuit
    /// = false` assignment), i.e. BEFORE `windowShouldClose`'s own
    /// `closingTabIDs.subtract` has run, so the replayed decision hits
    /// `handleReconnectGiveUp`'s reentrancy guard (`closingTabIDs` still
    /// contains this tab) and is silently dropped, never re-deferred.
    /// The fixed (asynchronous) drain must instead run on a fresh
    /// MainActor turn, after `windowShouldClose` has fully unwound and
    /// removed this tab from `closingTabIDs`, so the replay finds the
    /// guard clear and actually applies the decision.
    func test_giveUp_deferredDuringWindowShouldCloseCancelPath_isAppliedAfterClosingTabIDsSubtract_notLost() throws {
        let fixture = makeFixture()
        let mock = CancelPathReplayAppDelegate()
        mock.controller = fixture.controller
        mock.surfaceIDToDefer = fixture.trackedLeafID
        let window = try XCTUnwrap(fixture.controller.window)

        let originalDelegate = NSApp.delegate
        NSApp.delegate = mock
        defer { NSApp.delegate = originalDelegate }

        let shouldClose = withExtendedLifetime(mock) {
            fixture.controller.windowShouldClose(window)
        }
        XCTAssertFalse(shouldClose, "Cancelling the confirm-quit prompt must return false")

        pumpRunLoop(timeout: 1.0) {
            !fixture.tab.splitTree.allLeafIDs().contains(fixture.trackedLeafID)
        }

        XCTAssertEqual(fixture.tab.splitTree.allLeafIDs(), [fixture.siblingLeafID],
                       "A .giveUp decision deferred mid-modal during a CANCELLED close must still be " +
                       "applied once windowShouldClose's own closingTabIDs.subtract has run, losing it " +
                       "silently downgrades the pane's eventual keypress-close to kill semantics instead " +
                       "of the intended detach (see r5-verdicts.md V1)")
        XCTAssertNil(SessionSurfaceMap.shared.sessionID(for: fixture.trackedLeafID),
                    "The eventually-applied decision must still run detach bookkeeping")
    }

    /// R6-A item 3 (shutdown suppression, r5-verdicts.md V5): while the
    /// app is actually terminating (`AppDelegate.isApplicationTerminating`,
    /// new this round, see its own doc comment in AppDelegate.swift; a
    /// broader, app-wide signal than any one window's
    /// `isClosingForShutdown`), a deferred decision must NOT be replayed
    /// at all once the confirm-quit gate clears: `windowWillClose`'s
    /// teardown during quit intentionally PRESERVES `sessionRefs` into
    /// the snapshot (see `CalyxWindowControllerNonLastWindowCloseTests`),
    /// so replaying a `.giveUp`/`.closePane` decision on top of that is
    /// both unnecessary and dangerous (r5-verdicts.md V5: a replayed
    /// decision's teardown can cascade into `window?.close()` ->
    /// `removeWindowController` -> reentrant `NSApp.terminate` from
    /// inside `applicationWillTerminate`).
    ///
    /// Against the CURRENT code, `isApplicationTerminating` does not
    /// exist as a concept the drain consults at all (it is a new,
    /// not-yet-wired seam, see AppDelegate.swift), so the deferred
    /// decision is applied regardless of it, exactly as the F4 test
    /// above already proves for the non-terminating case.
    func test_handleSessionReconnectDecision_deferredEvent_notReplayed_whileApplicationIsTerminating() {
        let fixture = makeFixture()
        let appDelegate = AppDelegate()
        let originalDelegate = NSApp.delegate
        NSApp.delegate = appDelegate
        defer { NSApp.delegate = originalDelegate }

        appDelegate._setApplicationTerminatingForTesting(true)
        appDelegate._setConfirmingQuitForTesting(true)
        fixture.controller.handleSessionReconnectDecision(surfaceID: fixture.trackedLeafID, decision: .giveUp)

        appDelegate._setConfirmingQuitForTesting(false)
        pumpRunLoop(timeout: 1.0) {
            !fixture.tab.splitTree.allLeafIDs().contains(fixture.trackedLeafID)
        }

        XCTAssertEqual(
            Set(fixture.tab.splitTree.allLeafIDs()),
            Set([fixture.trackedLeafID, fixture.siblingLeafID]),
            "While the app is actually terminating, a decision deferred while isConfirmingQuit was true " +
            "must NOT be replayed once that gate clears, quit's own teardown already preserves tracking " +
            "state into the snapshot; replaying on top of that is exactly r5-verdicts.md V5's hazard"
        )
        XCTAssertNotNil(SessionSurfaceMap.shared.sessionID(for: fixture.trackedLeafID),
                        "...and must leave SessionSurfaceMap's entry untouched, matching the preserve-not-" +
                        "teardown contract quit teardown relies on")
    }

    /// R6-A item 4 (re-defer on back-to-back modals): a deferred decision
    /// whose replay would land while `isConfirmingQuit` is ALREADY true
    /// again (a second confirm-quit modal already up, e.g. two closes
    /// racing) must re-defer via the SAME mechanism, not apply early or
    /// drop. `handleSessionReconnectDecision`'s own entry guard gives
    /// this "for free" once replay genuinely re-enters the public
    /// handler on a later, asynchronous turn.
    ///
    /// Against the CURRENT code, the drain is synchronous: it runs
    /// immediately inside the very `_setConfirmingQuitForTesting(false)`
    /// call below, before this test ever gets a chance to flip
    /// `isConfirmingQuit` true again, so the decision is always applied
    /// immediately, with no window for a second modal to matter at all.
    func test_handleSessionReconnectDecision_replayLandingDuringSecondModal_reDefersInsteadOfApplying() {
        let fixture = makeFixture()
        let appDelegate = AppDelegate()
        let originalDelegate = NSApp.delegate
        NSApp.delegate = appDelegate
        defer { NSApp.delegate = originalDelegate }

        appDelegate._setConfirmingQuitForTesting(true)
        fixture.controller.handleSessionReconnectDecision(surfaceID: fixture.trackedLeafID, decision: .giveUp)

        appDelegate._setConfirmingQuitForTesting(false)
        // A second modal is already up by the time the deferred drain's
        // scheduled turn would arrive.
        appDelegate._setConfirmingQuitForTesting(true)

        pumpRunLoop(timeout: 0.5) {
            !fixture.tab.splitTree.allLeafIDs().contains(fixture.trackedLeafID)
        }

        XCTAssertEqual(
            Set(fixture.tab.splitTree.allLeafIDs()),
            Set([fixture.trackedLeafID, fixture.siblingLeafID]),
            "A replay landing while a second confirm-quit modal is already active must re-defer, not apply " +
            "the decision. The pane must still be intact"
        )

        // Only once the gate is genuinely, finally clear must the
        // decision actually land.
        appDelegate._setConfirmingQuitForTesting(false)
        pumpRunLoop(timeout: 1.0) {
            !fixture.tab.splitTree.allLeafIDs().contains(fixture.trackedLeafID)
        }

        XCTAssertEqual(fixture.tab.splitTree.allLeafIDs(), [fixture.siblingLeafID],
                       "Once no modal remains active, the re-deferred decision must eventually be applied, " +
                       "not permanently dropped")
    }

    /// R6-A items 1/2 (defer close_surface too, r5-verdicts.md V3/V2):
    /// `handleCloseSurfaceNotification` must defer (not immediately tear
    /// down) a `.ghosttyCloseSurface` notification for a tracked surface
    /// while `isConfirmingQuit` is true, and replay it once the gate
    /// clears, mirroring the `.decision`/`.childExited` deferral F4
    /// already established. Posts the real notification
    /// `ghosttyCloseSurfaceCallback` posts (see GhosttyApp.swift), rather
    /// than calling the `@objc private` handler directly, since
    /// `NotificationCenter` dispatch doesn't care about access control:
    /// this exercises the exact production entry point.
    ///
    /// Against the CURRENT code, `handleCloseSurfaceNotification` has NO
    /// `isConfirmingQuit` guard at all. It tears the pane down
    /// immediately, regardless of the gate. The primary RED-proving
    /// assertion is therefore the first one below (still both panes
    /// immediately after posting, while the gate is up): against today's
    /// code the pane is ALREADY gone at that point, so it fails.
    func test_handleCloseSurfaceNotification_deferredWhileConfirmingQuit_thenReplayedAfterGateClears() {
        let fixture = makeFixture()
        let appDelegate = AppDelegate()
        let originalDelegate = NSApp.delegate
        NSApp.delegate = appDelegate
        defer { NSApp.delegate = originalDelegate }

        guard let trackedSurfaceView = fixture.tab.registry.view(for: fixture.trackedLeafID) else {
            XCTFail("makeFixture's _testInsert must make the tracked leaf's SurfaceView resolvable")
            return
        }

        appDelegate._setConfirmingQuitForTesting(true)
        NotificationCenter.default.post(
            name: .ghosttyCloseSurface, object: trackedSurfaceView, userInfo: ["process_alive": false]
        )

        XCTAssertEqual(
            Set(fixture.tab.splitTree.allLeafIDs()),
            Set([fixture.trackedLeafID, fixture.siblingLeafID]),
            "A close_surface notification arriving while isConfirmingQuit is true must be deferred, not " +
            "torn down immediately. This is the primary RED-proving assertion for this test"
        )

        appDelegate._setConfirmingQuitForTesting(false)
        pumpRunLoop(timeout: 1.0) {
            !fixture.tab.splitTree.allLeafIDs().contains(fixture.trackedLeafID)
        }

        XCTAssertEqual(fixture.tab.splitTree.allLeafIDs(), [fixture.siblingLeafID],
                       "Once isConfirmingQuit clears, the deferred close_surface event must be replayed, " +
                       "tearing the pane down exactly once")
        XCTAssertNil(SessionSurfaceMap.shared.sessionID(for: fixture.trackedLeafID),
                    "The replayed close must run the same kill/detach teardown an immediate close would")
    }
}
