//
//  SessionModelTests.swift
//  CalyxTests
//
//  Tests for the runtime session model classes: Tab, TabGroup,
//  WindowSession, and AppSession.
//
//  Coverage:
//  - TabGroup add/remove/move tab
//  - TabGroup active-tab selection after removal (next, previous, nil)
//  - WindowSession activeGroup computed property
//  - WindowSession remove active group → selects next
//  - Tab title/pwd mutation
//  - AppSession add/remove windows
//

import XCTest
@testable import Calyx

@MainActor
final class SessionModelTests: XCTestCase {

    // MARK: - Helpers

    /// Create a minimal Tab for testing purposes.
    private func makeTab(title: String = "Terminal") -> Tab {
        Tab(title: title)
    }

    /// Create a TabGroup pre-populated with the given tabs.
    private func makeGroup(
        name: String = "Default",
        tabs: [Tab] = [],
        activeTabID: UUID? = nil
    ) -> TabGroup {
        TabGroup(name: name, tabs: tabs, activeTabID: activeTabID)
    }

    // ==================== 1. TabGroup Add Tab ====================

    func test_should_increase_tab_count_when_tab_added() {
        // Arrange
        let group = makeGroup()
        let tab = makeTab()

        // Act
        group.addTab(tab)

        // Assert
        XCTAssertEqual(group.tabs.count, 1, "Tab count should be 1 after adding one tab")
    }

    func test_should_make_tab_accessible_after_adding() {
        // Arrange
        let group = makeGroup()
        let tab = makeTab(title: "MyTab")

        // Act
        group.addTab(tab)

        // Assert
        XCTAssertTrue(group.tabs.contains(where: { $0.id == tab.id }),
                       "Added tab should be accessible via tabs array")
        XCTAssertEqual(group.tabs.first?.title, "MyTab",
                       "Tab title should match")
    }

    func test_should_set_activeTabID_when_first_tab_added() {
        // Arrange
        let group = makeGroup()
        let tab = makeTab()

        // Act
        group.addTab(tab)

        // Assert
        XCTAssertEqual(group.activeTabID, tab.id,
                       "activeTabID should be set to the first added tab")
    }

    func test_should_not_change_activeTabID_when_second_tab_added() {
        // Arrange
        let group = makeGroup()
        let firstTab = makeTab()
        let secondTab = makeTab()
        group.addTab(firstTab)

        // Act
        group.addTab(secondTab)

        // Assert
        XCTAssertEqual(group.activeTabID, firstTab.id,
                       "activeTabID should remain on the first tab when a second is added")
        XCTAssertEqual(group.tabs.count, 2)
    }

    // ==================== 2. TabGroup Remove Tab ====================

    func test_should_decrease_tab_count_when_tab_removed() {
        // Arrange
        let tab1 = makeTab()
        let tab2 = makeTab()
        let group = makeGroup(tabs: [tab1, tab2], activeTabID: tab1.id)

        // Act
        group.removeTab(id: tab1.id)

        // Assert
        XCTAssertEqual(group.tabs.count, 1, "Tab count should decrease by 1 after removal")
    }

    func test_should_not_contain_removed_tab() {
        // Arrange
        let tab1 = makeTab()
        let tab2 = makeTab()
        let group = makeGroup(tabs: [tab1, tab2], activeTabID: tab1.id)

        // Act
        group.removeTab(id: tab1.id)

        // Assert
        XCTAssertFalse(group.tabs.contains(where: { $0.id == tab1.id }),
                        "Removed tab should no longer be in the tabs array")
    }

    // ==================== 3. Remove Active Tab → Selects Next Sibling ====================

    func test_should_select_next_sibling_when_active_tab_removed() {
        // Arrange — three tabs: [A, B, C], active = B (middle)
        let tabA = makeTab(title: "A")
        let tabB = makeTab(title: "B")
        let tabC = makeTab(title: "C")
        let group = makeGroup(tabs: [tabA, tabB, tabC], activeTabID: tabB.id)

        // Act — remove B (index 1); next sibling is C (now at index 1)
        group.removeTab(id: tabB.id)

        // Assert
        XCTAssertEqual(group.activeTabID, tabC.id,
                       "Active tab should move to the next sibling (C) after removing the middle tab")
    }

