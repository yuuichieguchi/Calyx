//
//  CalyxWindowControllerMarkTerminationConfirmedTests.swift
//  CalyxTests
//
//  TDD Red phase for round-8 fix R8-A (r8-fix-spec.md; evidence in
//  r7-verdicts.md R7-V1): windowShouldClose's last-window success
//  branch (CalyxWindowController.swift, near :2778) sets
//  appDelegate.isTerminationConfirmed = true unconditionally, using
//  only its ENTRY closingWouldTerminate check (taken before
//  confirmQuitIfNeeded's modal ever runs). A quick-terminal toggle can
//  fire mid-modal (GlobalEventTap's CGEventTap runs on .commonModes,
//  which includes NSModalPanelRunLoopMode, see r7-verdicts.md R7-V1),
//  making the close no longer terminating by the time the modal
//  returns. The existing re-checking helper,
//  markTerminationConfirmedIfWouldTerminate(), already exists for
//  exactly this case (closeLastWindow already uses it), but this one
//  inline site never re-checks, it just trusts its stale entry-time
//  result.
//
//  Scripts closingWouldTerminate to return true on its FIRST call (the
//  entry check) and false on every call after (standing in for the
//  quick terminal appearing during confirmQuitIfNeeded's modal),
//  subclassing ConfirmQuitMockAppDelegate (R6-J) and overriding
//  closingWouldTerminate again for this per-call scripting.
//

import XCTest
import AppKit
@testable import Calyx

@MainActor
final class CalyxWindowControllerMarkTerminationConfirmedTests: XCTestCase {

    // MARK: - Fixture

    private struct SingleTabFixture {
        let controller: CalyxWindowController
    }

    /// Single-tab/single-group window: the "last tab in the last
    /// group" case windowShouldClose's confirm-quit prompt gates on.
    /// Mirrors CalyxWindowControllerCloseArmsTests.makeSingleTabFixture().
    private func makeSingleTabFixture() -> SingleTabFixture {
        let tab = Tab(title: "Only")
        let group = TabGroup(name: "Default", tabs: [tab], activeTabID: tab.id)
        let session = WindowSession(groups: [group], activeGroupID: group.id)
        let window = CalyxWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        let controller = CalyxWindowController(window: window, windowSession: session, restoring: true)
        return SingleTabFixture(controller: controller)
    }

    // MARK: - Mock

    /// Scripts closingWouldTerminate to answer true only on its FIRST
    /// call (windowShouldClose's entry check), false on every later
    /// call (the re-check the fix must perform), simulating a
    /// quick-terminal toggle firing mid-modal. confirmQuitIfNeeded
    /// confirms unconditionally, standing in for the user clicking
    /// through the real alert. removeWindowController comes from
    /// ConfirmQuitMockAppDelegate (R6-J); closingWouldTerminate is
    /// overridden again here for the per-call scripting.
    private final class MidModalQuickTerminalAppDelegate: ConfirmQuitMockAppDelegate {
        private(set) var closingWouldTerminateCallCount = 0

        override func closingWouldTerminate(_ controller: CalyxWindowController) -> Bool {
            closingWouldTerminateCallCount += 1
            return closingWouldTerminateCallCount == 1
        }

        override func confirmQuitIfNeeded(_ mode: ConfirmQuitMode = .killProcesses) -> Bool { true }
    }

    // MARK: - R8-A

    /// R8-A (r8-fix-spec.md; r7-verdicts.md R7-V1): against the CURRENT
    /// code, windowShouldClose's success branch sets
    /// isTerminationConfirmed = true directly from its entry-time
    /// closingWouldTerminate result, without re-checking. Here, that
    /// entry check (call #1) returns true, but a re-check performed at
    /// the same point the fix must add (mirroring closeLastWindow's
    /// markTerminationConfirmedIfWouldTerminate()) would return false
    /// (call #2+, the quick terminal appeared mid-modal). The window
    /// must still close (return true, the close itself isn't
    /// cancelled), but isTerminationConfirmed must NOT be left true for
    /// a close that, by the time of the re-check, would no longer
    /// actually terminate the app, otherwise a LATER real Cmd+Q sees
    /// the stale flag and terminates immediately, silently skipping
    /// confirmQuitIfNeeded.
    func test_windowShouldClose_doesNotStickTerminationConfirmed_whenClosingWouldNotTerminateAtReCheck() throws {
        let fixture = makeSingleTabFixture()
        let mock = MidModalQuickTerminalAppDelegate()
        let window = try XCTUnwrap(fixture.controller.window)

        let originalDelegate = NSApp.delegate
        NSApp.delegate = mock
        defer { NSApp.delegate = originalDelegate }

        let shouldClose = withExtendedLifetime(mock) {
            fixture.controller.windowShouldClose(window)
        }

        XCTAssertTrue(shouldClose,
                      "The window itself must still close, only the app-termination side effect changes")
        XCTAssertFalse(mock.isTerminationConfirmed,
                       "isTerminationConfirmed must not be set for a close that would no longer actually " +
                       "terminate the app by the time of the re-check. Only its stale entry-time check said " +
                       "so, otherwise a later real Cmd+Q silently skips confirmQuitIfNeeded")
    }
}
