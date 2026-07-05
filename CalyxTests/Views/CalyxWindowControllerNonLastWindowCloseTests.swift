//
//  CalyxWindowControllerNonLastWindowCloseTests.swift
//  CalyxTests
//
//  TDD Red phase for round-6 fix R6-D (r6-fix-spec.md; sweep finding in
//  r5-verdicts.md): `windowWillClose`'s destroy loop currently runs the
//  SAME direct `tab.registry.destroySurface(id)` teardown unconditionally,
//  whether this window is closing on its own (app not terminating, a
//  red-button close on one of several open windows) or as part of a real
//  quit (app terminating, whose snapshot must still see this window's
//  persistent sessions). Today it NEVER calls `killSessionIfPersistent`/
//  `detachSessionIfPersistent`/`SessionCloseKillPolicy` at all, so:
//  - Closing a non-last window orphans every persistent surface it held:
//    `SessionSurfaceMap` keeps pointing at a UUID no window's registry
//    contains any more, and `tab.sessionRefs` is simply discarded with
//    the tab (this window's own snapshot is never saved, since
//    `AppDelegate.removeWindowController` only re-saves the SURVIVING
//    windows). A later `attachWindow` for that sessionID hits the stale
//    mapping and (today) silently does nothing at all (see
//    `AppDelegateFocusExistingSessionTests`'s stale-mapping coverage).
//  - Quitting the app (the ONE case this direct-destroy behavior is
//    actually correct for) happens to look identical today, since
//    nothing distinguishes the two cases.
//
//  The intended fix: run each persistent surface through the same
//  close-policy teardown `closeTab` already uses (kill semantics, an
//  explicit window close) UNLESS the app is actually terminating, in
//  which case today's preserve-into-snapshot behavior must stay exactly
//  as it is (`AppDelegate.isApplicationTerminating`, new in this round,
//  see its own doc comment, is the discriminator; the window's own
//  `isClosingForShutdown` alone is NOT enough, since `closeLastWindow`
//  also sets that flag for a non-terminating close, per round-5 finding
//  I2).
//
//  Drives `windowWillClose(_:)` directly with a bare `Notification`
//  (mirrors `CalyxWindowControllerFullScreenTests`'s established
//  pattern for this exact delegate method) against a `_testInsert`-only,
//  no-live-ghostty-surface fixture (this codebase's established pattern;
//  see `SessionReconnectGiveUpTests`). `NSApp.delegate` is swapped for a
//  `removeWindowController`-no-op `AppDelegate` subclass for test-process
//  safety (mirrors `CalyxWindowControllerCloseArmsTests`'s
//  `ConfirmingAppDelegate` and this file's siblings' identical reasoning:
//  the default implementation calls `NSApp.terminate(nil)` once its
//  `windowControllers` list is empty, which it always is here since this
//  fixture's controller is never added to it).
//

import XCTest
import AppKit
@testable import Calyx

@MainActor
final class CalyxWindowControllerNonLastWindowCloseTests: XCTestCase {

    // MARK: - Fixture

    /// sessionIDs registered with `SessionSurfaceMap.shared` by
    /// `makeFixture()`, unregistered in `tearDown` (R8-G item G2,
    /// r8-fix-spec.md: the single cleanup pattern this file now shares
    /// with `SessionReconnectGiveUpTests`, whose original discipline
    /// this mirrors).
    private var registeredSessionIDs: [String] = []

    override func tearDown() {
        for sessionID in registeredSessionIDs {
            SessionSurfaceMap.shared.unregister(sessionID: sessionID)
        }
        registeredSessionIDs.removeAll()
        super.tearDown()
    }

    /// Two-pane, single-tab, single-group window (R8-G item G2,
    /// r8-fix-spec.md: shared with `SessionReconnectGiveUpTests`, see
    /// `TwoPaneSessionFixture`'s own header comment): `trackedLeafID`
    /// carries a `SessionRef` (registered in both `tab.sessionRefs` and
    /// `SessionSurfaceMap.shared`); `siblingLeafID` is an ordinary,
    /// untracked pane, present only so the fixture isn't a degenerate
    /// single-surface case.
    private func makeFixture() -> TwoPaneSessionFixture {
        let fixture = makeTwoPaneSessionFixture()
        registeredSessionIDs.append(fixture.sessionID)
        return fixture
    }

    /// R8-G item G3 (r8-fix-spec.md; verified behavior-neutral):
    /// subclasses `ConfirmQuitMockAppDelegate` (R6-J) instead of
    /// `AppDelegate` directly, consolidating this file's mock with the
    /// rest of the suite's shared base. `ConfirmQuitMockAppDelegate`'s
    /// `closingWouldTerminate` override (always `true`) is inert for
    /// every test in this file: none of them drive `windowShouldClose`,
    /// only `windowWillClose` directly, which never calls it.
    private final class NoTerminateAppDelegate: ConfirmQuitMockAppDelegate {}

    private func withMockAppDelegate(_ mock: NoTerminateAppDelegate, _ body: () -> Void) {
        let original = NSApp.delegate
        NSApp.delegate = mock
        defer { NSApp.delegate = original }
        withExtendedLifetime(mock) {
            body()
        }
    }

