// DiffPaneView.swift
// Calyx
//
// One side of the diff view: a scroll view holding a `DiffTextView` and a
// `DiffLineNumberView` ruler. Every row has the same height, so row
// geometry and hit-testing are arithmetic (`inset + row * rowHeight`).
// Decorations follow VS Code's diffEditorDecorations.ts: full-row
// deletion/addition backgrounds, stronger inner-change backgrounds, a thin
// marker for empty inner changes, -/+ gutter indicators, hatched filler
// rows and a flat band for collapsed unchanged regions.

import AppKit

/// Shared fonts, colours and row metrics of the diff panes.
@MainActor
enum DiffMetrics {
    static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    static let boldFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .bold)
    static let gutterFont = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
    static let rowHeight: CGFloat = NSLayoutManager().defaultLineHeight(for: font)
    static let textInset = NSSize(width: 4, height: 4)

    static let deletionLineBackground = NSColor.systemRed.withAlphaComponent(0.08)
    static let additionLineBackground = NSColor.systemGreen.withAlphaComponent(0.08)
    static let deletionInnerBackground = NSColor.systemRed.withAlphaComponent(0.28)
    static let additionInnerBackground = NSColor.systemGreen.withAlphaComponent(0.28)
    static let deletionMarker = NSColor.systemRed.withAlphaComponent(0.8)
    static let additionMarker = NSColor.systemGreen.withAlphaComponent(0.8)
    static let commentBackground = NSColor.systemBlue.withAlphaComponent(0.08)
    static let collapsedBackground = NSColor.secondaryLabelColor.withAlphaComponent(0.08)
    static let bannerBackground = NSColor.systemOrange.withAlphaComponent(0.1)
    static let fillerHatch = NSColor.secondaryLabelColor.withAlphaComponent(0.18)

    /// Paragraph style that pins every row to `rowHeight`.
    static let rowParagraphStyle: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = rowHeight
        style.maximumLineHeight = rowHeight
        return style
    }()

    static func collapsedLabel(hiddenCount: Int) -> String {
        "\u{22EF} \(hiddenCount) unchanged lines \u{22EF}"
    }
}

/// One gutter row; parallel to the pane's cells.
struct GutterRow: Equatable {
    let oldNumber: Int?
    let newNumber: Int?
    let kind: DiffCellKind?
    let displayIndex: Int?
    let lineIndex: Int?
    /// "-" / "+" on changed lines (VS Code `renderIndicators`).
    let indicator: String?
}

enum GutterColumns {
    /// Old and new numbers (inline, 80 pt).
    case dual
    /// One number column (side-by-side, 44 pt).
    case single

    var thickness: CGFloat {
        switch self {
        case .dual: return 80
        case .single: return 44
        }
    }
}

enum CollapsedAction {
    case expandTop
    case expandBottom
    case expandAll
}

@MainActor
final class DiffPaneView: NSView {
    let side: DiffSide
    let gutterColumns: GutterColumns
    let scrollView = NSScrollView()
    let textView = DiffTextView()
    let lineNumberView: DiffLineNumberView

    var onRowClicked: ((Int) -> Void)?
    var onRangeSelected: ((Int, Int) -> Void)?
    var onCollapsedRowAction: ((Int, CollapsedAction) -> Void)?
    /// The text view became first responder (used to clear the other pane's selection).
    var onBecameFirstResponder: (() -> Void)?

    private(set) var cells: [DiffCell?] = []

