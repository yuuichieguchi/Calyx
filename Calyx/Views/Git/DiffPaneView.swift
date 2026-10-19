import AppKit

@MainActor
enum DiffMetrics {
    static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    static let boldFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .bold)
    static let gutterFont = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
    static let gutterDigitWidth: CGFloat = ("0" as NSString).size(withAttributes: [.font: gutterFont]).width
    static let rowHeight: CGFloat = NSLayoutManager().defaultLineHeight(for: font)
    static let columnWidth: CGFloat = ("0" as NSString).size(withAttributes: [.font: font]).width
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

    static let commentSymbol: NSImage? = {
        let config = NSImage.SymbolConfiguration(pointSize: font.pointSize, weight: .regular)
            .applying(NSImage.SymbolConfiguration(hierarchicalColor: .systemBlue))
        return NSImage(systemSymbolName: "text.bubble", accessibilityDescription: "Comment")?
            .withSymbolConfiguration(config)
    }()

    static func collapsedLabel(hiddenCount: Int) -> String {
        "\u{22EF} \(hiddenCount) unchanged lines \u{22EF}"
    }
}

enum DiffGutterGeometry {
    static func labelY(rowFrame: CGRect, rowHeight: CGFloat, fontHeight: CGFloat) -> CGFloat {
        rowFrame.minY + (rowHeight - fontHeight) / 2
    }

    static func markerRect(rowFrame: CGRect, rowHeight: CGFloat, x: CGFloat, size: CGFloat) -> CGRect {
        CGRect(x: x, y: rowFrame.minY + (rowHeight - size) / 2, width: size, height: size)
    }

    static func rowsToDraw(geometry: DiffRowGeometry, offsetY: CGFloat, in rect: CGRect, bounds: CGRect) -> Range<Int> {
        let area = rect.intersection(bounds)
        guard !area.isNull, !area.isEmpty else { return 0..<0 }
        return geometry.rows(intersecting: area.minY - offsetY, area.maxY - offsetY)
    }
}

struct GutterRow: Equatable {
    let oldNumber: Int?
    let newNumber: Int?
    let kind: DiffCellKind?
    let displayIndex: Int?
    let lineIndex: Int?
    let indicator: String?
}

enum GutterColumns {
    case dual
    case single(DiffSide)

    var lineNumbers: [KeyPath<GutterRow, Int?>] {
        switch self {
        case .dual: [\.oldNumber, \.newNumber]
        case .single(.left): [\.oldNumber]
        case .single(.right): [\.newNumber]
        }
    }
}

struct GutterLayout: Equatable {
    static let markerLaneWidth: CGFloat = 22
    static let minimumDigits = 5
    static let columnGap: CGFloat = 4
    static let indicatorGap: CGFloat = 2
    static let trailingPadding: CGFloat = 4

    let numberRightEdges: [CGFloat]
    let indicatorX: CGFloat
    let thickness: CGFloat

    init(columns: GutterColumns, rows: [GutterRow], digitWidth: CGFloat) {
        let widths = columns.lineNumbers.map { number in
            let largest = rows.reduce(0) { max($0, $1[keyPath: number] ?? 0) }
            return (CGFloat(max(String(largest).count, Self.minimumDigits)) * digitWidth).rounded()
        }
        var edges: [CGFloat] = []
        var x = Self.markerLaneWidth
        for (index, columnWidth) in widths.enumerated() {
            if index > 0 { x += Self.columnGap }
            x += columnWidth
            edges.append(x)
        }
        numberRightEdges = edges
        indicatorX = x + Self.indicatorGap
        thickness = indicatorX + digitWidth.rounded(.up) + Self.trailingPadding
    }
}

enum CollapsedAction {
    case expandTop
    case expandBottom
    case expandAll
}

struct DiffPaneContent {
    let cells: [DiffCell?]
    let text: DiffPaneText
    let gutterRows: [GutterRow]
}

@MainActor
final class DiffPaneView: NSView, NSUserInterfaceValidations {
    let side: DiffSide
    let gutterColumns: GutterColumns
    let scrollView = NSScrollView()
    let linesView = DiffLinesView(frame: .zero)
    let lineNumberView: DiffLineNumberView

    var onRowClicked: ((Int) -> Void)?
    var onRangeSelected: ((Int, Int) -> Void)?
    var onCollapsedRowAction: ((Int, CollapsedAction) -> Void)?
    var onBecameFirstResponder: (() -> Void)?
    var onSelectionChanged: (() -> Void)?

    var wordWrap: Bool {
        didSet { scrollView.hasHorizontalScroller = !wordWrap }
    }

    var cells: [DiffCell?] { linesView.cells }

