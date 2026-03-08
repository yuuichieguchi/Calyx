// TabBarContentView.swift
// Calyx
//
// SwiftUI horizontal tab strip for the active tab group.

import SwiftUI

struct TabBarContentView: View {
    let tabs: [Tab]
    let activeTabID: UUID?
    var onTabSelected: ((UUID) -> Void)?
    var onNewTab: (() -> Void)?
    var onCloseTab: ((UUID) -> Void)?

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        HStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 1) {
                        ForEach(tabs) { tab in
                            TabItemButton(
                                tab: tab,
                                isActive: tab.id == activeTabID,
                                onSelected: { onTabSelected?(tab.id) },
                                onClose: { onCloseTab?(tab.id) }
                            )
                            .id(tab.id)
                        }
                    }
                }
                .onAppear {
                    scrollToActiveTab(proxy: proxy, animated: false)
                }
                .onChange(of: activeTabID) { _, _ in
                    scrollToActiveTab(proxy: proxy, animated: true)
                }
                .onChange(of: tabs.map(\.id)) { _, _ in
                    scrollToActiveTab(proxy: proxy, animated: false)
                }
            }

            Color.clear
                .frame(maxWidth: .infinity, minHeight: 32)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { onNewTab?() }

            Button(action: { onNewTab?() }) {
                Image(systemName: "plus")
                    .font(.caption)
            }
            .modifier(GlassButtonModifier(reduceTransparency: reduceTransparency))
            .padding(.horizontal, 8)
        }
        .padding(.horizontal, 4)
        .frame(height: 32)
        .contentShape(Rectangle())
        .modifier(TabBarBackgroundModifier(reduceTransparency: reduceTransparency))
    }

    private func scrollToActiveTab(proxy: ScrollViewProxy, animated: Bool) {
        guard let activeTabID else { return }
        DispatchQueue.main.async {
            if animated {
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(activeTabID, anchor: .center)
                }
            } else {
                proxy.scrollTo(activeTabID, anchor: .center)
            }
        }
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

private struct TabBarBackgroundModifier: ViewModifier {
    let reduceTransparency: Bool

    func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(Color(nsColor: .windowBackgroundColor))
        } else {
            content.glassEffect(.regular, in: .rect)
        }
    }
}

private struct TabItemButton: View {
    let tab: Tab
    let isActive: Bool
    var onSelected: (() -> Void)?
    var onClose: (() -> Void)?
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 0) {
            Button(action: { onSelected?() }) {
                Text(tab.title)
                    .lineLimit(1)
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 10)
                    .padding(.trailing, 4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if tab.unreadNotifications > 0 {
                Text(tab.unreadNotifications > 99 ? "99+" : "\(tab.unreadNotifications)")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.red))
            }

            Button(action: { onClose?() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
            .padding(.trailing, 6)
            .opacity(isHovering || isActive ? 1 : 0)
            .allowsHitTesting(isHovering || isActive)
        }
        .frame(minWidth: 96, idealWidth: 140, maxWidth: 180)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 4).fill(
                isActive ? Color.accentColor.opacity(0.12) :
                isHovering ? Color.white.opacity(0.06) : Color.clear
            )
        )
        .onHover { isHovering = $0 }
    }
}
