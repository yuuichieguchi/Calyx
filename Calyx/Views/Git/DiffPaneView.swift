// DiffPaneView.swift
// Calyx
//
// One side of the diff view: a scroll view holding a `DiffTextView` and a
// `DiffLineNumberView` ruler. Row geometry is measured: each row's frame
// comes from the TextKit 1 layout manager (a wrapped row spans several
// line fragments; an alignment pad adds paragraph spacing to a row).
// Decorations follow VS Code's diffEditorDecorations.ts: full-row
// deletion/addition backgrounds, stronger inner-change backgrounds, a thin
// marker for empty inner changes, -/+ gutter indicators, hatched filler
// rows and alignment pads, and a flat band for collapsed unchanged regions.

import AppKit

/// Shared fonts, colours and row metrics of the diff panes.
@MainActor
enum DiffMetrics {
    static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    static let boldFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .bold)
    static let gutterFont = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
    static let rowHeight: CGFloat = NSLayoutManager().defaultLineHeight(for: font)
    /// Advance of one monospaced column.
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

    private struct StyleKey: Hashable {
        let indentColumns: Int
        let paragraphSpacing: CGFloat
    }

    private static var styleCache: [StyleKey: NSParagraphStyle] = [:]

    /// Row paragraph style: every line fragment is `rowHeight` tall,
    /// continuation lines are indented by `indentColumns` columns (VS Code
    /// `wrappingIndent: same`), tabs advance 4 columns, and
    /// `paragraphSpacing` is the row's alignment pad.
    static func paragraphStyle(indentColumns: Int, paragraphSpacing: CGFloat) -> NSParagraphStyle {
        let key = StyleKey(indentColumns: indentColumns, paragraphSpacing: paragraphSpacing)
        if let cached = styleCache[key] { return cached }
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = rowHeight
        style.maximumLineHeight = rowHeight
        style.firstLineHeadIndent = 0
        style.headIndent = CGFloat(indentColumns) * columnWidth
        style.tabStops = []
        style.defaultTabInterval = CGFloat(DiffWrapIndent.tabSize) * columnWidth
        style.paragraphSpacing = paragraphSpacing
        // Never mutated after caching.
        styleCache[key] = style
        return style
    }

    /// Paragraph style that pins every row to `rowHeight` (no indent, no pad).
    static let rowParagraphStyle: NSParagraphStyle = paragraphStyle(indentColumns: 0, paragraphSpacing: 0)

    static func collapsedLabel(hiddenCount: Int) -> String {
        "\u{22EF} \(hiddenCount) unchanged lines \u{22EF}"
    }
}

/// Binary searches over ascending, contiguous row frames.
enum DiffRowFrameSearch {
    /// Index of the row containing `y`, nil above the first or below the last row.
    static func row(containingY y: CGFloat, in frames: [CGRect]) -> Int? {
        guard let first = frames.first, let last = frames.last,
              y >= first.minY, y < last.maxY else { return nil }
        return lastRow(startingAtOrBefore: y, in: frames)
    }

    /// Last row whose minY <= y, clamped to 0 (frames must be non-empty).
    static func lastRow(startingAtOrBefore y: CGFloat, in frames: [CGRect]) -> Int {
        var lo = 0
        var hi = frames.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if frames[mid].minY <= y { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    /// Rows intersecting `minY..<maxY`: first row with maxY > minY through
    /// the last row with minY < maxY.
    static func rows(intersecting minY: CGFloat, _ maxY: CGFloat, in frames: [CGRect]) -> Range<Int> {
        guard !frames.isEmpty, maxY > minY else { return 0..<0 }
        // First row with maxY > minY.
        var lo = 0
        var hi = frames.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if frames[mid].maxY > minY { hi = mid } else { lo = mid + 1 }
        }
        let first = lo
        // Number of rows with minY < maxY.
        lo = first
        hi = frames.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if frames[mid].minY < maxY { lo = mid + 1 } else { hi = mid }
        }
        return first < lo ? first..<lo : 0..<0
    }
}

