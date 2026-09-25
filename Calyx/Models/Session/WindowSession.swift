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
    var showComposeOverlay: Bool = false
    /// Mission Map (the all-panes overview). Transient like the two
    /// overlays above: never serialized, always starts hidden.
    var showMissionMap: Bool = false
    var composeOverlayHeight: CGFloat = 120
    var composeOverlayText: String = ""
    var sidebarMode: SidebarMode = .tabs
    /// Phase of the Changes sidebar as a whole: `.notLoaded` before the
    /// first discovery, `.loading` during it, `.loaded` once sections are
    /// on screen, `.notRepository` when no seed directory is inside a
    /// repository, and `.error` when discovery itself could not run.
    /// Per-section state lives in `gitRepoChanges`.
    var gitChangesState: GitChangesState = .notLoaded
    /// Commit file lists keyed by full SHA. Global rather than per-repo
    /// because a commit's file list is identical from every worktree that
    /// can see it.
    var commitFiles: [String: [CommitFileEntry]] = [:]
    var isGitRefreshing: Bool = false
    /// Set when repository discovery itself fails while sections are still
    /// on screen. Per-section failures use `GitRepoChanges.staleRefreshMessage`.
    var gitStaleRefreshMessage: String?
    var gitRepoSections: [GitRepoDescriptor] = []
    var gitRepoChanges: [String: GitRepoChanges] = [:]
    var gitActiveRepoID: String?
    var gitExpandedRepoIDs: Set<String> = []
    /// Per-section ref-picker choice, keyed by repo ID. Missing a key means
    /// `.auto`, mirroring `GitRefFilterSettings.selection(forRepo:)`'s own
    /// default.
    var gitRefSelections: [String: GitRefSelection] = [:]
    var sidebarWidth: CGFloat = SidebarLayout.defaultWidth

    static let minSidebarWidth: CGFloat = SidebarLayout.minWidth
    static let maxSidebarWidth: CGFloat = SidebarLayout.maxWidth
    static let composeMinHeight: CGFloat = 60
    static let composeMaxHeight: CGFloat = 400

    var activeGroup: TabGroup? {
        groups.first { $0.id == activeGroupID }
    }

    init(
        id: UUID = UUID(),
        groups: [TabGroup] = [],
        activeGroupID: UUID? = nil,
        showSidebar: Bool = true,
        showCommandPalette: Bool = false,
        showComposeOverlay: Bool = false,
        sidebarWidth: CGFloat = SidebarLayout.defaultWidth
    ) {
        self.id = id
        self.groups = groups
        self.activeGroupID = activeGroupID
        self.showSidebar = showSidebar
        self.showCommandPalette = showCommandPalette
        self.showComposeOverlay = showComposeOverlay
        self.sidebarWidth = sidebarWidth
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

    /// Computes the next default group name based on existing names.
    ///
    /// Extracts names strictly matching the pattern `"Group N"` (literal
    /// `"Group "` prefix followed by an integer) and returns `"Group (max + 1)"`.
    /// If no existing name matches, returns `"Group 1"`. Gaps are never filled.
    ///
    /// Loose matches such as `"Groupie 1"` (different prefix) or `"Group "`
    /// (prefix present but no integer suffix) are ignored.
    static func nextDefaultGroupName(existing: [String]) -> String {
        let prefix = "Group "
        let numbers: [Int] = existing.compactMap { name in
            guard name.hasPrefix(prefix) else { return nil }
            return Int(String(name.dropFirst(prefix.count)))
        }
        let next = (numbers.max() ?? 0) + 1
        return "Group \(next)"
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

        // Group is now empty — remove it under removeGroup's rule: the
        // active group moves to the neighbour only if the emptied group
        // was active.
        return removeGroup(id: groupID)
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

    // MARK: - Git Sections

    /// The Changes state of the section identified by `repoID`.
    /// `applyGitSections` keeps one entry per displayed section, so every
    /// section in `gitRepoSections` finds its own.
    func gitChanges(for repoID: String) -> GitRepoChanges {
        gitRepoChanges[repoID] ?? GitRepoChanges()
    }

    /// Installs `sections` as the displayed order. Repo IDs that survive
    /// keep their loaded data and expansion state, IDs that appear start at
    /// `.notLoaded`, and every trace of an ID that vanished is dropped,
    /// including the active selection when it pointed at that ID.
    func applyGitSections(_ sections: [GitRepoDescriptor]) {
        let liveIDs = Set(sections.map(\.id))

        var changes: [String: GitRepoChanges] = [:]
        changes.reserveCapacity(sections.count)
        for section in sections {
            changes[section.id] = gitRepoChanges[section.id] ?? GitRepoChanges()
        }

        gitRepoSections = sections
        gitRepoChanges = changes
        gitExpandedRepoIDs.formIntersection(liveIDs)
        gitRefSelections = gitRefSelections.filter { liveIDs.contains($0.key) }
        if let activeID = gitActiveRepoID, !liveIDs.contains(activeID) {
            gitActiveRepoID = nil
        }
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
