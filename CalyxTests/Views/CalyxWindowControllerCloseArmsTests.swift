//
//  CalyxWindowControllerCloseArmsTests.swift
//  CalyxTests
//
//  TDD Red phase for round-4 fixes F3/F7/F8 (r4-fix-spec.md; full
//  evidence in r4-verdicts.md V03/V07/V08). Covers the five places
//  `CalyxWindowController` calls `window?.close()` as part of tearing
//  down the last tab/group/window:
//
//  - F3/T3: `windowShouldClose` must pre-populate `closingTabIDs` with
//    EVERY tab id in this window BEFORE consulting `confirmQuitIfNeeded`
//    (closing the only gate — V03 — that does NOT already do this: an
//    unrelated pane's process can exit synchronously mid-modal via
//    ghostty's `close_surface` callback, and without this
//    pre-population, `closeSurfaceAndCleanUp`'s `:1563` reentrancy guard
//    is empty and does not fire), and remove them again on the cancel
//    path (return false).
//  - F7/T7 (the three arms NOT already covered by
//    `SessionCommandPaletteTests`'s `closeSurfaceAndCleanUp` coverage):
//    `closeTab`, `closeActiveGroup` (via the public `closeGroup(_:)`),
//    and `closeAllTabsInGroup` must set `isClosingForShutdown = true`
//    immediately before `window?.close()`, matching `windowShouldClose`'s
//    own eager set — currently dead code for `windowDidExitFullScreen`'s
//    stale-snapshot guard on these three paths (V07's "bonus lead").
//
//  Fixtures below use plain, leaf-less `Tab(title:)` tabs (no
//  `SurfaceRegistry` surfaces): `closeTab`/`closeActiveGroup`/
//  `closeAllTabsInGroup`/`windowShouldClose` all operate on
//  `WindowSession`'s tab/group model and `tab.registry.allIDs` (empty
//  here, so the kill/destroy loop is a harmless no-op) — no live
//  ghostty surface is needed to exercise the confirm-gate/flag-timing
//  contracts under test.
//
//  `closeAllTabsInGroup(id:)` is not `private` (P4 round-4 fix RED
//  phase, see its own doc comment) so this file can drive it directly,
//  matching this codebase's `handleSessionReconnectDecision` precedent.
//

import XCTest
import AppKit
@testable import Calyx

@MainActor
final class CalyxWindowControllerCloseArmsTests: XCTestCase {

    // MARK: - Fixtures

    private struct SingleTabFixture {
        let controller: CalyxWindowController
        let tabID: UUID
        let groupID: UUID
    }