/// Gutter drawing geometry: numbers, indicators and markers sit in a row's
/// first line fragment (continuation fragments stay blank).
enum DiffGutterGeometry {
    /// Baseline-box y of a gutter label in the row's first fragment.
    static func labelY(rowFrame: CGRect, rowHeight: CGFloat, fontHeight: CGFloat) -> CGFloat {
        rowFrame.minY + (rowHeight - fontHeight) / 2
    }

    /// Square marker of side `size` at `x`, centred in the row's first fragment.
    static func markerRect(rowFrame: CGRect, rowHeight: CGFloat, x: CGFloat, size: CGFloat) -> CGRect {
        CGRect(x: x, y: rowFrame.minY + (rowHeight - size) / 2, width: size, height: size)
    }

    /// Rows to draw for a dirty `rect`: those intersecting `rect ∩ bounds`.
    /// With `clipsToBounds == false` (macOS 14+) AppKit may pass a dirty
    /// rect reaching past the view's bounds (up to whatever ancestor
    /// clips); rows there are outside the gutter and must not be drawn.
    static func rowsToDraw(rowFrames: [CGRect], in rect: CGRect, bounds: CGRect) -> Range<Int> {
        let area = rect.intersection(bounds)
        guard !area.isNull, !area.isEmpty else { return 0..<0 }
        return DiffRowFrameSearch.rows(intersecting: area.minY, area.maxY, in: rowFrames)
    }
}

/// Viewport top relative to the rows (see `DiffPaneView.captureScrollAnchor`).
enum DiffScrollAnchor: Equatable {
    /// Above the first row (in the top inset), at document `y`.
    case aboveRows(y: CGFloat)
    /// Inside `row`'s content, `fraction` of its natural (unpadded) height down.
    case row(Int, fraction: CGFloat)
    /// Inside `row`'s alignment pad, `offset` pt below its content.
    case pad(Int, offset: CGFloat)
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
    /// The text view's selection changed (user or programmatic).
    var onSelectionChanged: (() -> Void)?
    /// The viewport width changed in `layout()` (rows may have re-wrapped).
    var onViewportWidthChanged: (() -> Void)?
    /// The rows are about to re-wrap at a new viewport width (the old row
    /// geometry is still in place: the scroll anchor is read from it).
    var onViewportWidthWillChange: (() -> Void)?

    /// Wrap lines at the viewport width (VS Code `wordWrap: on`). Applied
    /// synchronously from the current viewport width.
    var wordWrap: Bool {
        didSet {
            guard wordWrap != oldValue else { return }
            applyWrapMode()
        }
    }

    private(set) var cells: [DiffCell?] = []

    init(side: DiffSide, gutterColumns: GutterColumns, accessibilitySuffix: String) {
        self.side = side
        self.gutterColumns = gutterColumns
        self.lineNumberView = DiffLineNumberView(columns: gutterColumns, textView: textView)
        self.wordWrap = DiffLayoutSettings.wordWrap
        super.init(frame: .zero)
        setupViews(accessibilitySuffix: accessibilitySuffix)
        applyWrapMode()
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
        scrollView.contentView.postsFrameChangedNotifications = true
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
        textView.container.widthTracksTextView = false
        textView.container.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                  height: CGFloat.greatestFiniteMagnitude)
        textView.container.lineBreakMode = .byWordWrapping
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

        NotificationCenter.default.addObserver(
            self, selector: #selector(clipViewFrameDidChange(_:)),
            name: NSView.frameDidChangeNotification, object: scrollView.contentView
        )

