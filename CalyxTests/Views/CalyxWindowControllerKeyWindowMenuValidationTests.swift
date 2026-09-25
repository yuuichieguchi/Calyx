//
//  CalyxWindowControllerKeyWindowMenuValidationTests.swift
//  CalyxTests
//
//  GitHub issue #45. Full root-cause writeup:
//  `NSWindow+CalyxClose.swift`'s header comment.
//
//  `CalyxWindowController.validateMenuItem(_:)` (CalyxWindowController
//  .swift, "MARK: - Menu Actions") is reached via the responder chain's
//  window-DELEGATE hop (this controller is `window.delegate`), which
//  `NSApplication.targetForAction:` walks for BOTH the key window's
//  chain AND, on fallback, the MAIN window's chain — the exact
//  mechanism issue #45 exploits (see the header comment cited above).
//  `calyxPerformClose(_:)` closes the Cmd+W hole structurally, but
//  every OTHER File/View-menu item still routes through this same
//  fallback-prone resolution. Defense in depth: gate every
//  window-scoped action (close/fullscreen/tab-cycling) on "is THIS
//  window's own NSWindow actually the key window", via the
//  `_isKeyWindowOverrideForTesting` seam (a real key-window transition
//  needs the window server; unsafe/unavailable in this test host — see
//  `CalyxWindowControllerCloseWindowTests`'s own precondition assertion
//  that a freshly constructed, never-shown `CalyxWindow` is never key).
//
//  `newTab:`/`newBrowserTab:`/`newGroup:` are deliberately EXCLUDED from
//  this gate — macOS convention keeps "New ..." commands enabled even
//  when a non-document panel (About) is key, targeting whatever window
//  ends up main/frontmost. Tests below pin this as intentional, not an
//  oversight.
//
//  Originally this file scoped the key-window gate to
//  5 selectors — `closeTab:`/`closeGroup:`/`toggleFullScreen:`/
//  `selectNextTab:`/`selectPreviousTab:` — and deliberately did not
//  re-test `jumpToMostRecentUnreadTab`/`findNext:`/`findPrevious:`/
//  `nextGroup:`/`previousGroup:`. The implementation went further and
//  gated all 13 non-creation selectors (`keyWindowGatedActions` in
//  `CalyxWindowController.swift`), so this file was extended to cover
//  the remaining 8 as well: `nextGroup:`/`previousGroup:`/
//  `jumpToMostRecentUnreadTab`/`toggleSidebar`/`toggleCommandPalette`/
//  `toggleComposeOverlay`/`findNext:`/`findPrevious:`. `focusSplit*` is
//  still deliberately excluded from this file (and from the gate
//  itself) — see `CalyxWindowController.swift`'s own "Known gap"
//  comment next to `keyWindowGatedActions` for why.
//
//  Against the CURRENT code, `validateMenuItem(_:)` never reads
//  `_isKeyWindowOverrideForTesting` at all (the property exists purely
//  as an unused stub seam), so:
//
//  Every "disabledWhenNotKeyWindow" test
//  pins the gate — the pre-fix code's `return true` fallthrough (for
//  closeTab:/closeGroup:/toggleFullScreen:) or existing tabs.count-only
//  gate (for selectNextTab:/selectPreviousTab:, run here with 2 tabs so
//  that gate alone would already say "enabled") ignores the override
//  entirely and answers `true`/enabled, not the expected `false`/
//  disabled. Every "enabledWhenKeyWindow"/"disabledWhenKeyWindow
//  WithSingleTab" test and both `newTab:`/`newBrowserTab:`/`newGroup:`
//  tests are regression guards: they assert exactly
//  what the override-blind code already did, and must keep
//  doing now that the gate exists.
//
//  Follow-up ledger (added 2026-08-07): the 8
//  selectors covered below (`nextGroup:`/`previousGroup:`/
//  `jumpToMostRecentUnreadTab`/`toggleSidebar`/`toggleCommandPalette`/
//  `toggleComposeOverlay`/`findNext:`/`findPrevious:`) are already
//  present in `keyWindowGatedActions` and already correctly gated, so
//  every test added for them here is a regression guard: each goes
//  green immediately against the current
//  implementation. Their value is catching a FUTURE regression instead
//  (an entry silently dropped from the `Set`, or the gate block in
//  `validateMenuItem(_:)` deleted outright): today, without these
//  tests, either mistake would compile cleanly and the full suite would
//  pass unnoticed.
//

