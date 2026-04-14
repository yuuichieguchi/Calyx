//
//  CalyxWindowControllerFullScreenTests.swift
//  CalyxTests
//
//  Tests for Issue #26 Part B — fullscreen persistence state tracking on
//  `CalyxWindowController`.
//
//  The controller must gain:
//  - `var trackedFullScreen: Bool` (default false)
//  - `var preFullScreenFrame: NSRect?` (default nil)
//  - `var isClosingForShutdown: Bool` (default false)
//  - Delegate callbacks: `windowWillEnterFullScreen(_:)`, `windowDidEnterFullScreen(_:)`,
//    `windowDidExitFullScreen(_:)`.
//  - An updated `windowSnapshot()` that returns `isFullScreen = trackedFullScreen`
//    and, when tracking fullscreen, saves `preFullScreenFrame ?? window?.frame`
//    so that the persisted frame is the pre-fullscreen one, not the screen-filling
//    one.
//  - An updated `windowDidExitFullScreen(_:)` that preserves the tracking state
//    when `isClosingForShutdown == true` (so the snapshot at app shutdown still
//    records fullscreen + the pre-fullscreen frame).
//
//  We do NOT drive real `NSWindow` fullscreen transitions here because
//  `toggleFullScreen(_:)` requires a real screen and is asynchronous. Instead,
//  we invoke the delegate callbacks directly with a stub `Notification` and
//  manipulate the tracking properties to verify `windowSnapshot()`.
//
//  These tests target symbols that do NOT exist in the codebase yet. They are
//  expected to FAIL compile until the TDD Green phase implements the feature.
//

import AppKit
import XCTest
@testable import Calyx

@MainActor
final class CalyxWindowControllerFullScreenTests: XCTestCase {

    // MARK: - Helpers

    /// Build a minimal `CalyxWindowController` for direct delegate invocation.
    /// We pass `restoring: true` so the controller does NOT call
    /// `setupTerminalSurface()`, which requires a live Ghostty app instance.
    private func makeController() -> CalyxWindowController {
        let window = CalyxWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        let tab = Tab(title: "Shell")
        let group = TabGroup(name: "Default", tabs: [tab], activeTabID: tab.id)
        let session = WindowSession(groups: [group], activeGroupID: group.id)
        return CalyxWindowController(window: window, windowSession: session, restoring: true)
    }

    /// Build a bare `Notification` for a window-fullscreen delegate invocation.
    private func makeNotification(_ name: Notification.Name) -> Notification {
        Notification(name: name)
    }

    // MARK: - Initial State

    /// Before any fullscreen event, all tracking state should be false/nil.
    func test_trackedFullScreen_defaults_false() {
        let controller = makeController()

        XCTAssertFalse(
            controller.trackedFullScreen,
            "trackedFullScreen should default to false on a fresh controller"
        )
        XCTAssertNil(
            controller.preFullScreenFrame,
            "preFullScreenFrame should default to nil on a fresh controller"
        )
        XCTAssertFalse(
            controller.isClosingForShutdown,
            "isClosingForShutdown should default to false on a fresh controller"
        )
    }

    // MARK: - Will Enter Full Screen

    /// On `windowWillEnterFullScreen`, the controller must capture the current
    /// window frame into `preFullScreenFrame` — that is the frame we want to
    /// persist to disk so restart restores to it.
    func test_windowWillEnterFullScreen_captures_preFullScreenFrame() {
        let controller = makeController()
        let expectedFrame = NSRect(x: 100, y: 100, width: 1000, height: 700)
        controller.window?.setFrame(expectedFrame, display: false)

        controller.windowWillEnterFullScreen(
            makeNotification(NSWindow.willEnterFullScreenNotification)
        )

        XCTAssertNotNil(
            controller.preFullScreenFrame,
            "preFullScreenFrame must be captured on windowWillEnterFullScreen"
        )
        XCTAssertEqual(
            controller.preFullScreenFrame?.origin.x,
            expectedFrame.origin.x,
            "preFullScreenFrame.origin.x must match the window frame at the moment of entry"
        )
        XCTAssertEqual(
            controller.preFullScreenFrame?.origin.y,
            expectedFrame.origin.y,
            "preFullScreenFrame.origin.y must match the window frame at the moment of entry"
        )
        XCTAssertEqual(
            controller.preFullScreenFrame?.size.width,
            expectedFrame.size.width,
            "preFullScreenFrame.width must match the window frame at the moment of entry"
        )
        XCTAssertEqual(
            controller.preFullScreenFrame?.size.height,
            expectedFrame.size.height,
            "preFullScreenFrame.height must match the window frame at the moment of entry"
        )
    }

