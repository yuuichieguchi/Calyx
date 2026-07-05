//
//  SessionCommandPaletteTests.swift
//  CalyxTests
//
//  TDD Red Phase for P4's session command-palette entries:
//  `session.attach` / `session.detach` / `session.kill` must be
//  registered by `CalyxWindowController.setupCommandRegistry`, gated
//  by `isAvailable`. Directly queries `commandRegistry.allCommands`
//  (not `private` — see that property's P4 doc comment) rather than
//  driving the real command palette UI, matching this codebase's
//  direct-query test style.
//
//  None of the three commands exist yet — every test below fails at
//  `XCTUnwrap` until the Green phase registers them.
//
//  Fix round (review findings, item 3): `session.detach`/`session.kill`
//  used to execute `closeTab(id:killSessions:)`, tearing down every
//  surface in the active tab even though `isAvailable`
//  (`focusedPaneHasTrackedSession`) only checks the ONE focused pane.
//  The tests below build a two-pane tab (one tracked, one untracked
//  sibling) and invoke each command's `handler` directly, proving only
//  the focused/tracked pane's leaf and `SessionRef` are torn down and
//  the untracked sibling survives untouched.
//
//  Last-pane quit confirmation: `closeFocusedSessionSurface` gates
//  teardown on `confirmQuitBeforeCloseIfWouldTerminate` only when the
//  focused pane is the last leaf in the last tab of the last group of
//  the last managed window (`isLastPaneEverywhere`) — an ordinary
//  multi-pane tab never consults it, since detaching/killing one pane
//  can't empty the window. `MockConfirmQuitAppDelegate` below swaps
//  into `NSApp.delegate` to drive both outcomes (cancel/confirm)
//  deterministically, without a real `NSAlert.runModal()` blocking the
//  test run.
//

import XCTest
import AppKit
@testable import Calyx

@MainActor
final class SessionCommandPaletteTests: XCTestCase {

    /// sessionIDs registered with `SessionSurfaceMap.shared` by
    /// `makeMultiPaneFixture()`/`makeSinglePaneFixture()`, so `tearDown`
    /// can unregister exactly those entries rather than nuking the
    /// whole shared singleton (review finding: fixtures registered
    /// sessions here but never unregistered them, leaking entries into
    /// other tests that share the same process-wide singleton).
    private var registeredSessionIDs: [String] = []

    override func tearDown() {
        for sessionID in registeredSessionIDs {
            SessionSurfaceMap.shared.unregister(sessionID: sessionID)
        }
        registeredSessionIDs.removeAll()
        super.tearDown()
    }

    /// Build a minimal `CalyxWindowController` for direct registry
    /// inspection — `restoring: true` skips `setupTerminalSurface()`,
    /// which requires a live Ghostty app instance (same helper shape
    /// as `CalyxWindowControllerFullScreenTests.makeController()`).
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