    func test_should_select_next_sibling_when_first_active_tab_removed() {
        // Arrange — three tabs: [A, B, C], active = A (first)
        let tabA = makeTab(title: "A")
        let tabB = makeTab(title: "B")
        let tabC = makeTab(title: "C")
        let group = makeGroup(tabs: [tabA, tabB, tabC], activeTabID: tabA.id)

        // Act — remove A (index 0); next sibling is B (now at index 0)
        group.removeTab(id: tabA.id)

        // Assert
        XCTAssertEqual(group.activeTabID, tabB.id,
                       "Active tab should move to next sibling (B) after removing the first tab")
    }

    // ==================== 4. Remove Active Tab (Last) → Selects Previous ====================

    func test_should_select_previous_sibling_when_last_active_tab_removed() {
        // Arrange — three tabs: [A, B, C], active = C (last)
        let tabA = makeTab(title: "A")
        let tabB = makeTab(title: "B")
        let tabC = makeTab(title: "C")
        let group = makeGroup(tabs: [tabA, tabB, tabC], activeTabID: tabC.id)

        // Act — remove C (index 2, last position); should fall back to previous (B)
        group.removeTab(id: tabC.id)

        // Assert
        XCTAssertEqual(group.activeTabID, tabB.id,
                       "Active tab should fall back to the previous sibling (B) when the last tab is removed")
    }

    func test_should_select_previous_when_removing_last_of_two_tabs() {
        // Arrange — two tabs: [A, B], active = B (last)
        let tabA = makeTab(title: "A")
        let tabB = makeTab(title: "B")
        let group = makeGroup(tabs: [tabA, tabB], activeTabID: tabB.id)

        // Act
        group.removeTab(id: tabB.id)

        // Assert
        XCTAssertEqual(group.activeTabID, tabA.id,
                       "Active tab should move to the only remaining tab (A)")
    }

    // ==================== 5. Remove Only Tab → activeTabID Becomes Nil ====================

    func test_should_set_activeTabID_to_nil_when_only_tab_removed() {
        // Arrange — single tab
        let tab = makeTab()
        let group = makeGroup(tabs: [tab], activeTabID: tab.id)

        // Act
        group.removeTab(id: tab.id)

        // Assert
        XCTAssertNil(group.activeTabID,
                     "activeTabID should be nil after removing the only tab")
        XCTAssertTrue(group.tabs.isEmpty,
                      "Tabs array should be empty")
    }

    func test_should_return_nil_activeTab_when_only_tab_removed() {
        // Arrange
        let tab = makeTab()
        let group = makeGroup(tabs: [tab], activeTabID: tab.id)

        // Act
        group.removeTab(id: tab.id)

        // Assert
        XCTAssertNil(group.activeTab,
                     "activeTab computed property should return nil when no tabs remain")
    }

    // ==================== 6. TabGroup moveTab ====================

    func test_should_reorder_tabs_when_moveTab_called() {
        // Arrange — [A, B, C]
        let tabA = makeTab(title: "A")
        let tabB = makeTab(title: "B")
        let tabC = makeTab(title: "C")
        let group = makeGroup(tabs: [tabA, tabB, tabC], activeTabID: tabA.id)

        // Act — move A (index 0) to index 2 → [B, C, A] or [B, A, C] depending on impl
        group.moveTab(fromIndex: 0, toIndex: 2)

        // Assert — A should no longer be at index 0
        XCTAssertNotEqual(group.tabs[0].id, tabA.id,
                          "Tab A should have moved away from index 0")
        XCTAssertEqual(group.tabs.count, 3, "Tab count should remain unchanged after move")
    }

    func test_should_move_tab_forward_correctly() {
        // Arrange — [A, B, C]
        let tabA = makeTab(title: "A")
        let tabB = makeTab(title: "B")
        let tabC = makeTab(title: "C")
        let group = makeGroup(tabs: [tabA, tabB, tabC], activeTabID: tabA.id)

        // Act — move index 0 to index 1 → [B, A, C]
        group.moveTab(fromIndex: 0, toIndex: 1)

        // Assert
        XCTAssertEqual(group.tabs[0].id, tabB.id, "B should now be at index 0")
        XCTAssertEqual(group.tabs[1].id, tabA.id, "A should now be at index 1")
        XCTAssertEqual(group.tabs[2].id, tabC.id, "C should remain at index 2")
    }

