//
//  AppDelegateAttachSessionAsTabTests.swift
//  CalyxTests
//
//  TDD Red phase for a UX inconsistency reported by the user: the
//  session browser's "Attach" button always opens a NEW WINDOW
//  (SessionBrowserWindowController.attach(_:) -> AppDelegate.attachWindow),
//  even while a main Calyx window is already open -- unlike the sibling
//  remote-session flow (AppDelegate.spawnRemoteSessionTab(host:)), which
//  adds a new TAB to an available window and only opens a fresh window
//  when none exists.
//
//  AppDelegate.attachSessionAsTab(sessionID:cwd:host:) is the proposed
//  single entry point that unifies both flows' rule (see
//  SessionAttachRoutingPolicy.swift's own header comment for the full
//  three-way decision: focus an already-attached session, add a tab to
//  an available window, or open a fresh window only as a last resort).
//  `SessionBrowserWindowController.attach(_:)` calling this instead of
//  `attachWindow(sessionID:cwd:)` directly is the remaining call-site
//  change this file does NOT cover (that file has no dedicated test file
//  by its own long-standing convention -- see its header comment -- the
//  logic worth testing lives here and in `SessionAttachRoutingPolicyTests`
//  instead).
//
//  SAFETY: reuses AppDelegateAttachWindowTests'/AppDelegateFocusExistingSessionTests'
//  established fixture shapes and test seams
//  (`_attachWindowCreationHookForTesting`, `_focusWindowForExistingSessionShowHookForTesting`,
//  `_testInsertWindowController`) for the exact same reason those files
//  give: driving a real window/ghostty surface from this test host hangs
//  the XCTest process indefinitely. `attachSessionAsTab`'s RED-phase stub
//  (see AppDelegate.swift) only ever reaches real work through
//  `attachWindow`/`focusWindowForExistingSession`, both already safe
//  through those existing hooks -- no new unsafe-to-test seam was needed
//  for this file. The one new seam here,
//  `_attachSessionAsTabRoutingObserverForTesting`, only observes the
//  `SessionAttachRoutingPolicy.Decision` value `attachSessionAsTab`
//  computed; it never replaces any real call.
//
//  Coverage (one test per row of SessionAttachRoutingPolicyTests' 2x2
//  truth table, exercised through real AppDelegate state --
//  SessionSurfaceMap registration and windowControllers -- instead of
//  passing booleans directly):
//  - Already attached, a window also available: focuses, never opens a
//    new window (regression-shaped: passes today only because
//    attachWindow's own pre-existing F6 guard happens to catch it via
//    this method's `.attachAsNewWindow` fallback branch -- but the
//    routing-decision observer assertion is genuine RED, since the
//    RED-phase policy stub always answers `.attachAsNewWindow`
//    regardless of input).
//  - A STALE mapping (registered, but no controller owns it, and no
//    other window exists either): must unregister it and fall through to
//    a fresh attach, going through TWO decisions
//    (`.focusExistingSurface` then `.attachAsNewWindow`) once fixed --
//    the RED-phase stub only ever produces one, this sequence assertion
//    is this test's genuine RED evidence.
//  - CORE regression: not yet attached, a window IS available -- must
//    choose `.attachAsTab` and must NEVER reach attachWindow's real
//    window-creation step. Fails on both counts against the RED-phase
//    stub (which always chooses `.attachAsNewWindow` and therefore always
//    reaches window creation) -- this is the exact reported defect.
//  - Sanity/regression companion: not attached, no window at all --
//    `.attachAsNewWindow` is correct both before and after the fix
//    (mirrors AppDelegateAttachWindowTests' own "still reaches window
//    creation" regression companion). Expected to pass already.
//

import XCTest
import AppKit
@testable import Calyx

@MainActor
final class AppDelegateAttachSessionAsTabTests: XCTestCase {

    // MARK: - Row 1: already attached, a window is also available

    func test_attachSessionAsTab_forAlreadyAttachedLiveSession_focusesWithoutOpeningNewWindow() {
        let appDelegate = AppDelegate()
        var observedDecisions: [SessionAttachRoutingPolicy.Decision] = []
        appDelegate._attachSessionAsTabRoutingObserverForTesting = { observedDecisions.append($0) }
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

        appDelegate.attachSessionAsTab(sessionID: sessionID, cwd: nil)

        XCTAssertEqual(observedDecisions, [.focusExistingSurface],
                       "An already-attached session (a window is also available) must route through " +
                       "focusExistingSurface, not attachAsNewWindow")
        XCTAssertEqual(showHookCallCount, 1,
                       "attachSessionAsTab must focus the controller already hosting this session's live " +
                       "surface exactly once")
        XCTAssertEqual(creationHookCallCount, 0,
                       "attachSessionAsTab must never reach real window/surface creation for an already-" +
                       "attached session")
        XCTAssertEqual(SessionSurfaceMap.shared.surfaceID(for: sessionID), existingSurfaceID,
                       "The pre-existing SessionSurfaceMap mapping must be preserved, not replaced")
    }

    // MARK: - Row 2 (stale variant): registered, but no controller owns it, no window at all

