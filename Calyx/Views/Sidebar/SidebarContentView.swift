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
    var onCollapseToggled: (() -> Void)?
    var onCloseAllTabsInGroup: ((UUID) -> Void)?
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
                                    onCollapseToggled: onCollapseToggled,
                                    onCloseAllTabsInGroup: onCloseAllTabsInGroup
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
        .frame(minWidth: 200)
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

    func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(Color(nsColor: .controlBackgroundColor).ignoresSafeArea(.all, edges: .top))
        } else {
            content
                .glassEffect(.clear.tint(GlassTheme.chromeTint(for: glassOpacity)), in: .rect)
                .overlay(alignment: .trailing) {
                    Rectangle()
                        .fill(GlassTheme.specularStroke.opacity(0.30))
                        .frame(width: 1)
                }
                .overlay(alignment: .topLeading) {
                    LinearGradient(
                        colors: [Color.white.opacity(0.20), Color.clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 32)
                    .allowsHitTesting(false)
                }
        }
    }
}

private struct GroupNameTextField: NSViewRepresentable {
    let initialText: String
    let accessibilityID: String
    var onCommit: (String) -> Void
    var onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCommit: onCommit, onCancel: onCancel)
    }

    func makeNSView(context: Context) -> NSTextField {
        let textField = NSTextField()
        textField.isBordered = false
        textField.drawsBackground = false
        textField.focusRingType = .none
        textField.cell?.isScrollable = true
        textField.cell?.lineBreakMode = .byTruncatingTail
        textField.stringValue = initialText
        textField.delegate = context.coordinator
        textField.setAccessibilityIdentifier(accessibilityID)

        let systemFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
        if let rounded = systemFont.fontDescriptor.withDesign(.rounded) {
            textField.font = NSFont(descriptor: rounded, size: 12)
        } else {
            textField.font = systemFont
        }

        context.coordinator.textField = textField

        DispatchQueue.main.async {
            textField.selectText(nil)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            context.coordinator.installClickMonitor()
        }

        return textField
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        context.coordinator.onCommit = onCommit
        context.coordinator.onCancel = onCancel
    }

    class Coordinator: NSObject, NSTextFieldDelegate {
        weak var textField: NSTextField?
        var onCommit: (String) -> Void
        var onCancel: () -> Void
        private var clickMonitor: Any?
        private var didEnd = false

        init(onCommit: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
            self.onCommit = onCommit
            self.onCancel = onCancel
        }

        func installClickMonitor() {
            clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
                guard let self, !self.didEnd else { return event }
                if let textField = self.textField,
                   let eventWindow = event.window,
                   eventWindow == textField.window {
                    let point = textField.convert(event.locationInWindow, from: nil)
                    if textField.bounds.contains(point) {
                        return event
                    }
                    if let editor = textField.currentEditor() as? NSView {
                        let editorPoint = editor.convert(event.locationInWindow, from: nil)
                        if editor.bounds.contains(editorPoint) {
                            return event
                        }
                    }
                }
                self.finish(commit: true)
                return event
            }
        }

        private func finish(commit: Bool) {
            guard !didEnd else { return }
            didEnd = true
            removeClickMonitor()
            if commit {
                onCommit(textField?.stringValue ?? "")
            } else {
                onCancel()
            }
        }

        private func removeClickMonitor() {
            if let monitor = clickMonitor {
                NSEvent.removeMonitor(monitor)
                clickMonitor = nil
            }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                finish(commit: true)
                return true
            }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                finish(commit: false)
                return true
            }
            return false
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            finish(commit: true)
        }

        deinit {
            removeClickMonitor()
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
    var onCollapseToggled: (() -> Void)?
    var onCloseAllTabsInGroup: ((UUID) -> Void)?

    @State private var isEditing = false
    @State private var isHoveringHeader = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Group header
            if isEditing {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color(nsColor: group.color.nsColor))
                        .frame(width: 8, height: 8)
                    GroupNameTextField(
                        initialText: group.name,
                        accessibilityID: AccessibilityID.Sidebar.groupNameTextField(group.id),
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
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    // Close all tabs button (shown on hover)
                    Button(action: { onCloseAllTabsInGroup?(group.id) }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.plain)
                    .opacity(isHoveringHeader ? 1 : 0)
                    .allowsHitTesting(isHoveringHeader)
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
                .padding(.vertical, 10)
                .modifier(GroupHeaderBackgroundModifier(
                    isActiveGroup: isActiveGroup,
                    reduceTransparency: reduceTransparency,
                    groupColor: group.color
                ))
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier(AccessibilityID.Sidebar.group(group.id))
                .highPriorityGesture(TapGesture(count: 2).onEnded { isEditing = true })
                .onHover { isHoveringHeader = $0 }
            }

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
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    groupColor.color.opacity(0.16),
                                    Color.gray.opacity(0.10),
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                )
                .glassEffect(
                    .clear.tint(groupColor.color.opacity(0.12)).interactive(),
                    in: .rect(cornerRadius: 12)
                )
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
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var isHovering = false

    private var tabIcon: String {
        switch tab.content {
        case .terminal: "terminal"
        case .browser: "globe"
        case .diff: "doc.text"
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: tabIcon)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(tab.title.isEmpty ? fallbackTitle : tab.title)
                .lineLimit(1)
                .font(.system(size: 12.5, weight: isActive ? .semibold : .medium, design: .rounded))
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
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
            .opacity(isHovering || isActive ? 1 : 0)
            .allowsHitTesting(isHovering || isActive)
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
        .onTapGesture { onSelected?() }
        .onHover { isHovering = $0 }
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
