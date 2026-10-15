// DiffView.swift
// Calyx
//
// Container of the diff panes: one inline `DiffPaneView`, or an
// `NSSplitView` with the original (left) and modified (right) panes.
// Rows come from `DiffRowBuilder` (+ `UnchangedRegions` when collapsing
// is enabled); the effective layout follows `DiffLayoutSettings`.

import AppKit

@MainActor
final class DiffView: NSView {
    static let splitViewDefaultRatio: CGFloat = 0.5
    static let splitViewMinPaneWidth: CGFloat = 200

    private let inlinePane = DiffPaneView(side: .left, gutterColumns: .dual, accessibilitySuffix: ".inline")
    private let leftPane = DiffPaneView(side: .left, gutterColumns: .single, accessibilitySuffix: ".old")
    private let rightPane = DiffPaneView(side: .right, gutterColumns: .single, accessibilitySuffix: ".new")
    private let splitView = NSSplitView()

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
    /// A width-driven layout switch detected in `layout()` is applied on
    /// the next main-queue turn, outside the layout pass.
    private var isLayoutSwitchPending = false
    private(set) var displayLines: [DisplayLine] = []
    private(set) var rows: [DiffLayoutRow] = []
    private(set) var currentLayout: DiffLayout?
    private var activePopover: NSPopover?
    private var isSyncingScroll = false
    private var needsInitialDividerPosition = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

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
        splitView.translatesAutoresizingMaskIntoConstraints = false
        splitView.addSubview(leftPane)
        splitView.addSubview(rightPane)

        inlinePane.translatesAutoresizingMaskIntoConstraints = false

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
        leftPane.onBecameFirstResponder = { [weak self] in self?.rightPane.clearSelection() }
        rightPane.onBecameFirstResponder = { [weak self] in self?.leftPane.clearSelection() }