    init(side: DiffSide, gutterColumns: GutterColumns, accessibilitySuffix: String) {
        self.side = side
        self.gutterColumns = gutterColumns
        self.lineNumberView = DiffLineNumberView(columns: gutterColumns)
        super.init(frame: .zero)
        setupViews(accessibilitySuffix: accessibilitySuffix)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func setupViews(accessibilitySuffix: String) {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.contentView.postsBoundsChangedNotifications = true
        addSubview(scrollView)

        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.usesFindBar = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainerInset = DiffMetrics.textInset
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.drawsBackground = false
        textView.font = DiffMetrics.font
        textView.defaultParagraphStyle = DiffMetrics.rowParagraphStyle
        textView.typingAttributes = [
            .font: DiffMetrics.font,
            .paragraphStyle: DiffMetrics.rowParagraphStyle,
        ]
        scrollView.documentView = textView

        scrollView.rulersVisible = true
        scrollView.hasVerticalRuler = true
        scrollView.verticalRulerView = lineNumberView
        lineNumberView.clientView = textView
        lineNumberView.ruleThickness = gutterColumns.thickness
        lineNumberView.setAccessibilityElement(true)
        lineNumberView.setAccessibilityRole(.group)
        lineNumberView.setAccessibilityIdentifier(AccessibilityID.Diff.lineNumberGutter + accessibilitySuffix)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        NotificationCenter.default.addObserver(
            self, selector: #selector(textViewFrameDidChange(_:)),
            name: NSView.frameDidChangeNotification, object: textView
        )

        lineNumberView.onRowClicked = { [weak self] row in self?.onRowClicked?(row) }
        lineNumberView.onRangeSelected = { [weak self] lo, hi in self?.onRangeSelected?(lo, hi) }
        lineNumberView.onCollapsedRowAction = { [weak self] row, action in
            self?.onCollapsedRowAction?(row, action)
        }
        textView.onRowClicked = { [weak self] row in self?.onRowClicked?(row) }
        textView.onBecameFirstResponder = { [weak self] in self?.onBecameFirstResponder?() }
    }

    override func layout() {
        super.layout()
        // Keep the document at least as wide as the viewport so full-row
        // backgrounds and filler hatching span the visible width.
        let width = scrollView.contentSize.width
        if textView.minSize.width != width {
            textView.minSize = NSSize(width: width, height: 0)
            textView.sizeToFit()
        }
    }

    @objc private func textViewFrameDidChange(_ notification: Notification) {
        lineNumberView.needsDisplay = true
    }

    // MARK: Content

    /// `cells`, the attributed string's rows (joined with "\n") and
    /// `gutterRows` must have the same count.
    func setRows(cells: [DiffCell?], attributed: NSAttributedString, gutterRows: [GutterRow]) {
        self.cells = cells
        textView.setRows(cells: cells, attributed: attributed)
        lineNumberView.rows = gutterRows
        lineNumberView.needsDisplay = true
    }

    /// Plain message without rows (binary files).
    func showMessage(_ attributed: NSAttributedString) {
        cells = []
        textView.setRows(cells: [], attributed: attributed)
        lineNumberView.rows = []
        lineNumberView.needsDisplay = true
    }

    func setCommentedLineIndices(_ indices: Set<Int>) {
        lineNumberView.commentedLineIndices = indices
    }

    // MARK: Geometry

    /// Row rect in the gutter's coordinates (popover anchor).
    func rowRect(_ row: Int) -> NSRect {
        NSRect(x: 0, y: lineNumberView.rowMinY(row),
               width: lineNumberView.bounds.width, height: DiffMetrics.rowHeight)
    }

    /// Row at a y coordinate of the text view, nil outside the rows.
    func rowIndex(atY y: CGFloat) -> Int? {
        textView.rowIndex(atY: y)
    }

    var firstVisibleRow: Int? {
        rowIndex(atY: scrollView.documentVisibleRect.minY)
    }

    func scrollToRow(_ row: Int) {
        let clip = scrollView.contentView
        let docHeight = textView.frame.height
        let maxY = max(docHeight - clip.bounds.height, 0)
        let y = min(DiffTextView.rowMinY(row), maxY)
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
        scrollView.reflectScrolledClipView(clip)
    }

    func clearSelection() {
        let location = textView.selectedRange().location
        textView.setSelectedRange(NSRange(location: min(location, textView.string.utf16.count), length: 0))
    }
}

// MARK: - DiffTextView

@MainActor
final class DiffTextView: NSTextView {
    /// Called when a comment or collapsed row is clicked in the text.
    var onRowClicked: ((Int) -> Void)?
    var onBecameFirstResponder: (() -> Void)?

    private(set) var cells: [DiffCell?] = []
    /// UTF-16 range of each row's text (without the trailing "\n").
    private var rowRanges: [NSRange] = []

    static func rowMinY(_ row: Int) -> CGFloat {
        DiffMetrics.textInset.height + CGFloat(row) * DiffMetrics.rowHeight
    }

    func setRows(cells: [DiffCell?], attributed: NSAttributedString) {
        self.cells = cells
        var ranges: [NSRange] = []
        ranges.reserveCapacity(cells.count)
        let string = attributed.string as NSString
        var location = 0
        if !cells.isEmpty {
            while true {
                let newline = string.range(of: "\n", options: .literal,
                                           range: NSRange(location: location, length: string.length - location))
                if newline.location == NSNotFound {
                    ranges.append(NSRange(location: location, length: string.length - location))
                    break
                }
                ranges.append(NSRange(location: location, length: newline.location - location))
                location = newline.location + 1
            }
        }
        rowRanges = ranges
        textStorage?.setAttributedString(attributed)
        needsDisplay = true
    }

