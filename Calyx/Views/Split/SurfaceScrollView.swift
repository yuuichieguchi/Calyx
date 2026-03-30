// SurfaceScrollView.swift
// Calyx
//
// Wraps a SurfaceView inside an NSScrollView to provide a native scrollbar
// for terminal scrollback. The SurfaceView is placed on top of (not inside)
// the scroll view, which uses an empty document view sized to represent the
// total scrollback height.

@preconcurrency import AppKit

/// Flipped document view so scroll coordinates match top-to-bottom orientation.
private class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// NSScrollView subclass that only intercepts hits on its scroller.
/// All other hits pass through to the surfaceView underneath.
private class OverlayScrollView: NSScrollView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        if let scroller = verticalScroller, !scroller.isHidden {
            let scrollerPoint = scroller.convert(point, from: superview)
            if scroller.bounds.contains(scrollerPoint) {
                return super.hitTest(point)
            }
        }
        return nil
    }

}

@MainActor
class SurfaceScrollView: NSView {

    static let maxDocumentHeight: CGFloat = 1_000_000_000

    // MARK: - Static Helpers (testable)

    /// Validate and clamp scrollbar state values.
    /// Returns nil if total is 0 (nothing to scroll).
    static func validatedScrollbar(total: UInt64, offset: UInt64, len: UInt64) -> (total: Int, offset: Int, len: Int)? {
        guard total > 0 else { return nil }
        let clampedTotal = min(Int(clamping: total), Int.max / 2)
        let clampedLen = min(Int(clamping: len), clampedTotal)
        let maxOffset = max(clampedTotal - clampedLen, 0)
        let clampedOffset = min(Int(clamping: offset), maxOffset)
        return (clampedTotal, clampedOffset, clampedLen)
    }

    /// Calculate document height for the given scrollbar parameters.
    static func documentHeight(total: Int, len: Int, cellHeight: CGFloat, contentHeight: CGFloat) -> CGFloat {
        let gridHeight = CGFloat(total) * cellHeight
        let padding = contentHeight - CGFloat(len) * cellHeight
        return min(gridHeight + padding, maxDocumentHeight)
    }

    /// Convert a ghostty scroll offset (row index from top) to AppKit Y coordinate.
    static func offsetToScrollY(offset: Int, cellHeight: CGFloat) -> CGFloat {
        CGFloat(offset) * cellHeight
    }

    /// Convert an AppKit scroll Y position to a ghostty row index.
    static func scrollYToRow(scrollY: CGFloat, cellHeight: CGFloat) -> Int {
        guard cellHeight > 0 else { return 0 }
        guard scrollY >= 0 else { return 0 }
        return Int(scrollY / cellHeight)
    }

    /// Clamp a row value to valid range [0, total-len].
    static func clampRow(_ row: Int, total: Int, len: Int) -> Int {
        let maxRow = max(total - len, 0)
        return max(0, min(row, maxRow))
    }

    /// Returns true if this row should be sent (differs from last sent row).
    static func shouldSendScrollRow(_ row: Int, lastSentRow: Int) -> Bool {
        row != lastSentRow
    }

    /// Coalesce scroll rows: always takes the latest value.
    static func coalesceScrollRow(pending: Int?, newRow: Int) -> Int {
        newRow
    }

    /// Describes expected isLiveScrolling state after notification events.
    static func liveScrollState(
        afterWillStart: Bool = false,
        afterDidLiveScroll: Bool = false,
        afterDidEnd: Bool = false
    ) -> Bool {
        if afterDidEnd { return false }
        if afterWillStart || afterDidLiveScroll { return true }
        return false
    }

    /// Returns true if enough time has passed to flash scrollers again.
    static func shouldFlashScrollers(lastFlashTime: CFTimeInterval, now: CFTimeInterval, interval: CFTimeInterval = 0.1) -> Bool {
        lastFlashTime == 0 || now - lastFlashTime > interval
    }

    // MARK: - Instance Properties

    private let scrollView = OverlayScrollView()
    private let documentContentView = FlippedView() // documentView
    private(set) var surfaceView: SurfaceView

    private var cellHeight: CGFloat = 0
    private var lastFlashTime: CFTimeInterval = 0
    private var isLiveScrolling = false
    private var lastAppliedOffset: Int = -1
    private var lastSentRow: Int = -1
    private var lastKnownTotal: Int = 0
    private var lastKnownLen: Int = 0

