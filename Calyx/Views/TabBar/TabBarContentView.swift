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
    var onMoveTab: ((Int, Int) -> Void)?
    var activeGroupID: UUID? = nil

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var reorderState = TabReorderState()

    var body: some View {
        HStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    GlassEffectContainer(spacing: 10) {
                        HStack(spacing: 10) {
                            ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
                                TabItemButton(
                                    tab: tab,
                                    isActive: tab.id == activeTabID,
                                    onSelected: { onTabSelected?(tab.id) },
                                    onClose: { onCloseTab?(tab.id) }
                                )
                                .id(tab.id)
                                .background(
                                    GeometryReader { geo in
                                        Color.clear.preference(
                                            key: TabFramePreferenceKey.self,
                                            value: [tab.id: geo.frame(in: .named("tabBarScroll"))]
                                        )
                                    }
                                )
                                .offset(x: reorderState.draggedTabID == tab.id ? reorderState.dragOffset : 0)
                                .zIndex(reorderState.draggedTabID == tab.id ? 1 : 0)
                                .scaleEffect(reorderState.draggedTabID == tab.id ? 1.03 : 1.0)
                                .shadow(color: .black.opacity(reorderState.draggedTabID == tab.id ? 0.15 : 0), radius: 8)
                                .gesture(tabDragGesture(index: index, tab: tab))
                                .accessibilityValue(AccessibilityID.TabBar.tabAtIndex(index))
                            }
                        }
                        .overlay {
                            if let slot = reorderState.insertionSlot,
                               reorderState.draggedTabID != nil {
                                insertionIndicator(slot: slot)
                            }
                        }
                    }
                }
                .coordinateSpace(name: "tabBarScroll")
                .onAppear {
                    scrollToActiveTab(proxy: proxy, animated: false)
                }
                .onChange(of: activeTabID) { _, _ in
                    scrollToActiveTab(proxy: proxy, animated: true)
                }
                .onChange(of: tabs.map(\.id)) { _, _ in
                    reorderState.reset()
                    scrollToActiveTab(proxy: proxy, animated: false)
                }
                .background(TabBarWheelBridge(onDoubleClickEmptyArea: onNewTab))
                .onPreferenceChange(TabFramePreferenceKey.self) { frames in
                    reorderState.tabFrames = frames
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)

            Spacer(minLength: 40)
                .frame(height: 38)
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
        .frame(height: 38)
        .contentShape(Rectangle())
        .modifier(TabBarBackgroundModifier(reduceTransparency: reduceTransparency))
        .clipped(antialiased: false)
        .accessibilityIdentifier(AccessibilityID.TabBar.container)
    }

    // MARK: - Drag Gesture

    private func tabDragGesture(index: Int, tab: Tab) -> some Gesture {
        DragGesture(minimumDistance: 5)
            .onChanged { value in
                guard tabs.count > 1, onMoveTab != nil else { return }
                if reorderState.draggedTabID == nil {
                    reorderState.draggedTabID = tab.id
                    reorderState.draggedTabIndex = index
                }
                reorderState.dragOffset = value.translation.width
                if let frame = reorderState.tabFrames[tab.id] {
                    let midpoint = frame.midX + value.translation.width
                    reorderState.updateInsertionSlot(dragMidpoint: midpoint, axis: .horizontal)
                }
            }
            .onEnded { _ in
                let moveFrom = reorderState.draggedTabIndex
                let moveTo = moveFrom.flatMap { reorderState.destinationIndex(fromIndex: $0, tabCount: tabs.count) }
                withAnimation(.easeOut(duration: 0.15)) {
                    reorderState.reset()
                }
                if let from = moveFrom, let to = moveTo {
                    onMoveTab?(from, to)
                }
            }
    }

    // MARK: - Insertion Indicator

    private func insertionIndicator(slot: Int) -> some View {
        GeometryReader { geo in
            let sortedFrames = reorderState.tabFrames.values.sorted { $0.minX < $1.minX }
            let xPos: CGFloat = {
                if slot == 0 {
                    return sortedFrames.first?.minX ?? 0
                } else if slot >= sortedFrames.count {
                    return sortedFrames.last?.maxX ?? geo.size.width
                } else {
                    let prev = sortedFrames[slot - 1]
                    let next = sortedFrames[slot]
                    return (prev.maxX + next.minX) / 2
                }
            }()
            RoundedRectangle(cornerRadius: 1)
                .fill(Color.accentColor.opacity(0.8))
                .frame(width: 2, height: 24)
                .position(x: xPos, y: geo.size.height / 2)
        }
        .allowsHitTesting(false)
    }

    // MARK: - Scroll Helpers

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
    nonisolated(unsafe) private var eventMonitor: Any?
    var onDoubleClickEmptyArea: (() -> Void)?

    deinit {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            installMonitorIfNeeded()
        } else {
            removeMonitor()
        }
    }

    private func removeMonitor() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }

    private func installMonitorIfNeeded() {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .leftMouseDown]) { [weak self] event in
            guard let self else { return event }
            return self.handle(event: event)
        }
    }

    private func handle(event: NSEvent) -> NSEvent? {
        guard event.window === self.window else { return event }
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

    func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(Color(nsColor: .windowBackgroundColor).ignoresSafeArea(.all, edges: .top))
        } else {
            content
                .glassEffect(.clear.tint(Color(nsColor: GlassTheme.chromeTint(for: themeColor, glassOpacity: glassOpacity))), in: .rect)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(GlassTheme.specularStroke.opacity(0.28))
                        .frame(height: 1)
                }
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(
                            LinearGradient(
                                colors: [Color.white.opacity(0.20), Color.clear],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .frame(height: 18)
                }
        }
    }
}

private struct TabItemButton: View {
    let tab: Tab
    let isActive: Bool
    var onSelected: (() -> Void)?
    var onClose: (() -> Void)?
    @State private var isHovering = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        HStack(spacing: 6) {
            Text(tab.title.isEmpty ? fallbackTitle : tab.title)
                .lineLimit(1)
                .font(.system(size: 12.5, weight: isActive ? .semibold : .medium, design: .rounded))
                .tracking(0.18)
                .foregroundStyle(isActive ? .primary : .secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            if tab.unreadNotifications > 0 {
                Text(tab.unreadNotifications > 99 ? "99+" : "\(tab.unreadNotifications)")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(
                        Capsule()
                            .fill(
                                Color.red
                            )
                    )
                    .overlay(
                        Capsule()
                            .stroke(Color.white.opacity(0.22), lineWidth: 1)
                    )
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
            .accessibilityIdentifier(AccessibilityID.TabBar.tabCloseButton(tab.id))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
        .frame(minWidth: 72, maxWidth: 180)
        .contentShape(Rectangle())
        .onTapGesture { onSelected?() }
        .modifier(TabChromeModifier(
            isActive: isActive,
            cornerRadius: 8,
            reduceTransparency: reduceTransparency
        ))
        .onHover { isHovering = $0 }
        .accessibilityIdentifier(AccessibilityID.TabBar.tab(tab.id))
        .accessibilityLabel(tab.title)
    }

    private var fallbackTitle: String {
        if case .browser(let url) = tab.content {
            return url.host() ?? url.absoluteString
        }
        return "Terminal"
    }
}