    func test_attachSessionAsTab_forStaleSessionSurfaceMapEntry_unregistersAndFallsThroughToFreshDecision() {
        let appDelegate = AppDelegate()
        var observedDecisions: [SessionAttachRoutingPolicy.Decision] = []
        appDelegate._attachSessionAsTabRoutingObserverForTesting = { observedDecisions.append($0) }
        var creationHookCallCount = 0
        appDelegate._attachWindowCreationHookForTesting = { creationHookCallCount += 1 }

        let sessionID = "test-session-\(UUID().uuidString)"
        let staleSurfaceID = UUID()
        // Deliberately registered with NO owning controller in
        // appDelegate.windowControllers (empty here, so hasAvailableWindow
        // is also false), the stale case.
        SessionSurfaceMap.shared.register(sessionID: sessionID, surfaceID: staleSurfaceID)
        defer { SessionSurfaceMap.shared.unregister(sessionID: sessionID) }

        appDelegate.attachSessionAsTab(sessionID: sessionID, cwd: nil)

        XCTAssertEqual(observedDecisions, [.focusExistingSurface, .attachAsNewWindow],
                       "A stale SessionSurfaceMap entry must first route through focusExistingSurface " +
                       "(discovering no live controller owns it), then re-decide once more (now genuinely " +
                       "unattached, and with no window available) instead of stopping after one decision")
        XCTAssertEqual(creationHookCallCount, 1,
                       "Once the stale mapping is unregistered, attachSessionAsTab must still reach a " +
                       "fresh attach (window/surface creation), not silently do nothing")
        XCTAssertNil(SessionSurfaceMap.shared.surfaceID(for: sessionID),
                    "The stale mapping must be unregistered rather than left pointing at a surfaceID no " +
                    "controller owns")
    }

    // MARK: - Row 3 (CORE regression): not yet attached, a window IS available

    func test_attachSessionAsTab_forNotYetAttachedSessionWithAvailableWindow_addsATabInsteadOfOpeningNewWindow() {
        let appDelegate = AppDelegate()
        var observedDecisions: [SessionAttachRoutingPolicy.Decision] = []
        appDelegate._attachSessionAsTabRoutingObserverForTesting = { observedDecisions.append($0) }
        var creationHookCallCount = 0
        appDelegate._attachWindowCreationHookForTesting = { creationHookCallCount += 1 }
        // Bail the `.attachAsTab` branch out immediately after it builds
        // its placeholder tab, BEFORE `attachSessionAsNewTab` reaches the
        // real ghostty-FFI surface + PTY creation
        // (`GhosttyAppController.shared.app`/`restoreTabSurfaces`), which is
        // unsafe from this test host and leaks a live surface across the
        // process-wide singletons (see this hook's own doc comment on
        // AppDelegate). Mirrors `_attachWindowCreationHookForTesting`'s
        // role for the sibling `.attachAsNewWindow` branch above.
        var attachAsTabCreationHookCallCount = 0
        appDelegate._attachSessionAsNewTabCreationHookForTesting = { attachAsTabCreationHookCallCount += 1 }

        // An ordinary, unrelated main window is already open (mirrors the
        // real-world case this whole fix addresses: the user has a Calyx
        // window open, opens the session browser, and clicks Attach on a
        // detached session).
        let unrelatedTab = Tab(title: "Unrelated")
        let unrelatedGroup = TabGroup(name: "Default", tabs: [unrelatedTab], activeTabID: unrelatedTab.id)
        let unrelatedSession = WindowSession(groups: [unrelatedGroup], activeGroupID: unrelatedGroup.id)
        let unrelatedWindow = CalyxWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        let unrelatedController = CalyxWindowController(
            window: unrelatedWindow, windowSession: unrelatedSession, restoring: true
        )
        appDelegate._testInsertWindowController(unrelatedController)

        let sessionID = "test-session-\(UUID().uuidString)"
        // Deliberately NOT registered in SessionSurfaceMap: an orphaned,
        // running-but-detached session, the isOrphan==true browser row case.

        appDelegate.attachSessionAsTab(sessionID: sessionID, cwd: nil)

        XCTAssertEqual(observedDecisions, [.attachAsTab],
                       "A not-yet-attached session, with a main window already available, must route " +
                       "through attachAsTab, not attachAsNewWindow -- this is the reported defect: the " +
                       "session browser's Attach button must not always open a second window")
        XCTAssertEqual(creationHookCallCount, 0,
                       "attachSessionAsTab must never reach attachWindow's real window/surface creation " +
                       "step when a main window is already available to add a tab to instead")
        XCTAssertEqual(attachAsTabCreationHookCallCount, 1,
                       "The .attachAsTab branch must reach attachSessionAsNewTab's own creation bail-out " +
                       "seam exactly once, proving the route is exercised without spawning a real ghostty " +
                       "surface/PTY in the test host")
    }

    // MARK: - Row 4 (sanity/regression companion): not attached, no window at all

    /// Passes against both the RED-phase stub and the eventual fix (the
    /// one truth-table row where both agree): included so a future
    /// regression that over-broadens `.attachAsTab` (e.g. always
    /// choosing it, even with no window at all) would be caught here.
    func test_attachSessionAsTab_forNotYetAttachedSessionWithNoAvailableWindow_stillOpensNewWindow() {
        let appDelegate = AppDelegate()
        var observedDecisions: [SessionAttachRoutingPolicy.Decision] = []
        appDelegate._attachSessionAsTabRoutingObserverForTesting = { observedDecisions.append($0) }
        var creationHookCallCount = 0
        appDelegate._attachWindowCreationHookForTesting = { creationHookCallCount += 1 }

        let sessionID = "test-session-\(UUID().uuidString)"
        // Deliberately NOT registered in SessionSurfaceMap, and no window
        // controller inserted at all.

        appDelegate.attachSessionAsTab(sessionID: sessionID, cwd: nil)

        XCTAssertEqual(observedDecisions, [.attachAsNewWindow],
                       "With no live surface and no window available at all, a fresh window is genuinely " +
                       "the only option")
        XCTAssertEqual(creationHookCallCount, 1,
                       "attachSessionAsTab must still reach window/surface creation when no window exists " +
                       "to add a tab to")
    }
}