        for pane in [leftPane, rightPane] {
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

    // MARK: Layout

    private func resolvedLayout() -> DiffLayout {
        if currentDiff?.isBinary == true { return .inline }
        return DiffLayoutSettings.effectiveLayout(preference: DiffLayoutSettings.preference, width: bounds.width)
    }

    private func install(_ layout: DiffLayout) {
        guard layout != currentLayout else { return }
        activePopover?.close()
        let view: NSView
        switch layout {
        case .inline:
            splitView.removeFromSuperview()
            view = inlinePane
        case .sideBySide:
            inlinePane.removeFromSuperview()
            view = splitView
            needsInitialDividerPosition = true
        }
        addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
            view.topAnchor.constraint(equalTo: topAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        currentLayout = layout
    }

    override func layout() {
        super.layout()
        // Swapping subviews, constraints and text storage must not happen
        // during the layout pass: schedule the switch once.
        if resolvedLayout() != currentLayout, !isLayoutSwitchPending {
            isLayoutSwitchPending = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isLayoutSwitchPending = false
                self.applyEffectiveLayout(preserveScroll: true, forceRebuild: false)
            }
        }
        if needsInitialDividerPosition, currentLayout == .sideBySide, splitView.bounds.width > 0 {
            needsInitialDividerPosition = false
            splitView.layoutSubtreeIfNeeded()
            splitView.setPosition(
                (splitView.bounds.width - splitView.dividerThickness) * Self.splitViewDefaultRatio,
                ofDividerAt: 0
            )
        }
    }

    @objc private func layoutSettingDidChange(_ notification: Notification) {
        applyEffectiveLayout(preserveScroll: true, forceRebuild: true)
    }

    /// Installs the effective layout and rebuilds. The scroll anchor is read
    /// from the pane active before the switch, so it survives the switch.
    private func applyEffectiveLayout(preserveScroll: Bool, forceRebuild: Bool) {
        let effective = resolvedLayout()
        let changed = effective != currentLayout
        guard changed || forceRebuild else { return }
        let anchor = preserveScroll ? firstVisibleDisplayIndex() : nil
        install(effective)
        rebuild(anchor: anchor)
    }

    // MARK: Scroll sync (side-by-side)

    /// Both axes follow the other pane, as VS Code's diff editor syncs
    /// scrollTop and scrollLeft between its two editors.
    @objc private func clipViewBoundsDidChange(_ notification: Notification) {
        guard !isSyncingScroll, currentLayout == .sideBySide,
              let source = notification.object as? NSClipView else { return }
        let target = source === leftPane.scrollView.contentView ? rightPane : leftPane
        let targetClip = target.scrollView.contentView
        // Each pane clamps to its own content (the panes' widths differ), as
        // each VS Code editor clamps scrollLeft to its own scrollWidth.
        let origin = targetClip.constrainBoundsRect(
            NSRect(origin: source.bounds.origin, size: targetClip.bounds.size)).origin
        guard targetClip.bounds.origin != origin else { return }
        isSyncingScroll = true
        targetClip.scroll(to: origin)
        target.scrollView.reflectScrolledClipView(targetClip)
        isSyncingScroll = false
    }

    // MARK: Display

    func display(diff: FileDiff) {
        let isNewFile = currentDiff?.path != diff.path
        // Anchor from the pane shown before `diff` may change the layout.
        let anchor = isNewFile ? nil : firstVisibleDisplayIndex()
        currentDiff = diff
        install(resolvedLayout())
        rebuild(anchor: anchor)
    }

    func redisplayWithComments() {
        guard currentDiff != nil else { return }
        rebuild(preserveScroll: true)
    }

    private func rebuild(preserveScroll: Bool) {
        rebuild(anchor: preserveScroll ? firstVisibleDisplayIndex() : nil)
    }

    private func rebuild(anchor: Int?) {
        guard let diff = currentDiff else { return }

        if diff.isBinary {
            displayLines = []
            rows = []
            inlinePane.setCommentedLineIndices([])
            displayBinaryMessage()
            return
        }

        let layout = currentLayout ?? resolvedLayout()
        displayLines = reviewStore?.buildDisplayLines(from: diff.lines) ?? diff.lines.map { .diff($0) }

        var commentedLineIndices = Set<Int>()
        for comment in reviewStore?.comments ?? [] {
            let end = comment.endLineIndex ?? comment.lineIndex
            guard comment.lineIndex <= end else { continue }
            commentedLineIndices.formUnion(comment.lineIndex...end)
        }

        var built = DiffRowBuilder.build(displayLines: displayLines, changes: diff.changes, layout: layout)

        // A too-large file was not compared: no line is known to be unchanged.
        if DiffLayoutSettings.hideUnchangedRegionsEnabled && !diff.isTooLarge {
            let regions = UnchangedRegions.fromDiffs(
                changes: diff.changes,
                originalLineCount: diff.oldLineCount,
                modifiedLineCount: diff.newLineCount
            )
            revealState?.updateRegions(regions)
            let snapshot = revealState?.snapshot ?? DiffRevealSnapshot(counts: [:], isAllRevealed: false)
            built = UnchangedRegions.apply(
                rows: built,
                regions: regions,
                reveal: snapshot,
                forcedVisibleDisplayIndices: forcedVisibleDisplayIndices(commentedLineIndices: commentedLineIndices)
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
            built.append(DiffLayoutRow(left: banner, right: layout == .sideBySide ? banner : nil))
        }
        rows = built

        // An uncompared file's inline view is the modified file alone.
        let showsOldNumbers = !(diff.isTooLarge && layout == .inline)
        for pane in activePanes {
            let cells = rows.map { row -> DiffCell? in
                let cell = pane.side == .left ? row.left : row.right
                return cell.map { Self.clampedToDisplayedText($0, displayLines: displayLines) }
            }
            let attributed = Self.attributedString(cells: cells, displayLines: displayLines, bannerMessage: bannerMessage)
            let gutterRows = cells.map { gutterRow(for: $0, lines: diff.lines, showsOldNumbers: showsOldNumbers) }
            pane.setCommentedLineIndices(commentedLineIndices)
            pane.setRows(cells: cells, attributed: attributed, gutterRows: gutterRows)
        }

        if let anchor {
            restoreScroll(toDisplayIndex: anchor)
        } else {
            for pane in activePanes { pane.scrollToRow(0) }
        }
    }

    /// Display indices of commented lines and of comment rows: the
    /// unchanged regions containing them stay expanded.
    private func forcedVisibleDisplayIndices(commentedLineIndices: Set<Int>) -> Set<Int> {
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

    // MARK: Scroll preservation

    private func firstVisibleDisplayIndex() -> Int? {
        guard let pane = activePanes.first, let first = pane.firstVisibleRow else { return nil }
        let paneCells = pane.cells
        for row in first..<paneCells.count {
            if let d = rowDisplayIndex(row, cells: paneCells) { return d }
        }
        return nil
    }

    /// Display index of the row from either side (rows of the pane's
    /// `cells` correspond to `rows`).
    private func rowDisplayIndex(_ row: Int, cells: [DiffCell?]) -> Int? {
        if row < rows.count {
            return rows[row].left?.displayIndex ?? rows[row].right?.displayIndex
        }
        return row < cells.count ? cells[row]?.displayIndex : nil
    }

    private func restoreScroll(toDisplayIndex anchor: Int) {
        var target: Int?
        for (index, row) in rows.enumerated() {
            let indices = [row.left?.displayIndex, row.right?.displayIndex].compactMap { $0 }
            if indices.contains(where: { $0 >= anchor }) {
                target = index
                break
            }
        }
        let row = target ?? max(rows.count - 1, 0)
        for pane in activePanes { pane.scrollToRow(row) }
    }

    // MARK: Attributed string

    private func displayBinaryMessage() {
        let message = "Binary file — cannot display diff"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 14, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        inlinePane.showMessage(NSAttributedString(string: "\n\n\t\(message)", attributes: attrs))
    }

    /// One paragraph per cell, joined by "\n" (the panes' row arithmetic
    /// depends on it: no other paragraph separator may appear).
    static func attributedString(cells: [DiffCell?], displayLines: [DisplayLine],
                                 bannerMessage: String?) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let paragraph = DiffMetrics.rowParagraphStyle
        let newline = NSAttributedString(string: "\n", attributes: [.font: DiffMetrics.font, .paragraphStyle: paragraph])

        for (index, cell) in cells.enumerated() {
            if index > 0 { result.append(newline) }
            guard let cell else {
                result.append(NSAttributedString(string: "", attributes: [.paragraphStyle: paragraph]))
                continue
            }
            switch cell.kind {
            case .line(let type):
                guard let d = cell.displayIndex, d < displayLines.count, case .diff(let line) = displayLines[d] else {
                    continue
                }
                result.append(lineString(line, type: type, cell: cell, paragraph: paragraph))
            case .comment:
                guard let d = cell.displayIndex, d < displayLines.count,
                      case .commentBlock(let comment) = displayLines[d] else { continue }
                result.append(commentString(comment, paragraph: paragraph))
            case .banner:
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: DiffMetrics.boldFont,
                    .foregroundColor: NSColor.systemOrange,
                    .paragraphStyle: paragraph,
                ]
                result.append(NSAttributedString(string: bannerMessage ?? "", attributes: attrs))
            case .filler, .collapsedRegion:
                // Drawn by DiffTextView (hatch / band + centred label).
                break
            }
        }
        return result
    }

    static let maxDisplayedLineLength = 10_000
    static let truncationSuffix = " [truncated]"

    /// A line cell's text as displayed: the cell's side of the line,
    /// truncated to `maxDisplayedLineLength` UTF-16 units (very long lines,
    /// e.g. minified files), with the characters NSTextView treats as
    /// line/paragraph breaks replaced one UTF-16 unit for one by visible
    /// symbols, so UTF-16 inner-range offsets stay valid. `contentLength`
    /// excludes the truncation suffix.
    static func displayedText(_ line: DiffLine, side: DiffSide) -> (text: String, contentLength: Int) {
        var units = Array((side == .left ? line.text : line.modifiedText).utf16)
        let isTruncated = units.count > maxDisplayedLineLength
        if isTruncated {
            var end = maxDisplayedLineLength
            // Do not split a surrogate pair.
            if UTF16.isTrailSurrogate(units[end]) { end -= 1 }
            units.removeSubrange(end...)
        }
        for i in units.indices {
            switch units[i] {
            case 0x000D: units[i] = 0x240D // CR -> SYMBOL FOR CARRIAGE RETURN
            case 0x2028: units[i] = 0x21B5 // LINE SEPARATOR -> DOWNWARDS ARROW WITH CORNER LEFTWARDS
            case 0x2029: units[i] = 0x00B6 // PARAGRAPH SEPARATOR -> PILCROW SIGN
            case 0x0085: units[i] = 0x2424 // NEXT LINE -> SYMBOL FOR NEWLINE
            default: break
            }
        }
        let content = String(decoding: units, as: UTF16.self)
        return (isTruncated ? content + truncationSuffix : content, units.count)
    }

    /// `cell` with inner ranges (and empty markers) clamped to the displayed
    /// content of its line, truncation suffix excluded.
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

    private static func lineString(_ line: DiffLine, type: DiffLineType, cell: DiffCell,
                                   paragraph: NSParagraphStyle) -> NSAttributedString {
        let (text, contentLength) = displayedText(line, side: cell.textSide)
        var attrs: [NSAttributedString.Key: Any] = [.font: DiffMetrics.font, .paragraphStyle: paragraph]
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

    private static func commentString(_ comment: ReviewComment, paragraph: NSParagraphStyle) -> NSAttributedString {
        let font = DiffMetrics.font
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.systemBlue,
            .paragraphStyle: paragraph,
        ]
        let result = NSMutableAttributedString()
        let config = NSImage.SymbolConfiguration(pointSize: font.pointSize, weight: .regular)
            .applying(NSImage.SymbolConfiguration(hierarchicalColor: .systemBlue))
        if let image = NSImage(systemSymbolName: "text.bubble", accessibilityDescription: "Comment")?
            .withSymbolConfiguration(config) {
            let attachment = NSTextAttachment()
            attachment.image = image
            let side = min(font.ascender - font.descender, DiffMetrics.rowHeight)
            let width = image.size.height > 0 ? side * image.size.width / image.size.height : side
            attachment.bounds = NSRect(x: 0, y: font.descender, width: width, height: side)
            let attachmentString = NSMutableAttributedString(attachment: attachment)
            attachmentString.addAttributes(attrs, range: NSRange(location: 0, length: attachmentString.length))
            result.append(attachmentString)
            result.append(NSAttributedString(string: " ", attributes: attrs))
        }
        let prefix = comment.endLineIndex != nil ? "[\(comment.displayLineNumber)] " : ""
        result.append(NSAttributedString(string: "\(prefix)\(comment.text)", attributes: attrs))
        return result
    }

    // MARK: - Comment Interaction

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
        // revealState.onChanged triggers the rebuild.
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

// MARK: - NSSplitViewDelegate

extension DiffView: NSSplitViewDelegate {
    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat {
        max(proposedMinimumPosition, Self.splitViewMinPaneWidth)
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat {
        min(proposedMaximumPosition, splitView.bounds.width - splitView.dividerThickness - Self.splitViewMinPaneWidth)
    }
}