import XCTest
import AppKit
@testable import Calyx

@MainActor
final class CalyxWindowControllerKeyWindowMenuValidationTests: XCTestCase {

    // MARK: - Fixture

    private func makeFixture(session: WindowSession) -> CalyxWindowController {
        let window = CalyxWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        return CalyxWindowController(window: window, windowSession: session, restoring: true)
    }

    /// `tabCount` tabs in a single group, no ghostty surfaces at all —
    /// `validateMenuItem` only ever reads `windowSession.activeGroup?
    /// .tabs.count`, never a live surface (mirrors
    /// `AppDelegateCloseAllWindowsTests.makeSingleTabFixture()`'s
    /// identical "no live ghostty surface needed" reasoning).
    private func makeFixture(tabCount: Int) -> CalyxWindowController {
        let tabs = (0..<tabCount).map { Tab(title: "Tab \($0)") }
        let group = TabGroup(name: "Default", tabs: tabs, activeTabID: tabs.first?.id)
        let session = WindowSession(groups: [group], activeGroupID: group.id)
        return makeFixture(session: session)
    }

    /// `groupCount` single-tab groups — same shape as `makeFixture(tabCount:)`
    /// above but varies GROUP count instead, for `nextGroup:`/
    /// `previousGroup:`'s own `windowSession.groups.count > 1` gate.
    private func makeFixture(groupCount: Int) -> CalyxWindowController {
        let groups = (0..<groupCount).map { index -> TabGroup in
            let tab = Tab(title: "Tab \(index)")
            return TabGroup(name: "Group \(index)", tabs: [tab], activeTabID: tab.id)
        }
        let session = WindowSession(groups: groups, activeGroupID: groups.first?.id)
        return makeFixture(session: session)
    }

    /// Single tab with an unread notification — `jumpToMostRecentUnreadTab`'s
    /// own `unreadNotifications > 0` gate. `lastNotificationTime` is set
    /// alongside it purely for fixture realism (mirrors this codebase's
    /// only production writer of these two properties, which always sets
    /// both together — see `CalyxWindowController`'s notification-arrival
    /// handling); `validateMenuItem` itself only ever reads
    /// `unreadNotifications`.
    private func makeFixtureWithUnreadTab() -> CalyxWindowController {
        let tab = Tab(title: "Tab 0")
        tab.unreadNotifications = 1
        tab.lastNotificationTime = Date()
        let group = TabGroup(name: "Default", tabs: [tab], activeTabID: tab.id)
        let session = WindowSession(groups: [group], activeGroupID: group.id)
        return makeFixture(session: session)
    }

    private func menuItem(action: Selector) -> NSMenuItem {
        NSMenuItem(title: "Test", action: action, keyEquivalent: "")
    }

    // MARK: - Disabled when NOT the key window

