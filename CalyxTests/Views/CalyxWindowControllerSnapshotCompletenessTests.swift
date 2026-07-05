//
//  CalyxWindowControllerSnapshotCompletenessTests.swift
//  CalyxTests
//
//  TDD Red phase, round 10 (r10-fix-spec.md, R10-A item 3): production
//  saves (requestSave/saveImmediately/applicationWillTerminate) all go
//  through CalyxWindowController.windowSnapshot(), which constructs its
//  TabSnapshot WITHOUT sessionRefs, even though the tested-but-
//  production-unused Tab.snapshot()/TabGroup.snapshot()/WindowSession
//  .snapshot() extension chain (SessionSnapshot.swift) carries every
//  field correctly. A persistent session's SessionRef therefore never
//  reaches disk from a real save, so it cannot survive a relaunch.
//
//  This is the missing production-builder completeness test named by
//  the round-10 sweep: build a real CalyxWindowController whose Tab
//  carries non-empty sessionRefs plus a representative, non-default
//  value for every other TabSnapshot/TabGroupSnapshot/WindowSnapshot
//  field, call windowSnapshot(), and assert every field against the
//  source model. Must FAIL today on sessionRefs (nil vs. populated);
//  all other assertions are expected to already pass, since a direct
//  read of windowSnapshot() confirms every other TabGroupSnapshot/
//  WindowSnapshot field IS already threaded through correctly, only
//  TabSnapshot.sessionRefs is dropped.
//
//  Coverage:
//  - windowSnapshot()'s TabSnapshot must carry tab.sessionRefs through
//  - Every other TabSnapshot/TabGroupSnapshot/WindowSnapshot field must
//    match the source Tab/TabGroup/WindowSession model
//

import AppKit
import XCTest
@testable import Calyx

@MainActor
final class CalyxWindowControllerSnapshotCompletenessTests: XCTestCase {

    func test_windowSnapshot_preservesEveryTabGroupAndWindowField() throws {
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
        let splitTree = SplitTree(root: root, focusedLeafID: trackedLeafID)

        let sessionID = "test-session-\(UUID().uuidString)"
        let sessionRef = SessionRef(sessionID: sessionID, host: nil, agentSessions: ["claude-code": "agent-123"])
        let sessionRefsDict: [UUID: SessionRef] = [trackedLeafID: sessionRef]

        let browserURL = try XCTUnwrap(URL(string: "https://example.com/round10"))

        let tab = Tab(
            title: "Custom Terminal Title",
            titleOverride: "User Override Title",
            pwd: "/Users/test/round10-fixture",
            splitTree: splitTree,
            content: .browser(url: browserURL),
            registry: registry,
            sessionRefs: sessionRefsDict
        )

        let group = TabGroup(
            name: "Round 10 Group",
            color: .purple,
            isCollapsed: true,
            tabs: [tab],
            activeTabID: tab.id
        )

        let windowSession = WindowSession(
            groups: [group],
            activeGroupID: group.id,
            showSidebar: false,
            sidebarWidth: 321
        )

        let window = CalyxWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        let controller = CalyxWindowController(window: window, windowSession: windowSession, restoring: true)

        // Representative non-default value for the isFullScreen/frame pair
        // (CalyxWindowControllerFullScreenTests already covers this pair's
        // own behavior in isolation; included here only so this test's
        // window-level field list is complete).
        let preFrame = NSRect(x: 12, y: 34, width: 900, height: 700)
        controller.trackedFullScreen = true
        controller.preFullScreenFrame = preFrame

        let snapshot = controller.windowSnapshot()

        // MARK: WindowSnapshot-level fields
        XCTAssertEqual(snapshot.id, windowSession.id)
        XCTAssertEqual(snapshot.activeGroupID, windowSession.activeGroupID)
        XCTAssertEqual(snapshot.showSidebar, windowSession.showSidebar)
        XCTAssertEqual(snapshot.sidebarWidth, windowSession.sidebarWidth)
        XCTAssertTrue(snapshot.isFullScreen)
        XCTAssertEqual(snapshot.frame, preFrame)

        // MARK: TabGroupSnapshot-level fields
        XCTAssertEqual(snapshot.groups.count, 1)
        let groupSnapshot = try XCTUnwrap(snapshot.groups.first)
        XCTAssertEqual(groupSnapshot.id, group.id)
        XCTAssertEqual(groupSnapshot.name, group.name)
        XCTAssertEqual(groupSnapshot.color, group.color.rawValue as String?)
        XCTAssertEqual(groupSnapshot.activeTabID, group.activeTabID)
        XCTAssertEqual(groupSnapshot.isCollapsed, group.isCollapsed)

        // MARK: TabSnapshot-level fields
        XCTAssertEqual(groupSnapshot.tabs.count, 1)
        let tabSnapshot = try XCTUnwrap(groupSnapshot.tabs.first)
        XCTAssertEqual(tabSnapshot.id, tab.id)
        XCTAssertEqual(tabSnapshot.title, tab.title)
        XCTAssertEqual(tabSnapshot.titleOverride, tab.titleOverride)
        XCTAssertEqual(tabSnapshot.pwd, tab.pwd)
        XCTAssertEqual(tabSnapshot.splitTree, tab.splitTree)
        XCTAssertEqual(tabSnapshot.browserURL, browserURL as URL?)
        XCTAssertEqual(
            tabSnapshot.sessionRefs, sessionRefsDict as [UUID: SessionRef]?,
            "windowSnapshot() must carry tab.sessionRefs through to TabSnapshot -- production saves currently " +
            "drop this field entirely, so a persistent session's SessionRef never reaches disk"
        )
    }
}
