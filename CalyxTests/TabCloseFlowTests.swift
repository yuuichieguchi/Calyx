//
//  TabCloseFlowTests.swift
//  CalyxTests
//
//  Tests for WindowSession.removeTab idempotency and edge cases
//  related to tab closing. These tests verify that double-removal
//  (e.g., from both closeTab and a notification handler) is handled
//  safely at the model level.
//
//  Coverage:
//  - Remove one tab from a two-tab group leaves one tab
//  - Double-removal of same tab ID is safe (idempotent)
//  - Removing only tab from a group switches to next group
//  - Removing last tab from last group returns .windowShouldClose
//

import XCTest
@testable import Calyx

@MainActor
final class TabCloseFlowTests: XCTestCase {

    // MARK: - Helpers

    private func makeTab(title: String = "Terminal") -> Tab {
        Tab(title: title)
    }

    private func makeGroup(
        name: String = "Default",
        tabs: [Tab] = [],
        activeTabID: UUID? = nil
    ) -> TabGroup {
        TabGroup(name: name, tabs: tabs, activeTabID: activeTabID)
    }

    // ==================== 1. Remove One Tab From Two-Tab Group ====================

    func test_removeTab_from_two_tab_group_leaves_one() {
        // Arrange — group with [A, B], active = A
        let tabA = makeTab(title: "A")
        let tabB = makeTab(title: "B")
        let group = makeGroup(tabs: [tabA, tabB], activeTabID: tabA.id)
        let session = WindowSession(groups: [group], activeGroupID: group.id)

        // Act — remove tab A
        let result = session.removeTab(id: tabA.id, fromGroup: group.id)

        // Assert — one tab remains, result is .switchedTab to B
        XCTAssertEqual(group.tabs.count, 1,
                       "Group should have exactly 1 tab after removing one of two")
        XCTAssertEqual(group.tabs.first?.id, tabB.id,
                       "The remaining tab should be B")
        if case .switchedTab(let gid, let tid) = result {
            XCTAssertEqual(gid, group.id,
                           "switchedTab groupID should match the group")
            XCTAssertEqual(tid, tabB.id,
                           "switchedTab tabID should be B (the remaining tab)")
        } else {
            XCTFail("Expected .switchedTab, got \(result)")
        }
    }

    // ==================== 2. Double-Removal Is Safe (Idempotent) ====================

    func test_removeTab_twice_same_id_is_safe() {
        // Arrange — group with [A, B], active = A
        let tabA = makeTab(title: "A")
        let tabB = makeTab(title: "B")
        let group = makeGroup(tabs: [tabA, tabB], activeTabID: tabA.id)
        let session = WindowSession(groups: [group], activeGroupID: group.id)

        // Act — remove tab A the first time (simulates closeTab)
        let result1 = session.removeTab(id: tabA.id, fromGroup: group.id)

        // Verify first removal worked as expected
        XCTAssertEqual(group.tabs.count, 1,
                       "After first removal, group should have 1 tab")
        if case .switchedTab(_, let tid) = result1 {
            XCTAssertEqual(tid, tabB.id, "First removal should switch to B")
        } else {
            XCTFail("First removal: expected .switchedTab, got \(result1)")
        }

        // Act — remove tab A again with the same group ID (simulates notification handler)
        let result2 = session.removeTab(id: tabA.id, fromGroup: group.id)

        // Assert — B should still be there; the second call must NOT cause
        // .windowShouldClose or remove additional tabs
        XCTAssertEqual(group.tabs.count, 1,
                       "After second removal of same ID, tab count must remain 1")
        XCTAssertEqual(group.tabs.first?.id, tabB.id,
                       "Tab B must still be present after double-removal of A")
        XCTAssertEqual(session.groups.count, 1,
                       "The group must not be removed by the second call")
        if case .switchedTab(let gid, let tid) = result2 {
            XCTAssertEqual(gid, group.id,
                           "Second removal should still reference the same group")
            XCTAssertEqual(tid, tabB.id,
                           "Second removal should still point to B")
        } else {
            XCTFail("Second removal: expected .switchedTab (B still exists), got \(result2)")
        }
    }