    /// R6-D (sweep finding, r5-verdicts.md): against the CURRENT code,
    /// `windowWillClose`'s destroy loop never calls `killSessionIfPersistent`/
    /// `detachSessionIfPersistent`/`SessionCloseKillPolicy` at all, it
    /// destroys every surface directly, leaving `SessionSurfaceMap` and
    /// `tab.sessionRefs` untouched regardless of whether the app is
    /// terminating. This is the PRIMARY RED-proving assertion: with the
    /// app NOT terminating (`isApplicationTerminating == false`, the
    /// default, a red-button close on one of several open windows),
    /// closing must run the normal close policy and unregister/clear the
    /// persistent surface's tracking, exactly like `closeTab` already
    /// does for an explicit tab close.
    func test_windowWillClose_nonTerminatingClose_unregistersAndClearsPersistentSession() {
        let fixture = makeFixture()
        let mock = NoTerminateAppDelegate()

        XCTAssertFalse(fixture.controller.isClosingForShutdown,
                      "Precondition: a plain, non-last-window red-button close never sets isClosingForShutdown " +
                      "before windowWillClose fires (only closeLastWindow/windowShouldClose's last-window arm " +
                      "do that)")
        XCTAssertFalse(mock.isApplicationTerminating, "Precondition: the app is not terminating in this scenario")

        withMockAppDelegate(mock) {
            fixture.controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        }

        XCTAssertNil(SessionSurfaceMap.shared.sessionID(for: fixture.trackedLeafID),
                    "Closing a window while the app is NOT terminating must unregister each persistent " +
                    "surface's SessionSurfaceMap entry through the normal close policy, leaving it " +
                    "registered orphans it: no window's registry contains this (now-destroyed) surfaceID " +
                    "any more")
        XCTAssertNil(fixture.tab.sessionRefs[fixture.trackedLeafID],
                    "...and must clear tab.sessionRefs for it too, matching closeTab's close-policy semantics " +
                    "for an explicit, non-quit window close")
    }

    /// Regression guard (r6-fix-spec.md R6-D), NOT a RED-proving test:
    /// while the app IS actually terminating (`isApplicationTerminating
    /// == true`, mirroring `markAllControllersClosingForShutdown` having
    /// run, which also sets the window's own `isClosingForShutdown`),
    /// `windowWillClose` must PRESERVE `SessionSurfaceMap`/`sessionRefs`
    /// into the shutdown snapshot, exactly as it already does today.
    /// This assertion passes against BOTH the current code (which never
    /// touches either at all) and the intended fix (which must
    /// deliberately skip the close-policy call in this branch), it
    /// exists to catch a future regression where the R6-D fix accidentally
    /// starts running kill/detach unconditionally, not to prove the fix
    /// is currently missing.
    func test_windowWillClose_terminatingClose_preservesSessionRefsIntoSnapshot() {
        let fixture = makeFixture()
        let mock = NoTerminateAppDelegate()
        mock._setApplicationTerminatingForTesting(true)
        fixture.controller.isClosingForShutdown = true

        withMockAppDelegate(mock) {
            fixture.controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        }

        XCTAssertEqual(SessionSurfaceMap.shared.sessionID(for: fixture.trackedLeafID), fixture.sessionID,
                      "While the app is actually terminating, windowWillClose's destroy loop must preserve " +
                      "the SessionSurfaceMap entry into the shutdown snapshot, not tear it down")
        XCTAssertNotNil(fixture.tab.sessionRefs[fixture.trackedLeafID],
                        "...and must preserve tab.sessionRefs too, so the next launch can restore/reattach it")
    }

    // MARK: - R8-C: one canonical termination discriminator

    /// R8-C (r8-fix-spec.md; consolidates r7-verdicts.md's I1/A2/C2
    /// dormant discriminator-mismatch finding): windowWillClose's outer
    /// loop gates on isAppActuallyTerminating (app-level:
    /// AppDelegate.isApplicationTerminating || isTerminationConfirmed),
    /// but killSessionIfPersistent's inner SessionCloseKillPolicy call
    /// passes isTerminating: isClosingForShutdown, this window's own,
    /// narrower flag. No production call path sets isClosingForShutdown
    /// true while the app is genuinely not terminating today (see
    /// r7-verdicts.md R7-V2, REFUTED for that reason), but the mismatch
    /// itself is real: with isClosingForShutdown true and the app NOT
    /// terminating, the outer gate correctly decides to run the close
    /// policy, but the inner policy independently reads its own
    /// isClosingForShutdown (true) as "terminating" and refuses to
    /// kill, leaving the persistent session's mapping in place even
    /// though the outer gate already decided otherwise. This test locks
    /// the invariant that both layers must read the SAME discriminator,
    /// so this mismatch cannot silently resurface on a future call path.
    func test_windowWillClose_isClosingForShutdownTrueButAppNotTerminating_stillKillsPersistentSession() {
        let fixture = makeFixture()
        let mock = NoTerminateAppDelegate()
        fixture.controller.isClosingForShutdown = true

        XCTAssertFalse(mock.isApplicationTerminating, "Precondition: the app is not terminating in this scenario")
        XCTAssertFalse(mock.isTerminationConfirmed, "Precondition: termination has not been confirmed either")

        withMockAppDelegate(mock) {
            fixture.controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        }

        XCTAssertNil(SessionSurfaceMap.shared.sessionID(for: fixture.trackedLeafID),
                    "windowWillClose's outer 'is the app actually terminating' gate and the inner kill " +
                    "policy must read the SAME discriminator: with isClosingForShutdown true but the app " +
                    "genuinely not terminating, the outer gate already decided to run the close policy, the " +
                    "inner policy must not independently refuse and leave this mapping in place")
        XCTAssertNil(fixture.tab.sessionRefs[fixture.trackedLeafID],
                    "...and must clear tab.sessionRefs too, matching the outer gate's kill decision")
    }
}