    /// Single-tab/single-group window: the "last tab in the last
    /// group" case every arm under test gates its confirm-quit prompt
    /// on.
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
        return SingleTabFixture(controller: controller, tabID: tab.id, groupID: group.id)
    }

    private struct TwoTabFixture {
        let controller: CalyxWindowController
        let tabAID: UUID
        let tabBID: UUID
    }

    /// Two tabs in one (the only) group — proves `windowShouldClose`
    /// pre-populates `closingTabIDs` with EVERY tab id in the window,
    /// not just the active one.
    private func makeTwoTabFixture() -> TwoTabFixture {
        let tabA = Tab(title: "A")
        let tabB = Tab(title: "B")
        let group = TabGroup(name: "Default", tabs: [tabA, tabB], activeTabID: tabA.id)
        let session = WindowSession(groups: [group], activeGroupID: group.id)
        let window = CalyxWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        let controller = CalyxWindowController(window: window, windowSession: session, restoring: true)
        return TwoTabFixture(controller: controller, tabAID: tabA.id, tabBID: tabB.id)
    }

    // MARK: - Mocks

    /// `AppDelegate` subclass reporting `closingWouldTerminate == true`
    /// unconditionally and confirming quit unconditionally — drives
    /// every close path under test through to its `.windowShouldClose`
    /// arm without a real, blocking `NSAlert.runModal()`.
    /// `removeWindowController` is a no-op purely as test-process
    /// safety (mirrors `SessionCommandPaletteTests
    /// .MockConfirmQuitAppDelegate`'s reasoning): confirmed teardown
    /// here empties the window for real, calling `window?.close()` ->
    /// `windowWillClose` -> `AppDelegate.removeWindowController`, whose
    /// real implementation calls `NSApp.terminate(nil)` once its
    /// (private) `windowControllers` list is empty.
    private final class ConfirmingAppDelegate: AppDelegate {
        override func closingWouldTerminate(_ controller: CalyxWindowController) -> Bool { true }
        override func confirmQuitIfNeeded(_ mode: ConfirmQuitMode = .killProcesses) -> Bool { true }
        override func removeWindowController(_ controller: CalyxWindowController) {}
    }

    /// Like `ConfirmingAppDelegate`, but captures
    /// `CalyxWindowController._closingTabIDsForTesting`'s state at the
    /// moment `confirmQuitIfNeeded` is consulted, and lets the test
    /// choose whether to confirm or cancel.
    private final class ClosingTabIDsWindowCloseSpyAppDelegate: AppDelegate {
        var shouldConfirm = true
        weak var controller: CalyxWindowController?
        private(set) var observedClosingTabIDs: Set<UUID>?

        override func closingWouldTerminate(_ controller: CalyxWindowController) -> Bool { true }

        override func confirmQuitIfNeeded(_ mode: ConfirmQuitMode = .killProcesses) -> Bool {
            observedClosingTabIDs = controller?._closingTabIDsForTesting
            return shouldConfirm
        }

        override func removeWindowController(_ controller: CalyxWindowController) {}
    }

    // MARK: - F7/T7: isClosingForShutdown timing

    /// Against the CURRENT code, `closeTab`'s `.windowShouldClose` case
    /// never sets `isClosingForShutdown`, so it remains `false` after
    /// this call.
    func test_closeTab_setsIsClosingForShutdown_beforeWindowCloses() {
        let fixture = makeSingleTabFixture()
        let mock = ConfirmingAppDelegate()
        let originalDelegate = NSApp.delegate
        NSApp.delegate = mock
        defer { NSApp.delegate = originalDelegate }

        withExtendedLifetime(mock) {
            fixture.controller.closeTab(nil)
        }

        XCTAssertTrue(fixture.controller.isClosingForShutdown,
                      "closeTab's .windowShouldClose arm must set isClosingForShutdown before " +
                      "window?.close(), matching windowShouldClose's own eager set")
    }

    /// Same contract for `closeActiveGroup` (driven via the public
    /// `closeGroup(_:)` action).
    func test_closeGroup_setsIsClosingForShutdown_beforeWindowCloses() {
        let fixture = makeSingleTabFixture()
        let mock = ConfirmingAppDelegate()
        let originalDelegate = NSApp.delegate
        NSApp.delegate = mock
        defer { NSApp.delegate = originalDelegate }

        withExtendedLifetime(mock) {
            fixture.controller.closeGroup(nil)
        }

        XCTAssertTrue(fixture.controller.isClosingForShutdown,
                      "closeActiveGroup's .windowShouldClose arm must set isClosingForShutdown before " +
                      "window?.close(), matching windowShouldClose's own eager set")
    }

    /// Same contract for `closeAllTabsInGroup(id:)`.
    func test_closeAllTabsInGroup_setsIsClosingForShutdown_beforeWindowCloses() {
        let fixture = makeSingleTabFixture()
        let mock = ConfirmingAppDelegate()
        let originalDelegate = NSApp.delegate
        NSApp.delegate = mock
        defer { NSApp.delegate = originalDelegate }

        withExtendedLifetime(mock) {
            fixture.controller.closeAllTabsInGroup(id: fixture.groupID)
        }

        XCTAssertTrue(fixture.controller.isClosingForShutdown,
                      "closeAllTabsInGroup's .windowShouldClose arm must set isClosingForShutdown before " +
                      "window?.close(), matching windowShouldClose's own eager set")
    }

    // MARK: - F3/T3: windowShouldClose closingTabIDs pre-population

    /// Against the CURRENT code, `windowShouldClose` never touches
    /// `closingTabIDs` before calling `confirmQuitIfNeeded`, so the
    /// observed set is empty (expected: both tab ids).
    func test_windowShouldClose_insertsAllTabIDsIntoClosingTabIDs_beforeConfirmQuitGate() throws {
        let fixture = makeTwoTabFixture()
        let mock = ClosingTabIDsWindowCloseSpyAppDelegate()
        mock.controller = fixture.controller
        let window = try XCTUnwrap(fixture.controller.window)

        let originalDelegate = NSApp.delegate
        NSApp.delegate = mock
        defer { NSApp.delegate = originalDelegate }

        _ = withExtendedLifetime(mock) {
            fixture.controller.windowShouldClose(window)
        }

        XCTAssertEqual(mock.observedClosingTabIDs, Set([fixture.tabAID, fixture.tabBID]),
                       "windowShouldClose must insert every tab id in this window into closingTabIDs " +
                       "BEFORE consulting confirmQuitIfNeeded")
    }

    /// Cancelling the confirm-quit prompt must remove the tab ids
    /// `windowShouldClose` inserted, matching `closeTab`'s established
    /// insert-then-remove-on-cancel pattern. This assertion alone would
    /// trivially pass against the CURRENT code too (nothing is ever
    /// inserted, so the set is vacuously empty on cancel) — it is
    /// meaningful only once the insertion above is implemented, which
    /// is why `test_windowShouldClose_insertsAllTabIDsIntoClosingTabIDs_beforeConfirmQuitGate`
    /// is the primary RED-proving assertion for F3.
    func test_windowShouldClose_removesClosingTabIDs_whenConfirmQuitCancelled() throws {
        let fixture = makeTwoTabFixture()
        let mock = ClosingTabIDsWindowCloseSpyAppDelegate()
        mock.controller = fixture.controller
        mock.shouldConfirm = false
        let window = try XCTUnwrap(fixture.controller.window)

        let originalDelegate = NSApp.delegate
        NSApp.delegate = mock
        defer { NSApp.delegate = originalDelegate }

        let shouldClose = withExtendedLifetime(mock) {
            fixture.controller.windowShouldClose(window)
        }

        XCTAssertFalse(shouldClose, "Cancelling the confirm-quit prompt must return false")
        XCTAssertTrue(fixture.controller._closingTabIDsForTesting.isEmpty,
                      "Cancelling must remove the tab ids windowShouldClose inserted, matching closeTab's " +
                      "insert-then-remove-on-cancel pattern")
    }
}
