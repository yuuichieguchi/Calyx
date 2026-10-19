import AppKit
import CoreText

struct DiffPaneLayout {
    let cells: [DiffCell?]
    let text: DiffPaneText
    let wrap: DiffPaneWrap
    let geometry: DiffRowGeometry
}

@MainActor
final class DiffLinesView: NSView, NSUserInterfaceValidations {
    private struct SegmentLine {
        let line: CTLine
        let originX: CGFloat
        let localStart: Int
        let localEnd: Int
        let modelToDisplay: [Int]
        let displayToModel: [Int]
        let symbolDisplayIndex: Int?
    }

    private struct ObliqueFontKey: Hashable {
        let font: NSFont
        let obliqueness: Double
    }

    private enum Granularity {
        case character
        case word
        case line
    }

    var onRowClicked: ((Int) -> Void)?
    var onBecameFirstResponder: (() -> Void)?
    var onSelectionChanged: (() -> Void)?
    var pasteboard: NSPasteboard = .general
    let textFinder = NSTextFinder()

    private(set) var cells: [DiffCell?] = []
    private(set) var text = DiffPaneText(cells: [], attributed: NSAttributedString())
    private(set) var wrap = DiffPaneWrap.unwrapped(rowCount: 1)
    private(set) var geometry = DiffRowGeometry(segmentCounts: [1], pads: [0], rowHeight: DiffMetrics.rowHeight,
                                                topInset: DiffMetrics.textInset.height)
    private(set) var lineBuildCount = 0
    private(set) var rewrapCountForTesting = 0
    private var visualLineStarts: [Int] = [0, 1]
    private var lineCache: [Int: [SegmentLine]] = [:]
    private var obliqueFonts: [ObliqueFontKey: NSFont] = [:]
    private var selection = NSRange(location: 0, length: 0)

    var string: String { text.string }
    var rowRanges: [NSRange] { text.rowRanges }
    var rowTexts: [DiffRowText] { text.rowTexts }
    var projections: [DiffLineProjection?] { wrap.projections }
    var segmentCounts: [Int] { wrap.segmentCounts }
    var wrappingColumn: Int? { wrap.column }
    var lineCacheCountForTesting: Int { lineCache.count }
    var lineCacheBoundForTesting: Int {
        Int((3 * visibleRect.height / DiffMetrics.rowHeight).rounded(.up)) + 2
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        textFinder.client = self
        setAccessibilityElement(true)
        setAccessibilityRole(.textArea)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    isolated deinit {
        textFinder.client = nil
        textFinder.findBarContainer = nil
    }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    func apply(_ layout: DiffPaneLayout, textChanged: Bool, rewrapped: Bool) {
        precondition(layout.text.rowCount == layout.wrap.segmentCounts.count
                     && layout.wrap.segmentCounts == layout.geometry.segmentCounts,
                     "text, wrap and geometry come from one snapshot")
        if textChanged { textFinder.noteClientStringWillChange() }
        cells = layout.cells
        text = layout.text
        wrap = layout.wrap
        geometry = layout.geometry
        if rewrapped { rewrapCountForTesting += 1 }
        if textChanged || rewrapped { lineCache = [:] }
        visualLineStarts = Self.prefixSums(layout.wrap.segmentCounts)
        if textChanged {
            selection = NSRange(location: 0, length: 0)
            NSAccessibility.post(element: self, notification: .valueChanged)
        } else {
            textFinder.cancelFindIndicator()
        }
        updateFrameSize()
        needsDisplay = true
    }

    private static func prefixSums(_ counts: [Int]) -> [Int] {
        var starts: [Int] = []
        starts.reserveCapacity(counts.count + 1)
        var total = 0
        for count in counts {
            starts.append(total)
            total += count
        }
        starts.append(total)
        return starts
    }

    func updateFrameSize() {
        let clipWidth = enclosingScrollView.map { Self.textAreaWidth(of: $0.contentView) } ?? 0
        let inset = DiffMetrics.textInset
        let width = wrap.column != nil
            ? clipWidth
            : max(clipWidth, 2 * inset.width + CGFloat(text.widestRowColumns) * DiffMetrics.columnWidth)
        let size = NSSize(width: width, height: geometry.documentHeight + inset.height)
        if frame.size != size { setFrameSize(size) }
    }

    static func textAreaWidth(of clip: NSClipView) -> CGFloat {
        max(clip.bounds.width - clip.contentInsets.left - clip.contentInsets.right, 0)
    }

    override func viewWillMove(toSuperview newSuperview: NSView?) {
        if let clip = superview as? NSClipView {
            NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: clip)
            NotificationCenter.default.removeObserver(self, name: NSView.frameDidChangeNotification, object: clip)
        }
        super.viewWillMove(toSuperview: newSuperview)
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        guard let clip = superview as? NSClipView else { return }
        NotificationCenter.default.addObserver(self, selector: #selector(clipBoundsDidChange(_:)),
                                               name: NSView.boundsDidChangeNotification, object: clip)
        NotificationCenter.default.addObserver(self, selector: #selector(clipFrameDidChange(_:)),
                                               name: NSView.frameDidChangeNotification, object: clip)
    }

