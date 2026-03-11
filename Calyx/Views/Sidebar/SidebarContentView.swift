// SidebarContentView.swift
// Calyx
//
// SwiftUI sidebar showing tab groups and their tabs.

import SwiftUI

struct SidebarContentView: View {
    let groups: [TabGroup]
    let activeGroupID: UUID?
    let activeTabID: UUID?
    @Binding var sidebarMode: SidebarMode
    var gitChangesState: GitChangesState = .notLoaded
    var gitEntries: [GitFileEntry] = []
    var gitCommits: [GitCommit] = []
    var expandedCommitIDs: Set<String> = []
    var commitFiles: [String: [CommitFileEntry]] = [:]
    var onGroupSelected: ((UUID) -> Void)?
    var onTabSelected: ((UUID) -> Void)?
    var onNewGroup: (() -> Void)?
    var onCloseTab: ((UUID) -> Void)?
    var onWorkingFileSelected: ((GitFileEntry) -> Void)?
    var onCommitFileSelected: ((CommitFileEntry) -> Void)?
    var onRefreshGitStatus: (() -> Void)?
    var onLoadMoreCommits: (() -> Void)?
    var onExpandCommit: ((String) -> Void)?

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        VStack(spacing: 0) {
            Picker("Mode", selection: $sidebarMode) {
                Text("Tabs").tag(SidebarMode.tabs)
                Text("Changes").tag(SidebarMode.changes)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .accessibilityIdentifier(AccessibilityID.Git.modeToggle)

            if sidebarMode == .tabs {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(groups) { group in
                            GroupSectionView(
                                group: group,
                                isActiveGroup: group.id == activeGroupID,
                                activeTabID: activeTabID,
                                reduceTransparency: reduceTransparency,
                                onGroupSelected: onGroupSelected,
                                onTabSelected: onTabSelected,
                                onCloseTab: onCloseTab
                            )
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                }

                Rectangle()
                    .fill(Color.white.opacity(reduceTransparency ? 0.14 : 0.10))
                    .frame(height: 1)
                    .padding(.horizontal, 8)

                Button(action: { onNewGroup?() }) {
                    Label("New Group", systemImage: "folder.badge.plus")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .modifier(GlassButtonModifier(reduceTransparency: reduceTransparency))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .accessibilityIdentifier(AccessibilityID.Sidebar.newGroupButton)
            } else {
                GitChangesView(
                    gitChangesState: gitChangesState,
                    gitEntries: gitEntries,
                    gitCommits: gitCommits,
                    expandedCommitIDs: expandedCommitIDs,
                    commitFiles: commitFiles,
                    onWorkingFileSelected: onWorkingFileSelected,
                    onCommitFileSelected: onCommitFileSelected,
                    onRefresh: onRefreshGitStatus,
                    onLoadMore: onLoadMoreCommits,
                    onExpandCommit: onExpandCommit
                )
            }
        }
        .frame(minWidth: 180)
        .modifier(SidebarBackgroundModifier(reduceTransparency: reduceTransparency))
        .accessibilityIdentifier(AccessibilityID.Sidebar.container)
    }
}

private struct GlassButtonModifier: ViewModifier {
    let reduceTransparency: Bool

    func body(content: Content) -> some View {
        if reduceTransparency {
            content.buttonStyle(.plain)
        } else {
            content.buttonStyle(.glass)
        }
    }
}

private struct SidebarBackgroundModifier: ViewModifier {
    let reduceTransparency: Bool

    func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(Color(nsColor: .controlBackgroundColor))
        } else {
            content.glassEffect(.clear.tint(.black.opacity(0.25)), in: .rect)
        }
    }
}

private struct GroupSectionView: View {
    let group: TabGroup
    let isActiveGroup: Bool
    let activeTabID: UUID?
    let reduceTransparency: Bool
    var onGroupSelected: ((UUID) -> Void)?
    var onTabSelected: ((UUID) -> Void)?
    var onCloseTab: ((UUID) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            // Group header
            Button(action: { onGroupSelected?(group.id) }) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color(nsColor: group.color.nsColor))
                        .frame(width: 8, height: 8)
                    Text(group.name)
                        .font(.headline)
                        .lineLimit(1)
                    Spacer()
                    Text("\(group.tabs.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
                .modifier(GroupHeaderBackgroundModifier(
                    isActiveGroup: isActiveGroup,
                    reduceTransparency: reduceTransparency,
                    groupColor: group.color
                ))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(AccessibilityID.Sidebar.group(group.id))

            // Tabs in this group (only show if not collapsed)
            if !group.isCollapsed {
                ForEach(group.tabs) { tab in
                    TabRowItemView(
                        tab: tab,
                        isActive: tab.id == activeTabID && isActiveGroup,
                        onSelected: { onTabSelected?(tab.id) },
                        onClose: { onCloseTab?(tab.id) }
                    )
                }
            }
        }
        .padding(.bottom, 4)
    }
}

private struct GroupHeaderBackgroundModifier: ViewModifier {
    let isActiveGroup: Bool
    let reduceTransparency: Bool
    let groupColor: TabGroupColor

    func body(content: Content) -> some View {
        if isActiveGroup {
            if reduceTransparency {
                content.background(
                    RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.15))
                )
            } else {
                content.background(
                    RoundedRectangle(cornerRadius: 6).fill(groupColor.color.opacity(0.2))
                )
            }
        } else {
            content
        }
    }
}

private struct TabRowItemView: View {
    let tab: Tab
    let isActive: Bool
    var onSelected: (() -> Void)?
    var onClose: (() -> Void)?

    private var tabIcon: String {
        switch tab.content {
        case .terminal: "terminal"
        case .browser: "globe"
        case .diff: "doc.text"
        }
    }

    var body: some View {
        Button(action: { onSelected?() }) {
            HStack(spacing: 4) {
                Image(systemName: tabIcon)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(tab.title)
                    .lineLimit(1)
                    .font(.body)
                Spacer()
                if tab.unreadNotifications > 0 {
                    Text(tab.unreadNotifications > 99 ? "99+" : "\(tab.unreadNotifications)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(minWidth: 16, minHeight: 16)
                        .background(Circle().fill(Color.red))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(
                isActive
                    ? RoundedRectangle(cornerRadius: 4).fill(Color.accentColor.opacity(0.1))
                    : nil
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(AccessibilityID.Sidebar.tab(tab.id))
    }
}

extension TabContent {
    var isTerminal: Bool {
        if case .terminal = self { return true }
        return false
    }

    var isDiff: Bool {
        if case .diff = self { return true }
        return false
    }
}
