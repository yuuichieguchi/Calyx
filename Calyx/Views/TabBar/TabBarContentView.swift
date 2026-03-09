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
                .background(TabBarWheelBridge(onDoubleClickEmptyArea: onNewTab))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)

            Spacer(minLength: 40)
                .frame(height: 32)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { onNewTab?() }

            Button(action: { onNewTab?() }) {
                Image(systemName: "plus")
                    .font(.caption)
            }
            .modifier(GlassButtonModifier(reduceTransparency: reduceTransparency))
            .padding(.horizontal, 8)
            .accessibilityIdentifier(AccessibilityID.TabBar.newTabButton)
        }
        .padding(.horizontal, 4)
        .frame(height: 32)
        .contentShape(Rectangle())
        .modifier(TabBarBackgroundModifier(reduceTransparency: reduceTransparency))
        .clipped(antialiased: false)
        .accessibilityIdentifier(AccessibilityID.TabBar.container)
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

private struct TabBarWheelBridge: NSViewRepresentable {
    var onDoubleClickEmptyArea: (() -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(onDoubleClickEmptyArea: onDoubleClickEmptyArea)
    }

    func makeNSView(context: Context) -> WheelBridgeView {
        let view = WheelBridgeView()
        view.onDoubleClickEmptyArea = { context.coordinator.onDoubleClickEmptyArea?() }
        return view
    }

    func updateNSView(_ nsView: WheelBridgeView, context: Context) {
        context.coordinator.onDoubleClickEmptyArea = onDoubleClickEmptyArea
        nsView.onDoubleClickEmptyArea = { context.coordinator.onDoubleClickEmptyArea?() }
    }

    final class Coordinator {
        var onDoubleClickEmptyArea: (() -> Void)?

        init(onDoubleClickEmptyArea: (() -> Void)?) {
            self.onDoubleClickEmptyArea = onDoubleClickEmptyArea
        }
    }
}

@MainActor
private final class WheelBridgeView: NSView {
    private var eventMonitor: Any?
    var onDoubleClickEmptyArea: (() -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        installMonitorIfNeeded()
    }

    private func installMonitorIfNeeded() {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .leftMouseDown]) { [weak self] event in
            guard let self else { return event }
            return self.handle(event: event)
        }
    }

    private func handle(event: NSEvent) -> NSEvent? {
        switch event.type {
        case .scrollWheel:
            return handleScrollWheel(event)
        case .leftMouseDown:
            return handleDoubleClick(event)
        default:
            return event
        }
    }

    private func handleScrollWheel(_ event: NSEvent) -> NSEvent? {
        guard abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) else { return event }
        guard let scrollView = targetScrollView(for: event) else { return event }
        guard let documentView = scrollView.documentView else { return event }

        let viewportWidth = scrollView.contentView.bounds.width
        let maxX = max(0, documentView.bounds.width - viewportWidth)
        guard maxX > 0 else { return event }

        let delta = event.scrollingDeltaY
        var newX = scrollView.contentView.bounds.origin.x - delta
        newX = min(max(0, newX), maxX)

        var origin = scrollView.contentView.bounds.origin
        origin.x = newX
        scrollView.contentView.setBoundsOrigin(origin)
        scrollView.reflectScrolledClipView(scrollView.contentView)

        return nil
    }

    private func handleDoubleClick(_ event: NSEvent) -> NSEvent? {
        guard event.clickCount == 2 else { return event }
        guard let window, let contentView = window.contentView else { return event }
        let locationInContent = contentView.convert(event.locationInWindow, from: nil)
        guard let hitView = contentView.hitTest(locationInContent) else { return event }
        guard let scrollView = hitView.enclosingScrollView else { return event }
        guard scrollView.contentView.bounds.height <= 48 else { return event }

        let isEmptyStripArea =
            hitView is NSClipView ||
            hitView is NSScroller ||
            hitView == scrollView
        guard isEmptyStripArea else { return event }

        onDoubleClickEmptyArea?()
        return nil
    }

    private func targetScrollView(for event: NSEvent) -> NSScrollView? {
        guard let window, let contentView = window.contentView else { return nil }
        let locationInContent = contentView.convert(event.locationInWindow, from: nil)
        guard let hitView = contentView.hitTest(locationInContent) else { return nil }
        guard let scrollView = hitView.enclosingScrollView else { return nil }
        // Only intercept the compact horizontal tab strip scroller (not sidebar/main content).
        guard scrollView.contentView.bounds.height <= 48 else { return nil }
        return scrollView
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
            content.glassEffect(.clear.tint(.black.opacity(0.25)), in: .rect)
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
            .accessibilityIdentifier(AccessibilityID.TabBar.tab(tab.id))
            .accessibilityLabel(tab.title)

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
            .accessibilityIdentifier(AccessibilityID.TabBar.tabCloseButton(tab.id))
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
