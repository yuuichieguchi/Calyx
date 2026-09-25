// MainContentView.swift
// Calyx
//
// SwiftUI root view composing sidebar, tab bar, and terminal content.

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct MainContentView: View {
    @Bindable var windowSession: WindowSession
    let commandRegistry: CommandRegistry?
    let splitContainerView: SplitContainerView
    var activeBrowserController: BrowserTabController?
    var activeDiffState: DiffLoadState?
    var activeDiffSource: DiffSource?
    var activeDiffReviewStore: DiffReviewStore?
    /// Chrome-style in-app recovery bar (RecoveryBarModel.swift), shown
    /// above the tab bar/pane content as the first child of `body`'s own
    /// top-level `VStack`. `nil` (no existing caller besides
    /// CalyxWindowController) simply shows no bar, same as
    /// `hasPreservedSessionSnapshot == false`.
    var recoveryBarModel: RecoveryBarModel?

    @Binding var sidebarMode: SidebarMode
    var gitSidebarState = GitSidebarViewState()

    var onTabSelected: ((UUID) -> Void)?
    var onGroupSelected: ((UUID) -> Void)?
    var onNewTab: (() -> Void)?
    var onNewGroup: (() -> Void)?
    var onCloseTab: ((UUID) -> Void)?
    var onCloseOtherTabs: ((UUID) -> Void)?
    var onCloseTabsToTheRight: ((UUID) -> Void)?
    var onGroupRenamed: (() -> Void)?
    var onTabRenamed: (() -> Void)?
    var onToggleSidebar: (() -> Void)?
    var onDismissCommandPalette: (() -> Void)?
    var onWorkingFileSelected: ((String, GitFileEntry) -> Void)?
    var onCommitFileSelected: ((String, CommitFileEntry) -> Void)?
    var onRefreshGitStatus: (() -> Void)?
    var onLoadMoreCommits: ((String) -> Void)?
    var onExpandCommit: ((String, String) -> Void)?
    var onToggleGitRepoSection: ((String) -> Void)?
    var onRetryGitRepoSection: ((String) -> Void)?
    var onSelectRefFilter: ((String, GitRefSelection) -> Void)?
    var onSidebarWidthChanged: ((CGFloat) -> Void)?
    var onCollapseToggled: (() -> Void)?
    var onCloseAllTabsInGroup: ((UUID) -> Void)?
    var onCloseOtherGroups: ((UUID) -> Void)?
    var onCloseGroupsBelow: ((UUID) -> Void)?
    var onGroupColorChanged: (() -> Void)?
    var onMoveTab: ((UUID, Int, Int) -> Void)?  // (groupID, fromIndex, toIndex)
    var paneTitle: (UUID) -> String?
    var paneCwd: (UUID) -> String?
    var onSidebarDragCommitted: (() -> Void)?
    var onSubmitReview: (() -> Void)?
    var onDiscardReview: (() -> Void)?
    var onSubmitAllReviews: (() -> Void)?
    var onDiscardAllReviews: (() -> Void)?
    var onComposeOverlaySend: ((String) -> Bool)?
    var onDismissComposeOverlay: (() -> Void)?
    var onComposeOverlayEscapePressed: (() -> Void)?
    let missionMapGitPoller: MissionMapGitPoller
    /// This window's panes for Mission Map, in window order.
    let missionMapPanes: () -> [CockpitPaneInfo]
    var onMissionMapFocusSurface: ((UUID) -> Void)?
    var onDismissMissionMap: (() -> Void)?
    var onMissionMapAllow: ((UUID) -> Void)?
    var onMissionMapOpenApproval: ((UUID) -> Void)?
    var onMissionMapKeyCatcherReady: ((NSView) -> Void)?
    var totalReviewCommentCount: Int = 0
    var reviewFileCount: Int = 0

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @AppStorage("terminalGlassOpacity") private var glassOpacity = 0.7
    @AppStorage("themeColorPreset") private var themePreset = "original"
    @AppStorage("themeColorCustomHex") private var customHex = "#050D1C"
    @ObservedObject private var secureInput = SecureInput.shared
    @State private var ghosttyProvider = GhosttyThemeProvider.shared

    private var themeColor: NSColor {
        ThemeColorPreset.resolve(
            preset: themePreset,
            customHex: customHex,
            ghosttyBackground: ghosttyProvider.ghosttyBackground
        )
    }

    // `mainContent` is applied here exactly once, unconditionally, as the
    // base of `.safeAreaInset` -- NOT branched inside an `if`/`else` (the
    // previous `VStack(spacing: 0) { conditional bar; mainContent }`
    // shape). Two reasons:
    //
    // 1. Root-shape invariant: `mainContent`'s own `GlassEffectContainer`
    //    chain must stay the SwiftUI root, because the single root glass
    //    sheet (`mainContent`'s own `.background` with
    //    `.ignoresSafeArea()`, further down in this file) only covers the
    //    titlebar and the RecoveryBar's own safe-area-inset strip when
    //    nothing ordinary sits above it in the tree. An `if`/`else`
    //    `VStack(spacing: 0) { conditional bar; mainContent }` shape puts
    //    an unstyled, non-safe-area-ignoring `VStack` at the root instead,
    //    which would clip that coverage and break the transparent/glass
    //    titlebar even with the bar hidden. `mainContent.safeAreaInset(...)`
    //    keeps `mainContent` itself as the root chain when the inset
    //    content is empty, preserving the sheet's coverage exactly.
    // 2. `mainContent` hosts `SplitContainerView` (real ghostty terminal
    //    `NSView`s via `TerminalContainerView`'s `NSViewRepresentable`). An
    //    `if { VStack { bar; mainContent } } else { mainContent }` shape
    //    puts `mainContent` at two different static positions in the view
    //    tree -- SwiftUI's `_ConditionalContent` tears down and rebuilds
    //    whichever branch was active every time the branch flips, which
    //    would destroy and recreate the live terminal surfaces every time
    //    Restore/Dismiss hides the bar. `.safeAreaInset` applies to
    //    `mainContent` unconditionally; only the inset's own (small,
    //    disposable) content is conditional, so `mainContent` never moves
    //    across a branch boundary and its terminal state survives.
    var body: some View {
        mainContent
            .safeAreaInset(edge: .top, spacing: 0) {
                if let recoveryBarModel, recoveryBarModel.showRecoveryBar {
                    RecoveryBarView(model: recoveryBarModel)
                }
            }
    }

    private var mainContent: some View {
        let activeGroup = windowSession.activeGroup
        let activeTabs = activeGroup?.tabs ?? []
        let activeTabID = activeGroup?.activeTabID

        // The `HStack` stays unconditional inside the `ZStack` (never in
        // an `if`), for the same reason `body` applies `mainContent`
        // unconditionally: it hosts the live terminal surfaces. Only the
        // Mission Map overlay above it is conditional.
        return GlassEffectContainer {
            ZStack {
                HStack(spacing: 0) {
                    if windowSession.showSidebar {
                        SidebarContentView(
                            groups: windowSession.groups,
                            activeGroupID: windowSession.activeGroupID,
                            activeTabID: activeTabID,
                            sidebarMode: $sidebarMode,
                            gitSidebarState: gitSidebarState,
                            onGroupSelected: onGroupSelected,
                            onTabSelected: onTabSelected,
                            onNewGroup: onNewGroup,
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
                            onWorkingFileSelected: onWorkingFileSelected,
                            onCommitFileSelected: onCommitFileSelected,
                            onRefreshGitStatus: onRefreshGitStatus,
                            onLoadMoreCommits: onLoadMoreCommits,
                            onExpandCommit: onExpandCommit,
                            onToggleGitRepoSection: onToggleGitRepoSection,
                            onRetryGitRepoSection: onRetryGitRepoSection,
                            onSelectRefFilter: onSelectRefFilter,
                            onMoveTab: onMoveTab,
                            paneTitle: paneTitle,
                            paneCwd: paneCwd
                        )
                        .frame(width: windowSession.sidebarWidth)
                        .overlay(alignment: .trailing) {
                            SidebarResizeHandle(
                                currentWidth: windowSession.sidebarWidth,
                                onWidthChanged: { onSidebarWidthChanged?($0) },
                                onDragCommitted: { onSidebarDragCommitted?() }
                            )
                            .offset(x: 0)
                            .zIndex(1)
                        }
                    }

                    ZStack {
                        VStack(spacing: 0) {
                            if !activeTabs.isEmpty {
                                TabBarContentView(
                                    tabs: activeTabs,
                                    activeTabID: activeTabID,
                                    onTabSelected: onTabSelected,
                                    onNewTab: onNewTab,
                                    onCloseTab: onCloseTab,
                                    onCloseOtherTabs: onCloseOtherTabs,
                                    onCloseTabsToTheRight: onCloseTabsToTheRight,
                                    onMoveTab: activeGroup != nil
                                        ? { from, to in onMoveTab?(activeGroup!.id, from, to) }
                                        : nil,
                                    onTabRenamed: onTabRenamed,
                                    activeGroupID: activeGroup?.id
                                )
                            }

                            if let diffSource = activeDiffSource, let diffState = activeDiffState {
                                VStack(spacing: 0) {
                                    DiffToolbarView(
                                        source: diffSource,
                                        reviewStore: activeDiffReviewStore,
                                        onSubmitReview: onSubmitReview,
                                        onDiscardReview: onDiscardReview,
                                        totalReviewCommentCount: totalReviewCommentCount,
                                        reviewFileCount: reviewFileCount,
                                        onSubmitAllReviews: onSubmitAllReviews,
                                        onDiscardAllReviews: onDiscardAllReviews
                                    )
                                    switch diffState {
                                    case .loading:
                                        VStack {
                                            Spacer()
                                            ProgressView("Loading diff...")
                                            Spacer()
                                        }
                                    case .success(let diff):
                                        DiffGlassContentView(
                                            diff: diff,
                                            reduceTransparency: reduceTransparency,
                                            glassOpacity: glassOpacity,
                                            reviewStore: activeDiffReviewStore
                                        )
                                            .accessibilityIdentifier(AccessibilityID.Diff.content)
                                    case .error(let message):
                                        VStack(spacing: 12) {
                                            Spacer()
                                            Image(systemName: "exclamationmark.triangle")
                                                .font(.largeTitle)
                                                .foregroundStyle(.secondary)
                                            Text(message)
                                                .foregroundStyle(.secondary)
                                            Spacer()
                                        }
                                    }
                                }
                                .accessibilityIdentifier(AccessibilityID.Diff.container)
                            } else if let browserController = activeBrowserController {
                                BrowserContainerView(controller: browserController)
                            } else {
                                VStack(spacing: 0) {
                                    TerminalContainerView(
                                        splitContainerView: splitContainerView,
                                        reduceTransparency: reduceTransparency,
                                        glassOpacity: glassOpacity
                                    )
                                    .onDrop(of: [.fileURL], delegate: TerminalDropDelegate(splitContainerView: splitContainerView))
                                    .layoutPriority(1)
                                    .overlay(alignment: .topTrailing) {
                                        if secureInput.enabled {
                                            SecureInputOverlay()
                                        }
                                    }

                                    if windowSession.showComposeOverlay {
                                        VStack(spacing: 0) {
                                            ComposeResizeHandle(
                                                currentHeight: windowSession.composeOverlayHeight,
                                                onHeightChanged: { windowSession.composeOverlayHeight = $0 }
                                            )

                                            ComposeOverlayContainerView(
                                                text: $windowSession.composeOverlayText,
                                                onSend: onComposeOverlaySend,
                                                onDismiss: onDismissComposeOverlay,
                                                onEscapePressed: onComposeOverlayEscapePressed
                                            )
                                            .frame(height: windowSession.composeOverlayHeight)
                                            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                                            .overlay {
                                                RoundedRectangle(cornerRadius: 22, style: .continuous)
                                                    .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
                                                    .allowsHitTesting(false)
                                            }
                                            .padding(.horizontal, 12)
                                            .padding(.bottom, 12)
                                        }
                                    }
                                }
                            }
                        }

                        if windowSession.showCommandPalette, let commandRegistry {
                            Color.black.opacity(0.01)
                                .onTapGesture { onDismissCommandPalette?() }

                            VStack {
                                CommandPaletteContainerView(
                                    registry: commandRegistry,
                                    onDismiss: onDismissCommandPalette
                                )
                                .frame(width: 500, height: 340)
                                .glassEffect(.regular, in: .rect(cornerRadius: 12))

                                Spacer()
                            }
                            .padding(.top, 40)
                        }
                    }
                }

                // The fade is scoped to this inner container so it only
                // animates the map's insertion/removal, not layout changes
                // in the `HStack` (compose overlay, command palette,
                // terminal) that land in the same update.
                ZStack {
                    if windowSession.showMissionMap {
                        missionMapOverlay
                            .transition(.opacity)
                    }
                }
                .animation(.easeOut(duration: 0.15), value: windowSession.showMissionMap)
            }
        }
        .background {
            Group {
                if reduceTransparency {
                    Color(nsColor: .windowBackgroundColor)
                } else {
                    Color.clear
                        .modifier(GlassInactiveTintModifier(themeColor: themeColor, glassOpacity: glassOpacity))
                        .glassEffect(.clear.tint(Color(nsColor: GlassTheme.chromeTint(for: themeColor, glassOpacity: glassOpacity))), in: .rect)
                }
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
        }
        .modifier(GlassAtmosphereBackground(themeColor: themeColor, glassOpacity: glassOpacity, reduceTransparency: reduceTransparency, specularStroke: true))
    }
}

extension MainContentView {
    /// Mission Map over the whole content area (sidebar included). The
    /// near-transparent layer underneath catches clicks the map itself
    /// leaves unhandled and closes it.
    fileprivate var missionMapOverlay: some View {
        ZStack {
            Color.black.opacity(0.01)
                .onTapGesture { onDismissMissionMap?() }

            MissionMapView(
                panes: missionMapPanes,
                gitPoller: missionMapGitPoller,
                onFocusSurface: onMissionMapFocusSurface,
                onDismiss: onDismissMissionMap,
                onAllow: onMissionMapAllow,
                onOpenApproval: onMissionMapOpenApproval,
                onKeyCatcherReady: onMissionMapKeyCatcherReady
            )
        }
    }
}

struct DiffGlassContentView: NSViewRepresentable {
    let diff: FileDiff
    let reduceTransparency: Bool
    let glassOpacity: Double
    var reviewStore: DiffReviewStore?

    func makeNSView(context: Context) -> DiffGlassHostView {
        let host = DiffGlassHostView(
            reduceTransparency: reduceTransparency,
            glassOpacity: glassOpacity
        )
        host.diffView.reviewStore = reviewStore
        host.diffView.display(diff: diff)
        return host
    }

    func updateNSView(_ nsView: DiffGlassHostView, context: Context) {
        nsView.configureAppearance(
            reduceTransparency: reduceTransparency,
            glassOpacity: glassOpacity
        )
        nsView.diffView.reviewStore = reviewStore
        if nsView.diffView.currentDiff != diff {
            nsView.diffView.display(diff: diff)
        } else {
            // Diff unchanged but comments may have changed (submit/discard)
            nsView.diffView.redisplayWithComments()
        }
    }
}

@MainActor
final class DiffGlassHostView: NSView {
    let diffView = DiffView(frame: .zero)

    init(reduceTransparency: Bool, glassOpacity: Double) {
        super.init(frame: .zero)
        setupViews()
        configureAppearance(reduceTransparency: reduceTransparency, glassOpacity: glassOpacity)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func setupViews() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        diffView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(diffView)
        NSLayoutConstraint.activate([
            diffView.leadingAnchor.constraint(equalTo: leadingAnchor),
            diffView.trailingAnchor.constraint(equalTo: trailingAnchor),
            diffView.topAnchor.constraint(equalTo: topAnchor),
            diffView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    func configureAppearance(reduceTransparency: Bool, glassOpacity: Double) {
        if reduceTransparency {
            layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        } else {
            layer?.backgroundColor = NSColor.clear.cgColor
        }
    }
}

struct TerminalContainerView: NSViewRepresentable {
    let splitContainerView: SplitContainerView
    let reduceTransparency: Bool
    let glassOpacity: Double

    func makeNSView(context: Context) -> NSView {
        TerminalGlassHostView(
            splitContainerView: splitContainerView,
            reduceTransparency: reduceTransparency,
            glassOpacity: glassOpacity
        )
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let host = nsView as? TerminalGlassHostView else { return }
        host.update(
            splitContainerView: splitContainerView,
            reduceTransparency: reduceTransparency,
            glassOpacity: glassOpacity
        )
    }
}

@MainActor
private final class TerminalGlassHostView: NSView {

    init(splitContainerView: SplitContainerView, reduceTransparency: Bool, glassOpacity: Double) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        update(
            splitContainerView: splitContainerView,
            reduceTransparency: reduceTransparency,
            glassOpacity: glassOpacity
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func update(splitContainerView: SplitContainerView, reduceTransparency: Bool, glassOpacity: Double) {
        if reduceTransparency {
            layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        } else {
            layer?.backgroundColor = NSColor.clear.cgColor
        }

        if splitContainerView.superview !== self {
            splitContainerView.removeFromSuperview()
            splitContainerView.translatesAutoresizingMaskIntoConstraints = false
            addSubview(splitContainerView)
            NSLayoutConstraint.activate([
                splitContainerView.leadingAnchor.constraint(equalTo: leadingAnchor),
                splitContainerView.trailingAnchor.constraint(equalTo: trailingAnchor),
                splitContainerView.topAnchor.constraint(equalTo: topAnchor),
                splitContainerView.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }
    }
}

// MARK: - Drag and Drop

@MainActor
struct TerminalDropDelegate: DropDelegate {
    let splitContainerView: SplitContainerView

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.fileURL])
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let window = splitContainerView.window,
              let surfaceView = window.firstResponder as? SurfaceView,
              let surfaceController = surfaceView.surfaceController else {
            return false
        }

        let providers = info.itemProviders(for: [.fileURL])
        guard !providers.isEmpty else { return false }

        let group = DispatchGroup()
        var paths: [(Int, String)] = []
        let lock = NSLock()

        for (i, provider) in providers.enumerated() {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                defer { group.leave() }
                guard let data = data as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                let escaped = ShellEscape.escape(url.path)
                lock.lock()
                paths.append((i, escaped))
                lock.unlock()
            }
        }

        group.notify(queue: .main) {
            let joined = paths.sorted { $0.0 < $1.0 }.map(\.1).joined(separator: " ")
            if !joined.isEmpty {
                surfaceController.sendText(joined)
            }
        }
        return true
    }
}
