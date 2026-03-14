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
    var onToggleSidebar: (() -> Void)?
    var onDismissCommandPalette: (() -> Void)?
    var onWorkingFileSelected: ((GitFileEntry) -> Void)?
    var onCommitFileSelected: ((CommitFileEntry) -> Void)?
    var onRefreshGitStatus: (() -> Void)?
    var onLoadMoreCommits: (() -> Void)?
    var onExpandCommit: ((String) -> Void)?
    var onSidebarWidthChanged: ((CGFloat) -> Void)?
    var onSidebarDragCommitted: (() -> Void)?

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @AppStorage("terminalGlassOpacity") private var glassOpacity = 0.7

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
                        onWorkingFileSelected: onWorkingFileSelected,
                        onCommitFileSelected: onCommitFileSelected,
                        onRefreshGitStatus: onRefreshGitStatus,
                        onLoadMoreCommits: onLoadMoreCommits,
                        onExpandCommit: onExpandCommit
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
                                onCloseTab: onCloseTab
                            )
                        }

                        if let diffSource = activeDiffSource, let diffState = activeDiffState {
                            VStack(spacing: 0) {
                                DiffToolbarView(source: diffSource)
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
                                        glassOpacity: glassOpacity
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
                            TerminalContainerView(
                                splitContainerView: splitContainerView,
                                reduceTransparency: reduceTransparency,
                                glassOpacity: glassOpacity
                            )
                            .padding(.top, -1)
                            .padding(.leading, 8)
                            .glassEffect(.clear.tint(GlassTheme.chromeTint(for: glassOpacity)), in: .rect)
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
                        .glassEffect(.clear.tint(GlassTheme.chromeTint(for: glassOpacity)), in: .rect)
                        .offset(y: -geo.safeAreaInsets.top)
                }
                .allowsHitTesting(false)
            }
            .background {
                if !reduceTransparency {
                    Rectangle()
                        .fill(
                            LinearGradient(
                                colors: [GlassTheme.atmosphereTop, GlassTheme.atmosphereBottom],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .overlay(
                            RadialGradient(
                                colors: [Color.cyan.opacity(0.18), Color.clear],
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

    func makeNSView(context: Context) -> DiffGlassHostView {
        let host = DiffGlassHostView(
            reduceTransparency: reduceTransparency,
            glassOpacity: glassOpacity
        )
        host.diffView.display(diff: diff)
        return host
    }

    func updateNSView(_ nsView: DiffGlassHostView, context: Context) {
        nsView.configureAppearance(
            reduceTransparency: reduceTransparency,
            glassOpacity: glassOpacity
        )
        if nsView.diffView.currentDiff != diff {
            nsView.diffView.display(diff: diff)
        }
    }
}

@MainActor
final class DiffGlassHostView: NSView {
    private let effectView = NSVisualEffectView()
    private let tintOverlay = NSView()
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

        effectView.translatesAutoresizingMaskIntoConstraints = false
        effectView.blendingMode = .behindWindow
        effectView.state = .followsWindowActiveState
        addSubview(effectView)
        NSLayoutConstraint.activate([
            effectView.leadingAnchor.constraint(equalTo: leadingAnchor),
            effectView.trailingAnchor.constraint(equalTo: trailingAnchor),
            effectView.topAnchor.constraint(equalTo: topAnchor),
            effectView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        tintOverlay.translatesAutoresizingMaskIntoConstraints = false
        tintOverlay.wantsLayer = true
        tintOverlay.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.03).cgColor
        addSubview(tintOverlay, positioned: .above, relativeTo: effectView)
        NSLayoutConstraint.activate([
            tintOverlay.leadingAnchor.constraint(equalTo: leadingAnchor),
            tintOverlay.trailingAnchor.constraint(equalTo: trailingAnchor),
            tintOverlay.topAnchor.constraint(equalTo: topAnchor),
            tintOverlay.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        diffView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(diffView, positioned: .above, relativeTo: tintOverlay)
        NSLayoutConstraint.activate([
            diffView.leadingAnchor.constraint(equalTo: leadingAnchor),
            diffView.trailingAnchor.constraint(equalTo: trailingAnchor),
            diffView.topAnchor.constraint(equalTo: topAnchor),
            diffView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    func configureAppearance(reduceTransparency: Bool, glassOpacity: Double) {
        if reduceTransparency {
            effectView.isHidden = true
            tintOverlay.isHidden = true
            effectView.alphaValue = 1.0
            tintOverlay.alphaValue = 1.0
            layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            return
        }

        let clampedOpacity = CGFloat(max(0.0, min(1.0, glassOpacity)))
        effectView.isHidden = false
        tintOverlay.isHidden = false
        effectView.alphaValue = clampedOpacity
        tintOverlay.alphaValue = clampedOpacity
        layer?.backgroundColor = NSColor.clear.cgColor
        if #available(macOS 26.0, *) {
            effectView.material = .menu
        } else {
            effectView.material = .hudWindow
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