    // ==================== 3. Empty Group Switches To Next Group ====================

    func test_removeTab_empty_group_switches_to_next_group() {
        // Arrange — two groups: group1 has [A], group2 has [B]
        let tabA = makeTab(title: "A")
        let tabB = makeTab(title: "B")
        let group1 = makeGroup(name: "G1", tabs: [tabA], activeTabID: tabA.id)
        let group2 = makeGroup(name: "G2", tabs: [tabB], activeTabID: tabB.id)
        let session = WindowSession(groups: [group1, group2], activeGroupID: group1.id)

        // Act — remove the only tab from group1
        let result = session.removeTab(id: tabA.id, fromGroup: group1.id)

        // Assert — group1 should be removed, switches to group2
        XCTAssertEqual(session.groups.count, 1,
                       "Empty group should be removed, leaving 1 group")
        XCTAssertEqual(session.groups.first?.id, group2.id,
                       "The remaining group should be G2")
        XCTAssertEqual(session.activeGroupID, group2.id,
                       "Active group should switch to G2")
        if case .switchedGroup(let gid, let tid) = result {
            XCTAssertEqual(gid, group2.id,
                           "switchedGroup should point to G2")
            XCTAssertEqual(tid, tabB.id,
                           "switchedGroup should point to G2's active tab (B)")
        } else {
            XCTFail("Expected .switchedGroup, got \(result)")
        }
    }

    // ==================== 4. Last Tab In Last Group Returns .windowShouldClose ====================

    func test_removeTab_last_tab_last_group_returns_windowShouldClose() {
        // Arrange — single group with single tab
        let tab = makeTab(title: "Only")
        let group = makeGroup(tabs: [tab], activeTabID: tab.id)
        let session = WindowSession(groups: [group], activeGroupID: group.id)

        // Act — remove the only tab
        let result = session.removeTab(id: tab.id, fromGroup: group.id)

        // Assert — everything is gone, window should close
        XCTAssertTrue(session.groups.isEmpty,
                      "All groups should be removed")
        XCTAssertNil(session.activeGroupID,
                     "activeGroupID should be nil")
        if case .windowShouldClose = result {
            // Expected
        } else {
            XCTFail("Expected .windowShouldClose, got \(result)")
        }
    }

    // ==================== 5. Remove Tab Works Regardless of View Window ====================

    func test_removeTab_succeeds_when_tab_exists_in_session() {
        // This test verifies that tab removal at the model level works correctly.
        // The bug was that handleCloseSurfaceNotification checked belongsToThisWindow
        // (view.window === self.window) which fails when ghostty detaches the view.
        // The fix removes that guard, relying on findTab(for:) which checks the
        // tab registry (object identity, not view hierarchy).
        //
        // At the model level, removeTab works by ID alone — no view hierarchy involved.
        let tab = makeTab(title: "Detached")
        let group = makeGroup(tabs: [tab], activeTabID: tab.id)
        let otherTab = makeTab(title: "Other")
        let group2 = makeGroup(name: "G2", tabs: [otherTab], activeTabID: otherTab.id)
        let session = WindowSession(groups: [group, group2], activeGroupID: group.id)

        // Act — remove the tab (simulating what happens after belongsToThisWindow guard is removed)
        let result = session.removeTab(id: tab.id, fromGroup: group.id)

        // Assert — tab removed successfully, switches to other group
        XCTAssertEqual(session.groups.count, 1, "Empty group should be removed")
        XCTAssertEqual(session.activeGroupID, group2.id, "Should switch to remaining group")
        if case .switchedGroup(let gid, _) = result {
            XCTAssertEqual(gid, group2.id, "Should switch to group2")
        } else {
            XCTFail("Expected .switchedGroup, got \(result)")
        }
    }
}
