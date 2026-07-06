//
//  CalyxWindowControllerLastWindowCloseSaveTests.swift
//  CalyxTests
//
//  TDD Red phase for the last-window-close session-loss bug (root-caused
//  from a real user incident): quitting the app by closing the last
//  window (the red button) loses the session snapshot, so the next
//  launch cannot reattach and instead creates fresh sessions, leaving
//  the previous ones running as orphans.
//
//  ROOT CAUSE: windowWillClose's `appDelegate.saveImmediately()` call
//  (CalyxWindowController.swift, guarded only by
//  `appDelegate.isClosingLastManagedWindow(self)`) fires whenever this
//  is the last managed window, with no regard for whether the close is
//  actually part of app termination. `saveImmediately()` is the SAME
//  "user deliberately emptied every window" save
//  `AppDelegate.applicationWillTerminate`'s own `saveAtTermination`
//  guard exists to protect against (see
//  SessionPersistenceActorTerminationSaveTests's header): it is
//  legitimate ONLY for a close that does not terminate the app (e.g.
//  the last managed window closes but a quick terminal keeps the app
//  alive). For a genuinely terminating close, this call fires from
//  inside windowWillClose, using AppDelegate.buildSnapshot()
//  (`windowControllers.map { $0.windowSnapshot() }`) at that moment --
//  any tab state that differs from the last known-good periodic
//  snapshot already on disk overwrites it, and
//  applicationWillTerminate's own saveAtTermination protection never
//  gets a chance to help, because it only refuses an EMPTY snapshot,
//  not one already written moments earlier by this exact call.
//
//  THE FIX must gate this save on the SAME canonical "is the app
//  actually terminating" discriminator windowWillClose's own destroy
//  loop already uses two lines below it (`isAppActuallyTerminating`, a
//  thin forward to `AppDelegate.isTerminating`, R8-C's doc comment) --
//  NOT on the per-window `isClosingForShutdown` flag alone:
//  `closeLastWindow` sets that flag even for a non-terminating close (a
//  quick terminal keeps the app alive, see that flag's own doc
//  comment), so gating on it directly would incorrectly skip the save
//  for that legitimate case too -- exactly the discriminator-mismatch
//  class round 6-8's fix rounds already fought (see
//  isAppActuallyTerminating's own doc comment). Test 2 below is the
//  trap that catches a fix which gates on isClosingForShutdown instead
//  of isAppActuallyTerminating.
//
//  Drives windowWillClose(_:) directly with a bare Notification, mirrors
//  CalyxWindowControllerNonLastWindowCloseTests' established pattern
//  (itself mirroring CalyxWindowControllerFullScreenTests): a
//  _testInsert-only, no-live-ghostty-surface fixture (plain Tab(title:)
//  tabs, no SurfaceRegistry surfaces, matching
//  CalyxWindowControllerCloseArmsTests' makeSingleTabFixture), NSApp
//  .delegate swapped for a removeWindowController-no-op AppDelegate
//  subclass (ConfirmQuitMockAppDelegate) for test-process safety, with
//  isClosingLastManagedWindow and saveImmediately further overridden so
//  this file can force the "last managed window" branch without
//  touching AppDelegate's private windowControllers array, and observe
//  the save call without hitting the real SessionPersistenceActor.shared
//  (which would write to the developer's actual ~/.calyx).
//
//  Coverage:
//  - genuinely terminating (isApplicationTerminating true): the
//    windowWillClose save must be SKIPPED entirely (RED: today it
//    always fires)
//  - NOT terminating, but isClosingForShutdown is (unconditionally, per
//    closeLastWindow) true anyway (quick-terminal-alive case): the save
//    must still fire, exactly as today (regression guard AND the
//    discriminator trap described above)
//  - not the last managed window: the save must never fire (regardless
//    of termination state) -- unaffected by this fix, sanity guard
//

import XCTest
import AppKit
@testable import Calyx

@MainActor
final class CalyxWindowControllerLastWindowCloseSaveTests: XCTestCase {

    // MARK: - Fixture

    private struct SingleTabFixture {
        let controller: CalyxWindowController
    }