    /// Build a `CalyxWindowController` whose active tab has exactly one
    /// leaf, focused (`SplitTree(leafID:)` focuses the leaf it creates),
    /// but with an empty `sessionRefs` — i.e. a real focused pane that
    /// is simply not a persistent-session pane. Distinct from
    /// `makeController()`'s tab, whose default `SplitTree()` has no
    /// leaf and no focused leaf at all: `focusedPaneHasTrackedSession`'s
    /// guard (`guard let tab = activeTab, let leafID =
    /// tab.splitTree.focusedLeafID else { return false }`) short-circuits
    /// on `makeController()`'s tab without ever reaching the
    /// `tab.sessionRefs[leafID] != nil` check — this fixture is what
    /// actually exercises that second check (review finding: the two
    /// `isUnavailable` tests below used to both drive the same
    /// short-circuited path via `makeController()`).
    private func makeControllerWithFocusedUntrackedPane() -> CalyxWindowController {
        let registry = SurfaceRegistry()
        let leafID = UUID()
        registry._testInsert(view: SurfaceView(frame: .zero), id: leafID)

        let tab = Tab(splitTree: SplitTree(leafID: leafID), registry: registry)
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

    private func command(_ id: String, in controller: CalyxWindowController) throws -> PaletteCommand {
        try XCTUnwrap(
            controller.commandRegistry.allCommands.first(where: { $0.id == id }),
            "setupCommandRegistry must register a '\(id)' command"
        )
    }

    // MARK: - Registration

    func test_sessionAttachCommand_isRegistered() throws {
        let controller = makeController()
        _ = try command("session.attach", in: controller)
    }

    func test_sessionDetachCommand_isRegistered() throws {
        let controller = makeController()
        _ = try command("session.detach", in: controller)
    }

    func test_sessionKillCommand_isRegistered() throws {
        let controller = makeController()
        _ = try command("session.kill", in: controller)
    }

    // MARK: - isAvailable gating

    /// With a real focused pane that carries no tracked `SessionRef`,
    /// `session.kill` must not be offered — killing a plain shell
    /// pane's session makes no sense, since there is no session to
    /// kill. Exercises `focusedPaneHasTrackedSession`'s
    /// `tab.sessionRefs[leafID] != nil` check itself, not just the
    /// `focusedLeafID == nil` short-circuit (see
    /// `test_sessionKillCommand_isUnavailable_whenNoFocusedLeaf` for
    /// that branch).
    func test_sessionKillCommand_isUnavailable_whenFocusedPaneHasNoTrackedSession() throws {
        let controller = makeControllerWithFocusedUntrackedPane()
        let killCommand = try command("session.kill", in: controller)

        XCTAssertFalse(killCommand.isAvailable(),
                       "session.kill must gate on the focused pane having a tracked SessionRef — an " +
                       "ordinary (non-persistent) pane must not offer it")
    }

    /// Same gate applies to `session.detach` — nothing to detach from
    /// when the focused pane isn't a persistent-session pane at all.
    func test_sessionDetachCommand_isUnavailable_whenFocusedPaneHasNoTrackedSession() throws {
        let controller = makeControllerWithFocusedUntrackedPane()
        let detachCommand = try command("session.detach", in: controller)

        XCTAssertFalse(detachCommand.isAvailable(),
                       "session.detach must gate on the focused pane having a tracked SessionRef")
    }

    /// `focusedPaneHasTrackedSession`'s guard also short-circuits when
    /// there is no focused leaf at all (`makeController()`'s tab has
    /// the default, leafless `SplitTree()`) — a separate branch from
    /// the "focused but untracked" case above, and one the two tests
    /// above no longer exercise now that they use
    /// `makeControllerWithFocusedUntrackedPane()`.
    func test_sessionKillCommand_isUnavailable_whenNoFocusedLeaf() throws {
        let controller = makeController()
        let killCommand = try command("session.kill", in: controller)

        XCTAssertFalse(killCommand.isAvailable(),
                       "session.kill must gate on there being a focused leaf at all — a tab with no " +
                       "focused leaf must not offer it")
    }

    /// Same gate applies to `session.detach`.
    func test_sessionDetachCommand_isUnavailable_whenNoFocusedLeaf() throws {
        let controller = makeController()
        let detachCommand = try command("session.detach", in: controller)

        XCTAssertFalse(detachCommand.isAvailable(),
                       "session.detach must gate on there being a focused leaf at all")
    }

    // MARK: - Multi-pane targeting (fix round, item 3)

    /// Two-pane fixture: `trackedLeafID` carries a `SessionRef` (both in
    /// `tab.sessionRefs` and `SessionSurfaceMap.shared`) and is focused;
    /// `siblingLeafID` is an ordinary, untracked pane. Mirrors
    /// `CalyxWindowControllerFocusSyncTests`'s `_testInsert`-backed
    /// two-pane fixture — no live ghostty app needed.
    private struct MultiPaneFixture {
        let controller: CalyxWindowController
        let tab: Tab
        let trackedLeafID: UUID
        let siblingLeafID: UUID
        let sessionID: String
    }

    private func makeMultiPaneFixture() -> MultiPaneFixture {
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
        registeredSessionIDs.append(sessionID)

        let group = TabGroup(name: "Default", tabs: [tab], activeTabID: tab.id)
        let session = WindowSession(groups: [group], activeGroupID: group.id)
        let window = CalyxWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        let controller = CalyxWindowController(window: window, windowSession: session, restoring: true)
        return MultiPaneFixture(
            controller: controller,
            tab: tab,
            trackedLeafID: trackedLeafID,
            siblingLeafID: siblingLeafID,
            sessionID: sessionID
        )
    }

    /// Regression test: `session.detach` used to call
    /// `closeTab(id:killSessions:false)`, which detached (and destroyed
    /// the surface of) EVERY leaf in the tab, including the untracked
    /// sibling. It must now tear down only the focused, tracked leaf.
    func test_sessionDetachCommand_actsOnlyOnFocusedPane_leavesSiblingPaneIntact() throws {
        let fixture = makeMultiPaneFixture()
        let detachCommand = try command("session.detach", in: fixture.controller)

        detachCommand.handler()

        XCTAssertEqual(fixture.tab.splitTree.allLeafIDs(), [fixture.siblingLeafID],
                       "session.detach must remove only the focused (tracked) leaf, leaving the " +
                       "untracked sibling pane's leaf in the split tree")
        XCTAssertNil(fixture.tab.sessionRefs[fixture.trackedLeafID],
                    "The detached leaf's SessionRef must be cleared")
        XCTAssertNil(SessionSurfaceMap.shared.sessionID(for: fixture.trackedLeafID),
                    "SessionSurfaceMap must no longer track the detached surface")
    }

    /// Same regression, for `session.kill`: it used to call
    /// `closeTab(id:killSessions:true)` (the default), destroying every
    /// surface in the tab. It must now tear down only the focused,
    /// tracked leaf.
    func test_sessionKillCommand_actsOnlyOnFocusedPane_leavesSiblingPaneIntact() throws {
        let fixture = makeMultiPaneFixture()
        let killCommand = try command("session.kill", in: fixture.controller)

        killCommand.handler()

        XCTAssertEqual(fixture.tab.splitTree.allLeafIDs(), [fixture.siblingLeafID],
                       "session.kill must remove only the focused (tracked) leaf, leaving the untracked " +
                       "sibling pane's leaf in the split tree")
        XCTAssertNil(fixture.tab.sessionRefs[fixture.trackedLeafID],
                    "The killed leaf's SessionRef must be cleared")
        XCTAssertNil(SessionSurfaceMap.shared.sessionID(for: fixture.trackedLeafID),
                    "SessionSurfaceMap must no longer track the killed surface")
    }

    // MARK: - Last-pane teardown (confirm-quit gate)

    /// `AppDelegate` subclass that lets the last-pane-everywhere
    /// confirm-quit gate be driven deterministically, without a real
    /// `NSAlert.runModal()` blocking the test run, and counts how many
    /// times it was consulted. Overrides `closingWouldTerminate` to
    /// always report `true` regardless of this test process's real
    /// `windowControllers` (which the fixture's contrived controller was
    /// never added to), and `removeWindowController` to a no-op purely
    /// as test-process safety: invoking `session.detach`/`session.kill`
    /// on `SinglePaneFixture` below, when `shouldConfirm` is `true`,
    /// empties the window for real, so `closeSurfaceAndCleanUp` calls
    /// `window?.close()`, which fires `windowWillClose` ->
    /// `AppDelegate.removeWindowController`. The real implementation
    /// calls `NSApp.terminate(nil)` there once its (private)
    /// `windowControllers` list is empty — swapped into `NSApp.delegate`
    /// for the duration of each test below so the test process itself
    /// never risks exiting, regardless of how many real windows the
    /// host app happens to have at the time.
    private final class MockConfirmQuitAppDelegate: AppDelegate {
        var shouldConfirm = true
        private(set) var confirmQuitCallCount = 0

        override func closingWouldTerminate(_ controller: CalyxWindowController) -> Bool {
            true
        }

        override func confirmQuitIfNeeded(_ mode: ConfirmQuitMode) -> Bool {
            confirmQuitCallCount += 1
            return shouldConfirm
        }

        override func removeWindowController(_ controller: CalyxWindowController) {}
    }

    private func withMockAppDelegate(_ mock: MockConfirmQuitAppDelegate, _ body: () throws -> Void) rethrows {
        // `mock` must stay alive for the whole call: `NSApp.delegate` is a
        // weak reference, so assigning a delegate with no other strong
        // reference would deallocate it immediately.
        let original = NSApp.delegate
        NSApp.delegate = mock
        defer { NSApp.delegate = original }
        try withExtendedLifetime(mock) {
            try body()
        }
    }

    /// Single-pane/single-tab/single-group fixture: the focused (and
    /// only) leaf carries a `SessionRef`, tracked in both
    /// `tab.sessionRefs` and `SessionSurfaceMap.shared` — the "closing
    /// this pane empties the window" case.
    private struct SinglePaneFixture {
        let controller: CalyxWindowController
        let tab: Tab
        let leafID: UUID
        let sessionID: String
    }

    private func makeSinglePaneFixture() -> SinglePaneFixture {
        let registry = SurfaceRegistry()
        let leafID = UUID()
        registry._testInsert(view: SurfaceView(frame: .zero), id: leafID)

        let sessionID = "test-session-\(UUID().uuidString)"
        let tab = Tab(
            splitTree: SplitTree(leafID: leafID),
            registry: registry,
            sessionRefs: [leafID: SessionRef(sessionID: sessionID)]
        )
        SessionSurfaceMap.shared.register(sessionID: sessionID, surfaceID: leafID)
        registeredSessionIDs.append(sessionID)

        let group = TabGroup(name: "Default", tabs: [tab], activeTabID: tab.id)
        let session = WindowSession(groups: [group], activeGroupID: group.id)
        let window = CalyxWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        let controller = CalyxWindowController(window: window, windowSession: session, restoring: true)
        return SinglePaneFixture(controller: controller, tab: tab, leafID: leafID, sessionID: sessionID)
    }

    /// A multi-pane tab's `session.detach` can never empty the window
    /// (the untracked sibling pane always survives), so
    /// `closeFocusedSessionSurface` must never even consult the
    /// confirm-quit gate — `isLastPaneEverywhere` is false before any
    /// alert would be shown.
    func test_sessionDetachCommand_multiPane_neverConsultsConfirmQuitGate() throws {
        let fixture = makeMultiPaneFixture()
        let detachCommand = try command("session.detach", in: fixture.controller)
        let mock = MockConfirmQuitAppDelegate()

        withMockAppDelegate(mock) {
            detachCommand.handler()
        }

        XCTAssertEqual(mock.confirmQuitCallCount, 0,
                       "Detaching one pane of a multi-pane tab never empties the window, so the " +
                       "confirm-quit gate must never be consulted")
        XCTAssertEqual(fixture.tab.splitTree.allLeafIDs(), [fixture.siblingLeafID],
                       "The focused, tracked leaf must still be torn down as usual")
    }

    /// Same guarantee for `session.kill`.
    func test_sessionKillCommand_multiPane_neverConsultsConfirmQuitGate() throws {
        let fixture = makeMultiPaneFixture()
        let killCommand = try command("session.kill", in: fixture.controller)
        let mock = MockConfirmQuitAppDelegate()

        withMockAppDelegate(mock) {
            killCommand.handler()
        }

        XCTAssertEqual(mock.confirmQuitCallCount, 0,
                       "Killing one pane of a multi-pane tab never empties the window, so the " +
                       "confirm-quit gate must never be consulted")
        XCTAssertEqual(fixture.tab.splitTree.allLeafIDs(), [fixture.siblingLeafID],
                       "The focused, tracked leaf must still be torn down as usual")
    }

    /// True last-pane/last-tab/last-group case, user cancels the
    /// confirm-quit prompt: teardown must not proceed at all — the
    /// pane's leaf, `SessionRef`, `SessionSurfaceMap` entry, and the
    /// group itself must all remain exactly as they were.
    func test_sessionDetachCommand_lastPaneEverywhere_confirmQuitCancelled_preservesAllState() throws {
        let fixture = makeSinglePaneFixture()
        let detachCommand = try command("session.detach", in: fixture.controller)
        let mock = MockConfirmQuitAppDelegate()
        mock.shouldConfirm = false

        withMockAppDelegate(mock) {
            detachCommand.handler()
        }

        XCTAssertEqual(mock.confirmQuitCallCount, 1,
                       "The last-pane-everywhere case must consult the confirm-quit gate exactly once")
        XCTAssertEqual(fixture.tab.splitTree.allLeafIDs(), [fixture.leafID],
                       "Cancelling the quit prompt must leave the pane's leaf untouched")
        XCTAssertNotNil(fixture.tab.sessionRefs[fixture.leafID],
                        "Cancelling must leave the SessionRef untouched")
        XCTAssertNotNil(SessionSurfaceMap.shared.sessionID(for: fixture.leafID),
                        "Cancelling must leave the SessionSurfaceMap entry untouched")
        XCTAssertEqual(fixture.controller.windowSession.groups.count, 1,
                       "Cancelling must leave the group (and its tab) in place")
    }

    /// Same guarantee for `session.kill`.
    func test_sessionKillCommand_lastPaneEverywhere_confirmQuitCancelled_preservesAllState() throws {
        let fixture = makeSinglePaneFixture()
        let killCommand = try command("session.kill", in: fixture.controller)
        let mock = MockConfirmQuitAppDelegate()
        mock.shouldConfirm = false

        withMockAppDelegate(mock) {
            killCommand.handler()
        }

        XCTAssertEqual(mock.confirmQuitCallCount, 1,
                       "The last-pane-everywhere case must consult the confirm-quit gate exactly once")
        XCTAssertEqual(fixture.tab.splitTree.allLeafIDs(), [fixture.leafID],
                       "Cancelling the quit prompt must leave the pane's leaf untouched")
        XCTAssertNotNil(fixture.tab.sessionRefs[fixture.leafID],
                        "Cancelling must leave the SessionRef untouched")
        XCTAssertNotNil(SessionSurfaceMap.shared.sessionID(for: fixture.leafID),
                        "Cancelling must leave the SessionSurfaceMap entry untouched")
        XCTAssertEqual(fixture.controller.windowSession.groups.count, 1,
                       "Cancelling must leave the group (and its tab) in place")
    }

    /// True last-pane/last-tab/last-group case, user confirms the
    /// prompt: teardown must proceed exactly as it would with no gate
    /// at all, and — since teardown reaches `closeSurfaceAndCleanUp`'s
    /// `.windowShouldClose` case — `AppDelegate.isTerminationConfirmed`
    /// must end up `true` so the `windowShouldClose` ->
    /// `applicationShouldTerminate` cascade this triggers for real
    /// doesn't prompt a second time.
    func test_sessionDetachCommand_lastPaneEverywhere_confirmQuitConfirmed_proceedsWithTeardown() throws {
        let fixture = makeSinglePaneFixture()
        let detachCommand = try command("session.detach", in: fixture.controller)
        let mock = MockConfirmQuitAppDelegate()
        mock.shouldConfirm = true

        withMockAppDelegate(mock) {
            detachCommand.handler()
        }

        XCTAssertEqual(mock.confirmQuitCallCount, 1,
                       "The last-pane-everywhere case must consult the confirm-quit gate exactly once")
        XCTAssertTrue(mock.isTerminationConfirmed,
                      "Confirming quit must mark isTerminationConfirmed once teardown reaches the window " +
                      "close, so the real windowShouldClose -> applicationShouldTerminate cascade this " +
                      "close triggers doesn't prompt again")
        XCTAssertTrue(fixture.tab.splitTree.isEmpty,
                      "Confirming quit must let teardown proceed, removing the pane's leaf")
        XCTAssertNil(fixture.tab.sessionRefs[fixture.leafID],
                    "Teardown must clear the SessionRef")
        XCTAssertNil(SessionSurfaceMap.shared.sessionID(for: fixture.leafID),
                    "Teardown must clear the SessionSurfaceMap entry")
        XCTAssertTrue(fixture.controller.windowSession.groups.isEmpty,
                     "Teardown must remove the now-empty tab and its now-empty group")
    }

    /// Same guarantee for `session.kill`.
    func test_sessionKillCommand_lastPaneEverywhere_confirmQuitConfirmed_proceedsWithTeardown() throws {
        let fixture = makeSinglePaneFixture()
        let killCommand = try command("session.kill", in: fixture.controller)
        let mock = MockConfirmQuitAppDelegate()
        mock.shouldConfirm = true

        withMockAppDelegate(mock) {
            killCommand.handler()
        }

        XCTAssertEqual(mock.confirmQuitCallCount, 1,
                       "The last-pane-everywhere case must consult the confirm-quit gate exactly once")
        XCTAssertTrue(mock.isTerminationConfirmed,
                      "Confirming quit must mark isTerminationConfirmed once teardown reaches the window " +
                      "close, so the real windowShouldClose -> applicationShouldTerminate cascade this " +
                      "close triggers doesn't prompt again")
        XCTAssertTrue(fixture.tab.splitTree.isEmpty,
                      "Confirming quit must let teardown proceed, removing the pane's leaf")
        XCTAssertNil(fixture.tab.sessionRefs[fixture.leafID],
                    "Teardown must clear the SessionRef")
        XCTAssertNil(SessionSurfaceMap.shared.sessionID(for: fixture.leafID),
                    "Teardown must clear the SessionSurfaceMap entry")
        XCTAssertTrue(fixture.controller.windowSession.groups.isEmpty,
                     "Teardown must remove the now-empty tab and its now-empty group")
    }
}
