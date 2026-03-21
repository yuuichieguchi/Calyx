// MainContentView.swift
// Calyx
//
// SwiftUI root view composing sidebar, tab bar, and terminal content.

import SwiftUI
import AppKit

struct MainContentView: View {
    @Bindable var windowSession: WindowSession
    let commandRegistry: CommandRegistry?
    let splitContainerView: SplitContainerView
    var activeBrowserController: BrowserTabController?
    var activeDiffState: DiffLoadState?
    var activeDiffSource: DiffSource?
    var activeDiffReviewStore: DiffReviewStore?

    @Binding var sidebarMode: SidebarMode
    var gitChangesState: GitChangesState = .notLoaded
    var gitEntries: [GitFileEntry] = []
    var gitCommits: [GitCommit] = []
    var expandedCommitIDs: Set<String> = []
    var commitFiles: [String: [CommitFileEntry]] = [:]

    var onTabSelected: ((UUID) -> Void)?
    var onGroupSelected: ((UUID) -> Void)?
    var onNewTab: (() -> Void)?
    var onNewGroup: (() -> Void)?
    var onCloseTab: ((UUID) -> Void)?
    var onGroupRenamed: (() -> Void)?
    var onToggleSidebar: (() -> Void)?
    var onDismissCommandPalette: (() -> Void)?
    var onWorkingFileSelected: ((GitFileEntry) -> Void)?
    var onCommitFileSelected: ((CommitFileEntry) -> Void)?
    var onRefreshGitStatus: (() -> Void)?
    var onLoadMoreCommits: (() -> Void)?
    var onExpandCommit: ((String) -> Void)?
    var onSidebarWidthChanged: ((CGFloat) -> Void)?
    var onCollapseToggled: (() -> Void)?
    var onCloseAllTabsInGroup: ((UUID) -> Void)?
    var onMoveTab: ((UUID, Int, Int) -> Void)?  // (groupID, fromIndex, toIndex)
    var onSidebarDragCommitted: (() -> Void)?
    var onSubmitReview: (() -> Void)?
    var onDiscardReview: (() -> Void)?
    var onSubmitAllReviews: (() -> Void)?
    var onDiscardAllReviews: (() -> Void)?
    var onComposeOverlaySend: ((String) -> Bool)?
    var onDismissComposeOverlay: (() -> Void)?
    var totalReviewCommentCount: Int = 0
    var reviewFileCount: Int = 0

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @AppStorage("terminalGlassOpacity") private var glassOpacity = 0.7
    @AppStorage("themeColorPreset") private var themePreset = "original"
    @AppStorage("themeColorCustomHex") private var customHex = "#050D1C"
    @ObservedObject private var secureInput = SecureInput.shared

    private var themeColor: NSColor {
        ThemeColorPreset.resolve(preset: themePreset, customHex: customHex)
    }

    var body: some View {
        let activeGroup = windowSession.activeGroup
        let activeTabs = activeGroup?.tabs ?? []
        let activeTabID = activeGroup?.activeTabID

        GlassEffectContainer {
            HStack(spacing: 0) {
                if windowSession.showSidebar {
                    SidebarContentView(
                        groups: windowSession.groups,
                        activeGroupID: windowSession.activeGroupID,
                        activeTabID: activeTabID,
                        sidebarMode: $sidebarMode,
                        gitChangesState: gitChangesState,
                        gitEntries: gitEntries,
                        gitCommits: gitCommits,
                        expandedCommitIDs: expandedCommitIDs,
                        commitFiles: commitFiles,
                        onGroupSelected: onGroupSelected,
                        onTabSelected: onTabSelected,
                        onNewGroup: onNewGroup,
                        onCloseTab: onCloseTab,
                        onGroupRenamed: onGroupRenamed,
                        onCollapseToggled: onCollapseToggled,
                        onCloseAllTabsInGroup: onCloseAllTabsInGroup,
                        onWorkingFileSelected: onWorkingFileSelected,
                        onCommitFileSelected: onCommitFileSelected,
                        onRefreshGitStatus: onRefreshGitStatus,
                        onLoadMoreCommits: onLoadMoreCommits,
                        onExpandCommit: onExpandCommit,
                        onMoveTab: onMoveTab
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

                    if reduceTransparency {
                        Divider()
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
                                onMoveTab: activeGroup != nil
                                    ? { from, to in onMoveTab?(activeGroup!.id, from, to) }
                                    : nil,
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
                            .glassEffect(.clear.tint(Color(nsColor: GlassTheme.chromeTint(for: themeColor, glassOpacity: glassOpacity))), in: .rect)
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
                                .padding(.top, -1)
                                .padding(.leading, 8)
                                .glassEffect(.clear.tint(Color(nsColor: GlassTheme.chromeTint(for: themeColor, glassOpacity: glassOpacity))), in: .rect)
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
                                            onSend: onComposeOverlaySend,
                                            onDismiss: onDismissComposeOverlay
                                        )
                                        .frame(height: windowSession.composeOverlayHeight)
                                    }
                                    .glassEffect(.clear.tint(Color(nsColor: GlassTheme.chromeTint(for: themeColor, glassOpacity: glassOpacity))), in: .rect)
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
            .overlay(alignment: .top) {
                GeometryReader { geo in
                    Color.white.opacity(0.001)
                        .frame(height: geo.safeAreaInsets.top + 1)
                        .glassEffect(.clear.tint(Color(nsColor: GlassTheme.chromeTint(for: themeColor, glassOpacity: glassOpacity))), in: .rect)
                        .offset(y: -geo.safeAreaInsets.top)
                }
                .allowsHitTesting(false)
            }
            .background {
                if !reduceTransparency {
                    Rectangle()
                        .fill(
                            LinearGradient(
                                colors: [Color(nsColor: GlassTheme.atmosphereTop(for: themeColor)), Color(nsColor: GlassTheme.atmosphereBottom(for: themeColor))],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .overlay(
                            RadialGradient(
                                colors: [Color(nsColor: GlassTheme.accentGradient(for: themeColor)), Color.clear],
                                center: .bottomTrailing,
                                startRadius: 20,
                                endRadius: 420
                            )
                        )
                        .overlay(
                            Rectangle()
                                .stroke(GlassTheme.specularStroke.opacity(0.30), lineWidth: 1)
                        )
                        .ignoresSafeArea()
                }
            }
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