    // MARK: - Did Enter Full Screen

    /// On `windowDidEnterFullScreen`, the controller must set
    /// `trackedFullScreen = true`.
    func test_windowDidEnterFullScreen_sets_trackedFullScreen_true() {
        let controller = makeController()

        controller.windowDidEnterFullScreen(
            makeNotification(NSWindow.didEnterFullScreenNotification)
        )

        XCTAssertTrue(
            controller.trackedFullScreen,
            "trackedFullScreen should be true after windowDidEnterFullScreen"
        )
    }

    // MARK: - Did Exit Full Screen — Not Closing

    /// When the user exits fullscreen interactively (e.g. via Control+Cmd+F or
    /// the menu) and the window is NOT closing for shutdown, the tracking
    /// state must reset so subsequent snapshots reflect the normal windowed
    /// state.
    func test_windowDidExitFullScreen_resets_when_not_closing() {
        let controller = makeController()
        controller.trackedFullScreen = true
        controller.preFullScreenFrame = NSRect(x: 1, y: 2, width: 3, height: 4)
        controller.isClosingForShutdown = false

        controller.windowDidExitFullScreen(
            makeNotification(NSWindow.didExitFullScreenNotification)
        )

        XCTAssertFalse(
            controller.trackedFullScreen,
            "trackedFullScreen should reset to false on interactive exit"
        )
        XCTAssertNil(
            controller.preFullScreenFrame,
            "preFullScreenFrame should reset to nil on interactive exit"
        )
    }

    // MARK: - Did Exit Full Screen — Closing For Shutdown

    /// When the app is terminating and the system exits fullscreen just before
    /// closing the window, the controller MUST preserve the tracking state so
    /// the snapshot taken at shutdown still records `isFullScreen = true` and
    /// the correct pre-fullscreen frame.
    func test_windowDidExitFullScreen_preserves_tracking_when_closing() {
        let controller = makeController()
        let preservedFrame = NSRect(x: 1, y: 2, width: 3, height: 4)
        controller.trackedFullScreen = true
        controller.preFullScreenFrame = preservedFrame
        controller.isClosingForShutdown = true

        controller.windowDidExitFullScreen(
            makeNotification(NSWindow.didExitFullScreenNotification)
        )

        XCTAssertTrue(
            controller.trackedFullScreen,
            "trackedFullScreen MUST remain true when exiting during shutdown"
        )
        XCTAssertNotNil(
            controller.preFullScreenFrame,
            "preFullScreenFrame MUST remain non-nil when exiting during shutdown"
        )
        XCTAssertEqual(
            controller.preFullScreenFrame?.origin.x,
            preservedFrame.origin.x,
            "preFullScreenFrame.origin.x must be preserved during shutdown exit"
        )
        XCTAssertEqual(
            controller.preFullScreenFrame?.origin.y,
            preservedFrame.origin.y,
            "preFullScreenFrame.origin.y must be preserved during shutdown exit"
        )
        XCTAssertEqual(
            controller.preFullScreenFrame?.size.width,
            preservedFrame.size.width,
            "preFullScreenFrame.width must be preserved during shutdown exit"
        )
        XCTAssertEqual(
            controller.preFullScreenFrame?.size.height,
            preservedFrame.size.height,
            "preFullScreenFrame.height must be preserved during shutdown exit"
        )
    }

    // MARK: - windowSnapshot() — Not Full Screen

    /// When not tracking fullscreen, `windowSnapshot()` must return the actual
    /// window frame and `isFullScreen = false`.
    func test_windowSnapshot_not_fullscreen_uses_window_frame() {
        let controller = makeController()
        controller.trackedFullScreen = false
        controller.preFullScreenFrame = nil
        let windowFrame = NSRect(x: 10, y: 20, width: 800, height: 600)
        controller.window?.setFrame(windowFrame, display: false)

        let snapshot = controller.windowSnapshot()

        XCTAssertEqual(
            snapshot.frame.origin.x,
            windowFrame.origin.x,
            "Non-fullscreen snapshot must use the window's actual origin.x"
        )
        XCTAssertEqual(
            snapshot.frame.origin.y,
            windowFrame.origin.y,
            "Non-fullscreen snapshot must use the window's actual origin.y"
        )
        XCTAssertEqual(
            snapshot.frame.size.width,
            windowFrame.size.width,
            "Non-fullscreen snapshot must use the window's actual width"
        )
        XCTAssertEqual(
            snapshot.frame.size.height,
            windowFrame.size.height,
            "Non-fullscreen snapshot must use the window's actual height"
        )
        XCTAssertFalse(
            snapshot.isFullScreen,
            "Non-fullscreen snapshot must report isFullScreen = false"
        )
    }