    func rowIndex(atY y: CGFloat) -> Int? {
        let row = Int(floor((y - DiffMetrics.textInset.height) / DiffMetrics.rowHeight))
        guard row >= 0, row < cells.count else { return nil }
        return row
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onBecameFirstResponder?() }
        return accepted
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let row = rowIndex(atY: point.y), let cell = cells[row] {
            switch cell.kind {
            case .comment, .collapsedRegion:
                onRowClicked?(row)
                return
            case .line, .filler, .banner:
                break
            }
        }
        super.mouseDown(with: event)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let rows = visibleRows(in: dirtyRect)
        let fillX = dirtyRect.minX
        let fillWidth = dirtyRect.width
        for row in rows {
            guard let cell = cells[row] else { continue }
            let rect = NSRect(x: fillX, y: Self.rowMinY(row), width: fillWidth, height: DiffMetrics.rowHeight)
            switch cell.kind {
            case .line(.deletion):
                DiffMetrics.deletionLineBackground.setFill()
                rect.fill()
            case .line(.addition):
                DiffMetrics.additionLineBackground.setFill()
                rect.fill()
            case .comment:
                DiffMetrics.commentBackground.setFill()
                rect.fill()
            case .banner:
                DiffMetrics.bannerBackground.setFill()
                rect.fill()
            case .collapsedRegion:
                DiffMetrics.collapsedBackground.setFill()
                rect.fill()
            case .filler:
                drawHatch(in: rect)
            case .line:
                break
            }
        }

        super.draw(dirtyRect)

        for row in rows {
            guard let cell = cells[row] else { continue }
            switch cell.kind {
            case .collapsedRegion(_, let hiddenCount):
                drawCollapsedLabel(row: row, hiddenCount: hiddenCount)
            case .line(let type) where !cell.isWholeLineChange:
                drawEmptyInnerMarkers(row: row, cell: cell, type: type)
            default:
                break
            }
        }
    }

    private func visibleRows(in rect: NSRect) -> Range<Int> {
        guard !cells.isEmpty else { return 0..<0 }
        let height = DiffMetrics.rowHeight
        let inset = DiffMetrics.textInset.height
        let first = max(Int(floor((rect.minY - inset) / height)), 0)
        let last = min(Int(ceil((rect.maxY - inset) / height)), cells.count)
        guard first < last else { return 0..<0 }
        return first..<last
    }

    /// 45° hatch; lines satisfy x + y ≡ 0 (mod spacing) so they continue across rows.
    private func drawHatch(in rect: NSRect) {
        let spacing: CGFloat = 8
        NSGraphicsContext.saveGraphicsState()
        rect.clip()
        let path = NSBezierPath()
        path.lineWidth = 1
        var c = floor((rect.minX + rect.minY) / spacing) * spacing
        let end = rect.maxX + rect.maxY
        while c <= end {
            path.move(to: NSPoint(x: c - rect.minY, y: rect.minY))
            path.line(to: NSPoint(x: c - rect.maxY, y: rect.maxY))
            c += spacing
        }
        DiffMetrics.fillerHatch.setStroke()
        path.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawCollapsedLabel(row: Int, hiddenCount: Int) {
        let visible = enclosingScrollView?.documentVisibleRect ?? visibleRect
        let label = DiffMetrics.collapsedLabel(hiddenCount: hiddenCount) as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: DiffMetrics.font,
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let size = label.size(withAttributes: attrs)
        let y = Self.rowMinY(row) + (DiffMetrics.rowHeight - size.height) / 2
        label.draw(at: NSPoint(x: visible.midX - size.width / 2, y: y), withAttributes: attrs)
    }

    /// VS Code `diffInsertedDecorationEmpty` / `diffDeletedDecorationEmpty`.
    private func drawEmptyInnerMarkers(row: Int, cell: DiffCell, type: DiffLineType) {
        let empties = cell.innerRanges.filter { $0.length == 0 }
        guard !empties.isEmpty, row < rowRanges.count,
              let layoutManager, let textContainer else { return }
        let rowRange = rowRanges[row]
        let color: NSColor
        switch type {
        case .deletion: color = DiffMetrics.deletionMarker
        case .addition: color = DiffMetrics.additionMarker
        case .context, .hunkHeader, .meta: return
        }
        color.setFill()
        for range in empties where range.location <= rowRange.length {
            let x: CGFloat
            if range.location < rowRange.length {
                let glyph = layoutManager.glyphIndexForCharacter(at: rowRange.location + range.location)
                let rect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer)
                x = rect.minX
            } else if rowRange.length > 0 {
                let glyph = layoutManager.glyphIndexForCharacter(at: rowRange.location + rowRange.length - 1)
                let rect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer)
                x = rect.maxX
            } else {
                x = textContainer.lineFragmentPadding
            }
            NSRect(x: x + textContainerInset.width, y: Self.rowMinY(row),
                   width: 1, height: DiffMetrics.rowHeight).fill()
        }
    }
}

