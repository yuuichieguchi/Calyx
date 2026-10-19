import AppKit

@MainActor
final class DiffView: NSView {
    static let splitViewDefaultRatio: CGFloat = 0.5
    static let splitViewMinPaneWidth: CGFloat = 200

    private struct Build {
        let layout: DiffLayout
        let displayLines: [DisplayLine]
        let rows: [DiffLayoutRow]
        let blocks: [Range<Int>]
        let panes: [DiffPaneContent]
        let commentedLineIndices: Set<Int>
    }

    private struct ContentAnchor {
        let displayIndex: Int
        let offset: Int
        let delta: CGFloat
    }

    private enum ScrollTarget {
        case top
        case preserved(ContentAnchor?)
    }

    private let inlinePane = DiffPaneView(side: .left, gutterColumns: .dual, accessibilitySuffix: ".inline")
    private let leftPane = DiffPaneView(side: .left, gutterColumns: .single, accessibilitySuffix: ".old")
    private let rightPane = DiffPaneView(side: .right, gutterColumns: .single, accessibilitySuffix: ".new")
    private let splitView = NSSplitView()
    private let rulerView = DiffOverviewRulerView(frame: .zero)

    private(set) var currentDiff: FileDiff?
    var reviewStore: DiffReviewStore?
    var revealState: DiffRevealState? {
        didSet {
            guard oldValue !== revealState else { return }
            oldValue?.onChanged = nil
            revealState?.onChanged = { [weak self] in
                self?.rebuild(preserveScroll: true)
            }
        }
    }
    private(set) var displayLines: [DisplayLine] = []
    private(set) var rows: [DiffLayoutRow] = []
    private(set) var blocks: [Range<Int>] = []
    private(set) var currentLayout: DiffLayout?
    private var build: Build?
    private var wraps: [DiffPaneWrap] = []
    private var activePopover: NSPopover?
    private var isSyncingScroll = false
    private var needsInitialDividerPosition = false
    private(set) var currentChangeIndex: Int?
    private var hasCaret = false
    private var pendingRevealChangeIndex: Int?
    private var isRevealScheduled = false
    private var isUpdatingPanes = false
    private(set) var geometryPassCountForTesting = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    var leftPaneForTesting: DiffPaneView { leftPane }
    var rightPaneForTesting: DiffPaneView { rightPane }
    var inlinePaneForTesting: DiffPaneView { inlinePane }
    var blocksForTesting: [Range<Int>] { blocks }

    private var activePanes: [DiffPaneView] {
        switch currentLayout {
        case .sideBySide: return [leftPane, rightPane]
        case .inline, .none: return [inlinePane]
        }
    }

    private func setupViews() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.delegate = self
        splitView.addSubview(leftPane)
        splitView.addSubview(rightPane)

        for pane in [inlinePane, leftPane, rightPane] {
            pane.onRowClicked = { [weak self, weak pane] row in
                guard let self, let pane else { return }
                self.handleRowClicked(pane: pane, row: row)
            }
            pane.onRangeSelected = { [weak self, weak pane] lo, hi in
                guard let self, let pane else { return }
                self.handleRangeSelected(pane: pane, startRow: lo, endRow: hi)
            }
            pane.onCollapsedRowAction = { [weak self, weak pane] row, action in
                guard let self, let pane else { return }
                self.handleCollapsedRowAction(pane: pane, row: row, action: action)
            }
        }
        leftPane.onBecameFirstResponder = { [weak self] in
            self?.rightPane.clearSelection()
            self?.hasCaret = true
        }
        leftPane.onSelectionChanged = { [weak self] in self?.mirrorLeftSelectionToCaretPane() }
        rightPane.onBecameFirstResponder = { [weak self] in
            self?.leftPane.clearSelection()
            self?.hasCaret = true
        }
        inlinePane.onBecameFirstResponder = { [weak self] in self?.hasCaret = true }

        addSubview(rulerView)
        rulerView.onRevealRow = { [weak self] row in
            guard let self else { return }
            self.cancelPendingReveal()
            self.revealRowsInCenter(row..<(row + 1))
        }
        rulerView.isHidden = !DiffLayoutSettings.renderOverviewRuler

        for pane in [inlinePane, leftPane, rightPane] {
            NotificationCenter.default.addObserver(
                self, selector: #selector(clipViewBoundsDidChange(_:)),
                name: NSView.boundsDidChangeNotification, object: pane.scrollView.contentView
            )
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(layoutSettingDidChange(_:)),
            name: .diffLayoutSettingChanged, object: nil
        )