    func test_should_move_tab_backward_correctly() {
        // Arrange — [A, B, C]
        let tabA = makeTab(title: "A")
        let tabB = makeTab(title: "B")
        let tabC = makeTab(title: "C")
        let group = makeGroup(tabs: [tabA, tabB, tabC], activeTabID: tabA.id)

        // Act — move index 2 to index 0 → [C, A, B]
        group.moveTab(fromIndex: 2, toIndex: 0)

        // Assert
        XCTAssertEqual(group.tabs[0].id, tabC.id, "C should now be at index 0")
        XCTAssertEqual(group.tabs[1].id, tabA.id, "A should now be at index 1")
        XCTAssertEqual(group.tabs[2].id, tabB.id, "B should now be at index 2")
    }

    func test_should_be_noop_when_moveTab_sameIndex() {
        // Arrange — [A, B]
        let tabA = makeTab(title: "A")
        let tabB = makeTab(title: "B")
        let group = makeGroup(tabs: [tabA, tabB], activeTabID: tabA.id)

        // Act — move index 1 to index 1 (no-op)
        group.moveTab(fromIndex: 1, toIndex: 1)

        // Assert
        XCTAssertEqual(group.tabs[0].id, tabA.id)
        XCTAssertEqual(group.tabs[1].id, tabB.id)
    }

    func test_should_be_noop_when_moveTab_outOfBounds() {
        // Arrange — [A, B]
        let tabA = makeTab(title: "A")
        let tabB = makeTab(title: "B")
        let group = makeGroup(tabs: [tabA, tabB], activeTabID: tabA.id)

        // Act — invalid fromIndex
        group.moveTab(fromIndex: 5, toIndex: 0)

        // Assert — no change
        XCTAssertEqual(group.tabs[0].id, tabA.id)
        XCTAssertEqual(group.tabs[1].id, tabB.id)
    }

    // ==================== 7. WindowSession activeGroup Resolves by ID ====================

    func test_should_resolve_activeGroup_by_id() {
        // Arrange
        let group1 = makeGroup(name: "Group 1")
        let group2 = makeGroup(name: "Group 2")
        let session = WindowSession(groups: [group1, group2], activeGroupID: group2.id)

        // Assert
        XCTAssertEqual(session.activeGroup?.id, group2.id,
                       "activeGroup should resolve to the group matching activeGroupID")
        XCTAssertEqual(session.activeGroup?.name, "Group 2")
    }

    func test_should_return_nil_activeGroup_when_id_does_not_match() {
        // Arrange
        let group = makeGroup(name: "Only")
        let session = WindowSession(groups: [group], activeGroupID: UUID())

        // Assert
        XCTAssertNil(session.activeGroup,
                     "activeGroup should be nil when activeGroupID does not match any group")
    }

    func test_should_return_nil_activeGroup_when_no_groups() {
        // Arrange
        let session = WindowSession()

        // Assert
        XCTAssertNil(session.activeGroup,
                     "activeGroup should be nil when there are no groups")
    }

    func test_should_set_activeGroupID_when_first_group_added() {
        // Arrange
        let session = WindowSession()
        let group = makeGroup()

        // Act
        session.addGroup(group)

        // Assert
        XCTAssertEqual(session.activeGroupID, group.id,
                       "activeGroupID should auto-set when first group is added")
    }

    // ==================== 8. WindowSession Remove Active Group → Selects Next ====================

    func test_should_select_next_group_when_active_group_removed() {
        // Arrange — [G1, G2, G3], active = G1
        let g1 = makeGroup(name: "G1")
        let g2 = makeGroup(name: "G2")
        let g3 = makeGroup(name: "G3")
        let session = WindowSession(groups: [g1, g2, g3], activeGroupID: g1.id)

        // Act — remove G1 (first); should select G2 (now at index 0)
        session.removeGroup(id: g1.id)

        // Assert
        XCTAssertEqual(session.activeGroupID, g2.id,
                       "Active group should move to the next group after removal")
        XCTAssertEqual(session.groups.count, 2)
    }

    func test_should_select_previous_group_when_last_active_group_removed() {
        // Arrange — [G1, G2], active = G2 (last)
        let g1 = makeGroup(name: "G1")
        let g2 = makeGroup(name: "G2")
        let session = WindowSession(groups: [g1, g2], activeGroupID: g2.id)

        // Act — remove G2 (last position)
        session.removeGroup(id: g2.id)

        // Assert
        XCTAssertEqual(session.activeGroupID, g1.id,
                       "Active group should fall back to previous when last group removed")
    }

