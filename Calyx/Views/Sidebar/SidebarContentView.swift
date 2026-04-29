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
    var onGroupRenamed: (() -> Void)?
    var onTabRenamed: (() -> Void)?
    var onCollapseToggled: (() -> Void)?
    var onCloseAllTabsInGroup: ((UUID) -> Void)?
    var onWorkingFileSelected: ((GitFileEntry) -> Void)?
    var onCommitFileSelected: ((CommitFileEntry) -> Void)?
    var onRefreshGitStatus: (() -> Void)?
    var onLoadMoreCommits: (() -> Void)?
    var onExpandCommit: ((String) -> Void)?
    var onMoveTab: ((UUID, Int, Int) -> Void)?

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        VStack(spacing: 0) {
            Picker("Mode", selection: $sidebarMode) {
                Text("Tabs").tag(SidebarMode.tabs)
                Text("Changes").tag(SidebarMode.changes)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .accessibilityIdentifier(AccessibilityID.Git.modeToggle)

            if sidebarMode == .tabs {
                ScrollView {
                    GlassEffectContainer(spacing: 8) {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(groups) { group in
                                GroupSectionView(
                                    group: group,
                                    isActiveGroup: group.id == activeGroupID,
                                    activeTabID: activeTabID,
                                    reduceTransparency: reduceTransparency,
                                    onGroupSelected: onGroupSelected,
                                    onTabSelected: onTabSelected,
                                    onCloseTab: onCloseTab,
                                    onGroupRenamed: onGroupRenamed,
                                    onTabRenamed: onTabRenamed,
                                    onCollapseToggled: onCollapseToggled,
                                    onCloseAllTabsInGroup: onCloseAllTabsInGroup,
                                    onMoveTab: onMoveTab
                                )
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                }
                .padding(.top, 10)

                Rectangle()
                    .fill(Color.white.opacity(reduceTransparency ? 0.14 : 0.10))
                    .frame(height: 1)
                    .padding(.horizontal, 8)

                Button(action: { onNewGroup?() }) {
                    Label("New Group", systemImage: "folder.badge.plus")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
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
                .padding(.top, 10)
            }
        }
        .frame(minWidth: SidebarLayout.minWidth)
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
            content
                .buttonStyle(.plain)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.black.opacity(0.2))
                )
        }
    }
}

private struct SidebarBackgroundModifier: ViewModifier {
    let reduceTransparency: Bool
    @AppStorage("terminalGlassOpacity") private var glassOpacity = 0.7
    @AppStorage("themeColorPreset") private var themePreset = "original"
    @AppStorage("themeColorCustomHex") private var customHex = "#050D1C"
    @State private var ghosttyProvider = GhosttyThemeProvider.shared

    private var themeColor: NSColor {
        ThemeColorPreset.resolve(
            preset: themePreset,
            customHex: customHex,
            ghosttyBackground: ghosttyProvider.ghosttyBackground
        )
    }

    private var chromeScheme: ColorScheme {
        let tint = GlassTheme.chromeTint(for: themeColor, glassOpacity: glassOpacity)
        return ColorLuminance.prefersDarkText(for: tint) ? .light : .dark
    }