    private var pendingScrollRow: Int?
    private var throttleScheduled = false

    private var pendingScrollbarOffset: Int?
    private var scrollbarUIScheduled = false

    private var cellSizeObserver: NSObjectProtocol?
    private var configChangeObserver: NSObjectProtocol?

    private var searchBar: SearchBarView?
    private var startSearchObserver: NSObjectProtocol?
    private var endSearchObserver: NSObjectProtocol?
    private var searchTotalObserver: NSObjectProtocol?
    private var searchSelectedObserver: NSObjectProtocol?

    // MARK: - Cell Height

    private func applyCellHeight(pixelHeight: CGFloat) {
        guard pixelHeight > 0, let window = surfaceView.window else { return }
        cellHeight = pixelHeight / window.backingScaleFactor
        synchronizeLayout()

        // Apply any cached scrollbar state now that cellHeight is available.
        if let scrollbar = surfaceView.surfaceController?.scrollbar {
            handleScrollbarUpdate(scrollbar)
        }
    }

    // MARK: - Init

    init(surfaceView: SurfaceView) {
        self.surfaceView = surfaceView
        super.init(frame: .zero)
        setupScrollView()
        setupObservers()
        setupSearchObservers()
        surfaceView.scrollbarUpdateHandler = { [weak self] state in
            self?.surfaceView.checkScrollbarStateTransitions()
            self?.handleScrollbarUpdate(state)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        MainActor.assumeIsolated {
            surfaceView.scrollbarUpdateHandler = nil
            pendingScrollRow = nil
            if let obs = cellSizeObserver { NotificationCenter.default.removeObserver(obs) }
            if let obs = configChangeObserver { NotificationCenter.default.removeObserver(obs) }
            if let obs = startSearchObserver { NotificationCenter.default.removeObserver(obs) }
            if let obs = endSearchObserver { NotificationCenter.default.removeObserver(obs) }
            if let obs = searchTotalObserver { NotificationCenter.default.removeObserver(obs) }
            if let obs = searchSelectedObserver { NotificationCenter.default.removeObserver(obs) }
            NotificationCenter.default.removeObserver(self)
        }
    }

    override var isFlipped: Bool { true }

    // MARK: - Setup

    private func setupScrollView() {
        // Configure overlay-style scrollbar
        scrollView.scrollerStyle = .overlay
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerKnobStyle = .default

        // The documentView is an empty NSView that defines scrollable height
        scrollView.documentView = documentContentView

        // Disable elastic scrolling
        scrollView.verticalScrollElasticity = .none
        scrollView.horizontalScrollElasticity = .none

        addSubview(surfaceView)
        addSubview(scrollView)

        // Register for live scroll notifications
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(scrollViewWillStartLiveScroll(_:)),
            name: NSScrollView.willStartLiveScrollNotification,
            object: scrollView
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(scrollViewDidLiveScroll(_:)),
            name: NSScrollView.didLiveScrollNotification,
            object: scrollView
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(scrollViewDidEndLiveScroll(_:)),
            name: NSScrollView.didEndLiveScrollNotification,
            object: scrollView
        )

        // Apply scrollbar config
        applyScrollbarConfig()
    }