    func test_should_set_activeGroupID_nil_when_only_group_removed() {
        // Arrange
        let g = makeGroup()
        let session = WindowSession(groups: [g], activeGroupID: g.id)

        // Act
        session.removeGroup(id: g.id)

        // Assert
        XCTAssertNil(session.activeGroupID,
                     "activeGroupID should be nil when the only group is removed")
        XCTAssertTrue(session.groups.isEmpty)
    }

    func test_should_not_change_activeGroupID_when_non_active_group_removed() {
        // Arrange — [G1, G2, G3], active = G2
        let g1 = makeGroup(name: "G1")
        let g2 = makeGroup(name: "G2")
        let g3 = makeGroup(name: "G3")
        let session = WindowSession(groups: [g1, g2, g3], activeGroupID: g2.id)

        // Act — remove G3 (not the active one)
        session.removeGroup(id: g3.id)

        // Assert
        XCTAssertEqual(session.activeGroupID, g2.id,
                       "activeGroupID should remain unchanged when a non-active group is removed")
        XCTAssertEqual(session.groups.count, 2)
    }

    // ==================== 9. Tab Title/PWD Update ====================

    func test_should_update_tab_title() {
        // Arrange
        let tab = makeTab(title: "Original")

        // Act
        tab.title = "Updated Title"

        // Assert
        XCTAssertEqual(tab.title, "Updated Title",
                       "Tab title should reflect the updated value")
    }

    func test_should_update_tab_pwd() {
        // Arrange
        let tab = makeTab()
        XCTAssertNil(tab.pwd, "pwd should be nil by default")

        // Act
        tab.pwd = "/Users/test/projects"

        // Assert
        XCTAssertEqual(tab.pwd, "/Users/test/projects",
                       "Tab pwd should reflect the updated value")
    }

    func test_should_allow_setting_pwd_to_nil() {
        // Arrange
        let tab = Tab(title: "Test", pwd: "/some/path")

        // Act
        tab.pwd = nil

        // Assert
        XCTAssertNil(tab.pwd, "Tab pwd should be nil after setting to nil")
    }

    func test_should_preserve_tab_identity_after_property_updates() {
        // Arrange
        let tab = makeTab(title: "Before")
        let originalID = tab.id

        // Act
        tab.title = "After"
        tab.pwd = "/new/path"

        // Assert
        XCTAssertEqual(tab.id, originalID,
                       "Tab ID must remain unchanged after property updates")
    }

    // ==================== 10. AppSession Add/Remove Windows ====================

    func test_should_add_window_to_appSession() {
        // Arrange
        let appSession = AppSession()
        let window = WindowSession()

        // Act
        appSession.addWindow(window)

        // Assert
        XCTAssertEqual(appSession.windows.count, 1,
                       "AppSession should have 1 window after adding")
        XCTAssertEqual(appSession.windows.first?.id, window.id,
                       "The added window should be accessible")
    }

    func test_should_add_multiple_windows() {
        // Arrange
        let appSession = AppSession()
        let win1 = WindowSession()
        let win2 = WindowSession()

        // Act
        appSession.addWindow(win1)
        appSession.addWindow(win2)

        // Assert
        XCTAssertEqual(appSession.windows.count, 2)
    }

    func test_should_remove_window_by_id() {
        // Arrange
        let win1 = WindowSession()
        let win2 = WindowSession()
        let appSession = AppSession(windows: [win1, win2])

        // Act
        appSession.removeWindow(id: win1.id)

        // Assert
        XCTAssertEqual(appSession.windows.count, 1,
                       "Window count should decrease after removal")
        XCTAssertFalse(appSession.windows.contains(where: { $0.id == win1.id }),
                        "Removed window should not be present")
        XCTAssertTrue(appSession.windows.contains(where: { $0.id == win2.id }),
                       "Other window should remain")
    }

    func test_should_handle_removing_nonexistent_window() {
        // Arrange
        let win = WindowSession()
        let appSession = AppSession(windows: [win])

        // Act — remove a UUID that doesn't match any window
        appSession.removeWindow(id: UUID())

        // Assert — nothing should change
        XCTAssertEqual(appSession.windows.count, 1,
                       "Removing a non-existent window ID should be a no-op")
    }

    func test_should_result_in_empty_windows_after_removing_all() {
        // Arrange
        let win = WindowSession()
        let appSession = AppSession(windows: [win])

        // Act
        appSession.removeWindow(id: win.id)

        // Assert
        XCTAssertTrue(appSession.windows.isEmpty,
                      "Windows array should be empty after removing all windows")
    }
}
