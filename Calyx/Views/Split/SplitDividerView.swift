// SplitDividerView.swift
// Calyx
//
// NSView subclass for the split divider line with drag handling.

import AppKit
import SwiftUI

@MainActor
class SplitDividerView: NSView {

    let direction: SplitDirection
    var onTargetRatioChange: ((Double) -> Void)?

    /// The rect (in our superview's coordinate space) that the SPLIT this
    /// divider belongs to occupies. For a root-level split this equals the
    /// container's bounds; for a nested split it's the sub-rect carved out
    /// for that subtree. Drag math is performed RELATIVE to this rect so
    /// that nested dividers don't accidentally interpret cursor positions
    /// in the whole-container coordinate space (Bug C).
    ///
    /// Defaults to `.zero` — callers that don't set it fall back to
    /// `superview.bounds` to preserve the original semantics for top-level
    /// splits and to keep existing fixtures working.
    var containingRect: CGRect = .zero

    private var isDragging = false

    private let visibleThickness: CGFloat = 1
    private let hitAreaThickness: CGFloat = 7

    private let glassHost: PassThroughHostingView<SplitDividerGlassStrip>

    init(direction: SplitDirection) {
        self.direction = direction
        self.glassHost = PassThroughHostingView(rootView: SplitDividerGlassStrip())
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(glassHost)
        // Expose as splitter to AppKit accessibility so UI tests (and screen
        // readers) can identify split divider geometry.
        setAccessibilityRole(.splitter)
        setAccessibilityElement(true)
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
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging, let superview else { return }

        // Read the cursor in the superview's coordinate space — that anchor
        // is immune to our own frame shifting during the layout-pass round-trip.
        let point = superview.convert(event.locationInWindow, from: nil)
        guard let ratio = ratio(forSuperviewPoint: point, superview: superview) else { return }
        onTargetRatioChange?(ratio)
    }

    override func mouseUp(with event: NSEvent) {
        isDragging = false
    }

    /// AppKit removes a view from its window when it's detached. If a drag
    /// was in flight we'd otherwise leak `isDragging == true` and the next
    /// stray mouseDragged that AppKit routes our way would mutate the tree
    /// even though the user lifted nothing — defensive cleanup (Bug F).
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil {
            isDragging = false
        }
    }

    /// Compute the absolute target ratio in [0, 1] for a cursor at
    /// `superviewPoint` (in `superview`'s coordinate space). Uses
    /// `containingRect` when it has positive width AND height so that
    /// nested-split dividers interpret the cursor RELATIVE to their own
    /// sub-rect; otherwise falls back to `superview.bounds`.
    private func ratio(forSuperviewPoint superviewPoint: NSPoint, superview: NSView) -> Double? {
        let rect: CGRect
        if containingRect.width > 0 && containingRect.height > 0 {
            rect = containingRect
        } else {
            rect = superview.bounds
        }
        switch direction {
        case .horizontal:
            guard rect.width > 0 else { return nil }
            return Double((superviewPoint.x - rect.minX) / rect.width)
        case .vertical:
            guard rect.height > 0 else { return nil }
            return Double((superviewPoint.y - rect.minY) / rect.height)
        }
    }

    #if DEBUG
    /// Test-only: bypasses the NSEvent path because XCTest cannot reliably
    /// attach a live NSWindow. Runs the same math as `mouseDragged`.
    func _testSimulateDrag(toSuperviewPoint point: NSPoint) {
        guard let superview else { return }
        guard let ratio = ratio(forSuperviewPoint: point, superview: superview) else { return }
        onTargetRatioChange?(ratio)
    }
    #endif
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
        let tint: NSColor
        if let configColor = ghosttyProvider.splitDividerColor {
            tint = configColor
        } else {
            tint = GlassTheme.chromeTint(for: themeColor, glassOpacity: glassOpacity)
        }
        return Color.clear
            .glassEffect(.clear.tint(Color(nsColor: tint)), in: .rect)
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
