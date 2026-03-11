// WindowSession.swift
// Calyx
//
// Represents a single window's state with tab groups.

import Foundation

enum TabRemoveResult {
    case switchedTab(groupID: UUID, tabID: UUID)
    case switchedGroup(groupID: UUID, tabID: UUID)
    case windowShouldClose
}

@MainActor @Observable
class WindowSession: Identifiable {
    let id: UUID
    var groups: [TabGroup]
    var activeGroupID: UUID?
    var showSidebar: Bool
    var showCommandPalette: Bool = false
    var sidebarMode: SidebarMode = .tabs
    var gitChangesState: GitChangesState = .notLoaded
    var gitEntries: [GitFileEntry] = []
    var gitCommits: [GitCommit] = []
    var expandedCommitIDs: Set<String> = []
    var commitFiles: [String: [CommitFileEntry]] = [:]
    var repoRoots: [String: String] = [:]

    var activeGroup: TabGroup? {
        groups.first { $0.id == activeGroupID }
    }

    init(
        id: UUID = UUID(),
        groups: [TabGroup] = [],
        activeGroupID: UUID? = nil,
        showSidebar: Bool = true,
        showCommandPalette: Bool = false
    ) {
        self.id = id
        self.groups = groups
        self.activeGroupID = activeGroupID
        self.showSidebar = showSidebar
        self.showCommandPalette = showCommandPalette
    }

    convenience init(initialTab: Tab) {
        let group = TabGroup(name: "Group 1", tabs: [initialTab], activeTabID: initialTab.id)
        self.init(groups: [group], activeGroupID: group.id)
    }

    func addGroup(_ group: TabGroup) {
        groups.append(group)
        if activeGroupID == nil {
            activeGroupID = group.id
        }
    }

    @discardableResult
    func removeTab(id tabID: UUID, fromGroup groupID: UUID) -> TabRemoveResult {
        guard let groupIndex = groups.firstIndex(where: { $0.id == groupID }) else {
            return .windowShouldClose
        }

        let group = groups[groupIndex]
        group.removeTab(id: tabID)

        if let newActiveTab = group.activeTab {
            return .switchedTab(groupID: groupID, tabID: newActiveTab.id)
        }

        // Group is now empty — remove it
        groups.remove(at: groupIndex)

        if groups.isEmpty {
            activeGroupID = nil
            return .windowShouldClose
        }

        // Select next or previous group
        let newGroupIndex = groupIndex < groups.count ? groupIndex : groups.count - 1
        let newGroup = groups[newGroupIndex]
        activeGroupID = newGroup.id

        if let tab = newGroup.activeTab {
            return .switchedGroup(groupID: newGroup.id, tabID: tab.id)
        }

        return .windowShouldClose
    }

    @discardableResult
    func removeGroup(id: UUID) -> TabRemoveResult {
        guard let index = groups.firstIndex(where: { $0.id == id }) else {
            return .windowShouldClose
        }

        groups.remove(at: index)

        if groups.isEmpty {
            activeGroupID = nil
            return .windowShouldClose
        }

        if activeGroupID == id {
            let newIndex = index < groups.count ? index : groups.count - 1
            let newGroup = groups[newIndex]
            activeGroupID = newGroup.id

            if let tab = newGroup.activeTab {
                return .switchedGroup(groupID: newGroup.id, tabID: tab.id)
            }
            return .windowShouldClose
        }

        // Removed a non-active group — return current state
        if let ag = activeGroup, let tab = ag.activeTab {
            return .switchedGroup(groupID: ag.id, tabID: tab.id)
        }
        return .windowShouldClose
    }

    // MARK: - Tab Navigation

    func nextTab() {
        guard let group = activeGroup,
              let currentID = group.activeTabID,
              let currentIndex = group.tabs.firstIndex(where: { $0.id == currentID }),
              group.tabs.count > 1 else { return }

        let nextIndex = (currentIndex + 1) % group.tabs.count
        group.activeTabID = group.tabs[nextIndex].id
    }

    func previousTab() {
        guard let group = activeGroup,
              let currentID = group.activeTabID,
              let currentIndex = group.tabs.firstIndex(where: { $0.id == currentID }),
              group.tabs.count > 1 else { return }

        let prevIndex = (currentIndex - 1 + group.tabs.count) % group.tabs.count
        group.activeTabID = group.tabs[prevIndex].id
    }

    func selectTab(at index: Int) {
        guard let group = activeGroup,
              index >= 0, index < group.tabs.count else { return }
        group.activeTabID = group.tabs[index].id
    }

    // MARK: - Group Navigation

    func nextGroup() {
        guard let currentID = activeGroupID,
              let currentIndex = groups.firstIndex(where: { $0.id == currentID }),
              groups.count > 1 else { return }

        let nextIndex = (currentIndex + 1) % groups.count
        activeGroupID = groups[nextIndex].id
    }

    func previousGroup() {
        guard let currentID = activeGroupID,
              let currentIndex = groups.firstIndex(where: { $0.id == currentID }),
              groups.count > 1 else { return }

        let prevIndex = (currentIndex - 1 + groups.count) % groups.count
        activeGroupID = groups[prevIndex].id
    }
}