    // MARK: - windowSnapshot() — Full Screen Uses preFullScreenFrame

    /// When tracking fullscreen and we have a saved pre-fullscreen frame, the
    /// snapshot MUST return that frame, not the current (screen-filling)
    /// window frame.
    func test_windowSnapshot_fullscreen_uses_preFullScreenFrame() {
        let controller = makeController()
        let preFrame = NSRect(x: 50, y: 60, width: 900, height: 700)
        controller.trackedFullScreen = true
        controller.preFullScreenFrame = preFrame
        // Simulate the screen-filling fullscreen frame as the current window frame.
        let fullscreenFrame = NSRect(x: 0, y: 0, width: 1920, height: 1080)
        controller.window?.setFrame(fullscreenFrame, display: false)

        let snapshot = controller.windowSnapshot()

        XCTAssertEqual(
            snapshot.frame.origin.x,
            preFrame.origin.x,
            "Fullscreen snapshot must use preFullScreenFrame.origin.x, not the current window frame"
        )
        XCTAssertEqual(
            snapshot.frame.origin.y,
            preFrame.origin.y,
            "Fullscreen snapshot must use preFullScreenFrame.origin.y, not the current window frame"
        )
        XCTAssertEqual(
            snapshot.frame.size.width,
            preFrame.size.width,
            "Fullscreen snapshot must use preFullScreenFrame.width, not the current window frame"
        )
        XCTAssertEqual(
            snapshot.frame.size.height,
            preFrame.size.height,
            "Fullscreen snapshot must use preFullScreenFrame.height, not the current window frame"
        )
        XCTAssertTrue(
            snapshot.isFullScreen,
            "Fullscreen snapshot must report isFullScreen = true"
        )
    }

    // MARK: - windowSnapshot() — Full Screen With Nil preFullScreenFrame

    /// If we are tracking fullscreen but somehow have no saved pre-fullscreen
    /// frame (e.g. app launched directly into fullscreen), the snapshot must
    /// fall back to the current window frame so we still persist something
    /// meaningful rather than `.zero`.
    func test_windowSnapshot_fullscreen_falls_back_to_window_frame_when_preFullScreenFrame_nil() {
        let controller = makeController()
        controller.trackedFullScreen = true
        controller.preFullScreenFrame = nil
        let windowFrame = NSRect(x: 10, y: 20, width: 800, height: 600)
        controller.window?.setFrame(windowFrame, display: false)

        let snapshot = controller.windowSnapshot()

        XCTAssertEqual(
            snapshot.frame.origin.x,
            windowFrame.origin.x,
            "Fullscreen snapshot without preFullScreenFrame must fall back to window frame origin.x"
        )
        XCTAssertEqual(
            snapshot.frame.origin.y,
            windowFrame.origin.y,
            "Fullscreen snapshot without preFullScreenFrame must fall back to window frame origin.y"
        )
        XCTAssertEqual(
            snapshot.frame.size.width,
            windowFrame.size.width,
            "Fullscreen snapshot without preFullScreenFrame must fall back to window frame width"
        )
        XCTAssertEqual(
            snapshot.frame.size.height,
            windowFrame.size.height,
            "Fullscreen snapshot without preFullScreenFrame must fall back to window frame height"
        )
        XCTAssertTrue(
            snapshot.isFullScreen,
            "Fullscreen snapshot (even without preFullScreenFrame) must report isFullScreen = true"
        )
    }

