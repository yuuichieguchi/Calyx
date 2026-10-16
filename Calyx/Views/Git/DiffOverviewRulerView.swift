// DiffOverviewRulerView.swift
// Calyx
//
// The diff view's overview ruler (VS Code overviewRulerFeature.ts): a
// 30 pt strip at the trailing edge with the original zones in the left
// 15 pt column, the modified zones in the right column and a translucent
// viewport slider. Pressing or dragging scrolls the panes so the row under
// the pointer is centred.

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
    var rowCount = 0 {
        didSet { needsDisplay = true }
    }
    /// First visible row and number of visible rows of the active pane.
    var visibleRows: (first: Int, count: Int) = (0, 0) {
        didSet {
            guard visibleRows != oldValue else { return }
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
        guard rowCount > 0 else { return }
        let scale = bounds.height / CGFloat(rowCount)
        let column = DiffOverviewRuler.columnWidth
        func fill(_ ranges: [Range<Int>], x: CGFloat, color: NSColor) {
            color.setFill()
            for range in ranges {
                let height = max(CGFloat(range.count) * scale, DiffOverviewRuler.minimumMarkHeight)
                NSRect(x: x, y: CGFloat(range.lowerBound) * scale, width: column, height: height).fill()
            }
        }
        fill(zones.original, x: 0, color: Self.removedColor)
        fill(zones.modified, x: column, color: Self.insertedColor)

        let slider = DiffOverviewRuler.viewport(firstVisibleRow: visibleRows.first, visibleRows: visibleRows.count,
                                                rowCount: rowCount, height: bounds.height)
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
        guard rowCount > 0, bounds.height > 0 else { return }
        let y = convert(event.locationInWindow, from: nil).y
        let row = Int(floor(y / bounds.height * CGFloat(rowCount)))
        onRevealRow?(min(max(row, 0), rowCount - 1))
    }
}