    @objc private func clipBoundsDidChange(_ notification: Notification) {
        pruneLineCache()
    }

    @objc private func clipFrameDidChange(_ notification: Notification) {
        updateFrameSize()
        pruneLineCache()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        lineCache = [:]
        needsDisplay = true
    }

    func row(containingCharacterAt location: Int) -> Int {
        let ranges = text.rowRanges
        var lo = 0
        var hi = ranges.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if ranges[mid].location <= location { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    private func cell(_ row: Int) -> DiffCell? {
        row < cells.count ? cells[row] : nil
    }

    private func localStart(row: Int, segment: Int) -> Int {
        guard segment > 0 else { return 0 }
        return text.rowTexts[row].markerLength + breakOffsets(row)[segment - 1]
    }

    private func localEnd(row: Int, segment: Int) -> Int {
        guard segment < wrap.segmentCounts[row] - 1 else { return text.rowRanges[row].length }
        return text.rowTexts[row].markerLength + breakOffsets(row)[segment]
    }

    private func breakOffsets(_ row: Int) -> [Int] {
        wrappedProjection(row).breakOffsets
    }

    private func wrappedProjection(_ row: Int) -> DiffLineProjection {
        guard let projection = wrap.projections[row] else {
            preconditionFailure("row \(row) has \(wrap.segmentCounts[row]) segments but no projection")
        }
        return projection
    }

    private func segment(row: Int, local: Int) -> Int {
        let marker = text.rowTexts[row].markerLength
        guard local > marker else { return 0 }
        return DiffStableViewport.segment(containing: local - marker, in: wrap.projections[row])
    }

    private var cacheableRows: Range<Int> {
        let rect = visibleRect
        guard rect.height > 0 else { return 0..<0 }
        return geometry.rows(intersecting: rect.minY - rect.height, rect.maxY + rect.height)
    }

    private func pruneLineCache() {
        guard !lineCache.isEmpty else { return }
        let keep = cacheableRows
        lineCache = lineCache.filter { keep.contains($0.key) }
    }

    private func segmentLines(_ row: Int) -> [SegmentLine] {
        if let cached = lineCache[row] { return cached }
        var lines: [SegmentLine] = []
        effectiveAppearance.performAsCurrentDrawingAppearance {
            lines = (0..<wrap.segmentCounts[row]).map { buildSegmentLine(row: row, segment: $0) }
        }
        if cacheableRows.contains(row) { lineCache[row] = lines }
        return lines
    }

    private func font(for attributes: [NSAttributedString.Key: Any]) -> NSFont {
        let base = (attributes[.font] as? NSFont) ?? DiffMetrics.font
        guard let obliqueness = (attributes[.obliqueness] as? NSNumber)?.doubleValue, obliqueness != 0 else { return base }
        let key = ObliqueFontKey(font: base, obliqueness: obliqueness)
        if let cached = obliqueFonts[key] { return cached }
        var matrix = CGAffineTransform(a: 1, b: 0, c: CGFloat(obliqueness), d: 1, tx: 0, ty: 0)
        let oblique = CTFontCreateCopyWithAttributes(base, base.pointSize, &matrix, nil) as NSFont
        obliqueFonts[key] = oblique
        return oblique
    }

    private func buildSegmentLine(row: Int, segment: Int) -> SegmentLine {
        lineBuildCount += 1
        let rowText = text.rowTexts[row]
        let rowLocation = text.rowRanges[row].location
        let marker = rowText.markerLength
        let start = localStart(row: row, segment: segment)
        let end = localEnd(row: row, segment: segment)
        var visibleColumn = segment == 0 ? 0 : wrappedProjection(row).breakOffsetsVisibleColumn[segment - 1]
        var display: [UInt16] = []
        var modelToDisplay: [Int] = []
        var displayToModel: [Int] = []
        var symbolDisplayIndex: Int?
        display.reserveCapacity(end - start)
        for local in start..<end {
            modelToDisplay.append(display.count)
            if local < marker {
                let unit = text.nsString.character(at: rowLocation + local)
                if unit == DiffPaneText.commentSymbol {
                    symbolDisplayIndex = display.count
                    for _ in 0..<DiffPaneText.commentSymbolColumns {
                        display.append(0x20)
                        displayToModel.append(local)
                    }
                } else {
                    display.append(unit)
                    displayToModel.append(local)
                }
                continue
            }
            let unit = rowText.units[local - marker]
            if Int(unit) == DiffLineBreaks.tab {
                let width = DiffLineBreaks.tabCharacterWidth(visibleColumn, DiffPaneText.tabSize)
                for _ in 0..<max(Int(width), 1) {
                    display.append(0x20)
                    displayToModel.append(local)
                }
                visibleColumn += width
            } else {
                display.append(unit)
                displayToModel.append(local)
                visibleColumn += DiffLineBreaks.computeCharWidth(Int(unit), visibleColumn, DiffPaneText.tabSize,
                                                                 DiffPaneText.columnsForFullWidthChar, true)
            }
        }
        modelToDisplay.append(display.count)
        displayToModel.append(end)

        let displayString = NSMutableAttributedString(string: String(utf16CodeUnits: display, count: display.count))
        if end > start {
            let modelRange = NSRange(location: rowLocation + start, length: end - start)
            text.attributed.enumerateAttributes(in: modelRange) { attributes, runRange, _ in
                let runStart = modelToDisplay[runRange.location - rowLocation - start]
                let runEnd = modelToDisplay[NSMaxRange(runRange) - rowLocation - start]
                guard runEnd > runStart else { return }
                let color = (attributes[.foregroundColor] as? NSColor) ?? NSColor.labelColor
                displayString.setAttributes([
                    NSAttributedString.Key(kCTFontAttributeName as String): font(for: attributes),
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): color.cgColor,
                ], range: NSRange(location: runStart, length: runEnd - runStart))
            }
        }
        let indent = segment > 0 ? CGFloat(wrappedProjection(row).wrappedTextIndentLength) : 0
        let originX = segment == 0
            ? DiffMetrics.textInset.width
            : DiffMetrics.textInset.width + (CGFloat(rowText.markerColumns) + indent) * DiffMetrics.columnWidth
        return SegmentLine(line: CTLineCreateWithAttributedString(displayString), originX: originX,
                           localStart: start, localEnd: end, modelToDisplay: modelToDisplay,
                           displayToModel: displayToModel, symbolDisplayIndex: symbolDisplayIndex)
    }

    private func x(of line: SegmentLine, local: Int) -> CGFloat {
        let index = min(max(local - line.localStart, 0), line.modelToDisplay.count - 1)
        return line.originX + CTLineGetOffsetForStringIndex(line.line, line.modelToDisplay[index], nil)
    }

    func characterIndex(at point: NSPoint) -> Int {
        let (row, segment) = geometry.segment(atY: point.y)
        return text.rowRanges[row].location + localIndex(row: row, segment: segment, x: point.x)
    }

    private func localIndex(row: Int, segment: Int, x px: CGFloat) -> Int {
        let line = segmentLines(row)[segment]
        let found = CTLineGetStringIndexForPosition(line.line, CGPoint(x: px - line.originX, y: 0))
        let displayIndex = found == kCFNotFound ? 0 : min(max(found, 0), line.displayToModel.count - 1)
        let local = line.displayToModel[displayIndex]
        guard local < line.localEnd else { return line.localEnd }
        let rowLocation = text.rowRanges[row].location
        let cluster = text.nsString.rangeOfComposedCharacterSequence(at: rowLocation + local)
        let before = max(cluster.location - rowLocation, line.localStart)
        let after = min(NSMaxRange(cluster) - rowLocation, line.localEnd)
        return px - x(of: line, local: before) <= x(of: line, local: after) - px ? before : after
    }

    func rects(in range: NSRange) -> [NSRect] {
        let length = text.nsString.length
        let location = min(max(range.location, 0), length)
        let end = min(NSMaxRange(range), length)
        let rowHeight = DiffMetrics.rowHeight
        guard end > location else {
            let row = row(containingCharacterAt: location)
            let local = location - text.rowRanges[row].location
            let segment = segment(row: row, local: local)
            let line = segmentLines(row)[segment]
            return [NSRect(x: x(of: line, local: local), y: geometry.segmentTop(row: row, segment: segment),
                           width: 0, height: rowHeight)]
        }
        var rects: [NSRect] = []
        let firstRow = row(containingCharacterAt: location)
        let lastRow = row(containingCharacterAt: end - 1)
        for row in firstRow...lastRow {
            let rowRange = text.rowRanges[row]
            let start = max(location, rowRange.location) - rowRange.location
            let stop = min(end, NSMaxRange(rowRange)) - rowRange.location
            let includesNewline = end > NSMaxRange(rowRange) && row < text.rowCount - 1
            let lines = segmentLines(row)
            for (segment, line) in lines.enumerated() {
                let s = max(start, line.localStart)
                let e = min(stop, line.localEnd)
                let isLast = segment == lines.count - 1
                guard s < e || (isLast && includesNewline && s <= e) else { continue }
                let minX = x(of: line, local: s)
                var maxX = x(of: line, local: e)
                if isLast && includesNewline { maxX += DiffMetrics.columnWidth }
                rects.append(NSRect(x: minX, y: geometry.segmentTop(row: row, segment: segment),
                                    width: maxX - minX, height: rowHeight))
            }
        }
        return rects
    }

    var visibleCharacterRange: NSRange {
        let rows = geometry.rows(intersecting: visibleRect.minY, visibleRect.maxY)
        guard let first = rows.first, let last = rows.last else { return NSRange(location: 0, length: 0) }
        let start = text.rowRanges[first].location
        let end = NSMaxRange(text.rowRanges[last]) + (last < text.rowCount - 1 ? 1 : 0)
        return NSRange(location: start, length: end - start)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let rows = geometry.rows(intersecting: dirtyRect.minY, dirtyRect.maxY)
        for row in rows { drawRowBackground(row, dirtyRect: dirtyRect) }
        drawSelection(rows: rows)
        for row in rows { drawRowText(row, context: context) }
    }

    private func drawRowBackground(_ row: Int, dirtyRect: NSRect) {
        let top = geometry.rowTop(row)
        let content = geometry.contentHeight(row)
        let pad = geometry.pads[row]
        let rowRect = NSRect(x: dirtyRect.minX, y: top, width: dirtyRect.width, height: content)
        if let cell = cell(row) {
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
                drawHatch(in: NSRect(x: dirtyRect.minX, y: top, width: dirtyRect.width, height: content + pad))
                return
            case .line:
                break
            }
        }
        if pad > 0 {
            drawHatch(in: NSRect(x: dirtyRect.minX, y: top + content, width: dirtyRect.width, height: pad))
        }
    }

