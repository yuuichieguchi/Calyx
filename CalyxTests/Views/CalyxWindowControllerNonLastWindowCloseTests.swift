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

    private struct WindowCloseFixture {
        let controller: CalyxWindowController
        let tab: Tab
        let trackedLeafID: UUID
        let siblingLeafID: UUID
        let sessionID: String
    }

    /// Two-pane, single-tab, single-group window: `trackedLeafID` carries
    /// a `SessionRef` (registered in both `tab.sessionRefs` and
    /// `SessionSurfaceMap.shared`); `siblingLeafID` is an ordinary,
    /// untracked pane, present only so the fixture isn't a degenerate
    /// single-surface case. Mirrors `SessionReconnectGiveUpTests
    /// .makeFixture()`.
    private func makeFixture() -> WindowCloseFixture {
        let registry = SurfaceRegistry()
        let trackedLeafID = UUID()
        let siblingLeafID = UUID()
        registry._testInsert(view: SurfaceView(frame: .zero), id: trackedLeafID)
        registry._testInsert(view: SurfaceView(frame: .zero), id: siblingLeafID)

        let root = SplitNode.split(SplitData(
            direction: .horizontal,
            ratio: 0.5,
            first: .leaf(id: trackedLeafID),
            second: .leaf(id: siblingLeafID)
        ))
        let sessionID = "test-session-\(UUID().uuidString)"
        let tab = Tab(
            splitTree: SplitTree(root: root, focusedLeafID: trackedLeafID),
            registry: registry,
            sessionRefs: [trackedLeafID: SessionRef(sessionID: sessionID)]
        )
        SessionSurfaceMap.shared.register(sessionID: sessionID, surfaceID: trackedLeafID)

        let group = TabGroup(name: "Default", tabs: [tab], activeTabID: tab.id)
        let session = WindowSession(groups: [group], activeGroupID: group.id)
        let window = CalyxWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        let controller = CalyxWindowController(window: window, windowSession: session, restoring: true)
        return WindowCloseFixture(
            controller: controller, tab: tab,
            trackedLeafID: trackedLeafID, siblingLeafID: siblingLeafID, sessionID: sessionID
        )
    }

    private final class NoTerminateAppDelegate: AppDelegate {
        override func removeWindowController(_ controller: CalyxWindowController) {}
    }

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
        defer { SessionSurfaceMap.shared.unregister(sessionID: fixture.sessionID) }

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
        defer { SessionSurfaceMap.shared.unregister(sessionID: fixture.sessionID) }

        withMockAppDelegate(mock) {
            fixture.controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        }

        XCTAssertEqual(SessionSurfaceMap.shared.sessionID(for: fixture.trackedLeafID), fixture.sessionID,
                      "While the app is actually terminating, windowWillClose's destroy loop must preserve " +
                      "the SessionSurfaceMap entry into the shutdown snapshot, not tear it down")
        XCTAssertNotNil(fixture.tab.sessionRefs[fixture.trackedLeafID],
                        "...and must preserve tab.sessionRefs too, so the next launch can restore/reattach it")
    }
}