        lineNumberView.onRowClicked = { [weak self] row in self?.onRowClicked?(row) }
        lineNumberView.onRangeSelected = { [weak self] lo, hi in self?.onRangeSelected?(lo, hi) }
        lineNumberView.onCollapsedRowAction = { [weak self] row, action in
            self?.onCollapsedRowAction?(row, action)
        }
        textView.onRowClicked = { [weak self] row in self?.onRowClicked?(row) }
        textView.onBecameFirstResponder = { [weak self] in self?.onBecameFirstResponder?() }
        NotificationCenter.default.addObserver(
            self, selector: #selector(textViewSelectionDidChange(_:)),
            name: NSTextView.didChangeSelectionNotification, object: textView
        )
    }

    @objc private func textViewSelectionDidChange(_ notification: Notification) {
        onSelectionChanged?()
    }

    // MARK: Wrap mode

    /// Width available to text: the scroll view's content width minus the
    /// line-number ruler (tiled inside the scroll view).
    private var wrapViewportWidth: CGFloat {
        let ruler = scrollView.rulersVisible && scrollView.hasVerticalRuler ? lineNumberView.requiredThickness : 0
        return scrollView.contentSize.width - ruler
    }

    private func applyWrapMode() {
        scrollView.hasHorizontalScroller = !wordWrap
        textView.isHorizontallyResizable = !wordWrap
        if !wordWrap {
            textView.minSize = NSSize(width: scrollView.contentSize.width, height: textView.minSize.height)
        }
        _ = updateContainerWidth(announcing: false)
    }

    /// Sets the container width for the current mode and viewport; returns
    /// whether it changed. Wrapping at a zero-width viewport is deferred
    /// (infinite width) until the pane has a size. `announcing` calls
    /// `onViewportWidthWillChange` before the rows re-wrap (viewport width
    /// changes; a wrap toggle rebuilds with its own anchor instead).
    private func updateContainerWidth(announcing: Bool) -> Bool {
        let container = textView.container
        let target: CGFloat
        let viewport = wrapViewportWidth
        if wordWrap {
            target = viewport > 0
                ? max(viewport - 2 * DiffMetrics.textInset.width, 8 * DiffMetrics.columnWidth)
                : .greatestFiniteMagnitude
        } else {
            target = .greatestFiniteMagnitude
        }
        let rewraps = container.containerSize.width != target
        // Before the text view's frame changes too: the clip view may
        // re-constrain its origin on a document frame change.
        if rewraps, announcing { onViewportWidthWillChange?() }
        if wordWrap, viewport > 0, textView.minSize.width != viewport || textView.frame.width != viewport {
            textView.minSize = NSSize(width: viewport, height: textView.minSize.height)
            textView.setFrameSize(NSSize(width: viewport, height: textView.frame.height))
        }
        guard rewraps else { return false }
        container.containerSize = NSSize(width: target, height: CGFloat.greatestFiniteMagnitude)
        textView.invalidateRowFrames()
        textView.sizeToFit()
        return true
    }

    /// Columns available to wrapped text (VS Code `wrappingColumn`);
    /// `.max` when not wrapping.
    var wrappingColumns: Int {
        let width = textView.container.containerSize.width
        guard width < .greatestFiniteMagnitude else { return .max }
        let usable = width - 2 * textView.container.lineFragmentPadding
        return max(Int(usable / DiffMetrics.columnWidth), 0)
    }

    /// `layout()` is running: clip-view origin changes in it come from
    /// geometry (frame changes, AppKit's origin constraining and
    /// alignment), not from a scroll.
    private(set) var isLayingOut = false

    override func layout() {
        isLayingOut = true
        defer { isLayingOut = false }
        super.layout()
        if wordWrap {
            if updateContainerWidth(announcing: true) { onViewportWidthChanged?() }
        } else {
            // Keep the document at least as wide as the viewport so full-row
            // backgrounds and filler hatching span the visible width.
            let width = scrollView.contentSize.width
            if textView.minSize.width != width {
                textView.minSize = NSSize(width: width, height: textView.minSize.height)
                textView.sizeToFit()
                onViewportWidthChanged?()
            }
        }
    }

    /// A clip-view width update is queued for the next main-queue turn.
    private var isClipWidthUpdatePending = false

    /// The clip view's width can change without this view's frame changing
    /// (a legacy scroller appearing or hiding after a pad changes the
    /// document height). The notification arrives inside
    /// `NSScrollView.tile()`, i.e. mid layout pass, so the container-width
    /// update is deferred to the next main-queue turn (coalesced) instead of
    /// re-marking layout during the pass, which loops the window's
    /// constraint pass.
    @objc private func clipViewFrameDidChange(_ notification: Notification) {
        guard wordWrap, !isClipWidthUpdatePending else { return }
        isClipWidthUpdatePending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isClipWidthUpdatePending = false
            guard self.wordWrap, self.updateContainerWidth(announcing: true) else { return }
            self.onViewportWidthChanged?()
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

    /// The row's first line fragment in the gutter's coordinates (popover anchor).
    func rowRect(_ row: Int) -> NSRect {
        let frame = textView.ensureRowFrames()[row]
        let y = lineNumberView.convert(NSPoint(x: 0, y: frame.minY), from: textView).y
        return NSRect(x: 0, y: y, width: lineNumberView.bounds.width, height: DiffMetrics.rowHeight)
    }

    /// Row at a y coordinate of the text view, nil outside the rows.
    func rowIndex(atY y: CGFloat) -> Int? {
        textView.rowIndex(atY: y)
    }

    var firstVisibleRow: Int? {
        rowIndex(atY: scrollView.documentVisibleRect.minY)
    }

    /// Height of the text view's rows including the top inset.
    var documentHeight: CGFloat {
        textView.ensureRowFrames().last?.maxY ?? 0
    }

    /// Scrolls the document so `y` is at the top, clamped to the content.
    func scroll(toY y: CGFloat) {
        let clip = scrollView.contentView
        let maxY = max(textView.frame.height - clip.bounds.height, 0)
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: min(max(y, 0), maxY)))
        scrollView.reflectScrolledClipView(clip)
    }

    func scrollToRow(_ row: Int) {
        let frames = textView.ensureRowFrames()
        scroll(toY: frames.indices.contains(row) ? frames[row].minY : 0)
    }

    /// The viewport top as a row-relative position (VS Code keeps the
    /// viewport's start line and its offset across a re-wrap). Rows keep
    /// their indices across re-wraps and pads; only their geometry changes.
    func captureScrollAnchor() -> DiffScrollAnchor? {
        let frames = textView.ensureRowFrames()
        guard let first = frames.first else { return nil }
        let top = scrollView.documentVisibleRect.minY
        guard top >= first.minY else { return .aboveRows(y: top) }
        let row = DiffRowFrameSearch.lastRow(startingAtOrBefore: top, in: frames)
        let content = textView.naturalHeights()[row]
        let delta = top - frames[row].minY
        if delta < content {
            return .row(row, fraction: content > 0 ? delta / content : 0)
        }
        return .pad(row, offset: delta - content)
    }

    /// Viewport-top y for `anchor` in the current geometry.
    func scrollY(for anchor: DiffScrollAnchor) -> CGFloat? {
        let frames = textView.ensureRowFrames()
        switch anchor {
        case .aboveRows(let y):
            return y
        case .row(let row, let fraction):
            guard frames.indices.contains(row) else { return nil }
            return frames[row].minY + fraction * textView.naturalHeights()[row]
        case .pad(let row, let offset):
            guard frames.indices.contains(row) else { return nil }
            let content = textView.naturalHeights()[row]
            let pad = frames[row].height - content
            return frames[row].minY + content + min(offset, max(pad, 0))
        }
    }

    /// Rows intersecting the visible rect (partially visible rows included).
    var visibleRowRange: Range<Int> {
        let rect = scrollView.documentVisibleRect
        guard !cells.isEmpty, rect.height > 0 else { return 0..<0 }
        return DiffRowFrameSearch.rows(intersecting: rect.minY, rect.maxY, in: textView.ensureRowFrames())
    }

    /// Row at the vertical pixel centre of the viewport (clamped to the rows).
    var rowIndexAtViewportCentre: Int? {
        let frames = textView.ensureRowFrames()
        guard !frames.isEmpty else { return nil }
        return DiffRowFrameSearch.lastRow(startingAtOrBefore: scrollView.documentVisibleRect.midY, in: frames)
    }

    /// Row containing the start of the text selection.
    var selectionStartRow: Int? {
        textView.row(containingCharacterAt: textView.selectedRange().location)
    }

    /// Moves the insertion point to the start of `row`'s text without scrolling.
    func placeInsertionPoint(atRow row: Int) {
        guard let location = textView.textStart(ofRow: row) else { return }
        textView.setSelectedRange(NSRange(location: location, length: 0))
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
    /// Wrap indent (columns) of each row as built by `attributedString`.
    private var rowIndents: [Int] = []
    private var maxRowIndent = 0
    /// Rows whose wrap indent is zeroed because it leaves no room (VS Code
    /// `computeWrappedTextIndentLength`'s no-room rule).
    private var zeroedIndentRows: Set<Int> = []
    /// Alignment pad (paragraph spacing) of each padded non-final row.
    private(set) var appliedPadding: [Int: CGFloat] = [:]
    /// Alignment pad of the final row: virtual (extends the document via
    /// `alignedMinHeight`; an empty final paragraph cannot carry attributes).
    private(set) var tailPadding: CGFloat = 0

    private var cachedRowFrames: [CGRect]?
    private var cachedContainerWidth: CGFloat = 0

    /// The TextKit 1 network is built here explicitly (the text view does
    /// not retain its text storage).
    private let ownedTextStorage: NSTextStorage
    let container: NSTextContainer
    private let textLayoutManager1: NSLayoutManager

    init() {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                     height: CGFloat.greatestFiniteMagnitude))
        layoutManager.addTextContainer(container)
        ownedTextStorage = storage
        textLayoutManager1 = layoutManager
        self.container = container
        super.init(frame: .zero, textContainer: container)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Document height that carries the virtual tail pad. Not stored in
    /// `minSize`: AppKit (`-[NSTextView _superviewClipViewFrameChanged:]`)
    /// resets `minSize` to the clip size whenever the clip view's frame
    /// changes (e.g. a legacy scroller appearing), which would drop the pad.
    private var alignedMinHeight: CGFloat = 0

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(NSSize(width: newSize.width, height: max(newSize.height, alignedMinHeight)))
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
        rowIndents = ranges.map { range in
            guard range.length > 0,
                  let style = attributed.attribute(.paragraphStyle, at: range.location,
                                                   effectiveRange: nil) as? NSParagraphStyle else { return 0 }
            return Int((style.headIndent / DiffMetrics.columnWidth).rounded())
        }
        maxRowIndent = rowIndents.max() ?? 0
        zeroedIndentRows = []
        appliedPadding = [:]
        tailPadding = 0
        alignedMinHeight = 0
        ownedTextStorage.setAttributedString(attributed)
        invalidateRowFrames()
        needsDisplay = true
    }

    /// UTF-16 location of the start of `row`'s text.
    func textStart(ofRow row: Int) -> Int? {
        guard row >= 0, row < rowRanges.count else { return nil }
        return rowRanges[row].location
    }

    /// Row whose text (or trailing newline) holds the UTF-16 `location`.
    func row(containingCharacterAt location: Int) -> Int? {
        guard !rowRanges.isEmpty else { return nil }
        var lo = 0
        var hi = rowRanges.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if rowRanges[mid].location <= location { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    // MARK: Measured geometry

    func invalidateRowFrames() {
        cachedRowFrames = nil
    }

    /// Frame of each row in view coordinates: from its first line fragment
    /// to the next row's first fragment (the last row: to its last
    /// fragment, plus `tailPadding`). Full view width.
    @discardableResult
    func ensureRowFrames() -> [CGRect] {
        let width = container.containerSize.width
        if let cached = cachedRowFrames, cachedContainerWidth == width { return cached }
        let frames = measureRowFrames()
        cachedRowFrames = frames
        cachedContainerWidth = width
        return frames
    }

    private func measureRowFrames() -> [CGRect] {
        let count = rowRanges.count
        guard count > 0 else { return [] }
        let layoutManager = textLayoutManager1
        layoutManager.ensureLayout(for: container)
        var minYs = [CGFloat](repeating: .nan, count: count)
        var maxYs = [CGFloat](repeating: 0, count: count)
        var cursor = 0
        let ranges = rowRanges
        let glyphs = layoutManager.glyphRange(for: container)
        layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { rect, _, _, glyphRange, _ in
            let character = layoutManager.characterIndexForGlyph(at: glyphRange.location)
            while cursor + 1 < count, ranges[cursor + 1].location <= character { cursor += 1 }
            if minYs[cursor].isNaN { minYs[cursor] = rect.minY }
            maxYs[cursor] = max(maxYs[cursor], rect.maxY)
        }
        if minYs[count - 1].isNaN {
            // Empty final paragraph: laid out as the extra line fragment.
            let extra = layoutManager.extraLineFragmentRect
            minYs[count - 1] = extra.minY
            maxYs[count - 1] = extra.maxY
        }
        let origin = textContainerOrigin
        let width = bounds.width
        var frames: [CGRect] = []
        frames.reserveCapacity(count)
        for row in 0..<count {
            precondition(!minYs[row].isNaN, "row \(row) has no line fragment")
            let bottom = row + 1 < count ? minYs[row + 1] : maxYs[row] + tailPadding
            frames.append(CGRect(x: 0, y: minYs[row] + origin.y, width: width, height: bottom - minYs[row]))
        }
        return frames
    }

    /// Row heights without the alignment pads.
    func naturalHeights() -> [CGFloat] {
        let frames = ensureRowFrames()
        let last = frames.count - 1
        return frames.enumerated().map { row, frame in
            frame.height - (row == last ? tailPadding : appliedPadding[row] ?? 0)
        }
    }

    /// The pane carries alignment pads or zeroed indents that a realign
    /// may have to undo.
    var hasLayoutAdjustments: Bool {
        !appliedPadding.isEmpty || tailPadding > 0 || !zeroedIndentRows.isEmpty
    }

    /// Zeroes the wrap indent of rows whose indent leaves no room within
    /// `wrappingColumns` (VS Code `computeWrappedTextIndentLength`) and
    /// restores the others. Must run before `naturalHeights()` is measured,
    /// since it changes wrap counts. Only changed rows are touched, in one
    /// edit batch; returns false (no edit) when nothing changes.
    @discardableResult
    func applyIndentZeroing(wrappingColumns: Int) -> Bool {
        guard !rowRanges.isEmpty else { return false }
        var newZeroed = Set<Int>()
        if maxRowIndent + 2 > wrappingColumns {
            let string = ownedTextStorage.string as NSString
            for (row, indent) in rowIndents.enumerated() where indent > 0 {
                let text = string.substring(with: rowRanges[row])
                if DiffWrapIndent.columns(lineText: text, wrappingColumns: wrappingColumns) == 0 {
                    newZeroed.insert(row)
                }
            }
        }
        let dirty = zeroedIndentRows.symmetricDifference(newZeroed)
        guard !dirty.isEmpty else { return false }
        zeroedIndentRows = newZeroed
        restyle(rows: dirty)
        return true
    }

    /// Applies alignment pads (row -> pad; the final row's pad is virtual).
    /// Rows whose pad is unchanged are not touched; when nothing changes, no
    /// edit happens and the result is false. Otherwise all attribute changes
    /// are one edit batch.
    @discardableResult
    func applyPadding(_ pads: [Int: CGFloat]) -> Bool {
        let last = rowRanges.count - 1
        guard last >= 0 else { return false }
        var rowPads = pads
        let newTail = rowPads.removeValue(forKey: last) ?? 0

        var dirty = Set<Int>()
        var newPadding = appliedPadding
        for row in Set(appliedPadding.keys).union(rowPads.keys) {
            let old = appliedPadding[row] ?? 0
            let new = rowPads[row] ?? 0
            guard abs(old - new) > 0.5 else { continue }
            dirty.insert(row)
            newPadding[row] = new > 0 ? new : nil
        }
        let tailChanged = abs(tailPadding - newTail) > 0.5
        guard !dirty.isEmpty || tailChanged else { return false }

        appliedPadding = newPadding
        if tailChanged { tailPadding = newTail }
        if dirty.isEmpty {
            refreshAfterGeometryChange()
        } else {
            restyle(rows: dirty)
        }
        return true
    }

    /// Re-applies the paragraph style (indent + pad) of `rows` in one edit
    /// batch, then refreshes the measured geometry.
    private func restyle(rows: Set<Int>) {
        let last = rowRanges.count - 1
        ownedTextStorage.beginEditing()
        for row in rows.sorted() {
            var range = rowRanges[row]
            if row < last { range.length += 1 }
            guard range.length > 0 else { continue }
            let indent = zeroedIndentRows.contains(row) ? 0 : rowIndents[row]
            let style = DiffMetrics.paragraphStyle(indentColumns: indent,
                                                   paragraphSpacing: appliedPadding[row] ?? 0)
            ownedTextStorage.addAttribute(.paragraphStyle, value: style, range: range)
        }
        ownedTextStorage.endEditing()
        refreshAfterGeometryChange()
    }

    private func refreshAfterGeometryChange() {
        invalidateRowFrames()
        let frames = ensureRowFrames()
        let alignedHeight = tailPadding > 0 ? (frames.last?.maxY ?? 0) + textContainerInset.height : 0
        alignedMinHeight = alignedHeight
        sizeToFit()
        // sizeToFit skips setFrameSize when its own target equals the
        // current frame, so the aligned height is enforced explicitly.
        if frame.height < alignedMinHeight {
            setFrameSize(NSSize(width: frame.width, height: alignedMinHeight))
        }
        needsDisplay = true
    }

    func rowIndex(atY y: CGFloat) -> Int? {
        DiffRowFrameSearch.row(containingY: y, in: ensureRowFrames())
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

    /// Alignment pad at the bottom of `row`'s frame.
    private func pad(ofRow row: Int, lastRow: Int) -> CGFloat {
        row == lastRow ? tailPadding : appliedPadding[row] ?? 0
    }

    override func draw(_ dirtyRect: NSRect) {
        let frames = ensureRowFrames()
        let rows = DiffRowFrameSearch.rows(intersecting: dirtyRect.minY, dirtyRect.maxY, in: frames)
        let lastRow = frames.count - 1
        let fillX = dirtyRect.minX
        let fillWidth = dirtyRect.width
        for row in rows {
            let frame = frames[row]
            let pad = pad(ofRow: row, lastRow: lastRow)
            let rowRect = NSRect(x: fillX, y: frame.minY, width: fillWidth, height: frame.height - pad)
            if let cell = cells[row] {
                switch cell.kind {
                case .line(.deletion):
                    DiffMetrics.deletionLineBackground.setFill()
                    rowRect.fill()
                case .line(.addition):
                    DiffMetrics.additionLineBackground.setFill()
                    rowRect.fill()
                case .comment:
                    DiffMetrics.commentBackground.setFill()
                    rowRect.fill()
                case .banner:
                    DiffMetrics.bannerBackground.setFill()
                    rowRect.fill()
                case .collapsedRegion:
                    DiffMetrics.collapsedBackground.setFill()
                    rowRect.fill()
                case .filler:
                    drawHatch(in: NSRect(x: fillX, y: frame.minY, width: fillWidth, height: frame.height))
                    continue
                case .line:
                    break
                }
            }
            if pad > 0 {
                // VS Code: every side-by-side alignment zone is `diagonal-fill`.
                drawHatch(in: NSRect(x: fillX, y: frame.maxY - pad, width: fillWidth, height: pad))
            }
        }

        super.draw(dirtyRect)

        for row in rows {
            guard let cell = cells[row] else { continue }
            switch cell.kind {
            case .collapsedRegion(_, let hiddenCount):
                let frame = frames[row]
                drawCollapsedLabel(rowMinY: frame.minY, height: frame.height - pad(ofRow: row, lastRow: lastRow),
                                   hiddenCount: hiddenCount)
            case .line(let type) where !cell.isWholeLineChange:
                drawEmptyInnerMarkers(row: row, rowMinY: frames[row].minY, cell: cell, type: type)
            default:
                break
            }
        }
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

    private func drawCollapsedLabel(rowMinY: CGFloat, height: CGFloat, hiddenCount: Int) {
        let visible = enclosingScrollView?.documentVisibleRect ?? visibleRect
        let label = DiffMetrics.collapsedLabel(hiddenCount: hiddenCount) as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: DiffMetrics.font,
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let size = label.size(withAttributes: attrs)
        let y = rowMinY + (height - size.height) / 2
        label.draw(at: NSPoint(x: visible.midX - size.width / 2, y: y), withAttributes: attrs)
    }

    /// VS Code `diffInsertedDecorationEmpty` / `diffDeletedDecorationEmpty`;
    /// x and y come from the glyph's line fragment (it may be a continuation).
    private func drawEmptyInnerMarkers(row: Int, rowMinY: CGFloat, cell: DiffCell, type: DiffLineType) {
        let empties = cell.innerRanges.filter { $0.length == 0 }
        guard !empties.isEmpty, row < rowRanges.count else { return }
        let layoutManager = textLayoutManager1
        let rowRange = rowRanges[row]
        let color: NSColor
        switch type {
        case .deletion: color = DiffMetrics.deletionMarker
        case .addition: color = DiffMetrics.additionMarker
        case .context, .hunkHeader, .meta: return
        }
        color.setFill()
        let origin = textContainerOrigin
        for range in empties where range.location <= rowRange.length {
            let x: CGFloat
            let y: CGFloat
            if rowRange.length > 0 {
                let atEnd = range.location >= rowRange.length
                let character = rowRange.location + (atEnd ? rowRange.length - 1 : range.location)
                let glyph = layoutManager.glyphIndexForCharacter(at: character)
                let rect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
                x = atEnd ? rect.maxX : rect.minX
                y = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY + origin.y
            } else {
                x = container.lineFragmentPadding
                y = rowMinY
            }
            NSRect(x: x + origin.x, y: y, width: 1, height: DiffMetrics.rowHeight).fill()
        }
    }
}

// MARK: - Line Number Ruler

@MainActor
final class DiffLineNumberView: NSRulerView {
    let columns: GutterColumns
    /// The client text view: row frames come from its layout.
    let textView: DiffTextView
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

    init(columns: GutterColumns, textView: DiffTextView) {
        self.columns = columns
        self.textView = textView
        super.init(scrollView: nil, orientation: .verticalRuler)
        // The gutter is a viewport onto document rows, like the clip view
        // beside it: a row straddling the top or bottom edge is partially
        // visible and its label must be cut at the edge. Unclipped
        // (macOS 14+ default), that part is painted over whatever lies
        // outside the scroll view (tab bar, toolbar) and stays there.
        clipsToBounds = true
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var requiredThickness: CGFloat { columns.thickness }

    /// Row frames in this view's coordinates (full gutter width): the
    /// single source used by drawing and hit-testing.
    private func rowFrames() -> [CGRect] {
        let offset = convert(NSPoint.zero, from: textView).y
        let width = bounds.width
        return textView.ensureRowFrames().map {
            CGRect(x: 0, y: $0.minY + offset, width: width, height: $0.height)
        }
    }

    /// Rows `drawHashMarksAndLabels(in:)` draws for `rect` (within bounds).
    func rowsToDraw(in rect: CGRect) -> Range<Int> {
        let range = DiffGutterGeometry.rowsToDraw(rowFrames: rowFrames(), in: rect, bounds: bounds)
        return range.clamped(to: 0..<rows.count)
    }

    private func row(at point: NSPoint) -> Int? {
        guard !rows.isEmpty else { return nil }
        let frames = rowFrames()
        guard let row = DiffRowFrameSearch.row(containingY: point.y, in: frames), row < rows.count else { return nil }
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
        let frames = rowFrames()
        let visible = rowsToDraw(in: rect)
        let numberAttrs: [NSAttributedString.Key: Any] = [
            .font: DiffMetrics.gutterFont,
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let dragRange: ClosedRange<Int>? = {
            guard let s = dragStartRow, let c = dragCurrentRow else { return nil }
            return min(s, c)...max(s, c)
        }()

        for index in visible {
            let gutterRow = rows[index]
            let rowRect = frames[index]

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
            // GitHub-style hover "+" button
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
        guard dragStartRow != nil, !rows.isEmpty else { return }
        let point = convert(event.locationInWindow, from: nil)
        let frames = rowFrames()
        guard !frames.isEmpty else { return }
        // Above the rows clamps to the first, below to the last.
        let row = DiffRowFrameSearch.lastRow(startingAtOrBefore: point.y, in: frames)
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