    private func drawSelection(rows: Range<Int>) {
        guard selection.length > 0, let first = rows.first, let last = rows.last else { return }
        let visible = NSRange(location: text.rowRanges[first].location,
                              length: NSMaxRange(text.rowRanges[last]) + 1 - text.rowRanges[first].location)
        guard let shown = selection.intersection(visible), shown.length > 0 else { return }
        let isActive = window?.firstResponder === self && window?.isKeyWindow == true
        (isActive ? NSColor.selectedTextBackgroundColor : NSColor.unemphasizedSelectedTextBackgroundColor).setFill()
        for rect in rects(in: shown) { rect.fill() }
    }

    private func drawRowText(_ row: Int, context: CGContext) {
        let lines = segmentLines(row)
        let rowLocation = text.rowRanges[row].location
        for (segment, line) in lines.enumerated() {
            let top = geometry.segmentTop(row: row, segment: segment)
            if line.localEnd > line.localStart {
                let modelRange = NSRange(location: rowLocation + line.localStart, length: line.localEnd - line.localStart)
                text.attributed.enumerateAttribute(.backgroundColor, in: modelRange) { value, runRange, _ in
                    guard let color = value as? NSColor else { return }
                    let minX = x(of: line, local: runRange.location - rowLocation)
                    let maxX = x(of: line, local: NSMaxRange(runRange) - rowLocation)
                    color.setFill()
                    NSRect(x: minX, y: top, width: maxX - minX, height: DiffMetrics.rowHeight).fill()
                }
            }
            drawLine(line, top: top, context: context)
            if let symbolIndex = line.symbolDisplayIndex, let image = DiffMetrics.commentSymbol {
                let symbolX = line.originX + CTLineGetOffsetForStringIndex(line.line, symbolIndex, nil)
                drawSymbol(image, in: NSRect(x: symbolX, y: top,
                                             width: CGFloat(DiffPaneText.commentSymbolColumns) * DiffMetrics.columnWidth,
                                             height: DiffMetrics.rowHeight))
            }
        }
        guard let cell = cell(row) else { return }
        switch cell.kind {
        case .collapsedRegion(_, let hiddenCount):
            drawCollapsedLabel(rowMinY: geometry.rowTop(row), height: geometry.contentHeight(row), hiddenCount: hiddenCount)
        case .line(let type) where !cell.isWholeLineChange:
            drawEmptyInnerMarkers(row: row, cell: cell, type: type)
        default:
            break
        }
    }

