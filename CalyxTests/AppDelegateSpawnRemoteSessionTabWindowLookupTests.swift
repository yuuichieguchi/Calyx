//
//  AppDelegateSpawnRemoteSessionTabWindowLookupTests.swift
//  CalyxTests
//
//  TDD Red phase (latent-bug finding from the session-browser attach-as-
//  tab investigation, CONFIRMED and put in scope for this cycle's Green
//  phase -- not a follow-up ticket): `AppDelegate.spawnRemoteSessionTab
//  (host:)` (AppDelegate.swift ~440) looks for a "key" window controller
//  via `windowControllers.first(where: { $0.window?.isKeyWindow == true })`,
//  and opens a brand-new window whenever none matches. But every REAL
//  caller of this method (`SessionBrowserModel.onRemoteSessionRequested`,
//  wired from the Session Browser's own "New Remote Session…" picker)
//  fires from inside the Session Browser's own button action -- at which
//  point the Session Browser's own plain `NSWindow` (made key by
//  `SessionBrowserWindowController.showBrowser()`'s
//  `window?.makeKeyAndOrderFront(nil)`), not any `CalyxWindowController`'s
//  window, is the key window. So this lookup never matches in practice,
//  and `spawnRemoteSessionTab` always falls through to `openNewWindow`,
//  even when a main Calyx window is already open -- the exact same class
//  of defect `AppDelegateAttachSessionAsTabTests` fixes for the local
//  session-browser Attach flow.
//
//  There was previously ZERO test coverage of this lookup at all (grepped
//  the whole CalyxTests target before writing this file).
//
//  FIX (team-confirmed, mirrors scope 1's chosen resolution exactly):
//  `windowControllers.first(where: { $0.window?.isKeyWindow == true }) ??
//  windowControllers.first` -- prefer the actually-key window if one
//  exists, but fall back to any available controller instead of dead-
//  ending on the Session Browser panel holding key status. NOT applied
//  in this RED phase; `spawnRemoteSessionTab`'s own logic is unchanged,
//  only two new DEBUG observation seams were added around it (see their
//  doc comments in AppDelegate.swift) so today's actual (buggy) behavior
//  is observable without hanging the test process.
//
//  SAFETY: `createNewTab` itself guards on `GhosttyAppController.shared.app`,
//  which is `nil` in this test host (confirmed via
//  `CalyxWindowControllerCreateManagedSurfaceRemoteHostTests`'s own
//  dummy-app workaround for the identical constraint) -- driving it for
//  real here would silently no-op with nothing to observe. `openNewWindow`
//  constructs a real `CalyxWindowController` and calls `showWindow(nil)`
//  for real -- confirmed unsafe (see `AppDelegateAttachWindowTests`'s
//  header for the identical hang this codebase already avoids). Both are
//  intercepted by the two new hooks instead of driven for real.
//
//  Coverage:
//  - One available (not key -- this test host cannot simulate a real
//    isKeyWindow == true without hanging, matching every other test in
//    this suite) window controller: must add a tab to it, never open a
//    new window. Genuine RED: today's code finds no "key" match and
//    always falls through to openNewWindow.
//  - Two available controllers, neither key: must fall back to the
//    FIRST one specifically (not .last or any other arbitrary pick).
//    Also genuine RED for the same reason.
//  - No window controller at all: still opens a new window (sanity/
//    regression companion, passes both before and after the fix, same
//    convention as AppDelegateAttachWindowTests' own regression
//    companion).
//

import XCTest
import AppKit
@testable import Calyx

@MainActor
final class AppDelegateSpawnRemoteSessionTabWindowLookupTests: XCTestCase {

    private func makeController(title: String) -> CalyxWindowController {
        let tab = Tab(title: title)
        let group = TabGroup(name: "Default", tabs: [tab], activeTabID: tab.id)
        let session = WindowSession(groups: [group], activeGroupID: group.id)
        let window = CalyxWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        return CalyxWindowController(window: window, windowSession: session, restoring: true)
    }

    func test_spawnRemoteSessionTab_withOneAvailableWindowController_addsATabToItInsteadOfOpeningNewWindow() {
        let appDelegate = AppDelegate()
        var addTabTargets: [CalyxWindowController] = []
        appDelegate._spawnRemoteSessionTabAddTabHookForTesting = { addTabTargets.append($0) }
        var newWindowHookCallCount = 0
        appDelegate._spawnRemoteSessionTabNewWindowHookForTesting = { newWindowHookCallCount += 1 }

        // Mirrors the real invocation context: an ordinary main window is
        // already open, but NOT literally key (the Session Browser's own
        // window holds key status when its button fires -- see this
        // file's header).
        let controller = makeController(title: "Unrelated")
        appDelegate._testInsertWindowController(controller)

        appDelegate.spawnRemoteSessionTab(host: nil)

        XCTAssertEqual(addTabTargets.count, 1,
                       "spawnRemoteSessionTab must add a tab to the available window controller, not fall " +
                       "through to openNewWindow, when a main window is already open")
        XCTAssertTrue(addTabTargets.first === controller,
                      "The available controller must be the one that receives the new tab")
        XCTAssertEqual(newWindowHookCallCount, 0,
                       "spawnRemoteSessionTab must never open a new window when a window is already available")
    }

    func test_spawnRemoteSessionTab_withMultipleAvailableWindowControllersNoneKey_addsATabToTheFirstOne() {
        let appDelegate = AppDelegate()
        var addTabTargets: [CalyxWindowController] = []
        appDelegate._spawnRemoteSessionTabAddTabHookForTesting = { addTabTargets.append($0) }
        var newWindowHookCallCount = 0
        appDelegate._spawnRemoteSessionTabNewWindowHookForTesting = { newWindowHookCallCount += 1 }

        let first = makeController(title: "First")
        let second = makeController(title: "Second")
        appDelegate._testInsertWindowController(first)
        appDelegate._testInsertWindowController(second)

        appDelegate.spawnRemoteSessionTab(host: nil)

        XCTAssertEqual(addTabTargets.count, 1,
                       "spawnRemoteSessionTab must add a tab to an available window controller, not open a " +
                       "new window, when none is key but at least one exists")
        XCTAssertTrue(addTabTargets.first === first,
                      "With no controller literally key, the fallback must deterministically pick the " +
                      "FIRST available controller, not an arbitrary one")
        XCTAssertEqual(newWindowHookCallCount, 0,
                       "spawnRemoteSessionTab must never open a new window when a window is already available")
    }

    /// Sanity/regression companion: passes already (no controller exists
    /// either before or after the fix, so `openNewWindow` is genuinely
    /// the only option in both cases). Included so a future regression
    /// that over-broadens the fallback (e.g. creating a controller out of
    /// thin air) would be caught here.
    func test_spawnRemoteSessionTab_withNoWindowController_stillOpensNewWindow() {
        let appDelegate = AppDelegate()
        var addTabTargets: [CalyxWindowController] = []
        appDelegate._spawnRemoteSessionTabAddTabHookForTesting = { addTabTargets.append($0) }
        var newWindowHookCallCount = 0
        appDelegate._spawnRemoteSessionTabNewWindowHookForTesting = { newWindowHookCallCount += 1 }

        appDelegate.spawnRemoteSessionTab(host: nil)

        XCTAssertEqual(newWindowHookCallCount, 1,
                       "With no window controller at all, spawnRemoteSessionTab must still open a new window")
        XCTAssertTrue(addTabTargets.isEmpty, "There is no controller to add a tab to")
    }
}