    func test_validateMenuItem_closeTab_disabledWhenNotKeyWindow() {
        let controller = makeFixture(tabCount: 1)
        controller._isKeyWindowOverrideForTesting = false

        let result = controller.validateMenuItem(menuItem(action: #selector(CalyxWindowController.closeTab(_:))))

        XCTAssertFalse(result, "Close Tab must be disabled while this window is not the key window")
    }

    func test_validateMenuItem_closeGroup_disabledWhenNotKeyWindow() {
        let controller = makeFixture(tabCount: 1)
        controller._isKeyWindowOverrideForTesting = false

        let result = controller.validateMenuItem(menuItem(action: #selector(CalyxWindowController.closeGroup(_:))))

        XCTAssertFalse(result, "Close Group must be disabled while this window is not the key window")
    }

    func test_validateMenuItem_toggleFullScreen_disabledWhenNotKeyWindow() {
        let controller = makeFixture(tabCount: 1)
        controller._isKeyWindowOverrideForTesting = false

        let result = controller.validateMenuItem(menuItem(action: #selector(CalyxWindowController.toggleFullScreen(_:))))

        XCTAssertFalse(result, "Toggle Full Screen must be disabled while this window is not the key window")
    }

    /// Two tabs, so the EXISTING `tabs.count > 1` gate alone would say
    /// "enabled" — isolates the key-window gate as the reason this must
    /// be `false`.
    func test_validateMenuItem_selectNextTab_disabledWhenNotKeyWindow_evenWithMultipleTabs() {
        let controller = makeFixture(tabCount: 2)
        controller._isKeyWindowOverrideForTesting = false

        let result = controller.validateMenuItem(menuItem(action: #selector(CalyxWindowController.selectNextTab(_:))))

        XCTAssertFalse(result, "Select Next Tab must be disabled while not key, even with multiple tabs present")
    }

    func test_validateMenuItem_selectPreviousTab_disabledWhenNotKeyWindow_evenWithMultipleTabs() {
        let controller = makeFixture(tabCount: 2)
        controller._isKeyWindowOverrideForTesting = false

        let result = controller.validateMenuItem(menuItem(action: #selector(CalyxWindowController.selectPreviousTab(_:))))

        XCTAssertFalse(result, "Select Previous Tab must be disabled while not key, even with multiple tabs present")
    }

    /// Two groups, so the EXISTING `groups.count > 1` gate alone would say
    /// "enabled" — isolates the key-window gate as the reason this must
    /// be `false` (mirrors the `selectNextTab`/`selectPreviousTab` pair
    /// above).
    func test_validateMenuItem_nextGroup_disabledWhenNotKeyWindow_evenWithMultipleGroups() {
        let controller = makeFixture(groupCount: 2)
        controller._isKeyWindowOverrideForTesting = false

        let result = controller.validateMenuItem(menuItem(action: #selector(CalyxWindowController.nextGroup(_:))))

        XCTAssertFalse(result, "Next Group must be disabled while not key, even with multiple groups present")
    }

    func test_validateMenuItem_previousGroup_disabledWhenNotKeyWindow_evenWithMultipleGroups() {
        let controller = makeFixture(groupCount: 2)
        controller._isKeyWindowOverrideForTesting = false

        let result = controller.validateMenuItem(menuItem(action: #selector(CalyxWindowController.previousGroup(_:))))

        XCTAssertFalse(result, "Previous Group must be disabled while not key, even with multiple groups present")
    }

    /// An unread tab is present, so the EXISTING unread-count gate alone
    /// would say "enabled" — isolates the key-window gate as the reason
    /// this must be `false`.
    func test_validateMenuItem_jumpToMostRecentUnreadTab_disabledWhenNotKeyWindow_evenWithUnreadTab() {
        let controller = makeFixtureWithUnreadTab()
        controller._isKeyWindowOverrideForTesting = false

        let result = controller.validateMenuItem(menuItem(action: #selector(CalyxWindowController.jumpToMostRecentUnreadTab)))

        XCTAssertFalse(
            result,
            "Jump to Most Recent Unread Tab must be disabled while not key, even with an unread tab present"
        )
    }

    func test_validateMenuItem_toggleSidebar_disabledWhenNotKeyWindow() {
        let controller = makeFixture(tabCount: 1)
        controller._isKeyWindowOverrideForTesting = false

        let result = controller.validateMenuItem(menuItem(action: #selector(CalyxWindowController.toggleSidebar)))

        XCTAssertFalse(result, "Toggle Sidebar must be disabled while this window is not the key window")
    }

    func test_validateMenuItem_toggleCommandPalette_disabledWhenNotKeyWindow() {
        let controller = makeFixture(tabCount: 1)
        controller._isKeyWindowOverrideForTesting = false

        let result = controller.validateMenuItem(menuItem(action: #selector(CalyxWindowController.toggleCommandPalette)))

        XCTAssertFalse(result, "Toggle Command Palette must be disabled while this window is not the key window")
    }

    func test_validateMenuItem_toggleComposeOverlay_disabledWhenNotKeyWindow() {
        let controller = makeFixture(tabCount: 1)
        controller._isKeyWindowOverrideForTesting = false

        let result = controller.validateMenuItem(menuItem(action: #selector(CalyxWindowController.toggleComposeOverlay)))

        XCTAssertFalse(result, "Toggle Compose Overlay must be disabled while this window is not the key window")
    }

    func test_validateMenuItem_findNext_disabledWhenNotKeyWindow() {
        let controller = makeFixture(tabCount: 1)
        controller._isKeyWindowOverrideForTesting = false

        let result = controller.validateMenuItem(menuItem(action: #selector(CalyxWindowController.findNext(_:))))

        XCTAssertFalse(result, "Find Next must be disabled while this window is not the key window")
    }

    func test_validateMenuItem_toggleMissionMap_disabledWhenNotKeyWindow() {
        let controller = makeFixture(tabCount: 1)
        controller._isKeyWindowOverrideForTesting = false

        let result = controller.validateMenuItem(menuItem(action: #selector(CalyxWindowController.toggleMissionMap)))

        XCTAssertFalse(result, "Toggle Mission Map must be disabled while this window is not the key window")
    }

    func test_validateMenuItem_findPrevious_disabledWhenNotKeyWindow() {
        let controller = makeFixture(tabCount: 1)
        controller._isKeyWindowOverrideForTesting = false

        let result = controller.validateMenuItem(menuItem(action: #selector(CalyxWindowController.findPrevious(_:))))

        XCTAssertFalse(result, "Find Previous must be disabled while this window is not the key window")
    }

    // MARK: - Regression guards: enabled when key, existing gates unchanged

    func test_validateMenuItem_closeTab_enabledWhenKeyWindow() {
        let controller = makeFixture(tabCount: 1)
        controller._isKeyWindowOverrideForTesting = true

        let result = controller.validateMenuItem(menuItem(action: #selector(CalyxWindowController.closeTab(_:))))

        XCTAssertTrue(result, "Close Tab must stay enabled while this window IS the key window")
    }

    func test_validateMenuItem_closeGroup_enabledWhenKeyWindow() {
        let controller = makeFixture(tabCount: 1)
        controller._isKeyWindowOverrideForTesting = true

        let result = controller.validateMenuItem(menuItem(action: #selector(CalyxWindowController.closeGroup(_:))))

        XCTAssertTrue(result, "Close Group must stay enabled while this window IS the key window")
    }

    func test_validateMenuItem_toggleFullScreen_enabledWhenKeyWindow() {
        let controller = makeFixture(tabCount: 1)
        controller._isKeyWindowOverrideForTesting = true

        let result = controller.validateMenuItem(menuItem(action: #selector(CalyxWindowController.toggleFullScreen(_:))))

        XCTAssertTrue(result, "Toggle Full Screen must stay enabled while this window IS the key window")
    }

    /// The existing `tabs.count > 1` gate must still be the ONLY thing
    /// governing this once the window IS key.
    func test_validateMenuItem_selectNextTab_enabledWhenKeyWindow_withMultipleTabs() {
        let controller = makeFixture(tabCount: 2)
        controller._isKeyWindowOverrideForTesting = true

        let result = controller.validateMenuItem(menuItem(action: #selector(CalyxWindowController.selectNextTab(_:))))

        XCTAssertTrue(result, "Select Next Tab must be enabled while key, with more than one tab present")
    }

    /// Same fixture, but a single tab — the pre-existing `tabs.count > 1`
    /// gate must still disable this even though the window IS key.
    func test_validateMenuItem_selectNextTab_disabledWhenKeyWindow_withSingleTab() {
        let controller = makeFixture(tabCount: 1)
        controller._isKeyWindowOverrideForTesting = true

        let result = controller.validateMenuItem(menuItem(action: #selector(CalyxWindowController.selectNextTab(_:))))

        XCTAssertFalse(result, "Select Next Tab must stay disabled while key, with only a single tab present")
    }

    func test_validateMenuItem_selectPreviousTab_enabledWhenKeyWindow_withMultipleTabs() {
        let controller = makeFixture(tabCount: 2)
        controller._isKeyWindowOverrideForTesting = true

        let result = controller.validateMenuItem(menuItem(action: #selector(CalyxWindowController.selectPreviousTab(_:))))

        XCTAssertTrue(result, "Select Previous Tab must be enabled while key, with more than one tab present")
    }

    func test_validateMenuItem_selectPreviousTab_disabledWhenKeyWindow_withSingleTab() {
        let controller = makeFixture(tabCount: 1)
        controller._isKeyWindowOverrideForTesting = true

        let result = controller.validateMenuItem(menuItem(action: #selector(CalyxWindowController.selectPreviousTab(_:))))

        XCTAssertFalse(result, "Select Previous Tab must stay disabled while key, with only a single tab present")
    }

    func test_validateMenuItem_nextGroup_enabledWhenKeyWindow_withMultipleGroups() {
        let controller = makeFixture(groupCount: 2)
        controller._isKeyWindowOverrideForTesting = true

        let result = controller.validateMenuItem(menuItem(action: #selector(CalyxWindowController.nextGroup(_:))))

        XCTAssertTrue(result, "Next Group must be enabled while key, with more than one group present")
    }

    /// The existing `groups.count > 1` gate must still be the ONLY thing
    /// governing this once the window IS key.
    func test_validateMenuItem_nextGroup_disabledWhenKeyWindow_withSingleGroup() {
        let controller = makeFixture(groupCount: 1)
        controller._isKeyWindowOverrideForTesting = true

        let result = controller.validateMenuItem(menuItem(action: #selector(CalyxWindowController.nextGroup(_:))))

        XCTAssertFalse(result, "Next Group must stay disabled while key, with only a single group present")
    }

    func test_validateMenuItem_previousGroup_enabledWhenKeyWindow_withMultipleGroups() {
        let controller = makeFixture(groupCount: 2)
        controller._isKeyWindowOverrideForTesting = true

        let result = controller.validateMenuItem(menuItem(action: #selector(CalyxWindowController.previousGroup(_:))))

        XCTAssertTrue(result, "Previous Group must be enabled while key, with more than one group present")
    }

    func test_validateMenuItem_previousGroup_disabledWhenKeyWindow_withSingleGroup() {
        let controller = makeFixture(groupCount: 1)
        controller._isKeyWindowOverrideForTesting = true

        let result = controller.validateMenuItem(menuItem(action: #selector(CalyxWindowController.previousGroup(_:))))

        XCTAssertFalse(result, "Previous Group must stay disabled while key, with only a single group present")
    }

    func test_validateMenuItem_jumpToMostRecentUnreadTab_enabledWhenKeyWindow_withUnreadTab() {
        let controller = makeFixtureWithUnreadTab()
        controller._isKeyWindowOverrideForTesting = true

        let result = controller.validateMenuItem(menuItem(action: #selector(CalyxWindowController.jumpToMostRecentUnreadTab)))

        XCTAssertTrue(result, "Jump to Most Recent Unread Tab must be enabled while key, with an unread tab present")
    }

    /// No unread tab this time, so the existing unread-count gate must
    /// still be the thing disabling this once the window IS key.
    func test_validateMenuItem_jumpToMostRecentUnreadTab_disabledWhenKeyWindow_withNoUnreadTab() {
        let controller = makeFixture(tabCount: 1)
        controller._isKeyWindowOverrideForTesting = true

        let result = controller.validateMenuItem(menuItem(action: #selector(CalyxWindowController.jumpToMostRecentUnreadTab)))

        XCTAssertFalse(
            result,
            "Jump to Most Recent Unread Tab must stay disabled while key, with no unread tab present"
        )
    }

    func test_validateMenuItem_toggleSidebar_enabledWhenKeyWindow() {
        let controller = makeFixture(tabCount: 1)
        controller._isKeyWindowOverrideForTesting = true

        let result = controller.validateMenuItem(menuItem(action: #selector(CalyxWindowController.toggleSidebar)))

        XCTAssertTrue(result, "Toggle Sidebar must stay enabled while this window IS the key window")
    }

    func test_validateMenuItem_toggleCommandPalette_enabledWhenKeyWindow() {
        let controller = makeFixture(tabCount: 1)
        controller._isKeyWindowOverrideForTesting = true

        let result = controller.validateMenuItem(menuItem(action: #selector(CalyxWindowController.toggleCommandPalette)))

        XCTAssertTrue(result, "Toggle Command Palette must stay enabled while this window IS the key window")
    }

    func test_validateMenuItem_toggleComposeOverlay_enabledWhenKeyWindow() {
        let controller = makeFixture(tabCount: 1)
        controller._isKeyWindowOverrideForTesting = true

        let result = controller.validateMenuItem(menuItem(action: #selector(CalyxWindowController.toggleComposeOverlay)))

        XCTAssertTrue(result, "Toggle Compose Overlay must stay enabled while this window IS the key window")
    }

    func test_validateMenuItem_toggleMissionMap_enabledWhenKeyWindow() {
        let controller = makeFixture(tabCount: 1)
        controller._isKeyWindowOverrideForTesting = true

        let result = controller.validateMenuItem(menuItem(action: #selector(CalyxWindowController.toggleMissionMap)))

        XCTAssertTrue(result, "Toggle Mission Map must stay enabled while this window IS the key window")
    }

    /// Unlike every other selector in this section, `findNext:`'s own
    /// pre-existing gate (`focusedSurfaceHasVisibleSearchBar`) only ever
    /// answers `true` for a live, focused `GhosttySurfaceController`
    /// inside a real `SurfaceScrollView` — constructing one requires a
    /// real ghostty surface, which hangs the XCTest process (see
    /// `SurfaceLocator.swift`'s header). This fixture has no surface at
    /// all, so `focusedSurfaceHasVisibleSearchBar` is always `false`
    /// here, regardless of key-window state; what this test isolates
    /// instead is that, while key, the PRE-EXISTING gate is still the
    /// thing answering — not a fallthrough to the final `return true` —
    /// so a future removal of the `findNext:`/`findPrevious:` branch in
    /// `validateMenuItem(_:)` would flip this to `true` and fail here.
    func test_validateMenuItem_findNext_disabledWhenKeyWindow_withNoVisibleSearchBar() {
        let controller = makeFixture(tabCount: 1)
        controller._isKeyWindowOverrideForTesting = true

        let result = controller.validateMenuItem(menuItem(action: #selector(CalyxWindowController.findNext(_:))))

        XCTAssertFalse(result, "Find Next must stay disabled while key, with no visible in-terminal search bar")
    }

    /// See `test_validateMenuItem_findNext_disabledWhenKeyWindow_withNoVisibleSearchBar`
    /// above for why this cannot exercise the `true` branch.
    func test_validateMenuItem_findPrevious_disabledWhenKeyWindow_withNoVisibleSearchBar() {
        let controller = makeFixture(tabCount: 1)
        controller._isKeyWindowOverrideForTesting = true

        let result = controller.validateMenuItem(menuItem(action: #selector(CalyxWindowController.findPrevious(_:))))

        XCTAssertFalse(result, "Find Previous must stay disabled while key, with no visible in-terminal search bar")
    }

    // MARK: - Regression guards: creation actions are never key-window-gated

    func test_validateMenuItem_newTab_enabledRegardlessOfKeyWindow() {
        let controller = makeFixture(tabCount: 1)
        let item = menuItem(action: #selector(CalyxWindowController.newTab(_:)))

        controller._isKeyWindowOverrideForTesting = false
        XCTAssertTrue(controller.validateMenuItem(item), "New Tab must stay enabled while not key")

        controller._isKeyWindowOverrideForTesting = true
        XCTAssertTrue(controller.validateMenuItem(item), "New Tab must stay enabled while key")
    }

    func test_validateMenuItem_newBrowserTab_enabledRegardlessOfKeyWindow() {
        let controller = makeFixture(tabCount: 1)
        let item = menuItem(action: #selector(CalyxWindowController.newBrowserTab(_:)))

        controller._isKeyWindowOverrideForTesting = false
        XCTAssertTrue(controller.validateMenuItem(item), "New Browser Tab must stay enabled while not key")

        controller._isKeyWindowOverrideForTesting = true
        XCTAssertTrue(controller.validateMenuItem(item), "New Browser Tab must stay enabled while key")
    }

    func test_validateMenuItem_newGroup_enabledRegardlessOfKeyWindow() {
        let controller = makeFixture(tabCount: 1)
        let item = menuItem(action: #selector(CalyxWindowController.newGroup(_:)))

        controller._isKeyWindowOverrideForTesting = false
        XCTAssertTrue(controller.validateMenuItem(item), "New Group must stay enabled while not key")

        controller._isKeyWindowOverrideForTesting = true
        XCTAssertTrue(controller.validateMenuItem(item), "New Group must stay enabled while key")
    }
}
