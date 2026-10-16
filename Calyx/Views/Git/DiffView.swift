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
    private let rulerView = DiffOverviewRulerView(frame: .zero)
    /// Trailing constraint of the installed content (inline pane or split
    /// view): inset by the ruler's width while the ruler is shown.
    private var contentTrailingConstraint: NSLayoutConstraint?

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
    /// Alignment blocks partitioning `rows` (side by side: each block's
    /// height is equalised across the panes).
    private(set) var blocks: [Range<Int>] = []
    private(set) var currentLayout: DiffLayout?
    private var activePopover: NSPopover?
    private var isSyncingScroll = false
    private var needsInitialDividerPosition = false
    /// Index into `currentDiff.changes` of the change last navigated to.
    private(set) var currentChangeIndex: Int?
    /// The panes' selection was placed by navigation or by the user since
    /// the last rebuild (a rebuild replaces the text and its selection).
    private var hasCaret = false
    /// Change to reveal once the view has a size and its final layout
    /// (a new diff is displayed before SwiftUI sizes the view).
    private var pendingRevealChangeIndex: Int?
    private var isRevealScheduled = false
    /// A viewport width change may have re-wrapped rows: realign on the
    /// next main-queue turn (coalesced; deferred during live resize).
    private var isRealignPending = false
    private var isRealignScheduled = false
    /// Viewport anchor read before the first re-wrap of a width change;
    /// held across re-wraps (live-resize ticks, both panes) until the
    /// realign that follows them restores it after the pads.
    private var widthChangeAnchor: DiffScrollAnchor?
    /// The width-change anchor is being applied: the scrolls it causes do
    /// not discard it.
    private var isRestoringAnchor = false
    /// A pane announced a re-wrap (`onViewportWidthWillChange`) and has not
    /// yet reported it done (`onViewportWidthChanged`): clip-view changes
    /// in between come from the re-wrap, not from a scroll.
    private var isWidthChangeInProgress = false
    /// Last observed clip-view y per pane: a bounds notification that
    /// leaves y unchanged (a size change) is not a scroll.
    private var lastClipOriginY: [ObjectIdentifier: CGFloat] = [:]
    /// Width of the last layout pass (0 before the first sized one).
    private var lastLayoutWidth: CGFloat = 0
    /// Row heights of the active pane after the last alignment pass.
    private var lastAlignedHeights: [CGFloat] = []

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
            pane.onViewportWidthWillChange = { [weak self] in
                self?.isWidthChangeInProgress = true
                self?.captureWidthChangeAnchor()
            }
            pane.onViewportWidthChanged = { [weak self] in
                self?.restoreWidthChangeAnchor()
                self?.isWidthChangeInProgress = false
                self?.scheduleRealign()
            }
        }
        leftPane.onBecameFirstResponder = { [weak self] in
            self?.rightPane.clearSelection()
            self?.hasCaret = true
        }
        // VS Code's goToDiff reads only the modified editor's cursor: a
        // selection the user makes in the original pane moves the modified
        // pane's caret to the same row.
        leftPane.onSelectionChanged = { [weak self] in self?.mirrorLeftSelectionToCaretPane() }
        rightPane.onBecameFirstResponder = { [weak self] in
            self?.leftPane.clearSelection()
            self?.hasCaret = true
        }
        inlinePane.onBecameFirstResponder = { [weak self] in self?.hasCaret = true }

        rulerView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rulerView)
        NSLayoutConstraint.activate([
            rulerView.trailingAnchor.constraint(equalTo: trailingAnchor),
            rulerView.topAnchor.constraint(equalTo: topAnchor),
            rulerView.bottomAnchor.constraint(equalTo: bottomAnchor),
            rulerView.widthAnchor.constraint(equalToConstant: DiffOverviewRuler.width),
        ])
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
        addSubview(view, positioned: .below, relativeTo: rulerView)
        let trailing = view.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -rulerInset)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            trailing,
            view.topAnchor.constraint(equalTo: topAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        contentTrailingConstraint = trailing
        currentLayout = layout
    }

    private var rulerInset: CGFloat {
        rulerView.isHidden ? 0 : DiffOverviewRuler.width
    }

    /// Shows or hides the ruler per `DiffLayoutSettings.renderOverviewRuler`.
    private func applyRulerVisibility() {
        rulerView.isHidden = !DiffLayoutSettings.renderOverviewRuler
        contentTrailingConstraint?.constant = -rulerInset
    }

    override func layout() {
        // A width change resizes the panes in this pass (scroll view tile,
        // clip and document frames) before they re-wrap: read the viewport
        // anchor from the old geometry now; the realign restores it.
        if bounds.width != lastLayoutWidth {
            if lastLayoutWidth > 0 {
                captureWidthChangeAnchor()
                scheduleRealign()
            }
            lastLayoutWidth = bounds.width
        }
        super.layout()
        // Swapping subviews, constraints and text storage must not happen
        // during the layout pass: schedule the switch once.
        if resolvedLayout() != currentLayout, !isLayoutSwitchPending {
            isLayoutSwitchPending = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isLayoutSwitchPending = false
                self.applyEffectiveLayout(preserveScroll: true, forceRebuild: false)
                // The next layout pass runs a reveal deferred until the layout settled.
                if self.pendingRevealChangeIndex != nil { self.needsLayout = true }
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
        updateRulerViewport()
        // Reveal outside the layout pass, once the layout is final.
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
        bounds.height > 0 && !isLayoutSwitchPending && resolvedLayout() == currentLayout
    }

    private func performPendingReveal() {
        guard let index = pendingRevealChangeIndex, canRevealNow else { return }
        pendingRevealChangeIndex = nil
        goTo(changeIndex: index)
    }

    @objc private func layoutSettingDidChange(_ notification: Notification) {
        let key = notification.userInfo?[DiffLayoutSettings.changedKeyUserInfoKey] as? String
        if key == DiffLayoutSettings.renderOverviewRulerKey {
            // The ruler only changes the content inset: no rebuild, so the
            // caret and scroll position stay.
            applyRulerVisibility()
            needsLayout = true
        } else if key == DiffLayoutSettings.wordWrapKey {
            applyWordWrap()
        } else {
            applyEffectiveLayout(preserveScroll: true, forceRebuild: true)
        }
    }

    /// Installs the effective layout and rebuilds. The scroll anchor is read
    /// from the pane active before the switch, so it survives the switch.
    private func applyEffectiveLayout(preserveScroll: Bool, forceRebuild: Bool) {
        let effective = resolvedLayout()
        let changed = effective != currentLayout
        guard changed || forceRebuild else { return }
        let anchor = preserveScroll ? firstVisibleDisplayIndex() : nil
        let caret = caretDisplayIndex()
        install(effective)
        rebuild(anchor: anchor, caretDisplayIndex: caret)
    }

    /// Applies `DiffLayoutSettings.wordWrap` to every pane and rebuilds;
    /// the scroll anchor and the caret survive.
    private func applyWordWrap() {
        let anchor = firstVisibleDisplayIndex()
        let caret = caretDisplayIndex()
        let wrap = DiffLayoutSettings.wordWrap
        for pane in [inlinePane, leftPane, rightPane] { pane.wordWrap = wrap }
        rebuild(anchor: anchor, caretDisplayIndex: caret)
    }

    // MARK: Realign (word wrap)

    /// The pane whose geometry anchors the viewport across a re-wrap: the
    /// modified side (VS Code's modified editor drives the viewport).
    private var anchorPane: DiffPaneView? { activePanes.last }

    /// Reads the anchor from the anchor pane's geometry before any pane
    /// re-wraps; later re-wraps of the same width change keep it.
    private func captureWidthChangeAnchor() {
        guard widthChangeAnchor == nil else { return }
        widthChangeAnchor = anchorPane?.captureScrollAnchor()
    }

    /// Re-applies the width-change anchor after a re-wrap (every
    /// live-resize tick included; the pad realign may still be pending).
    private func restoreWidthChangeAnchor() {
        guard let anchor = widthChangeAnchor else { return }
        restoreScroll(to: anchor)
    }

    /// Scrolls every active pane to the anchor pane's y for `anchor` (the
    /// side-by-side panes share one vertical position).
    private func restoreScroll(to anchor: DiffScrollAnchor) {
        guard let y = anchorPane?.scrollY(for: anchor) else { return }
        isRestoringAnchor = true
        defer { isRestoringAnchor = false }
        for pane in activePanes { pane.scroll(toY: y) }
    }

    /// A scroll the anchor restore did not cause (user or programmatic)
    /// supersedes a pending width-change anchor. Origin changes made by a
    /// re-wrap or by the pane's layout pass are geometry, not scrolls.
    private func discardWidthChangeAnchorIfScrolled(_ clip: NSClipView) {
        let key = ObjectIdentifier(clip)
        let y = clip.bounds.origin.y
        let previous = lastClipOriginY.updateValue(y, forKey: key)
        let isPaneLayout = activePanes.contains { $0.scrollView.contentView === clip && $0.isLayingOut }
        // A sync scroll mirrors the source pane, whose own notification decided.
        guard !isRestoringAnchor, !isWidthChangeInProgress, !isSyncingScroll, !isPaneLayout,
              previous != y else { return }
        widthChangeAnchor = nil
    }

    private func scheduleRealign() {
        isRealignPending = true
        guard !isRealignScheduled else { return }
        isRealignScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isRealignScheduled = false
            // Re-wrapping per live-resize tick is too costly: realign once at the end.
            guard self.window?.inLiveResize != true else { return }
            self.realignIfNeeded()
        }
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        realignIfNeeded()
    }

    /// Runs a pending realign now; the scroll anchor is restored only when
    /// the row geometry changed. Never touches the text content, so the
    /// caret survives.
    private func realignIfNeeded() {
        guard isRealignPending else { return }
        isRealignPending = false
        let anchor = widthChangeAnchor ?? anchorPane?.captureScrollAnchor()
        widthChangeAnchor = nil
        if alignPanes(), let anchor {
            restoreScroll(to: anchor)
        }
        updateRulerViewport()
    }

    /// Two-pass alignment: measure both panes' natural row heights, pad the
    /// shorter side of each block (one edit batch per pane, none when
    /// nothing changes), and zero wrap indents that leave no room. Feeds
    /// the ruler geometry. Returns whether the active pane's row geometry
    /// changed since the last pass.
    @discardableResult
    private func alignPanes() -> Bool {
        switch currentLayout {
        case .sideBySide:
            let needsPass = !rows.isEmpty && [leftPane, rightPane].contains { pane in
                pane.wrappingColumns != .max || pane.textView.hasLayoutAdjustments
            }
            if needsPass {
                // Indent zeroing changes wrap counts, so it runs before the
                // heights the pads are computed from are measured.
                leftPane.textView.applyIndentZeroing(wrappingColumns: leftPane.wrappingColumns)
                rightPane.textView.applyIndentZeroing(wrappingColumns: rightPane.wrappingColumns)
                let leftHeights = leftPane.textView.naturalHeights()
                let rightHeights = rightPane.textView.naturalHeights()
                var leftPads: [Int: CGFloat] = [:]
                var rightPads: [Int: CGFloat] = [:]
                for pad in DiffBlockAlignment.padding(blocks: blocks, leftHeights: leftHeights,
                                                      rightHeights: rightHeights) {
                    switch pad.side {
                    case .left: leftPads[pad.row] = pad.pad
                    case .right: rightPads[pad.row] = pad.pad
                    }
                }
                leftPane.textView.applyPadding(leftPads)
                rightPane.textView.applyPadding(rightPads)
            }
        case .inline, .none:
            if inlinePane.wrappingColumns != .max || inlinePane.textView.hasLayoutAdjustments {
                inlinePane.textView.applyIndentZeroing(wrappingColumns: inlinePane.wrappingColumns)
                inlinePane.textView.applyPadding([:])
            }
        }
        guard let pane = activePanes.first else { return false }
        let frames = pane.textView.ensureRowFrames()
        let inset = DiffMetrics.textInset.height
        rulerView.rowOffsets = frames.map { $0.minY - inset }
        rulerView.documentHeight = max((frames.last?.maxY ?? inset) - inset, 0)
        let heights = frames.map(\.height)
        let changed = heights != lastAlignedHeights
        lastAlignedHeights = heights
        return changed
    }

    // MARK: Scroll sync (side-by-side)

    /// Both axes follow the other pane, as VS Code's diff editor syncs
    /// scrollTop and scrollLeft between its two editors. A wrapping source
    /// pane has no horizontal scroll: only y follows.
    @objc private func clipViewBoundsDidChange(_ notification: Notification) {
        if let clip = notification.object as? NSClipView {
            discardWidthChangeAnchorIfScrolled(clip)
        }
        if let source = notification.object as? NSClipView,
           source === activePanes.first?.scrollView.contentView {
            updateRulerViewport()
        }
        guard !isSyncingScroll, currentLayout == .sideBySide,
              let source = notification.object as? NSClipView else { return }
        let sourcePane = source === leftPane.scrollView.contentView ? leftPane : rightPane
        let target = sourcePane === leftPane ? rightPane : leftPane
        let targetClip = target.scrollView.contentView
        let proposed = sourcePane.wordWrap
            ? NSPoint(x: targetClip.bounds.origin.x, y: source.bounds.origin.y)
            : source.bounds.origin
        // Each pane clamps to its own content (the panes' widths differ), as
        // each VS Code editor clamps scrollLeft to its own scrollWidth.
        let origin = targetClip.constrainBoundsRect(
            NSRect(origin: proposed, size: targetClip.bounds.size)).origin
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
        let caret = isNewFile ? nil : caretDisplayIndex()
        currentDiff = diff
        install(resolvedLayout())
        rebuild(anchor: anchor, caretDisplayIndex: caret)
        if isNewFile {
            // VS Code revealFirstDiff: a newly opened diff starts at its first change.
            currentChangeIndex = nil
            // Always deferred to layout() -> main queue: display(diff:) runs
            // inside SwiftUI's updateNSView, where no layout may be forced.
            pendingRevealChangeIndex = diff.changes.isEmpty ? nil : 0
            needsLayout = true
        }
    }

    func redisplayWithComments() {
        guard currentDiff != nil else { return }
        rebuild(preserveScroll: true)
    }

    private func rebuild(preserveScroll: Bool) {
        rebuild(anchor: preserveScroll ? firstVisibleDisplayIndex() : nil, caretDisplayIndex: caretDisplayIndex())
    }

    /// Display index of the cursor's row, read before a rebuild replaces
    /// the text (and its selection) so the caret stays on its line.
    private func caretDisplayIndex() -> Int? {
        guard hasCaret else { return nil }
        return caretPane.selectionStartRow.flatMap { rowDisplayIndex($0, cells: caretPane.cells) }
    }

    private func rebuild(anchor: Int?, caretDisplayIndex: Int?) {
        guard let diff = currentDiff else { return }
        hasCaret = false
        // Row indices change: a pending width-change anchor no longer applies.
        widthChangeAnchor = nil

        if diff.isBinary {
            displayLines = []
            rows = []
            blocks = []
            lastAlignedHeights = []
            rulerView.zones = DiffOverviewRuler.zones(rows: [])
            rulerView.rowOffsets = []
            rulerView.documentHeight = 0
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

        var built = DiffRowBuilder.buildLayout(displayLines: displayLines, changes: diff.changes, layout: layout)

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
                layout: built,
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
            built.rows.append(DiffLayoutRow(left: banner, right: layout == .sideBySide ? banner : nil))
            built.blocks.append((built.rows.count - 1)..<built.rows.count)
        }
        rows = built.rows
        blocks = built.blocks
        rulerView.zones = DiffOverviewRuler.zones(rows: rows)

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
        if let caretDisplayIndex, let caretRow = rows.firstIndex(where: {
            $0.left?.displayIndex == caretDisplayIndex || $0.right?.displayIndex == caretDisplayIndex
        }) {
            caretPane.placeInsertionPoint(atRow: caretRow)
            hasCaret = true
        }
        // Scroll targets need the final (aligned) row frames.
        alignPanes()

        if let anchor {
            restoreScroll(toDisplayIndex: anchor)
        } else {
            for pane in activePanes { pane.scrollToRow(0) }
        }
        updateRulerViewport()
    }

    // MARK: Overview ruler

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

    /// Modified lines shown in the active pane's viewport, e.g.
    /// "lines 2690–2712 of 3000"; nil when no visible row maps to a line.
    var visibleLinesDescription: String? {
        let range = visibleRowRange
        guard let diff = currentDiff, !range.isEmpty, range.upperBound <= rows.count,
              let first = modifiedLineForCursor(atRow: range.lowerBound),
              let last = modifiedLineForCursor(atRow: range.upperBound - 1) else { return nil }
        return "lines \(first)\u{2013}\(last) of \(diff.newLineCount)"
    }

    // MARK: Change navigation (VS Code DiffEditorWidget goToDiff / _goTo)

    /// Rows of the active pane intersecting its viewport.
    var visibleRowRange: Range<Int> {
        activePanes.first?.visibleRowRange ?? 0..<0
    }

    /// The pane holding the modified editor's cursor.
    private var caretPane: DiffPaneView {
        currentLayout == .sideBySide ? rightPane : inlinePane
    }

    /// Places the modified pane's caret on the row of the user's selection
    /// in the original pane (side-by-side rows are aligned).
    private func mirrorLeftSelectionToCaretPane() {
        guard currentLayout == .sideBySide, window?.firstResponder === leftPane.textView,
              let row = leftPane.selectionStartRow else { return }
        rightPane.placeInsertionPoint(atRow: row)
        hasCaret = true
    }

    /// Row showing modified line `line` (right cell side-by-side, the
    /// single cell inline).
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

    /// Rows showing the mapping's original or modified lines.
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

    /// Modified line of `row`: its modified cell's line, else the modified
    /// start of the mapping holding its original line, else the nearest
    /// row above (then below) that has one (filler, comment, collapsed rows).
    /// Clamped to the last line, as Monaco clamps cursor positions (a pure
    /// deletion at the end of the file starts at `newLineCount + 1`).
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

    /// The modified editor's cursor line: from the modified (right / inline)
    /// pane's caret, or the row at the vertical centre of the viewport
    /// without one.
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
        // User navigation wins over a reveal still waiting for layout.
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

    /// Port of `_goTo`: the modified cursor moves to the mapping's modified
    /// start (clamped to the last line, as Monaco clamps positions), then
    /// the mapping's rows are revealed in the centre.
    private func goTo(changeIndex index: Int) {
        guard let diff = currentDiff, diff.changes.indices.contains(index) else { return }
        let mapping = diff.changes[index]
        currentChangeIndex = index
        // The viewport and row geometry must be current.
        layoutSubtreeIfNeeded()
        realignIfNeeded()
        let caretLine = min(mapping.modified.startLineNumber, max(diff.newLineCount, 1))
        if let caretRow = row(forModifiedLine: caretLine) {
            caretPane.placeInsertionPoint(atRow: caretRow)
            hasCaret = true
        }
        if let range = rowRange(for: mapping) {
            revealRowsInCenter(range)
        }
    }

    /// Centres `range` vertically in every active pane; a range taller than
    /// the viewport starts at the top (VS Code revealRangeInCenter).
    private func revealRowsInCenter(_ range: Range<Int>) {
        // An explicit reveal supersedes a pending width-change anchor.
        widthChangeAnchor = nil
        guard let pane = activePanes.first else { return }
        let frames = pane.textView.ensureRowFrames()
        let lo = min(max(range.lowerBound, 0), frames.count)
        let hi = min(max(range.upperBound, lo), frames.count)
        guard lo < hi else { return }
        let top = frames[lo].minY
        let height = frames[hi - 1].maxY - top
        let clipHeight = pane.scrollView.contentView.bounds.height
        let y = height >= clipHeight ? top : top - (clipHeight - height) / 2
        for pane in activePanes { pane.scroll(toY: y) }
        updateRulerViewport()
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
        // An explicit scroll supersedes a pending width-change anchor.
        widthChangeAnchor = nil
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
    /// depends on it: no other paragraph separator may appear). Each
    /// paragraph, its terminating "\n" included, carries one row paragraph
    /// style; line paragraphs carry their wrap indent (VS Code
    /// `wrappingIndent: same`), the others none.
    static func attributedString(cells: [DiffCell?], displayLines: [DisplayLine],
                                 bannerMessage: String?) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let plain = DiffMetrics.rowParagraphStyle

        for (index, cell) in cells.enumerated() {
            var paragraph = plain
            if let cell {
                switch cell.kind {
                case .line(let type):
                    if let d = cell.displayIndex, d < displayLines.count, case .diff(let line) = displayLines[d] {
                        let text = displayedText(line, side: cell.textSide).text
                        let indent = DiffWrapIndent.columns(lineText: text, wrappingColumns: .max)
                        paragraph = DiffMetrics.paragraphStyle(indentColumns: indent, paragraphSpacing: 0)
                        result.append(lineString(line, type: type, cell: cell, paragraph: paragraph))
                    }
                case .comment:
                    if let d = cell.displayIndex, d < displayLines.count,
                       case .commentBlock(let comment) = displayLines[d] {
                        result.append(commentString(comment, paragraph: paragraph))
                    }
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
            if index < cells.count - 1 {
                result.append(NSAttributedString(string: "\n",
                                                 attributes: [.font: DiffMetrics.font, .paragraphStyle: paragraph]))
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