    func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(Color(nsColor: .controlBackgroundColor).ignoresSafeArea(.all, edges: .top))
        } else {
            content
                .stableGlassTint(Color(nsColor: GlassTheme.chromeTint(for: themeColor, glassOpacity: glassOpacity)))
                .overlay(alignment: .trailing) {
                    Rectangle()
                        .fill(GlassTheme.specularStroke.opacity(0.30))
                        .frame(width: 1)
                }
                .environment(\.colorScheme, chromeScheme)
                .foregroundStyle(themePreset == "ghostty"
                    ? AnyShapeStyle(Color(nsColor: ghosttyProvider.ghosttyForeground))
                    : AnyShapeStyle(.primary))
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
    var onGroupRenamed: (() -> Void)?
    var onTabRenamed: (() -> Void)?
    var onCollapseToggled: (() -> Void)?
    var onCloseAllTabsInGroup: ((UUID) -> Void)?
    var onMoveTab: ((UUID, Int, Int) -> Void)?

    @State private var isEditing = false
    @State private var isHoveringHeader = false
    @State private var reorderState = TabReorderState()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Group header
            if isEditing {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color(nsColor: group.color.nsColor))
                        .frame(width: 8, height: 8)
                    InlineTextField(
                        initialText: group.name,
                        accessibilityID: AccessibilityID.Sidebar.groupNameTextField(group.id),
                        fontSize: 12,
                        fontWeight: .semibold,
                        onCommit: { text in
                            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !trimmed.isEmpty {
                                group.name = trimmed
                            }
                            isEditing = false
                            onGroupRenamed?()
                        },
                        onCancel: {
                            isEditing = false
                        }
                    )
                    Spacer()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
                .modifier(GroupHeaderBackgroundModifier(
                    isActiveGroup: isActiveGroup,
                    reduceTransparency: reduceTransparency,
                    groupColor: group.color
                ))
            } else {
                HStack(spacing: 0) {
                    // Left: group selection area
                    Button(action: { onGroupSelected?(group.id) }) {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(Color(nsColor: group.color.nsColor))
                                .frame(width: 8, height: 8)
                            Text(group.name)
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .tracking(0.4)
                                .lineLimit(1)
                            Spacer()
                            Text("\(group.tabs.count)")
                                .font(.system(size: 10, weight: .bold, design: .rounded))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 13)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    // Close all tabs button (shown on hover)
                    Button(action: { onCloseAllTabsInGroup?(group.id) }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .opacity(isHoveringHeader ? 1 : 0)
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .allowsHitTesting(isHoveringHeader)
                    .closeButtonHoverHighlight(size: 20, isVisible: isHoveringHeader, hoverOpacity: 0.08)
                    .accessibilityIdentifier(AccessibilityID.Sidebar.groupCloseAllButton(group.id))

                    // Right: collapse toggle button
                    Button(action: {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            group.isCollapsed.toggle()
                        }
                        onCollapseToggled?()
                    }) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(group.isCollapsed ? .zero : .degrees(90))
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier(AccessibilityID.Sidebar.groupCollapseButton(group.id))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .modifier(GroupHeaderBackgroundModifier(
                    isActiveGroup: isActiveGroup,
                    reduceTransparency: reduceTransparency,
                    groupColor: group.color
                ))
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier(AccessibilityID.Sidebar.group(group.id))
                .highPriorityGesture(TapGesture(count: 2).onEnded { isEditing = true })
                .onAssumeInsideHover($isHoveringHeader)
            }

            // Tabs in this group (only show if not collapsed)
            if !group.isCollapsed {
                VStack(spacing: 0) {
                    ForEach(Array(group.tabs.enumerated()), id: \.element.id) { index, tab in
                        TabRowItemView(
                            tab: tab,
                            isActive: tab.id == activeTabID && isActiveGroup,
                            onSelected: { onTabSelected?(tab.id) },
                            onClose: { onCloseTab?(tab.id) },
                            onTabRenamed: onTabRenamed
                        )
                        .background(
                            GeometryReader { geo in
                                Color.clear.preference(
                                    key: TabFramePreferenceKey.self,
                                    value: [tab.id: geo.frame(in: .named("sidebarGroup-\(group.id.uuidString)"))]
                                )
                            }
                        )
                        .offset(y: reorderState.draggedTabID == tab.id ? reorderState.dragOffset : 0)
                        .zIndex(reorderState.draggedTabID == tab.id ? 1 : 0)
                        .scaleEffect(reorderState.draggedTabID == tab.id ? 1.03 : 1.0)
                        .shadow(color: .black.opacity(reorderState.draggedTabID == tab.id ? 0.15 : 0), radius: 8)
                        .gesture(tabDragGesture(index: index, tab: tab))
                        .accessibilityValue(AccessibilityID.Sidebar.tabAtIndex(group.id, index))
                    }
                }
                .coordinateSpace(name: "sidebarGroup-\(group.id.uuidString)")
                .onPreferenceChange(TabFramePreferenceKey.self) { frames in
                    reorderState.tabFrames = frames
                }
                .overlay {
                    if let slot = reorderState.insertionSlot,
                       reorderState.draggedTabID != nil {
                        insertionIndicator(slot: slot)
                    }
                }
            }
        }
        .padding(.bottom, 4)
        .onChange(of: group.tabs.map(\.id)) { _, _ in
            reorderState.reset()
        }
    }

    // MARK: - Drag Gesture

    private func tabDragGesture(index: Int, tab: Tab) -> some Gesture {
        DragGesture(minimumDistance: 5)
            .onChanged { value in
                guard group.tabs.count > 1, onMoveTab != nil else { return }
                if reorderState.draggedTabID == nil {
                    reorderState.draggedTabID = tab.id
                    reorderState.draggedTabIndex = index
                }
                reorderState.dragOffset = value.translation.height
                if let frame = reorderState.tabFrames[tab.id] {
                    let midpoint = frame.midY + value.translation.height
                    reorderState.updateInsertionSlot(dragMidpoint: midpoint, axis: .vertical)
                }
            }
            .onEnded { _ in
                let moveFrom = reorderState.draggedTabIndex
                let moveTo = moveFrom.flatMap { reorderState.destinationIndex(fromIndex: $0, tabCount: group.tabs.count) }
                withAnimation(.easeOut(duration: 0.15)) {
                    reorderState.reset()
                }
                if let from = moveFrom, let to = moveTo {
                    onMoveTab?(group.id, from, to)
                }
            }
    }

    // MARK: - Insertion Indicator

    private func insertionIndicator(slot: Int) -> some View {
        GeometryReader { geo in
            let sortedFrames = reorderState.tabFrames.values.sorted { $0.minY < $1.minY }
            let yPos: CGFloat = {
                if slot == 0 {
                    return sortedFrames.first?.minY ?? 0
                } else if slot >= sortedFrames.count {
                    return sortedFrames.last?.maxY ?? geo.size.height
                } else {
                    let prev = sortedFrames[slot - 1]
                    let next = sortedFrames[slot]
                    return (prev.maxY + next.minY) / 2
                }
            }()
            RoundedRectangle(cornerRadius: 1)
                .fill(Color.accentColor.opacity(0.8))
                .frame(width: geo.size.width - 28, height: 2)
                .position(x: geo.size.width / 2, y: yPos)
        }
        .allowsHitTesting(false)
    }
}

