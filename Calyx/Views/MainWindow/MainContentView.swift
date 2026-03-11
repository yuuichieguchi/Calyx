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

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

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
                    .frame(width: 220)
                    .clipped(antialiased: false)

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
                            DiffContainerView(source: diffSource, loadState: diffState)
                        } else if let browserController = activeBrowserController {
                            BrowserContainerView(controller: browserController)
                        } else {
                            TerminalContainerView(
                                splitContainerView: splitContainerView,
                                reduceTransparency: reduceTransparency
                            )
                            .opacity(reduceTransparency ? 1.0 : 0.7)
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
        }
    }
}

struct TerminalContainerView: NSViewRepresentable {
    let splitContainerView: SplitContainerView
    let reduceTransparency: Bool

    func makeNSView(context: Context) -> NSView {
        TerminalGlassHostView(
            splitContainerView: splitContainerView,
            reduceTransparency: reduceTransparency
        )
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let host = nsView as? TerminalGlassHostView else { return }
        host.update(splitContainerView: splitContainerView, reduceTransparency: reduceTransparency)
    }
}

@MainActor
private final class TerminalGlassHostView: NSView {
    private let effectView = NSVisualEffectView()
    private let tintOverlay = NSView()

    init(splitContainerView: SplitContainerView, reduceTransparency: Bool) {
        super.init(frame: .zero)
        setupViews()
        update(splitContainerView: splitContainerView, reduceTransparency: reduceTransparency)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func update(splitContainerView: SplitContainerView, reduceTransparency: Bool) {
        configureAppearance(reduceTransparency: reduceTransparency)

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

    private func setupViews() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        effectView.translatesAutoresizingMaskIntoConstraints = false
        effectView.blendingMode = .withinWindow
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
    }

    private func configureAppearance(reduceTransparency: Bool) {
        if reduceTransparency {
            effectView.isHidden = true
            tintOverlay.isHidden = true
            layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            return
        }

        effectView.isHidden = false
        tintOverlay.isHidden = false
        layer?.backgroundColor = NSColor.clear.cgColor
        if #available(macOS 26.0, *) {
            effectView.material = .menu
        } else {
            effectView.material = .hudWindow
        }
    }
}
