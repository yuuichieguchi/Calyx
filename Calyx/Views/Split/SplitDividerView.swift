// SplitDividerView.swift
// Calyx
//
// NSView subclass for the split divider line with drag handling.

import AppKit
import SwiftUI

@MainActor
class SplitDividerView: NSView {

    let direction: SplitDirection
    var onRatioChange: ((Double) -> Void)?

    private var isDragging = false
    private var dragStartPoint: CGPoint = .zero
    private var dragStartRatio: Double = 0

    private let visibleThickness: CGFloat = 1
    private let hitAreaThickness: CGFloat = 7

    private let glassHost: PassThroughHostingView<SplitDividerGlassStrip>

    init(direction: SplitDirection) {
        self.direction = direction
        self.glassHost = PassThroughHostingView(rootView: SplitDividerGlassStrip())
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(glassHost)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: - Layout

    var thickness: CGFloat { hitAreaThickness }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        switch direction {
        case .horizontal:
            glassHost.frame = CGRect(
                x: (bounds.width - visibleThickness) / 2,
                y: 0,
                width: visibleThickness,
                height: bounds.height
            )
        case .vertical:
            glassHost.frame = CGRect(
                x: 0,
                y: (bounds.height - visibleThickness) / 2,
                width: bounds.width,
                height: visibleThickness
            )
        }
    }

    // MARK: - Cursor

    override func resetCursorRects() {
        let cursor: NSCursor = direction == .horizontal ? .resizeLeftRight : .resizeUpDown
        addCursorRect(bounds, cursor: cursor)
    }

    // MARK: - Mouse Handling

    override func mouseDown(with event: NSEvent) {
        isDragging = true
        dragStartPoint = convert(event.locationInWindow, from: nil)
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging else { return }
        guard let superview else { return }

        let currentPoint = convert(event.locationInWindow, from: nil)
        let parentSize = superview.bounds.size

        let delta: CGFloat
        let totalSize: CGFloat

        switch direction {
        case .horizontal:
            delta = currentPoint.x - dragStartPoint.x
            totalSize = parentSize.width
        case .vertical:
            delta = currentPoint.y - dragStartPoint.y
            totalSize = parentSize.height
        }

        guard totalSize > 0 else { return }
        let ratioDelta = delta / totalSize
        onRatioChange?(ratioDelta)
        dragStartPoint = currentPoint
    }

    override func mouseUp(with event: NSEvent) {
        isDragging = false
    }
}

private struct SplitDividerGlassStrip: View {
    @AppStorage("terminalGlassOpacity") private var glassOpacity: Double = 0.7
    @AppStorage("themeColorPreset") private var themePreset: String = "original"
    @AppStorage("themeColorCustomHex") private var customHex: String = "#050D1C"
    @State private var ghosttyProvider = GhosttyThemeProvider.shared

    private var themeColor: NSColor {
        ThemeColorPreset.resolve(
            preset: themePreset,
            customHex: customHex,
            ghosttyBackground: ghosttyProvider.ghosttyBackground
        )
    }

    var body: some View {
        Color.clear
            .glassEffect(
                .clear.tint(Color(nsColor: GlassTheme.chromeTint(for: themeColor, glassOpacity: glassOpacity))),
                in: .rect
            )
            .opacity(0.5)
            .allowsHitTesting(false)
    }
}

private final class PassThroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    required init(rootView: Content) {
        super.init(rootView: rootView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}