    private func drawLine(_ line: SegmentLine, top: CGFloat, context: CGContext) {
        let font = DiffMetrics.font
        let baseline = top + (DiffMetrics.rowHeight - (font.ascender - font.descender)) / 2 + font.ascender
        context.saveGState()
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        context.textPosition = CGPoint(x: line.originX, y: baseline)
        CTLineDraw(line.line, context)
        context.restoreGState()
    }

    private func drawSymbol(_ image: NSImage, in rect: NSRect) {
        guard image.size.width > 0, image.size.height > 0 else { return }
        let scale = min(rect.width / image.size.width, rect.height / image.size.height)
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        let target = NSRect(x: rect.minX + (rect.width - size.width) / 2, y: rect.minY + (rect.height - size.height) / 2,
                            width: size.width, height: size.height)
        image.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

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

    private func drawEmptyInnerMarkers(row: Int, cell: DiffCell, type: DiffLineType) {
        let empties = cell.innerRanges.filter { $0.length == 0 }
        guard !empties.isEmpty else { return }
        let color: NSColor
        switch type {
        case .deletion: color = DiffMetrics.deletionMarker
        case .addition: color = DiffMetrics.additionMarker
        case .context, .hunkHeader, .meta: return
        }
        color.setFill()
        let length = text.rowRanges[row].length
        let lines = segmentLines(row)
        for range in empties where range.location <= length {
            let segment = segment(row: row, local: range.location)
            let markerX = x(of: lines[segment], local: range.location)
            NSRect(x: markerX, y: geometry.segmentTop(row: row, segment: segment), width: 1,
                   height: DiffMetrics.rowHeight).fill()
        }
    }

    func selectedRange() -> NSRange { selection }

    func setSelectedRange(_ range: NSRange) {
        let length = text.nsString.length
        let location = min(max(range.location, 0), length)
        let clamped = NSRange(location: location, length: min(max(range.length, 0), length - location))
        updateSelection(composedAligned(clamped))
    }

    private func composedAligned(_ range: NSRange) -> NSRange {
        let string = text.nsString
        guard string.length > 0 else { return range }
        if range.length > 0 { return string.rangeOfComposedCharacterSequences(for: range) }
        guard range.location < string.length else { return range }
        return NSRange(location: string.rangeOfComposedCharacterSequence(at: range.location).location, length: 0)
    }

    private func updateSelection(_ range: NSRange) {
        guard range != selection else { return }
        selection = range
        needsDisplay = true
        NSAccessibility.post(element: self, notification: .selectedTextChanged)
        onSelectionChanged?()
    }

    override func selectAll(_ sender: Any?) {
        updateSelection(NSRange(location: 0, length: text.nsString.length))
    }

    private var selectedText: String {
        text.nsString.substring(with: selection)
    }

    @objc func copy(_ sender: Any?) {
        guard selection.length > 0 else { return }
        pasteboard.clearContents()
        pasteboard.setString(selectedText, forType: .string)
    }

    func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)):
            return selection.length > 0
        case #selector(selectAll(_:)):
            return true
        default:
            return false
        }
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            needsDisplay = true
            onBecameFirstResponder?()
        }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { needsDisplay = true }
        return accepted
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard modifiers.isEmpty, let scrollView = enclosingScrollView else {
            super.keyDown(with: event)
            return
        }
        let clip = scrollView.contentView
        let insets = clip.contentInsets
        let bounds = clip.bounds
        let page = max(bounds.height - insets.top - insets.bottom - scrollView.verticalPageScroll, 0)
        var origin = bounds.origin
        switch event.specialKey {
        case .pageDown?: origin.y += page
        case .pageUp?: origin.y -= page
        case .home?: origin.y = -insets.top
        case .end?: origin.y = frame.height
        case .downArrow?: origin.y += scrollView.verticalLineScroll
        case .upArrow?: origin.y -= scrollView.verticalLineScroll
        case .rightArrow?: origin.x += scrollView.horizontalLineScroll
        case .leftArrow?: origin.x -= scrollView.horizontalLineScroll
        default:
            super.keyDown(with: event)
            return
        }
        clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: origin, size: bounds.size)).origin)
        scrollView.reflectScrolledClipView(clip)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if point.y >= geometry.rowTop(0), point.y < geometry.documentHeight {
            let row = geometry.row(atY: point.y)
            if let cell = cell(row) {
                switch cell.kind {
                case .comment, .collapsedRegion:
                    onRowClicked?(row)
                    return
                case .line, .filler, .banner:
                    break
                }
            }
        }
        window?.makeFirstResponder(self)
        let granularity: Granularity
        switch event.clickCount {
        case ...1: granularity = .character
        case 2: granularity = .word
        default: granularity = .line
        }
        let index = characterIndex(at: point)
        let anchorRange: NSRange
        if event.modifierFlags.contains(.shift) {
            let start = selection.location
            let end = NSMaxRange(selection)
            anchorRange = NSRange(location: abs(index - start) > abs(index - end) ? start : end, length: 0)
        } else {
            anchorRange = range(at: index, granularity: granularity)
        }
        extendSelection(anchorRange: anchorRange, to: index, granularity: granularity)
        guard let window else { return }
        NSEvent.startPeriodicEvents(afterDelay: 0.1, withPeriod: 0.05)
        defer { NSEvent.stopPeriodicEvents() }
        var lastDrag: NSEvent?
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp, .periodic],
                                          until: .distantFuture, inMode: .eventTracking, dequeue: true) {
            if next.type == .leftMouseUp { break }
            if next.type == .leftMouseDragged { lastDrag = next }
            guard let drag = lastDrag else { continue }
            autoscroll(with: drag)
            extendSelection(anchorRange: anchorRange, to: characterIndex(at: convert(drag.locationInWindow, from: nil)),
                            granularity: granularity)
        }
    }

    private func range(at index: Int, granularity: Granularity) -> NSRange {
        let length = text.nsString.length
        switch granularity {
        case .character:
            return NSRange(location: index, length: 0)
        case .word:
            guard length > 0 else { return NSRange(location: 0, length: 0) }
            return text.attributed.doubleClick(at: min(index, length - 1))
        case .line:
            let row = row(containingCharacterAt: index)
            let rowRange = text.rowRanges[row]
            return NSRange(location: rowRange.location, length: rowRange.length + (row < text.rowCount - 1 ? 1 : 0))
        }
    }

    private func extendSelection(anchorRange: NSRange, to index: Int, granularity: Granularity) {
        let target = range(at: index, granularity: granularity)
        let start = min(anchorRange.location, target.location)
        let end = max(NSMaxRange(anchorRange), NSMaxRange(target))
        setSelectedRange(NSRange(location: start, length: end - start))
    }

    private func visualLine(containing index: Int) -> Int {
        let location = min(max(index, 0), text.nsString.length)
        let row = row(containingCharacterAt: location)
        return visualLineStarts[row] + segment(row: row, local: location - text.rowRanges[row].location)
    }

    override func accessibilityValue() -> Any? { text.string }

    override func accessibilityNumberOfCharacters() -> Int { text.nsString.length }

    override func accessibilitySelectedText() -> String? { selectedText }

    override func accessibilitySelectedTextRange() -> NSRange { selection }

    override func setAccessibilitySelectedTextRange(_ accessibilitySelectedTextRange: NSRange) {
        setSelectedRange(accessibilitySelectedTextRange)
    }

    override func accessibilityVisibleCharacterRange() -> NSRange { visibleCharacterRange }

    override func accessibilityInsertionPointLineNumber() -> Int { visualLine(containing: selection.location) }

    override func accessibilityLine(for index: Int) -> Int {
        index <= 0 ? 0 : visualLine(containing: index - 1)
    }

    override func accessibilityRange(forLine line: Int) -> NSRange {
        let total = visualLineStarts[visualLineStarts.count - 1]
        let clamped = min(max(line, 0), total - 1)
        var lo = 0
        var hi = text.rowCount - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if visualLineStarts[mid] <= clamped { lo = mid } else { hi = mid - 1 }
        }
        let row = lo
        let segment = clamped - visualLineStarts[row]
        let rowLocation = text.rowRanges[row].location
        let start = localStart(row: row, segment: segment)
        var end = localEnd(row: row, segment: segment)
        if segment == wrap.segmentCounts[row] - 1, row < text.rowCount - 1 { end += 1 }
        return NSRange(location: rowLocation + start, length: end - start)
    }

    override func accessibilityString(for range: NSRange) -> String? {
        let length = text.nsString.length
        let location = min(max(range.location, 0), length)
        let clamped = NSRange(location: location, length: min(max(range.length, 0), length - location))
        return text.nsString.substring(with: composedAligned(clamped))
    }

    override func accessibilityFrame(for range: NSRange) -> NSRect {
        let union = rects(in: range).reduce(NSRect.null) { $0.union($1) }
        guard !union.isNull, let window else { return .zero }
        return window.convertToScreen(convert(union, to: nil))
    }

    override func accessibilityRange(for point: NSPoint) -> NSRange {
        guard let window else { return NSRange(location: 0, length: 0) }
        let local = convert(window.convertPoint(fromScreen: point), from: nil)
        let index = characterIndex(at: local)
        guard index < text.nsString.length else { return NSRange(location: index, length: 0) }
        return text.nsString.rangeOfComposedCharacterSequence(at: index)
    }
}

