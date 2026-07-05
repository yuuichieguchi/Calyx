//
//  AppDelegateAttachWindowTests.swift
//  CalyxTests
//
//  TDD Red phase for round-4 fix F6/T6 (r4-fix-spec.md; evidence in
//  r4-verdicts.md S1/known-defect #3): `AppDelegate.attachWindow
//  (sessionID:cwd:)`, the session browser's "Attach" action for a
//  running, no-live-surface session, must not create a second
//  window/attach when `sessionID` is ALREADY registered in
//  `SessionSurfaceMap.shared` (the double-click / stale-row race:
//  browser rows only refresh on poll, and `attachWindow` has no
//  debounce of its own).
//
//  SAFETY / WHY THIS USES A SEAM INSTEAD OF DRIVING THE REAL FUNCTION:
//  An earlier version of this test called the real, unmodified
//  `attachWindow(sessionID:cwd:)` directly (pre-registering
//  `SessionSurfaceMap` so the fix's guard, once implemented, would
//  return before doing anything). Against the CURRENT, unfixed code,
//  this reliably HUNG the entire XCTest process indefinitely: with no
//  guard, `attachWindow` proceeds to `restoreTabSurfaces` (a real
//  `GhosttySurfaceController`/ghostty surface) and `wc.showWindow(nil)`
//  (a real `NSWindow` display), and no other test anywhere in this
//  suite creates a real ghostty surface or calls `showWindow` for real
//  (grepped the whole `CalyxTests` target to confirm), which is why
//  this was never previously exercised. The hung process had to be
//  killed manually; retrying it is not an acceptable RED-phase check.
//
//  Instead, this file uses `AppDelegate._attachWindowCreationHookForTesting`,
//  a minimal seam (`nil` by default, so production behavior is
//  unchanged) inserted at the EXACT point `attachWindow` is about to
//  construct a real window/surface, which the fix's guard sits BEFORE.
//  Every guard `attachWindow` runs before reaching this hook, the
//  CURRENT (buggy) code's total absence of one, and the eventual FIX's
//  `SessionSurfaceMap` check, is real, unmodified production code
//  exercised for real by these tests; only the actually-unsafe window/
//  surface creation itself is replaced with a counting closure.
//

import XCTest
import AppKit
@testable import Calyx

@MainActor
final class AppDelegateAttachWindowTests: XCTestCase {

    /// Against the CURRENT code, `attachWindow` never checks
    /// `SessionSurfaceMap` before reaching the window-creation hook, so
    /// the hook fires once (expected: zero times) and the pre-existing
    /// mapping would end up overwritten in the real (non-hooked)
    /// implementation.
    ///
    /// R6-D (r6-fix-spec.md) fixture update: a stale mapping (registered,
    /// but no controller anywhere contains the surfaceID) now legitimately
    /// proceeds to a fresh attach instead of silently doing nothing (see
    /// `AppDelegateFocusExistingSessionTests`'s stale-mapping coverage),
    /// so this test's fixture must give the mapped surfaceID a genuine
    /// owning controller (via `_testInsertWindowController`, mirroring
    /// `AppDelegateFocusExistingSessionTests.makeTwoTabFixture`) to keep
    /// testing a LIVE mapping, the case this test's name and contract
    /// actually cover. `_focusWindowForExistingSessionShowHookForTesting`
    /// replaces the real `wc.showWindow(nil)` call for the same test-
    /// process-safety reason `AppDelegateFocusExistingSessionTests` uses
    /// it. Flagged in this round's handoff (see both files' headers).
    func test_attachWindow_forAlreadyRegisteredSessionID_neverReachesWindowCreation() {
        let appDelegate = AppDelegate()
        var creationHookCallCount = 0
        appDelegate._attachWindowCreationHookForTesting = { creationHookCallCount += 1 }
        var showHookCallCount = 0
        appDelegate._focusWindowForExistingSessionShowHookForTesting = { _ in showHookCallCount += 1 }

        let sessionID = "test-session-\(UUID().uuidString)"
        let existingSurfaceID = UUID()

        let registry = SurfaceRegistry()
        registry._testInsert(view: SurfaceView(frame: .zero), id: existingSurfaceID)
        let tab = Tab(splitTree: SplitTree(leafID: existingSurfaceID), registry: registry)
        let group = TabGroup(name: "Default", tabs: [tab], activeTabID: tab.id)
        let session = WindowSession(groups: [group], activeGroupID: group.id)
        let window = CalyxWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        let controller = CalyxWindowController(window: window, windowSession: session, restoring: true)
        appDelegate._testInsertWindowController(controller)

        SessionSurfaceMap.shared.register(sessionID: sessionID, surfaceID: existingSurfaceID)
        defer { SessionSurfaceMap.shared.unregister(sessionID: sessionID) }

        appDelegate.attachWindow(sessionID: sessionID, cwd: nil)

        XCTAssertEqual(creationHookCallCount, 0,
                       "attachWindow must not reach window/surface creation at all for a sessionID " +
                       "already registered in SessionSurfaceMap, the session already has a live surface " +
                       "somewhere in this process")
        XCTAssertEqual(showHookCallCount, 1,
                       "attachWindow must focus the controller already hosting this session's live " +
                       "surface exactly once")
        XCTAssertEqual(SessionSurfaceMap.shared.surfaceID(for: sessionID), existingSurfaceID,
                       "The pre-existing SessionSurfaceMap mapping must be preserved, not replaced by a " +
                       "new surface")
    }

    /// Sanity/regression companion: for a sessionID with NO existing
    /// `SessionSurfaceMap` entry, `attachWindow` must still reach the
    /// window-creation step exactly once, proving the seam itself
    /// doesn't accidentally short-circuit the ordinary (not-already-
    /// attached) case. Passes against both the current and fixed code;
    /// included so a future regression that over-broadens the guard
    /// (e.g. always skipping) would be caught here.
    func test_attachWindow_forUnattachedSessionID_stillReachesWindowCreation() {
        let appDelegate = AppDelegate()
        var creationHookCallCount = 0
        appDelegate._attachWindowCreationHookForTesting = { creationHookCallCount += 1 }

        let sessionID = "test-session-\(UUID().uuidString)"
        // Deliberately NOT registered in SessionSurfaceMap.

        appDelegate.attachWindow(sessionID: sessionID, cwd: nil)

        XCTAssertEqual(creationHookCallCount, 1,
                       "attachWindow must still proceed to window/surface creation for a sessionID with " +
                       "no existing SessionSurfaceMap entry")
    }
}