// MARK: - Line Number Ruler

@MainActor
final class DiffLineNumberView: NSRulerView {
    let columns: GutterColumns
    var rows: [GutterRow] = []
    /// Flat `[DiffLine]` indices that carry a comment (blue dot).
    var commentedLineIndices: Set<Int> = []
    var onRowClicked: ((Int) -> Void)?
    var onRangeSelected: ((Int, Int) -> Void)?
    var onCollapsedRowAction: ((Int, CollapsedAction) -> Void)?

    private var dragStartRow: Int?
    private var dragCurrentRow: Int?
    private var hoveredRow: Int? {
        didSet {
            if oldValue != hoveredRow { needsDisplay = true }
        }
    }
    private var trackingArea: NSTrackingArea?

    init(columns: GutterColumns) {
        self.columns = columns
        super.init(scrollView: nil, orientation: .verticalRuler)
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var requiredThickness: CGFloat { columns.thickness }

    /// y of a row's top edge in this view; the single formula used by
    /// drawing, hit-testing and `DiffPaneView.rowRect`.
    func rowMinY(_ row: Int) -> CGFloat {
        guard let clientView else { return DiffTextView.rowMinY(row) }
        return convert(NSPoint(x: 0, y: DiffTextView.rowMinY(row)), from: clientView).y
    }

    private func row(at point: NSPoint) -> Int? {
        guard !rows.isEmpty else { return nil }
        let origin = rowMinY(0)
        let row = Int(floor((point.y - origin) / DiffMetrics.rowHeight))
        guard row >= 0, row < rows.count else { return nil }
        return row
    }

    private func row(at event: NSEvent) -> Int? {
        row(at: convert(event.locationInWindow, from: nil))
    }

    private static func isCommentable(_ kind: DiffCellKind?) -> Bool {
        switch kind {
        case .line(.addition), .line(.deletion), .line(.context): return true
        default: return false
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea { removeTrackingArea(existing) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseExited(with event: NSEvent) {
        hoveredRow = nil
    }

    override func mouseMoved(with event: NSEvent) {
        hoveredRow = row(at: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        // Override default NSRulerView drawing entirely (no background, no border)
        drawHashMarksAndLabels(in: dirtyRect)
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard !rows.isEmpty else { return }
        let height = DiffMetrics.rowHeight
        let origin = rowMinY(0)
        let first = max(Int(floor((rect.minY - origin) / height)), 0)
        let last = min(Int(ceil((rect.maxY - origin) / height)), rows.count)
        guard first < last else { return }

        let numberAttrs: [NSAttributedString.Key: Any] = [
            .font: DiffMetrics.gutterFont,
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let dragRange: ClosedRange<Int>? = {
            guard let s = dragStartRow, let c = dragCurrentRow else { return nil }
            return min(s, c)...max(s, c)
        }()

        for index in first..<last {
            let gutterRow = rows[index]
            let y = origin + CGFloat(index) * height
            let rowRect = NSRect(x: 0, y: y, width: bounds.width, height: height)

            if let dragRange, dragRange.contains(index) {
                NSColor.systemBlue.withAlphaComponent(0.15).setFill()
                rowRect.fill()
            }

            switch gutterRow.kind {
            case .comment:
                NSColor.systemBlue.withAlphaComponent(0.15).setFill()
                NSRect(x: 0, y: y, width: bounds.width - 1, height: height).fill()
            case .collapsedRegion:
                DiffMetrics.collapsedBackground.setFill()
                rowRect.fill()
                drawCollapsedAffordances(y: y)
            case .line:
                drawLineRow(gutterRow, index: index, y: y, attrs: numberAttrs)
            case .filler, .banner, .none:
                break
            }
        }
    }

    private func drawLineRow(_ gutterRow: GutterRow, index: Int, y: CGFloat, attrs: [NSAttributedString.Key: Any]) {
        let height = DiffMetrics.rowHeight
        if let lineIndex = gutterRow.lineIndex, commentedLineIndices.contains(lineIndex) {
            NSColor.systemBlue.setFill()
            NSBezierPath(ovalIn: NSRect(x: 4, y: y + (height - 6) / 2, width: 6, height: 6)).fill()
        } else if Self.isCommentable(gutterRow.kind) && hoveredRow == index {
            // GitHub-style hover "+" button
            let btnSize: CGFloat = min(16, height)
            let btnRect = NSRect(x: 2, y: y + (height - btnSize) / 2, width: btnSize, height: btnSize)
            NSColor.systemBlue.setFill()
            NSBezierPath(roundedRect: btnRect, xRadius: 3, yRadius: 3).fill()
            let plusStr = "+" as NSString
            let plusAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12, weight: .bold),
                .foregroundColor: NSColor.white,
            ]
            let plusSize = plusStr.size(withAttributes: plusAttrs)
            plusStr.draw(at: NSPoint(x: btnRect.midX - plusSize.width / 2,
                                     y: btnRect.midY - plusSize.height / 2), withAttributes: plusAttrs)
        }

        let numberY = y + (height - DiffMetrics.gutterFont.boundingRectForFont.height) / 2
        func drawNumber(_ number: Int?, rightEdge: CGFloat) {
            guard let number else { return }
            let str = "\(number)" as NSString
            let size = str.size(withAttributes: attrs)
            str.draw(at: NSPoint(x: rightEdge - size.width, y: numberY), withAttributes: attrs)
        }
        let indicatorX: CGFloat
        switch columns {
        case .dual:
            drawNumber(gutterRow.oldNumber, rightEdge: 34)
            drawNumber(gutterRow.newNumber, rightEdge: 72)
            indicatorX = 73
        case .single:
            drawNumber(gutterRow.oldNumber ?? gutterRow.newNumber, rightEdge: 34)
            indicatorX = 36
        }

        if let indicator = gutterRow.indicator {
            let color: NSColor = indicator == "+" ? .systemGreen : .systemRed
            let indicatorAttrs: [NSAttributedString.Key: Any] = [
                .font: DiffMetrics.gutterFont,
                .foregroundColor: color,
            ]
            (indicator as NSString).draw(at: NSPoint(x: indicatorX, y: numberY), withAttributes: indicatorAttrs)
        }
    }

    // MARK: Collapsed region affordances (▲ show more above, ▼ show more below, ↕ show all)

    private static let affordances: [(glyph: String, action: CollapsedAction)] = [
        ("\u{25B2}", .expandTop),
        ("\u{25BC}", .expandBottom),
        ("\u{2195}", .expandAll),
    ]

    private var affordanceWidth: CGFloat { bounds.width / CGFloat(Self.affordances.count) }

    private func drawCollapsedAffordances(y: CGFloat) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        for (i, item) in Self.affordances.enumerated() {
            let str = item.glyph as NSString
            let size = str.size(withAttributes: attrs)
            let x = CGFloat(i) * affordanceWidth + (affordanceWidth - size.width) / 2
            str.draw(at: NSPoint(x: x, y: y + (DiffMetrics.rowHeight - size.height) / 2), withAttributes: attrs)
        }
    }

    private func collapsedAction(atX x: CGFloat) -> CollapsedAction {
        let zone = min(max(Int(x / affordanceWidth), 0), Self.affordances.count - 1)
        return Self.affordances[zone].action
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let index = row(at: point) {
            switch rows[index].kind {
            case .collapsedRegion:
                onCollapsedRowAction?(index, collapsedAction(atX: point.x))
                return
            case .comment:
                onRowClicked?(index)
                return
            case let kind where Self.isCommentable(kind):
                dragStartRow = index
                dragCurrentRow = index
                needsDisplay = true
                return
            default:
                break
            }
        }
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragStartRow != nil else { return }
        let point = convert(event.locationInWindow, from: nil)
        let origin = rowMinY(0)
        let raw = Int(floor((point.y - origin) / DiffMetrics.rowHeight))
        dragCurrentRow = min(max(raw, 0), rows.count - 1)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let start = dragStartRow else {
            super.mouseUp(with: event)
            return
        }
        let current = dragCurrentRow ?? start
        let lo = min(start, current)
        let hi = max(start, current)
        dragStartRow = nil
        dragCurrentRow = nil
        needsDisplay = true

        if lo == hi {
            onRowClicked?(lo)
        } else {
            onRangeSelected?(lo, hi)
        }
    }
}