extension DiffLinesView: @preconcurrency NSTextFinderClient {
    nonisolated var isSelectable: Bool { true }
    nonisolated var isEditable: Bool { false }
    nonisolated var allowsMultipleSelection: Bool { false }

    var firstSelectedRange: NSRange { selection }

    var selectedRanges: [NSValue] {
        get { [NSValue(range: selection)] }
        set {
            guard let first = newValue.first else { return }
            setSelectedRange(first.rangeValue)
        }
    }

    func scrollRangeToVisible(_ range: NSRange) {
        let union = rects(in: range).reduce(NSRect.null) { $0.union($1) }
        guard !union.isNull else { return }
        scrollToVisible(union)
    }

    var visibleCharacterRanges: [NSValue] { [NSValue(range: visibleCharacterRange)] }

    func rects(forCharacterRange range: NSRange) -> [NSValue]? {
        rects(in: range).map { NSValue(rect: $0) }
    }

    func contentView(at index: Int, effectiveCharacterRange outRange: NSRangePointer) -> NSView {
        outRange.pointee = NSRange(location: 0, length: text.nsString.length)
        return self
    }

    func drawCharacters(in range: NSRange, forContentView view: NSView) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let rects = rects(in: range)
        guard let firstRect = rects.first, let lastRect = rects.last else { return }
        let rows = geometry.rows(intersecting: firstRect.minY, lastRect.maxY)
        for rect in rects {
            NSGraphicsContext.saveGraphicsState()
            rect.clip()
            for row in rows {
                for (segment, line) in segmentLines(row).enumerated() {
                    drawLine(line, top: geometry.segmentTop(row: row, segment: segment), context: context)
                }
            }
            NSGraphicsContext.restoreGraphicsState()
        }
    }
}
