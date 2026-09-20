//
//  NSWindowCalyxCloseTests.swift
//  CalyxTests
//
//  GitHub issue #45. Full root-cause writeup:
//  `NSWindow+CalyxClose.swift`'s header comment.
//
//  Exercises `NSWindow.calyxPerformClose(_:)`'s DEFAULT behavior — i.e.
//  the base `NSWindow` extension, not `CalyxWindow`'s override — on a
//  PLAIN, bare `NSWindow` (About/Settings/Session Browser stand-in;
//  none of those subclass `CalyxWindow`, so they all fall through to
//  this exact default implementation). Deliberately does NOT construct a
//  `CalyxWindowController` at all: these windows' delegate is this
//  file's own tiny test double, never `CalyxWindowController`, so the
//  real `window?.close()` cascade this codebase's other close-path
//  suites warn about (`window?.close()` -> `windowWillClose` ->
//  `AppDelegate.removeWindowController` -> `NSApp.terminate(nil)`, see
//  `CalyxWindowControllerCloseWindowTests`'s header and
//  `AppDelegateCloseAllWindowsTests`'s DANGER note) cannot happen here —
//  there is no `CalyxWindowController` anywhere in this file for that
//  cascade to reach. `windowShouldClose(_:)` always returns `false`
//  below for the same reason belt-and-suspenders: even if some future
//  change routed through a real `close()`, a `false` answer stops it
//  before any teardown notification fires.
//
//  Both windows use `.closable` in their `styleMask`: `NSWindow
//  .performClose(_:)` (the obvious, established building block for a
//  correct `calyxPerformClose(_:)` default — see `NSWindow+CalyxClose
//  .swift`'s header on why `processCloseWindow()` already depends on
//  `performClose(nil)`'s own delegate-consulting behavior) beeps and
//  returns WITHOUT consulting the delegate at all for a non-closable
//  window, which would make the first test below fail for the wrong
//  reason against a correct implementation.
//
//  What each test pins:
//   - `test_calyxPerformClose_onPlainWindow_queriesWindowShouldClose`
//     pins the fix: the pre-fix stub body was empty, so the delegate was
//     never queried (`windowShouldCloseCallCount` stayed 0, not 1).
//   - `test_calyxPerformClose_onSheetWindow_doesNotQueryWindowShouldClose`
//     is a regression guard: "the delegate was
//     never queried" is trivially true against the same empty stub. It
//     protects the OTHER half of the contract — that a sheet must never
//     be closed by Cmd+W (`ClipboardConfirmationController` presents a
//     sheet holding an in-flight libghostty clipboard request; skipping
//     its own `endSheet` would leave that surface waiting forever) —
//     against a future implementation that navigates straight to
//     `performClose`/`close` without ever checking `sheetParent` first.
//

import XCTest
import AppKit
@testable import Calyx

@MainActor
final class NSWindowCalyxCloseTests: XCTestCase {

    // MARK: - Test double

    /// Always answers `false` (never actually close) and records how
    /// many times AppKit asked.
    private final class RecordingDelegate: NSObject, NSWindowDelegate {
        private(set) var windowShouldCloseCallCount = 0

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            windowShouldCloseCallCount += 1
            return false
        }
    }

    // MARK: - Window factory

    private func makeBareWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        // Bare `NSWindow` defaults `isReleasedWhenClosed` to `true`
        // (unlike `CalyxWindow`, which sets `false` in `setupWindow()`):
        // since `windowShouldClose` always returns `false` here, nothing
        // in these tests actually reaches the point that flag guards,
        // but every existing fixture in this codebase disables it
        // defensively before ever calling a close-family method on a
        // real `NSWindow`, and this file follows the same discipline.
        window.isReleasedWhenClosed = false
        return window
    }

    // MARK: - No sheet: windowShouldClose IS queried (pins the fix)

    func test_calyxPerformClose_onPlainWindow_queriesWindowShouldClose() {
        let window = makeBareWindow()
        let delegate = RecordingDelegate()
        window.delegate = delegate
        defer {
            window.delegate = nil
            window.orderOut(nil)
        }

        window.calyxPerformClose(nil)

        XCTAssertEqual(
            delegate.windowShouldCloseCallCount, 1,
            "calyxPerformClose(_:) must consult windowShouldClose(_:) exactly like performClose(_:) does, " +
            "so every existing windowShouldClose gate (confirm-quit, unsent-review-comments, etc.) keeps working"
        )
    }

    // MARK: - Sheet: windowShouldClose is NOT queried (regression guard)

    /// Precondition-checked via `sheetParent` right after `beginSheet`:
    /// if attachment silently failed on this host, this fails with a
    /// clear message instead of the real assertion below passing for
    /// the wrong reason.
    func test_calyxPerformClose_onSheetWindow_doesNotQueryWindowShouldClose() {
        let parent = makeBareWindow()
        let sheet = makeBareWindow()
        let delegate = RecordingDelegate()
        sheet.delegate = delegate
        defer {
            sheet.delegate = nil
            parent.endSheet(sheet)
            sheet.orderOut(nil)
            parent.orderOut(nil)
        }

        parent.beginSheet(sheet)

        XCTAssertNotNil(sheet.sheetParent, "Precondition: beginSheet(_:) must attach sheet to parent")

        sheet.calyxPerformClose(nil)

        XCTAssertEqual(
            delegate.windowShouldCloseCallCount, 0,
            "A window presented as a sheet must never be closed by Cmd+W via windowShouldClose/performClose — " +
            "ClipboardConfirmationController's sheet holds an in-flight libghostty clipboard request that only " +
            "its own explicit endSheet may resolve; skipping it leaves the surface waiting forever"
        )
    }
}
