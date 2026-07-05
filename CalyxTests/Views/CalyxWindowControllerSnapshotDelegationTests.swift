//
//  CalyxWindowControllerSnapshotDelegationTests.swift
//  CalyxTests
//
//  TDD Red phase, round 12 (r12-fix-spec.md, R12-C): windowSnapshot()
//  builds its own TabSnapshot/TabGroupSnapshot construction inline
//  instead of delegating to the tested Tab.snapshot()/TabGroup
//  .snapshot() extension chain (SessionSnapshot.swift), so the codebase
//  carries two parallel TabSnapshot builders that must be kept in sync
//  by hand. R12-C's fix collapses windowSnapshot() down to delegate to
//  that chain, keeping only the live-window-only inputs
//  (frame/isFullScreen, and the live browserURL override from
//  browserControllers) local.
//
//  This test locks that delegation: for a tab with no live browser
//  override in play (a plain terminal tab, no BrowserTabController ever
//  created for it), windowSnapshot()'s TabSnapshot must equal
//  Tab.snapshot()'s own output for the identical tab. Per this
//  contract's round-12 spec: "This may PASS today by coincidence for
//  terminal tabs (both builders produce identical fields now)" -- and
//  it does (verified against a941b245d): both builders read title,
//  titleOverride, pwd, splitTree, and sessionRefs straight off the same
//  Tab, and a terminal tab's browserURL is nil in both. This assertion
//  is therefore a REGRESSION GUARD, not RED proof, for the terminal-tab
//  case -- it locks the two builders' agreement so any future edit to
//  either one that silently diverges them is caught immediately. The
//  refactor's real regression guard remains
//  CalyxWindowControllerSnapshotCompletenessTests (every field,
//  including sessionRefs, already covered end-to-end against a real
//  CalyxWindowController).
//
//  Coverage:
//  - windowSnapshot()'s TabSnapshot for a terminal tab with no live
//    browser override equals Tab.snapshot()'s output for that same tab
//    (regression guard: passes both before and after the R12-C
//    delegation refactor)
//

import AppKit
import XCTest
@testable import Calyx

@MainActor
final class CalyxWindowControllerSnapshotDelegationTests: XCTestCase {

    func test_windowSnapshot_tabSnapshotForTerminalTab_equalsTabSnapshotDirectly() throws {
        let registry = SurfaceRegistry()
        let leafID = UUID()
        registry._testInsert(view: SurfaceView(frame: .zero), id: leafID)
        let splitTree = SplitTree(root: .leaf(id: leafID), focusedLeafID: leafID)

        let sessionID = "test-session-\(UUID().uuidString)"
        let sessionRef = SessionRef(sessionID: sessionID, host: nil, agentSessions: [:])

        let tab = Tab(
            title: "Delegation Fixture Tab",
            titleOverride: "Delegation Override",
            pwd: "/Users/test/round12-fixture",
            splitTree: splitTree,
            content: .terminal,
            registry: registry,
            sessionRefs: [leafID: sessionRef]
        )

        let group = TabGroup(name: "Round 12 Group", color: .blue, tabs: [tab], activeTabID: tab.id)
        let windowSession = WindowSession(groups: [group], activeGroupID: group.id)

        let window = CalyxWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        let controller = CalyxWindowController(window: window, windowSession: windowSession, restoring: true)

        let windowTabSnapshot = try XCTUnwrap(
            controller.windowSnapshot().groups.first?.tabs.first,
            "windowSnapshot() must produce a TabSnapshot for the single terminal tab in this fixture"
        )
        let directTabSnapshot = try XCTUnwrap(
            tab.snapshot(),
            "Tab.snapshot() must produce a TabSnapshot for a terminal tab"
        )

        XCTAssertEqual(
            windowTabSnapshot, directTabSnapshot,
            "windowSnapshot()'s TabSnapshot for a tab with no live browser override must equal " +
            "Tab.snapshot()'s own output for the identical tab -- regression guard for the R12-C " +
            "delegation, not RED proof (both builders already agree here); see this file's header comment"
        )
    }
}