    private func setupObservers() {
        // Observe cell size changes for this surface only
        cellSizeObserver = NotificationCenter.default.addObserver(
            forName: .ghosttyCellSizeChange,
            object: surfaceView,
            queue: .main
        ) { [weak self] notification in
            let height = notification.userInfo?["height"] as? Double
            MainActor.assumeIsolated {
                guard let self, let height else { return }
                self.applyCellHeight(pixelHeight: CGFloat(height))
            }
        }

        // Observe config changes
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .ghosttyConfigChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            nonisolated(unsafe) let obj = notification.object
            MainActor.assumeIsolated {
                guard let self else { return }
                // Accept if object is nil (app-level) or matches our surfaceView
                let surfaceObj = obj as? SurfaceView
                if surfaceObj == nil || surfaceObj === self.surfaceView {
                    self.applyScrollbarConfig()
                }
            }
        }
    }

    private func applyScrollbarConfig() {
        let mode = GhosttyAppController.shared.configManager.scrollbarMode
        scrollView.hasVerticalScroller = (mode == .system)
    }

    // MARK: - Layout

    override func layout() {
        super.layout()

        // Enable clipping for smooth scroll CATransform3D overflow.
        // Done here (not init) because the layer needs a non-zero bounds first.
        if let layer, !layer.masksToBounds {
            layer.masksToBounds = true
        }

        synchronizeLayout()
    }

    private func synchronizeLayout() {
        let contentSize = bounds.size
        guard contentSize.width > 0, contentSize.height > 0 else { return }

        // Apply initial cell size if missed during surface init.
        if cellHeight <= 0 {
            if surfaceView.cachedCellSize.height > 0 {
                applyCellHeight(pixelHeight: surfaceView.cachedCellSize.height)
                return  // applyCellHeight calls synchronizeLayout again with cellHeight set.
            }
        }

        // ScrollView fills our entire bounds
        scrollView.frame = bounds

        // Surface view matches our content size (viewport)
        surfaceView.frame.size = contentSize

        // Update document height if we have scrollbar data
        if lastKnownTotal > 0, cellHeight > 0 {
            let docHeight = Self.documentHeight(
                total: lastKnownTotal,
                len: lastKnownLen,
                cellHeight: cellHeight,
                contentHeight: contentSize.height
            )
            documentContentView.frame = NSRect(
                x: 0, y: 0,
                width: contentSize.width,
                height: docHeight
            )
        } else {
            // No scrollback: document matches viewport
            documentContentView.frame = NSRect(
                x: 0, y: 0,
                width: contentSize.width,
                height: contentSize.height
            )
        }

        // Surface is a sibling of scrollView (not inside it), so it stays at origin.
        surfaceView.frame.origin = .zero

        layoutSearchBar()
    }

    // MARK: - Scrollbar Update (Core → UI)

    private func handleScrollbarUpdate(_ state: GhosttySurfaceController.ScrollbarState) {
        guard let validated = Self.validatedScrollbar(
            total: state.total,
            offset: state.offset,
            len: state.len
        ) else { return }

        lastKnownTotal = validated.total
        lastKnownLen = validated.len

        guard cellHeight > 0 else { return }

        let contentSize = bounds.size
        guard contentSize.width > 0, contentSize.height > 0 else { return }

        // Always update document height
        let docHeight = Self.documentHeight(
            total: validated.total,
            len: validated.len,
            cellHeight: cellHeight,
            contentHeight: contentSize.height
        )
        let newSize = NSSize(width: contentSize.width, height: docHeight)
        if documentContentView.frame.size != newSize {
            documentContentView.frame.size = newSize
        }

        // Skip position update if user is dragging scrollbar
        guard !isLiveScrolling else { return }

        // Skip if this is the same offset we already applied
        guard validated.offset != lastAppliedOffset else { return }
        lastAppliedOffset = validated.offset

        // Defer scrollbar UI update to avoid blocking the synchronous FFI call path.
        // The core callback fires inside ghostty_surface_mouse_scroll; heavy UI work
        // here delays scrollWheel from returning and starves event delivery.
        scheduleScrollbarUIUpdate(offset: validated.offset)
    }

    // MARK: - Scrollbar UI Coalescing

    private func scheduleScrollbarUIUpdate(offset: Int) {
        pendingScrollbarOffset = offset
        guard !scrollbarUIScheduled else { return }
        scrollbarUIScheduled = true
        RunLoop.main.perform(inModes: [.common]) { [weak self] in
            MainActor.assumeIsolated {
                self?.flushScrollbarUIUpdate()
            }
        }
    }

    private func flushScrollbarUIUpdate() {
        scrollbarUIScheduled = false
        guard let offset = pendingScrollbarOffset else { return }
        pendingScrollbarOffset = nil

        guard cellHeight > 0 else { return }
        let scrollY = Self.offsetToScrollY(offset: offset, cellHeight: cellHeight)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: scrollY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        let now = CACurrentMediaTime()
        if Self.shouldFlashScrollers(lastFlashTime: lastFlashTime, now: now) {
            lastFlashTime = now
            scrollView.flashScrollers()
        }
        surfaceView.frame.origin = .zero
    }

    // MARK: - Live Scroll (UI → Core)

    @objc private func scrollViewWillStartLiveScroll(_ notification: Notification) {
        isLiveScrolling = true
        surfaceView.resetSmoothScrollOffset()
    }

    @objc private func scrollViewDidLiveScroll(_ notification: Notification) {
        isLiveScrolling = true

        // Surface stays at origin; ghostty re-renders the visible content.
        surfaceView.frame.origin = .zero

        guard cellHeight > 0 else { return }

        let scrollY = scrollView.contentView.documentVisibleRect.origin.y
        let row = Self.scrollYToRow(scrollY: scrollY, cellHeight: cellHeight)
        let clampedRow = Self.clampRow(row, total: lastKnownTotal, len: lastKnownLen)

        scheduleLiveScrollUpdate(row: clampedRow)
    }

    @objc private func scrollViewDidEndLiveScroll(_ notification: Notification) {
        // Flush any pending scroll
        flushPendingScroll()

        // Final reconciliation: send the final position to core
        guard cellHeight > 0 else {
            isLiveScrolling = false
            return
        }

        let scrollY = scrollView.contentView.documentVisibleRect.origin.y
        let row = Self.scrollYToRow(scrollY: scrollY, cellHeight: cellHeight)
        let clampedRow = Self.clampRow(row, total: lastKnownTotal, len: lastKnownLen)
        sendScrollToRow(clampedRow)

        isLiveScrolling = false
    }

    // MARK: - Throttling

    private func scheduleLiveScrollUpdate(row: Int) {
        pendingScrollRow = row
        guard !throttleScheduled else { return }
        throttleScheduled = true
        RunLoop.main.perform(inModes: [.common]) { [weak self] in
            MainActor.assumeIsolated {
                self?.flushPendingScroll()
            }
        }
    }

    private func flushPendingScroll() {
        throttleScheduled = false
        guard let row = pendingScrollRow else { return }
        pendingScrollRow = nil
        sendScrollToRow(row)
    }

    private func sendScrollToRow(_ row: Int) {
        // Dedup: don't send same row twice
        guard Self.shouldSendScrollRow(row, lastSentRow: lastSentRow) else { return }
        lastSentRow = row

        surfaceView.surfaceController?.performAction("scroll_to_row:\(row)")
    }

    // MARK: - Search Bar Integration

    private func setupSearchObservers() {
        guard startSearchObserver == nil,
              endSearchObserver == nil,
              searchTotalObserver == nil,
              searchSelectedObserver == nil else { return }

        startSearchObserver = NotificationCenter.default.addObserver(
            forName: .ghosttyStartSearch,
            object: surfaceView,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self else { return }
                let needle = notification.userInfo?["needle"] as? String ?? ""
                self.showSearchBar(needle: needle)
            }
        }

        endSearchObserver = NotificationCenter.default.addObserver(
            forName: .ghosttyEndSearch,
            object: surfaceView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.hideSearchBar()
            }
        }

        searchTotalObserver = NotificationCenter.default.addObserver(
            forName: .ghosttySearchTotal,
            object: surfaceView,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self, let total = notification.userInfo?["total"] as? Int else { return }
                self.searchBar?.updateMatchTotal(total)
            }
        }

        searchSelectedObserver = NotificationCenter.default.addObserver(
            forName: .ghosttySearchSelected,
            object: surfaceView,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self, let selected = notification.userInfo?["selected"] as? Int else { return }
                self.searchBar?.updateMatchSelected(selected)
            }
        }
    }

    private func showSearchBar(needle: String) {
        if searchBar == nil {
            let bar = SearchBarView(frame: .zero)
            bar.sender = surfaceView.surfaceController
            searchBar = bar
            addSubview(bar)
        }

        guard let searchBar else { return }
        searchBar.resetSearchState()

        if !needle.isEmpty {
            searchBar.setSearchText(needle)
            searchBar.lastSubmittedQuery = needle
            surfaceView.surfaceController?.performSearch(query: needle)
        }

        layoutSearchBar()
        searchBar.focusSearchField()
    }

    private func hideSearchBar() {
        searchBar?.resetSearchState()
        searchBar?.setSearchText("")
        searchBar?.removeFromSuperview()
        searchBar = nil
        window?.makeFirstResponder(surfaceView)
    }

    private func layoutSearchBar() {
        guard let searchBar else { return }
        let barHeight: CGFloat = 36
        let padding: CGFloat = 8
        let barWidth = min(bounds.width - padding * 2, 500)
        searchBar.frame = NSRect(
            x: bounds.width - barWidth - padding,
            y: padding,  // top in flipped coordinates (isFlipped = true)
            width: barWidth,
            height: barHeight
        )
    }
}