private struct GroupHeaderBackgroundModifier: ViewModifier {
    let isActiveGroup: Bool
    let reduceTransparency: Bool
    let groupColor: TabGroupColor

    func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(
                            groupColor.color.opacity(isActiveGroup ? 0.18 : 0.08)
                        )
                )
        } else if isActiveGroup {
            content
                .stableGlassTint(groupColor.color.opacity(0.12), cornerRadius: 12)
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.white.opacity(0.22), lineWidth: 1)
                        .allowsHitTesting(false)
                }
        } else {
            content
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(groupColor.color.opacity(0.08))
                )
        }
    }
}

private struct TabRowItemView: View {
    let tab: Tab
    let isActive: Bool
    var onSelected: (() -> Void)?
    var onClose: (() -> Void)?
    var onTabRenamed: (() -> Void)?
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var isEditing = false
    @State private var isHovering = false

    private var tabIcon: String {
        switch tab.content {
        case .terminal: "terminal"
        case .browser: "globe"
        case .diff: "doc.text"
        }
    }

    private var visibleTitle: String {
        tab.titleOverride ?? tab.title
    }

    var body: some View {
        let displayText = visibleTitle.isEmpty ? fallbackTitle : visibleTitle

        HStack(spacing: 4) {
            Image(systemName: tabIcon)
                .font(.caption)
                .foregroundStyle(.secondary)
            if isEditing {
                InlineTextField(
                    initialText: displayText,
                    accessibilityID: AccessibilityID.Sidebar.tabNameTextField(tab.id),
                    fontSize: 12.5,
                    fontWeight: .semibold,
                    onCommit: { text in
                        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        tab.titleOverride = trimmed.isEmpty ? nil : trimmed
                        isEditing = false
                        onTabRenamed?()
                    },
                    onCancel: {
                        isEditing = false
                    }
                )
            } else {
                Text(displayText)
                    .lineLimit(1)
                    .font(.system(size: 12.5, weight: isActive ? .semibold : .medium, design: .rounded))
            }
            Spacer()
            if tab.unreadNotifications > 0 {
                Text(tab.unreadNotifications > 99 ? "99+" : "\(tab.unreadNotifications)")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(minWidth: 16, minHeight: 16)
                    .background(Circle().fill(Color.red))
            }
            Button(action: { onClose?() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(isActive ? .secondary : .tertiary)
                    .opacity(isHovering || isActive ? 1 : 0)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .closeButtonHoverHighlight(size: 16, isVisible: (isHovering || isActive) && !isEditing)
            .allowsHitTesting((isHovering || isActive) && !isEditing)
            .accessibilityIdentifier(AccessibilityID.Sidebar.tabCloseButton(tab.id))
        }
        .contentShape(Rectangle())
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .modifier(TabChromeModifier(
            isActive: isActive,
            cornerRadius: 12,
            reduceTransparency: reduceTransparency
        ))
        .onTapGesture { if !isEditing { onSelected?() } }
        .highPriorityGesture(TapGesture(count: 2).onEnded { if !isEditing { isEditing = true } })
        .onAssumeInsideHover($isHovering)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.Sidebar.tab(tab.id))
    }

    private var fallbackTitle: String {
        if case .browser(let url) = tab.content {
            return url.host() ?? url.absoluteString
        }
        return "Terminal"
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
