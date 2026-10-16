// DiffOverviewRulerView.swift
// Calyx
//
// The diff view's overview ruler (VS Code overviewRulerFeature.ts): a
// 30 pt strip at the trailing edge with the original zones in the left
// 15 pt column, the modified zones in the right column and a translucent
// viewport slider. Geometry is in pixels (rows may wrap). Pressing or
// dragging scrolls the panes so the row under the pointer is centred.

import AppKit

@MainActor
final class DiffOverviewRulerView: NSView {
    /// VS Code `diffEditor.removedTextBackground` with doubled alpha.
    static let removedColor = NSColor.systemRed.withAlphaComponent(0.4)
    /// VS Code `diffEditor.insertedTextBackground` with doubled alpha.
    static let insertedColor = NSColor.systemGreen.withAlphaComponent(0.4)
    static let sliderFill = NSColor.secondaryLabelColor.withAlphaComponent(0.1)
    static let sliderBorder = NSColor.secondaryLabelColor.withAlphaComponent(0.1)

    var zones = DiffOverviewZones(original: [], modified: []) {
        didSet { needsDisplay = true }
    }
    /// Top of each row in document coordinates (text inset excluded) of
    /// the active pane; rows have measured, possibly wrapped heights.
    var rowOffsets: [CGFloat] = [] {
        didSet { needsDisplay = true }
    }
    /// Height of all rows (text inset excluded).
    var documentHeight: CGFloat = 0 {
        didSet { needsDisplay = true }
    }
    /// Visible part of the document, in the same coordinates as `rowOffsets`.
    var viewportRect: CGRect = .zero {
        didSet {
            guard viewportRect != oldValue else { return }
            needsDisplay = true
        }
    }
    /// The row under the pointer while pressing / dragging.
    var onRevealRow: ((Int) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Overview ruler")
        setAccessibilityIdentifier(AccessibilityID.Diff.overviewRuler)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard documentHeight > 0, !rowOffsets.isEmpty else { return }
        let scale = bounds.height / documentHeight
        let column = DiffOverviewRuler.columnWidth
        let offsets = rowOffsets
        let total = documentHeight
        func top(_ row: Int) -> CGFloat { row < offsets.count ? offsets[row] : total }
        func fill(_ ranges: [Range<Int>], x: CGFloat, color: NSColor) {
            color.setFill()
            for range in ranges {
                let minY = top(range.lowerBound)
                let height = max((top(range.upperBound) - minY) * scale, DiffOverviewRuler.minimumMarkHeight)
                NSRect(x: x, y: minY * scale, width: column, height: height).fill()
            }
        }
        fill(zones.original, x: 0, color: Self.removedColor)
        fill(zones.modified, x: column, color: Self.insertedColor)

        let slider = DiffOverviewRuler.viewport(visibleRect: viewportRect, documentHeight: documentHeight,
                                                height: bounds.height)
        let rect = NSRect(x: 0, y: slider.minY, width: bounds.width, height: slider.height)
        Self.sliderFill.setFill()
        rect.fill()
        Self.sliderBorder.setStroke()
        let border = NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5))
        border.lineWidth = 1
        border.stroke()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        reveal(event)
    }

    override func mouseDragged(with event: NSEvent) {
        reveal(event)
    }

    private func reveal(_ event: NSEvent) {
        guard !rowOffsets.isEmpty, documentHeight > 0, bounds.height > 0 else { return }
        let y = convert(event.locationInWindow, from: nil).y
        let documentY = y / bounds.height * documentHeight
        onRevealRow?(DiffOverviewRuler.rowIndex(atDocumentY: documentY, rowOffsets: rowOffsets))
    }
}