    init(side: DiffSide, gutterColumns: GutterColumns, accessibilitySuffix: String) {
        self.side = side
        self.gutterColumns = gutterColumns
        self.lineNumberView = DiffLineNumberView(columns: gutterColumns, linesView: linesView)
        self.wordWrap = DiffLayoutSettings.wordWrap
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

        scrollView.frame = bounds
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = !wordWrap
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.contentView.postsFrameChangedNotifications = true
        scrollView.documentView = linesView
        addSubview(scrollView)

        scrollView.rulersVisible = true
        scrollView.hasVerticalRuler = true
        scrollView.verticalRulerView = lineNumberView
        lineNumberView.clientView = linesView
        lineNumberView.ruleThickness = lineNumberView.gutterLayout.thickness
        lineNumberView.setAccessibilityElement(true)
        lineNumberView.setAccessibilityRole(.group)
        lineNumberView.setAccessibilityIdentifier(AccessibilityID.Diff.lineNumberGutter + accessibilitySuffix)

        linesView.textFinder.findBarContainer = scrollView

        lineNumberView.onRowClicked = { [weak self] row in self?.onRowClicked?(row) }
        lineNumberView.onRangeSelected = { [weak self] lo, hi in self?.onRangeSelected?(lo, hi) }
        lineNumberView.onCollapsedRowAction = { [weak self] row, action in
            self?.onCollapsedRowAction?(row, action)
        }
        linesView.onRowClicked = { [weak self] row in self?.onRowClicked?(row) }
        linesView.onBecameFirstResponder = { [weak self] in self?.onBecameFirstResponder?() }
        linesView.onSelectionChanged = { [weak self] in self?.onSelectionChanged?() }
    }

    static func wrappingColumn(textAreaWidth clipWidth: CGFloat, reservesLegacyScroller: Bool,
                               scrollerStyle: NSScroller.Style) -> Int {
        let legacy = reservesLegacyScroller ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) : 0
        let overlay = scrollerStyle == .overlay ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .overlay) : 0
        let contentWidth = clipWidth - legacy - 2 * DiffMetrics.textInset.width - DiffMetrics.columnWidth
        return max(1, Int(((contentWidth - overlay - 2) / DiffMetrics.columnWidth).rounded(.down)))
    }

    var textAreaWidth: CGFloat {
        DiffLinesView.textAreaWidth(of: scrollView.contentView)
    }

    var targetWrappingColumn: Int? {
        guard wordWrap, scrollView.frame.width > 0 else { return nil }
        let clipWidth = textAreaWidth
        let reservesLegacy = scrollView.scrollerStyle == .legacy && (scrollView.verticalScroller?.isHidden ?? true)
        return Self.wrappingColumn(textAreaWidth: clipWidth, reservesLegacyScroller: reservesLegacy,
                                   scrollerStyle: scrollView.scrollerStyle)
    }

    func tileForGeometry() {
        if scrollView.frame != bounds { scrollView.frame = bounds }
        scrollView.tile()
    }


    func setGutter(rows: [GutterRow], commentedLineIndices: Set<Int>) {
        lineNumberView.rows = rows
        lineNumberView.commentedLineIndices = commentedLineIndices
        lineNumberView.needsDisplay = true
    }

    func apply(content: DiffPaneContent, wrap: DiffPaneWrap, geometry: DiffRowGeometry,
               textChanged: Bool, rewrapped: Bool) {
        linesView.apply(DiffPaneLayout(cells: content.cells, text: content.text, wrap: wrap, geometry: geometry),
                        textChanged: textChanged, rewrapped: rewrapped)
        lineNumberView.needsDisplay = true
    }


    func rowRect(_ row: Int) -> NSRect {
        let y = lineNumberView.convert(NSPoint(x: 0, y: linesView.geometry.rowTop(row)), from: linesView).y
        return NSRect(x: 0, y: y, width: lineNumberView.bounds.width, height: DiffMetrics.rowHeight)
    }

    var firstVisibleRow: Int? {
        let geometry = linesView.geometry
        let y = scrollView.documentVisibleRect.minY
        guard !cells.isEmpty, y >= geometry.rowTop(0), y < geometry.documentHeight else { return nil }
        return geometry.row(atY: y)
    }

    func scroll(toY y: CGFloat) {
        let clip = scrollView.contentView
        let x = wordWrap ? -clip.contentInsets.left : clip.bounds.origin.x
        let proposed = NSRect(origin: NSPoint(x: x, y: y), size: clip.bounds.size)
        clip.scroll(to: clip.constrainBoundsRect(proposed).origin)
        scrollView.reflectScrolledClipView(clip)
    }

    func scrollToTop() {
        let clip = scrollView.contentView
        let origin = NSPoint(x: -clip.contentInsets.left, y: -clip.contentInsets.top)
        clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size)).origin)
        scrollView.reflectScrolledClipView(clip)
    }

    func scrollToRow(_ row: Int) {
        let geometry = linesView.geometry
        scroll(toY: row < geometry.rowCount ? geometry.rowTop(row) : 0)
    }

    func viewportStart() -> DiffViewportStart? {
        DiffStableViewport.capture(scrollY: scrollView.documentVisibleRect.minY, geometry: linesView.geometry,
                                   projections: linesView.projections)
    }

    func scrollY(for start: DiffViewportStart) -> CGFloat {
        DiffStableViewport.recover(start, geometry: linesView.geometry, projections: linesView.projections)
    }

    var visibleRowRange: Range<Int> {
        let rect = scrollView.documentVisibleRect
        guard !cells.isEmpty, rect.height > 0 else { return 0..<0 }
        return linesView.geometry.rows(intersecting: rect.minY, rect.maxY)
    }

    var rowIndexAtViewportCentre: Int? {
        guard !cells.isEmpty else { return nil }
        return linesView.geometry.row(atY: scrollView.documentVisibleRect.midY)
    }

    var selectionStartRow: Int? {
        guard !cells.isEmpty else { return nil }
        return linesView.row(containingCharacterAt: linesView.selectedRange().location)
    }

    func placeInsertionPoint(atRow row: Int) {
        guard row < linesView.rowRanges.count else { return }
        linesView.setSelectedRange(NSRange(location: linesView.rowRanges[row].location, length: 0))
    }

    func clearSelection() {
        linesView.setSelectedRange(NSRange(location: linesView.selectedRange().location, length: 0))
    }

    func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(performTextFinderAction(_:)), #selector(performFindPanelAction(_:)):
            guard let action = NSTextFinder.Action(rawValue: item.tag) else { return false }
            return linesView.textFinder.validateAction(action)
        case #selector(performFindAction(_:)):
            return linesView.textFinder.validateAction(.showFindInterface)
        case #selector(findNext(_:)):
            return linesView.textFinder.validateAction(.nextMatch)
        case #selector(findPrevious(_:)):
            return linesView.textFinder.validateAction(.previousMatch)
        default:
            return false
        }
    }

    override func performTextFinderAction(_ sender: Any?) {
        guard let tag = (sender as? NSValidatedUserInterfaceItem)?.tag,
              let action = NSTextFinder.Action(rawValue: tag) else { return }
        linesView.textFinder.performAction(action)
    }

    @objc func performFindPanelAction(_ sender: Any?) {
        performTextFinderAction(sender)
    }

    @objc func performFindAction(_ sender: Any?) {
        linesView.textFinder.performAction(.showFindInterface)
    }

    @objc func findNext(_ sender: Any?) {
        linesView.textFinder.performAction(.nextMatch)
    }

    @objc func findPrevious(_ sender: Any?) {
        linesView.textFinder.performAction(.previousMatch)
    }
}


