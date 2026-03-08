// MainContentView.swift
// Calyx
//
// SwiftUI root view composing sidebar, tab bar, and terminal content.

import SwiftUI

struct MainContentView: View {
    @Bindable var windowSession: WindowSession
    let commandRegistry: CommandRegistry?
    let splitContainerView: SplitContainerView

    var onTabSelected: ((UUID) -> Void)?
    var onGroupSelected: ((UUID) -> Void)?
    var onNewTab: (() -> Void)?
    var onNewGroup: (() -> Void)?
    var onCloseTab: ((UUID) -> Void)?
    var onToggleSidebar: (() -> Void)?
    var onDismissCommandPalette: (() -> Void)?

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
                        onGroupSelected: onGroupSelected,
                        onTabSelected: onTabSelected,
                        onNewGroup: onNewGroup,
                        onCloseTab: onCloseTab
                    )
                    .frame(width: 220)

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

                        TerminalContainerView(splitContainerView: splitContainerView)
                            .opacity(0.85)
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

    func makeNSView(context: Context) -> NSView {
        let wrapper = NSView()
        wrapper.wantsLayer = true
        splitContainerView.translatesAutoresizingMaskIntoConstraints = false
        wrapper.addSubview(splitContainerView)
        NSLayoutConstraint.activate([
            splitContainerView.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor),
            splitContainerView.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor),
            splitContainerView.topAnchor.constraint(equalTo: wrapper.topAnchor),
            splitContainerView.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor),
        ])
        return wrapper
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if splitContainerView.superview !== nsView {
            nsView.subviews.forEach { $0.removeFromSuperview() }
            splitContainerView.translatesAutoresizingMaskIntoConstraints = false
            nsView.addSubview(splitContainerView)
            NSLayoutConstraint.activate([
                splitContainerView.leadingAnchor.constraint(equalTo: nsView.leadingAnchor),
                splitContainerView.trailingAnchor.constraint(equalTo: nsView.trailingAnchor),
                splitContainerView.topAnchor.constraint(equalTo: nsView.topAnchor),
                splitContainerView.bottomAnchor.constraint(equalTo: nsView.bottomAnchor),
            ])
        }
    }
}
