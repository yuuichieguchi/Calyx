// SidebarContentView.swift
// Calyx
//
// SwiftUI sidebar showing tab groups and their tabs.

import SwiftUI
import AppKit

struct SidebarContentView: View {
    let groups: [TabGroup]
    let activeGroupID: UUID?
    let activeTabID: UUID?
    @Binding var sidebarMode: SidebarMode
    var gitSidebarState = GitSidebarViewState()
    var onGroupSelected: ((UUID) -> Void)?
    var onTabSelected: ((UUID) -> Void)?
    var onNewGroup: (() -> Void)?
    var onCloseTab: ((UUID) -> Void)?
    var onCloseOtherTabs: ((UUID) -> Void)?
    var onCloseTabsToTheRight: ((UUID) -> Void)?
    var onGroupRenamed: (() -> Void)?
    var onTabRenamed: (() -> Void)?
    var onCollapseToggled: (() -> Void)?
    var onCloseAllTabsInGroup: ((UUID) -> Void)?
    var onCloseOtherGroups: ((UUID) -> Void)?
    var onCloseGroupsBelow: ((UUID) -> Void)?
    var onGroupColorChanged: (() -> Void)?
    var onWorkingFileSelected: ((String, GitFileEntry) -> Void)?
    var onCommitFileSelected: ((String, CommitFileEntry) -> Void)?
    var onRefreshGitStatus: (() -> Void)?
    var onLoadMoreCommits: ((String) -> Void)?
    var onExpandCommit: ((String, String) -> Void)?
    var onToggleGitRepoSection: ((String) -> Void)?
    var onRetryGitRepoSection: ((String) -> Void)?
    var onSelectRefFilter: ((String, GitRefSelection) -> Void)?
    var onMoveTab: ((UUID, Int, Int) -> Void)?
    var paneTitle: (UUID) -> String?
    var paneCwd: (UUID) -> String?

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.controlActiveState) private var controlActiveState
    @Namespace private var togglePillNS

    @ViewBuilder
    private var togglePill: some View {
        if reduceTransparency {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.gray.opacity(0.18))
        } else {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.08))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
                }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        sidebarMode = .tabs
                    }
                } label: {
                    Text("Tabs")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background {
                            if sidebarMode == .tabs {
                                Color.clear
                                    .overlay { togglePill }
                                    .matchedGeometryEffect(id: "togglePill", in: togglePillNS)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Tabs")
                .accessibilityAddTraits(sidebarMode == .tabs ? [.isSelected] : [])

                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        sidebarMode = .changes
                    }
                } label: {
                    Text("Changes")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background {
                            if sidebarMode == .changes {
                                Color.clear
                                    .overlay { togglePill }
                                    .matchedGeometryEffect(id: "togglePill", in: togglePillNS)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Changes")
                .accessibilityAddTraits(sidebarMode == .changes ? [.isSelected] : [])

                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        sidebarMode = .agents
                    }
                } label: {
                    Text("Agents")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background {
                            if sidebarMode == .agents {
                                Color.clear
                                    .overlay { togglePill }
                                    .matchedGeometryEffect(id: "togglePill", in: togglePillNS)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Agents")
                .accessibilityAddTraits(sidebarMode == .agents ? [.isSelected] : [])
                .accessibilityIdentifier(AccessibilityID.Sidebar.agentModeButton)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .opacity(controlActiveState == .key ? 1.0 : 0.5)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Sidebar mode")
            .accessibilityValue({
                switch sidebarMode {
                case .tabs: return "Tabs"
                case .changes: return "Changes"
                case .agents: return "Agents"
                }
            }())
            .accessibilityIdentifier(AccessibilityID.Git.modeToggle)

            switch sidebarMode {
            case .tabs:
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(groups.enumerated()), id: \.element.id) { groupIndex, group in
                            GroupSectionView(
                                group: group,
                                isActiveGroup: group.id == activeGroupID,
                                activeTabID: activeTabID,
                                reduceTransparency: reduceTransparency,
                                groupIndex: groupIndex,
                                groupCount: groups.count,
                                onGroupSelected: onGroupSelected,
                                onTabSelected: onTabSelected,
                                onCloseTab: onCloseTab,
                                onCloseOtherTabs: onCloseOtherTabs,
                                onCloseTabsToTheRight: onCloseTabsToTheRight,
                                onGroupRenamed: onGroupRenamed,
                                onTabRenamed: onTabRenamed,
                                onCollapseToggled: onCollapseToggled,
                                onCloseAllTabsInGroup: onCloseAllTabsInGroup,
                                onCloseOtherGroups: onCloseOtherGroups,
                                onCloseGroupsBelow: onCloseGroupsBelow,
                                onGroupColorChanged: onGroupColorChanged,
                                onMoveTab: onMoveTab
                            )
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

            case .changes:
                GitChangesView(
                    state: gitSidebarState,
                    onWorkingFileSelected: onWorkingFileSelected,
                    onCommitFileSelected: onCommitFileSelected,
                    onRefresh: onRefreshGitStatus,
                    onLoadMore: onLoadMoreCommits,
                    onExpandCommit: onExpandCommit,
                    onToggleRepoSection: onToggleGitRepoSection,
                    onRetryRepoSection: onRetryGitRepoSection,
                    onSelectRefFilter: onSelectRefFilter
                )
                .padding(.top, 10)

            case .agents:
                AgentStatusView(paneTitle: paneTitle, paneCwd: paneCwd)
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
    @Environment(\.controlActiveState) private var controlActiveState

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
                .opacity(controlActiveState == .key ? 1.0 : 0.5)
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
    let groupIndex: Int
    let groupCount: Int
    var onGroupSelected: ((UUID) -> Void)?
    var onTabSelected: ((UUID) -> Void)?
    var onCloseTab: ((UUID) -> Void)?
    var onCloseOtherTabs: ((UUID) -> Void)?
    var onCloseTabsToTheRight: ((UUID) -> Void)?
    var onGroupRenamed: (() -> Void)?
    var onTabRenamed: (() -> Void)?
    var onCollapseToggled: (() -> Void)?
    var onCloseAllTabsInGroup: ((UUID) -> Void)?
    var onCloseOtherGroups: ((UUID) -> Void)?
    var onCloseGroupsBelow: ((UUID) -> Void)?
    var onGroupColorChanged: (() -> Void)?
    var onMoveTab: ((UUID, Int, Int) -> Void)?

    @State private var isEditing = false
    @State private var isHoveringHeader = false
    @State private var reorderState = TabReorderState()

    private func toggleCollapse() {
        withAnimation(.easeInOut(duration: 0.15)) {
            group.isCollapsed.toggle()
        }
        onCollapseToggled?()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Group header. One `TabClickContainer` hosts both the editing
            // and non-editing content (mirroring `TabRowItemView` below),
            // so the header's context menu, accessibility identity and
            // hover tracking stay live while renaming, not just while
            // idle. A right-click outside the live editor is committed
            // first through `InlineTextField`'s own click monitor
            // (installed 0.3s after the editor opens), and the group menu
            // then opens on the already-committed header. In the brief
            // window before that monitor exists, the menu opens over the
            // live editor instead: Rename is then a no-op (`isEditing` is
            // already true), matching the tab-row precedent in
            // `TabClickRecognizer.swift`'s header comment.
            //
            // Both trailing glyphs (close-all, collapse chevron) are
            // visual-only images, hit-tested by this `TabClickContainer`
            // in AppKit via `trailingActions`, not by SwiftUI Buttons: a
            // plain click on the chevron toggles collapse, a plain click
            // on the close-all glyph (while hovering) closes the group,
            // and a Ctrl+click or right-click on either opens the group
            // menu instead of running the glyph's action. Each glyph also
            // carries an accessibility action that mirrors its trailing
            // rect's action, so VoiceOver can activate it directly.
            TabClickContainer(
                isEnabled: !isEditing,
                onSingleClick: { onGroupSelected?(group.id) },
                onDoubleClick: { isEditing = true },
                trailingActions: isEditing ? [] : [
                    TrailingAction(insetFromTrailing: 34, size: 20, isEnabled: isHoveringHeader) {
                        onCloseAllTabsInGroup?(group.id)
                    },
                    TrailingAction(insetFromTrailing: 14, size: 20, isEnabled: true) {
                        toggleCollapse()
                    },
                ],
                contextMenu: {
                    GroupContextMenu.make(
                        groupIndex: groupIndex,
                        groupCount: groupCount,
                        currentColor: group.color,
                        actions: .init(
                            close: { onCloseAllTabsInGroup?(group.id) },
                            closeOthers: { onCloseOtherGroups?(group.id) },
                            closeBelow: { onCloseGroupsBelow?(group.id) },
                            rename: { isEditing = true },
                            setColor: { color in
                                guard group.color != color else { return }
                                group.color = color
                                onGroupColorChanged?()
                            }
                        )
                    )
                }
            ) {
                HStack(spacing: 0) {
                    // Left: group name area (visual content only; click
                    // handled by surrounding TabClickContainer)
                    HStack(spacing: 6) {
                        Circle()
                            .fill(subduedDotColor(group.color.nsColor))
                            .frame(width: 6, height: 6)
                            .opacity(isActiveGroup ? 1.0 : 0.5)
                        if isEditing {
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
                        } else {
                            Text(group.name)
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .tracking(0.4)
                                .lineLimit(1)
                            Spacer()
                            Text("\(group.tabs.count)")
                                .font(.system(size: 10, weight: .bold, design: .rounded))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())

                    if !isEditing {
                        // Visual-only close-all icon (shown on hover). No
                        // `Button`, no `.onTapGesture`. Hit detection is
                        // done in `ClickContainerNSView.mouseDown` against
                        // the same 20x20 rect inset 34pt from the trailing
                        // edge.
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .opacity(isHoveringHeader ? 1 : 0)
                            .frame(width: 20, height: 20)
                            .closeButtonHoverHighlight(size: 20, isVisible: isHoveringHeader, hoverOpacity: 0.08)
                            .allowsHitTesting(false)
                            .accessibilityIdentifier(AccessibilityID.Sidebar.groupCloseAllButton(group.id))
                            .accessibilityLabel("Close Group")
                            .accessibilityAddTraits(.isButton)
                            .accessibilityAction { onCloseAllTabsInGroup?(group.id) }

                        // Visual-only collapse chevron. Hit detection is
                        // done in `ClickContainerNSView.mouseDown` against
                        // the same 20x20 rect inset 14pt from the trailing
                        // edge.
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(group.isCollapsed ? .zero : .degrees(90))
                            .frame(width: 20, height: 20)
                            .allowsHitTesting(false)
                            .accessibilityIdentifier(AccessibilityID.Sidebar.groupCollapseButton(group.id))
                            .accessibilityLabel(group.isCollapsed ? "Expand Group" : "Collapse Group")
                            .accessibilityAddTraits(.isButton)
                            .accessibilityAction { toggleCollapse() }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .modifier(GroupHeaderBackgroundModifier(
                    isActiveGroup: isActiveGroup,
                    reduceTransparency: reduceTransparency
                ))
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(AccessibilityID.Sidebar.group(group.id))
            // The group-name `Text` lives inside the header's
            // `TabClickContainer` `NSHostingView` and is otherwise
            // invisible to XCUITest / assistive tech (the `.contain`
            // container does not surface hosted children). Carry the
            // name explicitly so the group announces itself and
            // name-based lookups (e.g. after a rename) resolve it.
            .accessibilityLabel(group.name)
            .onAssumeInsideHover($isHoveringHeader)

            // Tabs in this group (only show if not collapsed)
            if !group.isCollapsed {
                VStack(spacing: 0) {
                    ForEach(Array(group.tabs.enumerated()), id: \.element.id) { index, tab in
                        TabRowItemView(
                            tab: tab,
                            isActive: tab.id == activeTabID && isActiveGroup,
                            tabIndex: index,
                            tabCount: group.tabs.count,
                            onSelected: { onTabSelected?(tab.id) },
                            onClose: { onCloseTab?(tab.id) },
                            onCloseOtherTabs: { onCloseOtherTabs?(tab.id) },
                            onCloseTabsToTheRight: { onCloseTabsToTheRight?(tab.id) },
                            onTabRenamed: onTabRenamed,
                            onDragChanged: { translation in
                                // Tab reorder: equivalent to the former
                                // SwiftUI `DragGesture.onChanged`, but
                                // driven by `ClickContainerNSView` so no
                                // `PlatformGroupContainer` compositing
                                // layer is created on top of the row.
                                guard group.tabs.count > 1, onMoveTab != nil else { return }
                                if reorderState.draggedTabID == nil {
                                    reorderState.draggedTabID = tab.id
                                    reorderState.draggedTabIndex = index
                                }
                                reorderState.dragOffset = translation.height
                                if let frame = reorderState.tabFrames[tab.id] {
                                    let midpoint = frame.midY + translation.height
                                    reorderState.updateInsertionSlot(dragMidpoint: midpoint, axis: .vertical)
                                }
                            },
                            onDragEnded: {
                                let moveFrom = reorderState.draggedTabIndex
                                let moveTo = moveFrom.flatMap { reorderState.destinationIndex(fromIndex: $0, tabCount: group.tabs.count) }
                                withAnimation(.easeOut(duration: 0.15)) {
                                    reorderState.reset()
                                }
                                if let from = moveFrom, let to = moveTo {
                                    onMoveTab?(group.id, from, to)
                                }
                            }
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
                        // NOTE: `.gesture(tabDragGesture(...))` was removed
                        // here. Drag tracking now happens inside
                        // `ClickContainerNSView` via `mouseDragged` /
                        // `mouseUp` to avoid a `PlatformGroupContainer`
                        // compositing layer that would intercept clicks.
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

    private func subduedDotColor(_ nsColor: NSColor) -> Color {
        let converted = nsColor.usingColorSpace(.sRGB) ?? nsColor
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        converted.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return Color(hue: Double(h), saturation: Double(s * 0.7), brightness: Double(b * 0.9), opacity: Double(a))
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
    @Environment(\.controlActiveState) private var controlActiveState

    func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.gray.opacity(isActiveGroup ? 0.18 : 0.05))
            )
        } else if isActiveGroup {
            content
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
                        .allowsHitTesting(false)
                }
                .opacity(controlActiveState == .key ? 1.0 : 0.5)
        } else {
            content
                .opacity(controlActiveState == .key ? 1.0 : 0.5)
        }
    }
}

private struct TabRowItemView: View {
    let tab: Tab
    let isActive: Bool
    let tabIndex: Int
    let tabCount: Int
    var onSelected: (() -> Void)?
    var onClose: (() -> Void)?
    var onCloseOtherTabs: (() -> Void)?
    var onCloseTabsToTheRight: (() -> Void)?
    var onTabRenamed: (() -> Void)?
    var onDragChanged: ((CGSize) -> Void)?
    var onDragEnded: (() -> Void)?
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
        tab.displayTitle
    }

    var body: some View {
        let displayText = visibleTitle.isEmpty ? fallbackTitle : visibleTitle
        let closeIsActive = (isHovering || isActive) && !isEditing

        // CLOSE BUTTON (geometry-only, no SwiftUI Button):
        // The close button is rendered as a visual-only
        // `Image(systemName: "xmark")` inside the HStack. Click hit
        // detection happens entirely in `ClickContainerNSView.mouseDown`
        // by computing a 16x16 right-aligned rect inset 14pt from the
        // trailing edge and matching it against the press location.
        // When `closeButtonEnabled` is true and the press lands inside
        // that rect, `onClose` fires directly. See the matching comment
        // in `TabItemButton` for the full rationale.
        TabClickContainer(
            isEnabled: !isEditing,
            onSingleClick: {
                onSelected?()
            },
            onDoubleClick: {
                isEditing = true
            },
            onClose: {
                onClose?()
            },
            closeButtonEnabled: closeIsActive,
            closeButtonInsetFromTrailing: 14,
            closeButtonSize: 16,
            onDragChanged: { translation in
                onDragChanged?(translation)
            },
            onDragEnded: {
                onDragEnded?()
            },
            contextMenu: {
                TabContextMenu.make(
                    tabIndex: tabIndex,
                    tabCount: tabCount,
                    actions: .init(
                        close: { onClose?() },
                        closeOthers: { onCloseOtherTabs?() },
                        closeToTheRight: { onCloseTabsToTheRight?() },
                        rename: { isEditing = true }
                    )
                )
            }
        ) {
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
                            tab.renameRequest = nil
                            onTabRenamed?()
                        },
                        onCancel: {
                            isEditing = false
                            tab.renameRequest = nil
                        }
                    )
                } else {
                    Text(displayText)
                        .lineLimit(1)
                        .font(.system(size: 12.5, weight: isActive ? .semibold : .medium, design: .rounded))
                }
                Spacer()
                MCPAppActivityDot(tabID: tab.id)
                if tab.unreadNotifications > 0 {
                    UnreadCountBadge(count: tab.unreadNotifications)
                }
                // Visual-only close icon. No `.onTapGesture`, no
                // `Button`. Hit detection is done in
                // `ClickContainerNSView.mouseDown` against the same
                // 16x16 rect inset 14pt from the trailing edge.
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(isActive ? .secondary : .tertiary)
                    .frame(width: 16, height: 16)
                    .opacity(closeIsActive ? 1 : 0)
                    .closeButtonHoverHighlight(size: 16, isVisible: closeIsActive)
                    .allowsHitTesting(false)
                    .accessibilityIdentifier(AccessibilityID.Sidebar.tabCloseButton(tab.id))
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(height: 31)
            .modifier(TabChromeModifier(
                isActive: isActive,
                cornerRadius: 12,
                reduceTransparency: reduceTransparency
            ))
        }
        .onAssumeInsideHover($isHovering)
        // See `TabItemButton`'s identical `.onChange`
        // (TabBarContentView.swift) for the full double-open-hazard
        // rationale -- this is its sidebar mirror image, gated on
        // `.sidebar` instead of `.tabBar`.
        .onChange(of: tab.renameRequest) { _, newValue in
            if newValue?.host == .sidebar {
                isEditing = true
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.Sidebar.tab(tab.id))
        // The title `Text` lives inside the `TabClickContainer`'s
        // `NSHostingView`, whose subtree the `.contain` container does not
        // surface to XCUITest / assistive tech. Carry the name explicitly on
        // the container so the row announces its title (and so name-based
        // lookups resolve it), matching `TabItemButton` in the tab bar.
        .accessibilityLabel(displayText)
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