@MainActor
final class DiffLineNumberView: NSRulerView {
    let columns: GutterColumns
    let linesView: DiffLinesView
    var rows: [GutterRow] = [] {
        didSet { updateGutterLayout() }
    }
    private(set) var gutterLayout: GutterLayout
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

    init(columns: GutterColumns, linesView: DiffLinesView) {
        self.columns = columns
        self.linesView = linesView
        self.gutterLayout = GutterLayout(columns: columns, rows: [], digitWidth: DiffMetrics.gutterDigitWidth)
        super.init(scrollView: nil, orientation: .verticalRuler)
        clipsToBounds = true
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var requiredThickness: CGFloat { gutterLayout.thickness }

    private func updateGutterLayout() {
        let layout = GutterLayout(columns: columns, rows: rows, digitWidth: DiffMetrics.gutterDigitWidth)
        guard layout != gutterLayout else { return }
        gutterLayout = layout
        ruleThickness = layout.thickness
        scrollView?.tile()
        needsDisplay = true
    }

    private var offsetY: CGFloat {
        convert(NSPoint.zero, from: linesView).y
    }

    private func rowFrame(_ row: Int, offsetY: CGFloat) -> CGRect {
        let geometry = linesView.geometry
        return CGRect(x: 0, y: geometry.rowTop(row) + offsetY, width: bounds.width, height: geometry.rowHeight(row))
    }

    func rowsToDraw(in rect: CGRect) -> Range<Int> {
        DiffGutterGeometry.rowsToDraw(geometry: linesView.geometry, offsetY: offsetY, in: rect, bounds: bounds)
            .clamped(to: 0..<rows.count)
    }

    private func row(at point: NSPoint) -> Int? {
        guard !rows.isEmpty else { return nil }
        let geometry = linesView.geometry
        let y = point.y - offsetY
        guard y >= geometry.rowTop(0), y < geometry.documentHeight else { return nil }
        let row = geometry.row(atY: y)
        return row < rows.count ? row : nil
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
        drawHashMarksAndLabels(in: dirtyRect)
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard !rows.isEmpty else { return }
        let offset = offsetY
        let numberAttrs: [NSAttributedString.Key: Any] = [
            .font: DiffMetrics.gutterFont,
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let dragRange: ClosedRange<Int>? = {
            guard let s = dragStartRow, let c = dragCurrentRow else { return nil }
            return min(s, c)...max(s, c)
        }()

        for index in rowsToDraw(in: rect) {
            let gutterRow = rows[index]
            let rowRect = rowFrame(index, offsetY: offset)

            if let dragRange, dragRange.contains(index) {
                NSColor.systemBlue.withAlphaComponent(0.15).setFill()
                rowRect.fill()
            }

            switch gutterRow.kind {
            case .comment:
                NSColor.systemBlue.withAlphaComponent(0.15).setFill()
                NSRect(x: 0, y: rowRect.minY, width: bounds.width - 1, height: rowRect.height).fill()
            case .collapsedRegion:
                DiffMetrics.collapsedBackground.setFill()
                rowRect.fill()
                drawCollapsedAffordances(midY: rowRect.midY)
            case .line:
                drawLineRow(gutterRow, index: index, rowFrame: rowRect, attrs: numberAttrs)
            case .filler, .banner, .none:
                break
            }
        }
    }

    private func drawLineRow(_ gutterRow: GutterRow, index: Int, rowFrame: CGRect,
                             attrs: [NSAttributedString.Key: Any]) {
        let height = DiffMetrics.rowHeight
        if let lineIndex = gutterRow.lineIndex, commentedLineIndices.contains(lineIndex) {
            NSColor.systemBlue.setFill()
            let dot = DiffGutterGeometry.markerRect(rowFrame: rowFrame, rowHeight: height, x: 4, size: 6)
            NSBezierPath(ovalIn: dot).fill()
        } else if Self.isCommentable(gutterRow.kind) && hoveredRow == index {
            let btnRect = DiffGutterGeometry.markerRect(rowFrame: rowFrame, rowHeight: height, x: 2,
                                                        size: min(16, height))
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

        let numberY = DiffGutterGeometry.labelY(rowFrame: rowFrame, rowHeight: height,
                                                fontHeight: DiffMetrics.gutterFont.boundingRectForFont.height)
        func drawNumber(_ number: Int?, rightEdge: CGFloat) {
            guard let number else { return }
            let str = "\(number)" as NSString
            let size = str.size(withAttributes: attrs)
            str.draw(at: NSPoint(x: rightEdge - size.width, y: numberY), withAttributes: attrs)
        }
        for (number, rightEdge) in zip(columns.lineNumbers, gutterLayout.numberRightEdges) {
            drawNumber(gutterRow[keyPath: number], rightEdge: rightEdge)
        }

        if let indicator = gutterRow.indicator {
            let color: NSColor = indicator == "+" ? .systemGreen : .systemRed
            let indicatorAttrs: [NSAttributedString.Key: Any] = [
                .font: DiffMetrics.gutterFont,
                .foregroundColor: color,
            ]
            (indicator as NSString).draw(at: NSPoint(x: gutterLayout.indicatorX, y: numberY), withAttributes: indicatorAttrs)
        }
    }

    private static let affordances: [(glyph: String, action: CollapsedAction)] = [
        ("\u{25B2}", .expandTop),
        ("\u{25BC}", .expandBottom),
        ("\u{2195}", .expandAll),
    ]

    private var affordanceWidth: CGFloat { bounds.width / CGFloat(Self.affordances.count) }

    private func drawCollapsedAffordances(midY: CGFloat) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        for (i, item) in Self.affordances.enumerated() {
            let str = item.glyph as NSString
            let size = str.size(withAttributes: attrs)
            let x = CGFloat(i) * affordanceWidth + (affordanceWidth - size.width) / 2
            str.draw(at: NSPoint(x: x, y: midY - size.height / 2), withAttributes: attrs)
        }
    }

    private func collapsedAction(atX x: CGFloat) -> CollapsedAction {
        let zone = min(max(Int(x / affordanceWidth), 0), Self.affordances.count - 1)
        return Self.affordances[zone].action
    }

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
        guard dragStartRow != nil, !rows.isEmpty else { return }
        let point = convert(event.locationInWindow, from: nil)
        let row = linesView.geometry.row(atY: point.y - offsetY)
        dragCurrentRow = min(row, rows.count - 1)
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