    // MARK: - !isRestoring Guard — State Mutation During Restore
    //
    // The `!isRestoring` guards inside `windowDidEnterFullScreen(_:)` and
    // `windowDidExitFullScreen(_:)` exist so that when `AppDelegate.restoreWindow`
    // reapplies a persisted fullscreen snapshot, the intermediate
    // fullscreen-transition notifications fired by AppKit do NOT trigger a
    // `requestSave()` that would persist a half-transitioned frame on disk.
    //
    // CONSTRAINT: `isRestoring` is declared `private` on `CalyxWindowController`,
    // so tests cannot toggle it directly. We control it indirectly by:
    //   - Constructing the controller with `restoring: true` (the default path
    //     used by `makeController()`, which puts the controller into the
    //     "restoring" state).
    //   - Calling `activateRestoredSession()` on the same controller to leave
    //     the restoring state (flips `isRestoring` to `false`).
    //
    // CONSTRAINT: `requestSave()` is `private` AND its only observable effect
    // is dispatching to `(NSApp.delegate as? AppDelegate)?.requestSave()`,
    // which is a no-op in the unit-test process because `NSApp.delegate` is
    // not a real `AppDelegate`. There is therefore NO observable hook we can
    // assert against from tests without modifying production code.
    //
    // Given those constraints, these tests lock in the OTHER observable
    // behavior of the guarded blocks: the state mutations (`trackedFullScreen`
    // and `preFullScreenFrame`) happen unconditionally, i.e. regardless of
    // `isRestoring`. If a future refactor accidentally moves the state
    // mutation INSIDE the `!isRestoring` branch, these tests will catch it.

    /// During the restoring phase (`isRestoring == true`), a
    /// `windowDidEnterFullScreen` event must still flip `trackedFullScreen`
    /// to `true` — the guard only suppresses the save, not the state mutation.
    func test_windowDidEnterFullScreen_mutates_state_during_restore() {
        // `makeController()` constructs the controller with `restoring: true`,
        // so `isRestoring` is `true` here.
        let controller = makeController()
        XCTAssertFalse(
            controller.trackedFullScreen,
            "Precondition: trackedFullScreen should be false before the event"
        )

        controller.windowDidEnterFullScreen(
            makeNotification(NSWindow.didEnterFullScreenNotification)
        )

        XCTAssertTrue(
            controller.trackedFullScreen,
            "trackedFullScreen must be set to true even while isRestoring == true; "
                + "the !isRestoring guard only suppresses the save, not the state update"
        )
    }

    /// During the restoring phase (`isRestoring == true`), a
    /// `windowDidExitFullScreen` event must still reset the tracking state —
    /// the guard only suppresses the save, not the state mutation.
    func test_windowDidExitFullScreen_mutates_state_during_restore() {
        // `makeController()` constructs the controller with `restoring: true`.
        let controller = makeController()
        controller.trackedFullScreen = true
        controller.preFullScreenFrame = NSRect(x: 1, y: 2, width: 3, height: 4)
        controller.isClosingForShutdown = false

        controller.windowDidExitFullScreen(
            makeNotification(NSWindow.didExitFullScreenNotification)
        )

        XCTAssertFalse(
            controller.trackedFullScreen,
            "trackedFullScreen must reset to false even while isRestoring == true"
        )
        XCTAssertNil(
            controller.preFullScreenFrame,
            "preFullScreenFrame must reset to nil even while isRestoring == true"
        )
    }

    /// After `activateRestoredSession()` has been called, `isRestoring` flips
    /// to `false`. A subsequent `windowDidEnterFullScreen` event must still
    /// mutate the tracking state correctly, matching the normal
    /// post-restore path where the save is no longer suppressed.
    ///
    /// Note: we cannot directly assert that `requestSave()` was called here
    /// because the private method routes through `NSApp.delegate` which is
    /// not a real `AppDelegate` in the test process. We instead lock in the
    /// state mutation as the observable contract of this branch.
    func test_windowDidEnterFullScreen_mutates_state_after_restore() {
        let controller = makeController()
        // Leave the restoring phase. After this call, `isRestoring == false`.
        controller.activateRestoredSession()
        XCTAssertFalse(
            controller.trackedFullScreen,
            "Precondition: trackedFullScreen should still be false after "
                + "activateRestoredSession() (it only flips isRestoring)"
        )

        controller.windowDidEnterFullScreen(
            makeNotification(NSWindow.didEnterFullScreenNotification)
        )

        XCTAssertTrue(
            controller.trackedFullScreen,
            "trackedFullScreen must be true after windowDidEnterFullScreen "
                + "in the post-restore (non-restoring) state"
        )
    }
}
