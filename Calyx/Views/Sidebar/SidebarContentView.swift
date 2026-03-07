// SidebarContentView.swift
// Calyx
//
// SwiftUI sidebar showing tab groups and their tabs.

import SwiftUI

struct SidebarContentView: View {
    let groups: [TabGroup]
    let activeGroupID: UUID?
    let activeTabID: UUID?
    var onGroupSelected: ((UUID) -> Void)?
    var onTabSelected: ((UUID) -> Void)?
    var onNewGroup: (() -> Void)?
    var onCloseTab: ((UUID) -> Void)?

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        VStack(spacing: 0) {
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

            Divider()

            Button(action: { onNewGroup?() }) {
                Label("New Group", systemImage: "folder.badge.plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .modifier(GlassButtonModifier(reduceTransparency: reduceTransparency))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(minWidth: 180)
        .modifier(SidebarBackgroundModifier(reduceTransparency: reduceTransparency))
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
            content.glassEffect(.clear.tint(.white.opacity(0.8)), in: .rect)
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
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .modifier(GroupHeaderBackgroundModifier(
                    isActiveGroup: isActiveGroup,
                    reduceTransparency: reduceTransparency,
                    groupColor: group.color
                ))
            }
            .buttonStyle(.plain)

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
                content.glassEffect(.regular.tint(groupColor.color))
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

    var body: some View {
        Button(action: { onSelected?() }) {
            HStack(spacing: 4) {
                Image(systemName: tab.content.isTerminal ? "terminal" : "globe")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(tab.title)
                    .lineLimit(1)
                    .font(.body)
                Spacer()
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
    }
}

extension TabContent {
    var isTerminal: Bool {
        if case .terminal = self { return true }
        return false
    }
}