        install(resolvedLayout())
    }

    private func resolvedLayout() -> DiffLayout {
        if currentDiff?.isBinary == true { return .inline }
        return DiffLayoutSettings.effectiveLayout(preference: DiffLayoutSettings.preference, width: bounds.width)
    }

    private func install(_ layout: DiffLayout) {
        guard layout != currentLayout else { return }
        activePopover?.close()
        switch layout {
        case .inline:
            splitView.removeFromSuperview()
            addSubview(inlinePane, positioned: .below, relativeTo: rulerView)
        case .sideBySide:
            inlinePane.removeFromSuperview()
            addSubview(splitView, positioned: .below, relativeTo: rulerView)
            needsInitialDividerPosition = true
        }
        currentLayout = layout
    }

    private var rulerInset: CGFloat {
        rulerView.isHidden ? 0 : DiffOverviewRuler.width
    }

    private func positionSubviews() {
        let content = NSRect(x: 0, y: 0, width: max(bounds.width - rulerInset, 0), height: bounds.height)
        let ruler = NSRect(x: bounds.width - DiffOverviewRuler.width, y: 0, width: DiffOverviewRuler.width,
                           height: bounds.height)
        if rulerView.frame != ruler { rulerView.frame = ruler }
        switch currentLayout {
        case .sideBySide:
            if splitView.frame != content { splitView.frame = content }
            if needsInitialDividerPosition, content.width > 0 {
                needsInitialDividerPosition = false
                splitView.adjustSubviews()
                splitView.setPosition((content.width - splitView.dividerThickness) * Self.splitViewDefaultRatio,
                                      ofDividerAt: 0)
            }
        case .inline, .none:
            if inlinePane.frame != content { inlinePane.frame = content }
        }
        for pane in activePanes { pane.tileForGeometry() }
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        refreshPanes()
    }

    override func layout() {
        super.layout()
        refreshPanes()
        updateRulerViewport()
        if pendingRevealChangeIndex != nil, !isRevealScheduled, canRevealNow {
            isRevealScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isRevealScheduled = false
                self.performPendingReveal()
            }
        }
    }

    private var canRevealNow: Bool {
        bounds.height > 0 && resolvedLayout() == currentLayout
    }

    private func performPendingReveal() {
        guard let index = pendingRevealChangeIndex, canRevealNow else { return }
        pendingRevealChangeIndex = nil
        goTo(changeIndex: index)
    }

    @objc private func layoutSettingDidChange(_ notification: Notification) {
        let key = notification.userInfo?[DiffLayoutSettings.changedKeyUserInfoKey] as? String
        if key == DiffLayoutSettings.renderOverviewRulerKey {
            rulerView.isHidden = !DiffLayoutSettings.renderOverviewRuler
            refreshPanes()
        } else if key == DiffLayoutSettings.wordWrapKey {
            let wrap = DiffLayoutSettings.wordWrap
            for pane in [inlinePane, leftPane, rightPane] { pane.wordWrap = wrap }
            refreshPanes()
        } else {
            rebuild(preserveScroll: true)
        }
    }

    private var anchorPane: DiffPaneView { activePanes[activePanes.count - 1] }

    private func refreshPanes() {
        guard !isUpdatingPanes else { return }
        if currentDiff != nil, resolvedLayout() != currentLayout {
            rebuild(preserveScroll: true)
            return
        }
        isUpdatingPanes = true
        defer { isUpdatingPanes = false }
        let start = anchorPane.viewportStart()
        positionSubviews()
        let panes = activePanes
        guard let build else { return }
        precondition(wraps.count == panes.count, "one wrap per active pane")
        let targets = panes.map(\.targetWrappingColumn)
        let rewrapped = zip(wraps, targets).map { $0.column != $1 }
        guard rewrapped.contains(true) else {
            for pane in panes { pane.linesView.updateFrameSize() }
            return
        }
        let newWraps = panes.indices.map { index in
            rewrapped[index] ? build.panes[index].text.rewrapped(wraps[index], column: targets[index]) : wraps[index]
        }
        apply(build, wraps: newWraps, textChanged: false, rewrapped: rewrapped)
        geometryPassCountForTesting += 1
        if let start {
            scrollActivePanes(toY: anchorPane.scrollY(for: start))
        } else {
            for pane in activePanes { pane.scrollToTop() }
        }
        updateRulerViewport()
    }

    private func rebuild(preserveScroll: Bool) {
        update(scroll: preserveScroll ? .preserved(captureContentAnchor()) : .top)
    }

    private func update(scroll: ScrollTarget) {
        guard let diff = currentDiff, !isUpdatingPanes else { return }
        isUpdatingPanes = true
        defer { isUpdatingPanes = false }
        let caret = caretDisplayIndex()
        hasCaret = false
        install(resolvedLayout())
        positionSubviews()
        let layout = currentLayout ?? resolvedLayout()
        let newBuild = makeBuild(diff: diff, layout: layout)
        let panes = activePanes
        let newWraps = panes.indices.map { index in
            let text = newBuild.panes[index].text
            return text.rewrapped(.unwrapped(rowCount: text.rowCount), column: panes[index].targetWrappingColumn)
        }
        apply(newBuild, wraps: newWraps, textChanged: true, rewrapped: Array(repeating: true, count: panes.count))
        geometryPassCountForTesting += 1
        if let caret, let caretRow = rows.firstIndex(where: {
            $0.left?.displayIndex == caret || $0.right?.displayIndex == caret
        }) {
            caretPane.placeInsertionPoint(atRow: caretRow)
            hasCaret = true
        }
        switch scroll {
        case .preserved(let anchor?):
            scrollActivePanes(toY: scrollY(for: anchor))
        case .top, .preserved(nil):
            for pane in activePanes { pane.scrollToTop() }
        }
        updateRulerViewport()
    }

    private func apply(_ build: Build, wraps newWraps: [DiffPaneWrap], textChanged: Bool, rewrapped: [Bool]) {
        let panes = activePanes
        precondition(build.panes.count == panes.count && newWraps.count == panes.count, "one wrap per active pane")
        let geometries = Self.geometries(blocks: build.blocks, wraps: newWraps)
        for (index, pane) in panes.enumerated() {
            pane.apply(content: build.panes[index], wrap: newWraps[index], geometry: geometries[index],
                       commentedLineIndices: build.commentedLineIndices, textChanged: textChanged,
                       rewrapped: rewrapped[index])
        }
        self.build = build
        wraps = newWraps
        displayLines = build.displayLines
        rows = build.rows
        blocks = build.blocks
        if textChanged { rulerView.zones = DiffOverviewRuler.zones(rows: build.rows) }
        let geometry = geometries[0]
        let inset = DiffMetrics.textInset.height
        rulerView.rowOffsets = (0..<min(build.rows.count, geometry.rowCount)).map { geometry.rowTop($0) - inset }
        rulerView.documentHeight = build.rows.isEmpty ? 0 : max(geometry.documentHeight - inset, 0)
    }

    private static func geometries(blocks: [Range<Int>], wraps: [DiffPaneWrap]) -> [DiffRowGeometry] {
        let rowHeight = DiffMetrics.rowHeight
        var pads = wraps.map { [CGFloat](repeating: 0, count: $0.segmentCounts.count) }
        if wraps.count == 2 {
            let left = wraps[0].segmentCounts.map { CGFloat($0) * rowHeight }
            let right = wraps[1].segmentCounts.map { CGFloat($0) * rowHeight }
            for pad in DiffBlockAlignment.padding(blocks: blocks, leftHeights: left, rightHeights: right) {
                pads[pad.side == .left ? 0 : 1][pad.row] = pad.pad
            }
        }
        return zip(wraps, pads).map { wrap, pads in
            DiffRowGeometry(segmentCounts: wrap.segmentCounts, pads: pads, rowHeight: rowHeight,
                            topInset: DiffMetrics.textInset.height)
        }
    }

    private func scrollActivePanes(toY y: CGFloat) {
        for pane in activePanes { pane.scroll(toY: y) }
    }

    private func displayIndex(ofRow row: Int) -> Int? {
        rows[row].right?.displayIndex ?? rows[row].left?.displayIndex
    }

    private func captureContentAnchor() -> ContentAnchor? {
        guard build != nil, let start = anchorPane.viewportStart() else { return nil }
        var row = start.row
        while row < rows.count, displayIndex(ofRow: row) == nil { row += 1 }
        guard row < rows.count, let index = displayIndex(ofRow: row) else { return nil }
        guard row != start.row else {
            return ContentAnchor(displayIndex: index, offset: start.offset, delta: start.delta)
        }
        let scrollY = anchorPane.scrollView.documentVisibleRect.minY
        return ContentAnchor(displayIndex: index, offset: 0, delta: scrollY - anchorPane.linesView.geometry.rowTop(row))
    }

    private func scrollY(for anchor: ContentAnchor) -> CGFloat {
        guard !rows.isEmpty else { return 0 }
        let exact = rows.firstIndex { $0.right?.displayIndex == anchor.displayIndex || $0.left?.displayIndex == anchor.displayIndex }
        let row = exact ?? rows.firstIndex { row in
            [row.left?.displayIndex, row.right?.displayIndex].contains { ($0 ?? -1) >= anchor.displayIndex }
        } ?? rows.count - 1
        let start = DiffViewportStart(row: row, offset: exact == nil ? 0 : anchor.offset, delta: anchor.delta)
        return anchorPane.scrollY(for: start)
    }

    @objc private func clipViewBoundsDidChange(_ notification: Notification) {
        guard !isUpdatingPanes, let source = notification.object as? NSClipView else { return }
        if source === activePanes.first?.scrollView.contentView {
            updateRulerViewport()
        }
        guard !isSyncingScroll, currentLayout == .sideBySide else { return }
        let sourcePane = source === leftPane.scrollView.contentView ? leftPane : rightPane
        let target = sourcePane === leftPane ? rightPane : leftPane
        let targetClip = target.scrollView.contentView
        let proposed = sourcePane.wordWrap
            ? NSPoint(x: targetClip.bounds.origin.x, y: source.bounds.origin.y)
            : source.bounds.origin
        let origin = targetClip.constrainBoundsRect(
            NSRect(origin: proposed, size: targetClip.bounds.size)).origin
        guard targetClip.bounds.origin != origin else { return }
        isSyncingScroll = true
        targetClip.scroll(to: origin)
        target.scrollView.reflectScrolledClipView(targetClip)
        isSyncingScroll = false
    }

    func display(diff: FileDiff) {
        let isNewFile = currentDiff?.path != diff.path
        let anchor = isNewFile ? nil : captureContentAnchor()
        currentDiff = diff
        update(scroll: isNewFile ? .top : .preserved(anchor))
        if isNewFile {
            currentChangeIndex = nil
            pendingRevealChangeIndex = diff.changes.isEmpty ? nil : 0
            needsLayout = true
        }
    }

    func redisplayWithComments() {
        guard currentDiff != nil else { return }
        rebuild(preserveScroll: true)
    }

    private func caretDisplayIndex() -> Int? {
        guard hasCaret, let row = caretPane.selectionStartRow, row < rows.count else { return nil }
        return rows[row].left?.displayIndex ?? rows[row].right?.displayIndex
    }

    private func makeBuild(diff: FileDiff, layout: DiffLayout) -> Build {
        guard !diff.isBinary else {
            let message = "Binary file \u{2014} cannot display diff"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 14, weight: .medium),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
            let attributed = NSAttributedString(string: "\n\n\t\(message)", attributes: attrs)
            let pane = DiffPaneContent(cells: [], text: DiffPaneText(cells: [], attributed: attributed), gutterRows: [])
            return Build(layout: .inline, displayLines: [], rows: [], blocks: [], panes: [pane],
                         commentedLineIndices: [])
        }

        let displayLines = reviewStore?.buildDisplayLines(from: diff.lines) ?? diff.lines.map { .diff($0) }

        var commentedLineIndices = Set<Int>()
        for comment in reviewStore?.comments ?? [] {
            let end = comment.endLineIndex ?? comment.lineIndex
            guard comment.lineIndex <= end else { continue }
            commentedLineIndices.formUnion(comment.lineIndex...end)
        }

        var built = DiffRowBuilder.buildLayout(displayLines: displayLines, changes: diff.changes, layout: layout)

        if DiffLayoutSettings.hideUnchangedRegionsEnabled && !diff.isTooLarge {
            let regions = UnchangedRegions.fromDiffs(
                changes: diff.changes,
                originalLineCount: diff.oldLineCount,
                modifiedLineCount: diff.newLineCount
            )
            revealState?.updateRegions(regions)
            let snapshot = revealState?.snapshot ?? DiffRevealSnapshot(counts: [:], isAllRevealed: false)
            built = UnchangedRegions.apply(
                layout: built,
                regions: regions,
                reveal: snapshot,
                forcedVisibleDisplayIndices: Self.forcedVisibleDisplayIndices(
                    displayLines: displayLines, commentedLineIndices: commentedLineIndices)
            )
        }

        let bannerMessage: String?
        if diff.isTooLarge {
            bannerMessage = "File too large to compare (> 50 MB)"
        } else if diff.hitTimeout {
            bannerMessage = "Diff computation stopped early (5000 ms)"
        } else {
            bannerMessage = nil
        }
        if bannerMessage != nil {
            let banner = DiffCell(displayIndex: nil, lineIndex: nil, kind: .banner,
                                  innerRanges: [], isWholeLineChange: false)
            built.rows.append(DiffLayoutRow(left: banner, right: layout == .sideBySide ? banner : nil))
            built.blocks.append((built.rows.count - 1)..<built.rows.count)
        }

        let showsOldNumbers = !(diff.isTooLarge && layout == .inline)
        let sides: [DiffSide] = layout == .sideBySide ? [.left, .right] : [.left]
        let panes = sides.map { side -> DiffPaneContent in
            let cells = built.rows.map { row -> DiffCell? in
                let cell = side == .left ? row.left : row.right
                return cell.map { Self.clampedToDisplayedText($0, displayLines: displayLines) }
            }
            let attributed = Self.attributedString(cells: cells, displayLines: displayLines, bannerMessage: bannerMessage)
            let gutterRows = cells.map { gutterRow(for: $0, lines: diff.lines, showsOldNumbers: showsOldNumbers) }
            return DiffPaneContent(cells: cells, text: DiffPaneText(cells: cells, attributed: attributed),
                                   gutterRows: gutterRows)
        }
        return Build(layout: layout, displayLines: displayLines, rows: built.rows, blocks: built.blocks,
                     panes: panes, commentedLineIndices: commentedLineIndices)
    }

    private func updateRulerViewport() {
        guard let pane = activePanes.first else { return }
        rulerView.viewportRect = pane.scrollView.documentVisibleRect
            .offsetBy(dx: 0, dy: -DiffMetrics.textInset.height)
        let description = visibleLinesDescription
        if rulerView.accessibilityValue() as? String != description {
            rulerView.setAccessibilityValue(description)
            NSAccessibility.post(element: rulerView, notification: .valueChanged)
        }
    }

    var visibleLinesDescription: String? {
        let range = visibleRowRange
        guard let diff = currentDiff, !range.isEmpty, range.upperBound <= rows.count,
              let first = modifiedLineForCursor(atRow: range.lowerBound),
              let last = modifiedLineForCursor(atRow: range.upperBound - 1) else { return nil }
        return "lines \(first)\u{2013}\(last) of \(diff.newLineCount)"
    }

    var visibleRowRange: Range<Int> {
        activePanes.first?.visibleRowRange ?? 0..<0
    }

    private var caretPane: DiffPaneView {
        currentLayout == .sideBySide ? rightPane : inlinePane
    }

    private func mirrorLeftSelectionToCaretPane() {
        guard currentLayout == .sideBySide, window?.firstResponder === leftPane.linesView,
              let row = leftPane.selectionStartRow else { return }
        rightPane.placeInsertionPoint(atRow: row)
        hasCaret = true
    }

    func row(forModifiedLine line: Int) -> Int? {
        rows.indices.first { modifiedLine(ofRow: $0) == line }
    }

    private func lineNumbers(of cell: DiffCell?) -> DiffLine? {
        guard let cell, case .line = cell.kind, let lineIndex = cell.lineIndex,
              let lines = currentDiff?.lines, lineIndex < lines.count else { return nil }
        return lines[lineIndex]
    }

    private func originalLine(ofRow row: Int) -> Int? {
        lineNumbers(of: rows[row].left)?.oldLineNumber
    }

    private func modifiedLine(ofRow row: Int) -> Int? {
        lineNumbers(of: rows[row].right ?? rows[row].left)?.newLineNumber
    }

    private func rowRange(for mapping: DetailedLineRangeMapping) -> Range<Int>? {
        let original = mapping.original.startLineNumber..<mapping.original.endLineNumberExclusive
        let modified = mapping.modified.startLineNumber..<mapping.modified.endLineNumberExclusive
        var lo: Int?
        var hi: Int?
        for index in rows.indices {
            let inOriginal = originalLine(ofRow: index).map(original.contains) ?? false
            let inModified = modifiedLine(ofRow: index).map(modified.contains) ?? false
            guard inOriginal || inModified else { continue }
            if lo == nil { lo = index }
            hi = index
        }
        guard let lo, let hi else { return nil }
        return lo..<(hi + 1)
    }

    private func modifiedLineForCursor(atRow row: Int) -> Int? {
        guard let diff = currentDiff, let line = unclampedModifiedLineForCursor(atRow: row) else { return nil }
        return min(line, max(diff.newLineCount, 1))
    }

    private func unclampedModifiedLineForCursor(atRow row: Int) -> Int? {
        func resolve(_ index: Int) -> Int? {
            if let line = modifiedLine(ofRow: index) { return line }
            guard let old = originalLine(ofRow: index) else { return nil }
            return currentDiff?.changes.first {
                ($0.original.startLineNumber..<$0.original.endLineNumberExclusive).contains(old)
            }?.modified.startLineNumber
        }
        guard rows.indices.contains(row) else { return nil }
        for index in stride(from: row, through: 0, by: -1) {
            if let line = resolve(index) { return line }
        }
        for index in (row + 1)..<rows.count {
            if let line = resolve(index) { return line }
        }
        return nil
    }

    func currentModifiedLine() -> Int? {
        let row: Int?
        if hasCaret {
            row = caretPane.selectionStartRow
        } else {
            row = activePanes.first?.rowIndexAtViewportCentre
        }
        return row.flatMap(modifiedLineForCursor(atRow:))
    }

    func goToDiff(_ direction: DiffChangeNavigator.Direction) {
        cancelPendingReveal()
        guard let diff = currentDiff, let line = currentModifiedLine(),
              let target = DiffChangeNavigator.target(changes: diff.changes, currentModifiedLine: line,
                                                      modifiedLineCount: diff.newLineCount, direction: direction)
        else { return }
        goTo(changeIndex: target)
    }

    private func cancelPendingReveal() {
        pendingRevealChangeIndex = nil
    }

    private func goTo(changeIndex index: Int) {
        guard let diff = currentDiff, diff.changes.indices.contains(index) else { return }
        let mapping = diff.changes[index]
        currentChangeIndex = index
        layoutSubtreeIfNeeded()
        let caretLine = min(mapping.modified.startLineNumber, max(diff.newLineCount, 1))
        if let caretRow = row(forModifiedLine: caretLine) {
            caretPane.placeInsertionPoint(atRow: caretRow)
            hasCaret = true
        }
        if let range = rowRange(for: mapping) {
            revealRowsInCenter(range)
        }
    }

    private func revealRowsInCenter(_ range: Range<Int>) {
        guard let pane = activePanes.first else { return }
        let geometry = pane.linesView.geometry
        let lo = min(max(range.lowerBound, 0), geometry.rowCount)
        let hi = min(max(range.upperBound, lo), geometry.rowCount)
        guard lo < hi else { return }
        let top = geometry.rowTop(lo)
        let height = geometry.rowBottom(hi - 1) - top
        let clipHeight = pane.scrollView.contentView.bounds.height
        scrollActivePanes(toY: height >= clipHeight ? top : top - (clipHeight - height) / 2)
        updateRulerViewport()
    }

    private static func forcedVisibleDisplayIndices(displayLines: [DisplayLine],
                                                    commentedLineIndices: Set<Int>) -> Set<Int> {
        var result = Set<Int>()
        var lineIndex = 0
        for (displayIndex, displayLine) in displayLines.enumerated() {
            switch displayLine {
            case .diff:
                if commentedLineIndices.contains(lineIndex) { result.insert(displayIndex) }
                lineIndex += 1
            case .commentBlock:
                result.insert(displayIndex)
            }
        }
        return result
    }

    private func gutterRow(for cell: DiffCell?, lines: [DiffLine], showsOldNumbers: Bool) -> GutterRow {
        guard let cell else {
            return GutterRow(oldNumber: nil, newNumber: nil, kind: nil, displayIndex: nil, lineIndex: nil, indicator: nil)
        }
        var oldNumber: Int?
        var newNumber: Int?
        var indicator: String?
        if let lineIndex = cell.lineIndex, lineIndex < lines.count {
            let line = lines[lineIndex]
            oldNumber = showsOldNumbers ? line.oldLineNumber : nil
            newNumber = line.newLineNumber
            switch line.type {
            case .addition: indicator = "+"
            case .deletion: indicator = "-"
            case .context, .hunkHeader, .meta: indicator = nil
            }
        }
        return GutterRow(oldNumber: oldNumber, newNumber: newNumber, kind: cell.kind,
                         displayIndex: cell.displayIndex, lineIndex: cell.lineIndex, indicator: indicator)
    }

    static func attributedString(cells: [DiffCell?], displayLines: [DisplayLine],
                                 bannerMessage: String?) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for (index, cell) in cells.enumerated() {
            if let cell {
                switch cell.kind {
                case .line(let type):
                    if let d = cell.displayIndex, d < displayLines.count, case .diff(let line) = displayLines[d] {
                        result.append(lineString(line, type: type, cell: cell))
                    }
                case .comment:
                    if let d = cell.displayIndex, d < displayLines.count,
                       case .commentBlock(let comment) = displayLines[d] {
                        result.append(commentString(comment))
                    }
                case .banner:
                    let attrs: [NSAttributedString.Key: Any] = [
                        .font: DiffMetrics.boldFont,
                        .foregroundColor: NSColor.systemOrange,
                    ]
                    result.append(NSAttributedString(string: bannerMessage ?? "", attributes: attrs))
                case .filler, .collapsedRegion:
                    break
                }
            }
            if index < cells.count - 1 {
                result.append(NSAttributedString(string: "\n", attributes: [.font: DiffMetrics.font]))
            }
        }
        return result
    }

    static let maxDisplayedLineLength = 10_000
    static let truncationSuffix = " [truncated]"

    static func displayedText(_ line: DiffLine, side: DiffSide) -> (text: String, contentLength: Int) {
        var units = Array((side == .left ? line.text : line.modifiedText).utf16)
        let isTruncated = units.count > maxDisplayedLineLength
        if isTruncated {
            var end = maxDisplayedLineLength
            if UTF16.isTrailSurrogate(units[end]) { end -= 1 }
            units.removeSubrange(end...)
        }
        for i in units.indices {
            switch units[i] {
            case 0x000D: units[i] = 0x240D
            case 0x2028: units[i] = 0x21B5
            case 0x2029: units[i] = 0x00B6
            case 0x0085: units[i] = 0x2424
            default: break
            }
        }
        let content = String(decoding: units, as: UTF16.self)
        return (isTruncated ? content + truncationSuffix : content, units.count)
    }

    static func clampedToDisplayedText(_ cell: DiffCell, displayLines: [DisplayLine]) -> DiffCell {
        guard case .line = cell.kind, !cell.innerRanges.isEmpty,
              let d = cell.displayIndex, d < displayLines.count, case .diff(let line) = displayLines[d] else {
            return cell
        }
        let length = displayedText(line, side: cell.textSide).contentLength
        var clamped = cell
        clamped.innerRanges = cell.innerRanges.compactMap { range in
            guard range.location <= length else { return nil }
            return NSRange(location: range.location, length: min(range.length, length - range.location))
        }
        return clamped
    }

    private static func lineString(_ line: DiffLine, type: DiffLineType, cell: DiffCell) -> NSAttributedString {
        let (text, contentLength) = displayedText(line, side: cell.textSide)
        var attrs: [NSAttributedString.Key: Any] = [.font: DiffMetrics.font]
        let innerColor: NSColor?
        switch type {
        case .addition:
            attrs[.foregroundColor] = NSColor(named: "diffAdditionText") ?? NSColor.systemGreen
            innerColor = DiffMetrics.additionInnerBackground
        case .deletion:
            attrs[.foregroundColor] = NSColor(named: "diffDeletionText") ?? NSColor.systemRed
            innerColor = DiffMetrics.deletionInnerBackground
        case .hunkHeader:
            attrs[.font] = DiffMetrics.boldFont
            attrs[.foregroundColor] = NSColor.systemCyan
            attrs[.backgroundColor] = NSColor.systemCyan.withAlphaComponent(0.06)
            innerColor = nil
        case .meta:
            attrs[.foregroundColor] = NSColor.secondaryLabelColor
            attrs[.obliqueness] = 0.1 as NSNumber
            innerColor = nil
        case .context:
            attrs[.foregroundColor] = NSColor.labelColor
            innerColor = nil
        }
        let string = NSMutableAttributedString(string: text, attributes: attrs)
        if let innerColor, !cell.isWholeLineChange {
            for range in cell.innerRanges where range.length > 0 && range.location < contentLength {
                let clamped = NSRange(location: range.location, length: min(range.length, contentLength - range.location))
                string.addAttribute(.backgroundColor, value: innerColor, range: clamped)
            }
        }
        return string
    }

    private static func commentString(_ comment: ReviewComment) -> NSAttributedString {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: DiffMetrics.font,
            .foregroundColor: NSColor.systemBlue,
        ]
        let symbol = String(utf16CodeUnits: [DiffPaneText.commentSymbol], count: 1)
        let prefix = comment.endLineIndex != nil ? "[\(comment.displayLineNumber)] " : ""
        return NSAttributedString(string: "\(symbol) \(prefix)\(comment.text)", attributes: attrs)
    }

    private func cell(pane: DiffPaneView, row: Int) -> DiffCell? {
        guard row >= 0, row < pane.cells.count else { return nil }
        return pane.cells[row]
    }

    private func handleRowClicked(pane: DiffPaneView, row: Int) {
        guard let cell = cell(pane: pane, row: row) else { return }
        switch cell.kind {
        case .collapsedRegion(let regionID, _):
            revealState?.showAll(regionID: regionID)
        case .comment:
            guard let store = reviewStore, let d = cell.displayIndex, d < displayLines.count,
                  case .commentBlock(let comment) = displayLines[d] else { return }
            showEditPopover(pane: pane, row: row, comment: comment, store: store)
        case .line(.addition), .line(.deletion), .line(.context):
            guard let store = reviewStore, let diff = currentDiff,
                  let lineIndex = cell.lineIndex, lineIndex < diff.lines.count else { return }
            showAddPopover(pane: pane, row: row, lineIndex: lineIndex, line: diff.lines[lineIndex], store: store)
        case .line, .filler, .banner:
            return
        }
    }

    private func handleCollapsedRowAction(pane: DiffPaneView, row: Int, action: CollapsedAction) {
        guard let cell = cell(pane: pane, row: row),
              case .collapsedRegion(let regionID, _) = cell.kind else { return }
        switch action {
        case .expandTop: revealState?.showMoreAbove(regionID: regionID, count: 20)
        case .expandBottom: revealState?.showMoreBelow(regionID: regionID, count: 20)
        case .expandAll: revealState?.showAll(regionID: regionID)
        }
    }

    private func presentPopover(_ controller: DiffCommentPopoverController, height: CGFloat,
                                pane: DiffPaneView, row: Int) {
        let popover = NSPopover()
        popover.contentViewController = controller
        controller.enclosingPopover = popover
        popover.contentSize = NSSize(width: 320, height: height)
        popover.behavior = .transient
        activePopover = popover
        popover.show(relativeTo: pane.rowRect(row), of: pane.lineNumberView, preferredEdge: .maxX)
    }

    private func showAddPopover(pane: DiffPaneView, row: Int, lineIndex: Int, line: DiffLine, store: DiffReviewStore) {
        activePopover?.close()
        let controller = DiffCommentPopoverController(mode: .add)
        controller.onAdd = { [weak self] text in
            store.addComment(
                lineIndex: lineIndex,
                lineNumber: line.newLineNumber,
                oldLineNumber: line.oldLineNumber,
                lineType: line.type,
                text: text
            )
            self?.redisplayWithComments()
        }
        presentPopover(controller, height: 80, pane: pane, row: row)
    }

    private func showEditPopover(pane: DiffPaneView, row: Int, comment: ReviewComment, store: DiffReviewStore) {
        activePopover?.close()
        let rangeHeader = comment.endLineIndex != nil ? comment.displayLineNumber : nil
        let controller = DiffCommentPopoverController(mode: .edit(existingText: comment.text), rangeHeader: rangeHeader)
        controller.onUpdate = { [weak self] text in
            store.updateComment(id: comment.id, text: text)
            self?.redisplayWithComments()
        }
        controller.onDelete = { [weak self] in
            store.removeComment(id: comment.id)
            self?.redisplayWithComments()
        }
        presentPopover(controller, height: comment.endLineIndex != nil ? 100 : 80, pane: pane, row: row)
    }

    private func handleRangeSelected(pane: DiffPaneView, startRow: Int, endRow: Int) {
        guard let store = reviewStore, let diff = currentDiff else { return }
        guard let display = DiffSideRangeResolver.displayRange(
            rows: rows, side: pane.side, startRow: startRow, endRow: endRow
        ) else { return }
        guard let range = DiffReviewStore.resolveDisplayRange(
            startDisplayIdx: display.start,
            endDisplayIdx: display.end,
            displayLines: displayLines
        ) else { return }

        guard range.startOriginal >= 0, range.endOriginal < diff.lines.count else { return }
        let startNum = DiffReviewStore.displayNumber(for: diff.lines[range.startOriginal])
        let endNum = DiffReviewStore.displayNumber(for: diff.lines[range.endOriginal])

        showAddPopoverForRange(
            pane: pane,
            row: max(startRow, endRow),
            startOriginal: range.startOriginal,
            endOriginal: range.endOriginal,
            rangeHeader: "Lines \(startNum) – \(endNum)",
            store: store
        )
    }

    private func showAddPopoverForRange(
        pane: DiffPaneView,
        row: Int,
        startOriginal: Int,
        endOriginal: Int,
        rangeHeader: String,
        store: DiffReviewStore
    ) {
        guard let diff = currentDiff else { return }
        activePopover?.close()
        let controller = DiffCommentPopoverController(mode: .add, rangeHeader: rangeHeader)
        controller.onAdd = { [weak self] text in
            store.addRangeComment(
                startLineIndex: startOriginal,
                endLineIndex: endOriginal,
                lines: diff.lines,
                text: text
            )
            self?.redisplayWithComments()
        }
        presentPopover(controller, height: 100, pane: pane, row: row)
    }
}

extension DiffView: NSSplitViewDelegate {
    func splitViewDidResizeSubviews(_ notification: Notification) {
        refreshPanes()
    }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat {
        max(proposedMinimumPosition, Self.splitViewMinPaneWidth)
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat {
        min(proposedMaximumPosition, splitView.bounds.width - splitView.dividerThickness - Self.splitViewMinPaneWidth)
    }
}