    /// Single-tab/single-group window, no live ghostty surface -- this
    /// file only asserts on whether `saveImmediately()` was called, so
    /// (mirrors CalyxWindowControllerCloseArmsTests.makeSingleTabFixture)
    /// tab/session content is irrelevant.
    private func makeFixture() -> SingleTabFixture {
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

    /// Forces `isClosingLastManagedWindow` to a test-controlled value
    /// (the real implementation reads AppDelegate's private
    /// `windowControllers`, which this fixture's contrived controller is
    /// deliberately never added to, mirroring
    /// CalyxWindowControllerNonLastWindowCloseTests' own reasoning), and
    /// spies on `saveImmediately()` WITHOUT calling through to the real
    /// implementation, which would hit SessionPersistenceActor.shared
    /// and write to the developer's actual ~/.calyx.
    private final class SaveOnCloseSpyAppDelegate: ConfirmQuitMockAppDelegate {
        var isClosingLastManagedWindowOverride = true
        private(set) var saveImmediatelyCallCount = 0

        override func isClosingLastManagedWindow(_ controller: CalyxWindowController) -> Bool {
            isClosingLastManagedWindowOverride
        }

        override func saveImmediately() {
            saveImmediatelyCallCount += 1
        }
    }

    private func withMockAppDelegate(_ mock: SaveOnCloseSpyAppDelegate, _ body: () -> Void) {
        let original = NSApp.delegate
        NSApp.delegate = mock
        defer { NSApp.delegate = original }
        withExtendedLifetime(mock) {
            body()
        }
    }

    // MARK: - Tests

    /// PRIMARY RED-proving assertion: against the CURRENT code,
    /// windowWillClose's save-gate consults only
    /// isClosingLastManagedWindow, never whether the app is actually
    /// terminating, so this call fires even while the app IS genuinely
    /// quitting.
    func test_windowWillClose_terminating_doesNotSaveImmediately() {
        let fixture = makeFixture()
        let mock = SaveOnCloseSpyAppDelegate()
        mock.isClosingLastManagedWindowOverride = true
        mock._setApplicationTerminatingForTesting(true)
        fixture.controller.isClosingForShutdown = true

        withMockAppDelegate(mock) {
            fixture.controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        }

        XCTAssertEqual(mock.saveImmediatelyCallCount, 0,
                      "While the app is genuinely terminating, windowWillClose must not call " +
                      "saveImmediately() at all -- the last periodic save already on disk must survive " +
                      "untouched, so the next launch can reattach every detached session instead of " +
                      "creating fresh ones")
    }

    /// Discriminator trap: `isClosingForShutdown` is unconditionally set
    /// true by `closeLastWindow` even when the app is NOT terminating (a
    /// quick terminal keeps it alive, see that flag's own doc comment).
    /// A fix that naively gates the save on `isClosingForShutdown`
    /// instead of the canonical `isAppActuallyTerminating` would
    /// incorrectly skip this legitimate, non-terminating save too. This
    /// currently passes against BOTH the buggy code (which never checks
    /// either flag) and any CORRECT fix; it exists to catch an
    /// INCORRECT fix, not to prove today's code is broken.
    func test_windowWillClose_notTerminatingButClosingForShutdownSet_stillSavesImmediately() {
        let fixture = makeFixture()
        let mock = SaveOnCloseSpyAppDelegate()
        mock.isClosingLastManagedWindowOverride = true
        fixture.controller.isClosingForShutdown = true

        XCTAssertFalse(mock.isApplicationTerminating, "Precondition: the app is not terminating in this scenario")
        XCTAssertFalse(mock.isTerminationConfirmed, "Precondition: termination has not been confirmed either")

        withMockAppDelegate(mock) {
            fixture.controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        }

        XCTAssertEqual(mock.saveImmediatelyCallCount, 1,
                      "Closing the last managed window while the app stays alive (e.g. a quick terminal " +
                      "keeps it running) must still save the reduced (now window-less) state exactly as " +
                      "today, even though isClosingForShutdown happens to be true")
    }

    /// Sanity guard: unaffected by this fix -- a close that is not the
    /// last managed window must never trigger this save, regardless of
    /// termination state.
    func test_windowWillClose_notLastManagedWindow_neverSavesImmediately() {
        let fixture = makeFixture()
        let mock = SaveOnCloseSpyAppDelegate()
        mock.isClosingLastManagedWindowOverride = false
        mock._setApplicationTerminatingForTesting(true)

        withMockAppDelegate(mock) {
            fixture.controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        }

        XCTAssertEqual(mock.saveImmediatelyCallCount, 0,
                      "A close that is not the last managed window must never trigger windowWillClose's " +
                      "save-on-last-window path")
    }
}
