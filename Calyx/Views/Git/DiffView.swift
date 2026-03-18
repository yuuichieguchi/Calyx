// DiffView.swift
// Calyx
//
// AppKit-based diff viewer with line number gutter and syntax coloring.

import AppKit

@MainActor
final class DiffView: NSView {
    private let scrollView = NSScrollView()
    private let textView = DiffTextView()
    private let lineNumberView = DiffLineNumberView()
    private(set) var currentDiff: FileDiff?
    var reviewStore: DiffReviewStore?
    private(set) var displayLines: [DisplayLine] = []
    private var activePopover: NSPopover?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func setupViews() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        // Scroll view
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        addSubview(scrollView)

        // Text view
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.usesFindBar = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.textContainerInset = NSSize(width: 4, height: 4)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.drawsBackground = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        scrollView.documentView = textView

        // Line number ruler
        scrollView.rulersVisible = true
        scrollView.hasVerticalRuler = true
        scrollView.verticalRulerView = lineNumberView
        lineNumberView.clientView = textView

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        // Observe text changes for ruler updates
        NotificationCenter.default.addObserver(
            self, selector: #selector(textDidChange(_:)),
            name: NSView.frameDidChangeNotification, object: textView
        )

        // Wire up line click callback (gutter)
        lineNumberView.onLineClicked = { [weak self] displayLineIndex, displayLine in
            self?.handleLineClicked(displayLineIndex: displayLineIndex, displayLine: displayLine)
        }

        // Wire up comment text click (💬 lines in text view)
        textView.onCommentLineClicked = { [weak self] textLineIndex in
            guard let self, textLineIndex < self.displayLines.count else { return }
            let displayLine = self.displayLines[textLineIndex]
            if case .commentBlock = displayLine {
                self.handleLineClicked(displayLineIndex: textLineIndex, displayLine: displayLine)
            }
        }
    }

    @objc private func textDidChange(_ notification: Notification) {
        lineNumberView.needsDisplay = true
    }

    func display(diff: FileDiff) {
        currentDiff = diff

        if diff.isBinary {
            displayBinaryMessage()
            return
        }

        rebuildDisplayLines()
        let attributed = buildAttributedString(from: displayLines)
        textView.textStorage?.setAttributedString(attributed)

        if diff.isTruncated {
            appendTruncationBanner()
        }

        lineNumberView.needsDisplay = true
    }

    func redisplayWithComments() {
        guard let diff = currentDiff, !diff.isBinary else { return }
        rebuildDisplayLines()
        let attributed = buildAttributedString(from: displayLines)
        textView.textStorage?.setAttributedString(attributed)
        if diff.isTruncated {
            appendTruncationBanner()
        }
        lineNumberView.needsDisplay = true
    }

    private func rebuildDisplayLines() {
        guard let diff = currentDiff else {
            displayLines = []
            lineNumberView.displayLines = []
            lineNumberView.commentedLineIndices = []
            return
        }
        if let store = reviewStore {
            displayLines = store.buildDisplayLines(from: diff.lines)
            // Build set of diff line indices that have comments
            lineNumberView.commentedLineIndices = Set(store.comments.map { $0.lineIndex })
        } else {
            displayLines = diff.lines.map { .diff($0) }
            lineNumberView.commentedLineIndices = []
        }
        lineNumberView.displayLines = displayLines
    }

    private func displayBinaryMessage() {
        lineNumberView.displayLines = []
        lineNumberView.commentedLineIndices = []
        displayLines = []
        let message = "Binary file — cannot display diff"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 14, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        textView.textStorage?.setAttributedString(NSAttributedString(string: "\n\n\t\(message)", attributes: attrs))
    }

    private func appendTruncationBanner() {
        let banner = "\n\n--- Diff truncated (file too large) ---\n"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .bold),
            .foregroundColor: NSColor.systemOrange,
            .backgroundColor: NSColor.systemOrange.withAlphaComponent(0.1),
        ]
        textView.textStorage?.append(NSAttributedString(string: banner, attributes: attrs))
    }

    private func buildAttributedString(from displayLines: [DisplayLine]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let boldFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .bold)

        for (index, displayLine) in displayLines.enumerated() {
            if index > 0 {
                result.append(NSAttributedString(string: "\n"))
            }

            switch displayLine {
            case .diff(let line):
                // Truncate very long lines (minified files)
                var text = line.text
                if text.count > 10_000 {
                    text = String(text.prefix(10_000)) + " [truncated]"
                }

                let attrs: [NSAttributedString.Key: Any]
                switch line.type {
                case .addition:
                    attrs = [
                        .font: font,
                        .foregroundColor: NSColor(named: "diffAdditionText") ?? NSColor.systemGreen,
                        .backgroundColor: NSColor.systemGreen.withAlphaComponent(0.08),
                    ]
                case .deletion:
                    attrs = [
                        .font: font,
                        .foregroundColor: NSColor(named: "diffDeletionText") ?? NSColor.systemRed,
                        .backgroundColor: NSColor.systemRed.withAlphaComponent(0.08),
                    ]
                case .hunkHeader:
                    attrs = [
                        .font: boldFont,
                        .foregroundColor: NSColor.systemCyan,
                        .backgroundColor: NSColor.systemCyan.withAlphaComponent(0.06),
                    ]
                case .meta:
                    attrs = [
                        .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                        .foregroundColor: NSColor.secondaryLabelColor,
                        .obliqueness: 0.1 as NSNumber,
                    ]
                case .context:
                    attrs = [
                        .font: font,
                        .foregroundColor: NSColor.labelColor,
                    ]
                }
                result.append(NSAttributedString(string: text, attributes: attrs))

            case .commentBlock(let comment):
                let commentText = "\u{1F4AC} \(comment.text)"
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .foregroundColor: NSColor.systemBlue,
                    .backgroundColor: NSColor.systemBlue.withAlphaComponent(0.08),
                ]
                result.append(NSAttributedString(string: commentText, attributes: attrs))
            }
        }

        return result
    }

    // MARK: - Comment Interaction

    private func handleLineClicked(displayLineIndex: Int, displayLine: DisplayLine) {
        guard let store = reviewStore else { return }

        switch displayLine {
        case .diff(let line):
            // Only commentable types
            guard line.type == .addition || line.type == .deletion || line.type == .context else { return }

            // Find the original lineIndex in diff.lines by counting .diff entries
            var diffCount = 0
            for i in 0..<displayLineIndex {
                if case .diff = displayLines[i] {
                    diffCount += 1
                }
            }
            let originalIndex = diffCount

            showAddPopover(
                atDisplayLineIndex: displayLineIndex,
                originalDiffLineIndex: originalIndex,
                line: line,
                store: store
            )

        case .commentBlock(let comment):
            showEditPopover(
                atDisplayLineIndex: displayLineIndex,
                comment: comment,
                store: store
            )
        }
    }

    private func showAddPopover(atDisplayLineIndex: Int, originalDiffLineIndex: Int, line: DiffLine, store: DiffReviewStore) {
        activePopover?.close()

        let controller = DiffCommentPopoverController(mode: .add)
        controller.onAdd = { [weak self] text in
            store.addComment(
                lineIndex: originalDiffLineIndex,
                lineNumber: line.newLineNumber,
                oldLineNumber: line.oldLineNumber,
                lineType: line.type,
                text: text
            )
            self?.redisplayWithComments()
        }

        let popover = NSPopover()
        popover.contentViewController = controller
        controller.enclosingPopover = popover
        popover.contentSize = NSSize(width: 320, height: 80)
        popover.behavior = .transient
        activePopover = popover

        let rect = rectForLine(at: atDisplayLineIndex)
        popover.show(relativeTo: rect, of: lineNumberView, preferredEdge: .maxX)
    }

    private func showEditPopover(atDisplayLineIndex: Int, comment: ReviewComment, store: DiffReviewStore) {
        activePopover?.close()

        let controller = DiffCommentPopoverController(mode: .edit(existingText: comment.text))
        controller.onUpdate = { [weak self] text in
            store.updateComment(id: comment.id, text: text)
            self?.redisplayWithComments()
        }
        controller.onDelete = { [weak self] in
            store.removeComment(id: comment.id)
            self?.redisplayWithComments()
        }

        let popover = NSPopover()
        popover.contentViewController = controller
        controller.enclosingPopover = popover
        popover.contentSize = NSSize(width: 320, height: 80)
        popover.behavior = .transient
        activePopover = popover

        let rect = rectForLine(at: atDisplayLineIndex)
        popover.show(relativeTo: rect, of: lineNumberView, preferredEdge: .maxX)
    }

    private func rectForLine(at displayLineIndex: Int) -> NSRect {
        guard let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else {
            return .zero
        }

        let content = textView.string
        let lines = content.components(separatedBy: "\n")
        guard displayLineIndex < lines.count else { return .zero }

        var charOffset = 0
        for i in 0..<displayLineIndex {
            charOffset += lines[i].utf16.count + 1 // +1 for \n
        }

        let lineLength = max(1, lines[displayLineIndex].utf16.count)
        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: NSRange(location: charOffset, length: lineLength),
            actualCharacterRange: nil
        )
        var lineRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        lineRect.origin.y += textView.textContainerInset.height

        // Convert from textView coordinates to lineNumberView coordinates
        let visibleRect = scrollView.documentVisibleRect
        lineRect.origin.y -= visibleRect.minY
        lineRect.origin.y += lineNumberView.convert(NSPoint.zero, from: textView).y

        return NSRect(x: 0, y: lineRect.minY, width: lineNumberView.bounds.width, height: lineRect.height)
    }
}

// MARK: - DiffTextView (click-on-comment support)

@MainActor
final class DiffTextView: NSTextView {
    /// Called when a comment line (💬) is clicked. Parameter is the text line index.
    var onCommentLineClicked: ((Int) -> Void)?

    override func mouseDown(with event: NSEvent) {
        // Check if click is on a comment line before passing to super
        if let lineIndex = textLineIndex(at: event) {
            onCommentLineClicked?(lineIndex)
            return
        }
        super.mouseDown(with: event)
    }

    private func textLineIndex(at event: NSEvent) -> Int? {
        guard let layoutManager, let textContainer else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        let adjustedPoint = NSPoint(x: point.x - textContainerInset.width,
                                    y: point.y - textContainerInset.height)
        let glyphIndex = layoutManager.glyphIndex(for: adjustedPoint, in: textContainer)
        let charIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)

        let lines = string.components(separatedBy: "\n")
        var offset = 0
        for (idx, line) in lines.enumerated() {
            let lineEnd = offset + line.utf16.count
            if charIndex >= offset && charIndex <= lineEnd {
                return idx
            }
            offset = lineEnd + 1 // +1 for \n
        }
        return nil
    }
}

// MARK: - Line Number Ruler

@MainActor
final class DiffLineNumberView: NSRulerView {
    var displayLines: [DisplayLine] = []
    var commentedLineIndices: Set<Int> = []
    var onLineClicked: ((Int, DisplayLine) -> Void)?
    private var hoveredDisplayLineIndex: Int? {
        didSet {
            if oldValue != hoveredDisplayLineIndex { needsDisplay = true }
        }
    }
    private var trackingArea: NSTrackingArea?

    override var requiredThickness: CGFloat { 80 }

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
        hoveredDisplayLineIndex = nil
    }

    override func mouseMoved(with event: NSEvent) {
        hoveredDisplayLineIndex = displayLineIndex(at: event)
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView = clientView as? NSTextView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return }

        let visibleRect = scrollView?.documentVisibleRect ?? bounds
        let font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        let lineNumberColor = NSColor.secondaryLabelColor

        // Separator line (no background fill — Liquid Glass shows through)
        NSColor.separatorColor.withAlphaComponent(0.15).setStroke()
        let separatorX = bounds.maxX - 0.5
        NSBezierPath.strokeLine(from: NSPoint(x: separatorX, y: rect.minY),
                                to: NSPoint(x: separatorX, y: rect.maxY))

        let content = textView.string as NSString
        guard content.length > 0 else { return }

        let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: textContainer)
        let charRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)

        // Track the current diff line index (for commentedLineIndices lookup)
        var currentDiffLineIndex = 0

        let lines = textView.string.components(separatedBy: "\n")
        var charOffset = 0

        for (idx, line) in lines.enumerated() {
            let lineLength = line.utf16.count + (idx < lines.count - 1 ? 1 : 0)
            let lineStart = charOffset
            charOffset += lineLength

            guard lineStart < charRange.upperBound else { break }
            guard charOffset > charRange.location else {
                // Track diff line index even for offscreen lines
                if idx < displayLines.count, case .diff = displayLines[idx] {
                    currentDiffLineIndex += 1
                }
                continue
            }

            guard idx < displayLines.count else { break }
            let displayLine = displayLines[idx]

            let lineGlyphRange = layoutManager.glyphRange(forCharacterRange: NSRange(location: lineStart, length: max(1, lineLength - 1)), actualCharacterRange: nil)
            var lineRect = layoutManager.boundingRect(forGlyphRange: lineGlyphRange, in: textContainer)
            lineRect.origin.y += textView.textContainerInset.height

            let y = lineRect.minY - visibleRect.minY + convert(NSPoint.zero, from: textView).y

            switch displayLine {
            case .diff(let diffLine):
                let isCommentable = diffLine.type == .addition || diffLine.type == .deletion || diffLine.type == .context

                // Draw blue dot for commented lines
                if commentedLineIndices.contains(currentDiffLineIndex) {
                    NSColor.systemBlue.setFill()
                    let dotRect = NSRect(x: 4, y: y + (lineRect.height - 6) / 2, width: 6, height: 6)
                    NSBezierPath(ovalIn: dotRect).fill()
                } else if isCommentable && hoveredDisplayLineIndex == idx {
                    // GitHub-style hover "+" button
                    let btnSize: CGFloat = 16
                    let btnRect = NSRect(x: 2, y: y + (lineRect.height - btnSize) / 2, width: btnSize, height: btnSize)
                    NSColor.systemBlue.setFill()
                    NSBezierPath(roundedRect: btnRect, xRadius: 3, yRadius: 3).fill()
                    let plusStr = "+" as NSString
                    let plusAttrs: [NSAttributedString.Key: Any] = [
                        .font: NSFont.systemFont(ofSize: 12, weight: .bold),
                        .foregroundColor: NSColor.white,
                    ]
                    let plusSize = plusStr.size(withAttributes: plusAttrs)
                    plusStr.draw(at: NSPoint(
                        x: btnRect.midX - plusSize.width / 2,
                        y: btnRect.midY - plusSize.height / 2
                    ), withAttributes: plusAttrs)
                }

                // Draw old line number (left column)
                if let oldNum = diffLine.oldLineNumber {
                    let str = "\(oldNum)" as NSString
                    let attrs: [NSAttributedString.Key: Any] = [
                        .font: font,
                        .foregroundColor: lineNumberColor,
                    ]
                    let size = str.size(withAttributes: attrs)
                    let x = 34 - size.width
                    str.draw(at: NSPoint(x: x, y: y), withAttributes: attrs)
                }

                // Draw new line number (right column)
                if let newNum = diffLine.newLineNumber {
                    let str = "\(newNum)" as NSString
                    let attrs: [NSAttributedString.Key: Any] = [
                        .font: font,
                        .foregroundColor: lineNumberColor,
                    ]
                    let size = str.size(withAttributes: attrs)
                    let x = 72 - size.width
                    str.draw(at: NSPoint(x: x, y: y), withAttributes: attrs)
                }

                currentDiffLineIndex += 1

            case .commentBlock:
                // Draw blue background band for comment lines (no icon — click 💬 in text to edit)
                let bandRect = NSRect(x: 0, y: y, width: bounds.width - 1, height: lineRect.height)
                NSColor.systemBlue.withAlphaComponent(0.15).setFill()
                bandRect.fill()
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        if let idx = displayLineIndex(at: event), idx < displayLines.count {
            onLineClicked?(idx, displayLines[idx])
        } else {
            super.mouseDown(with: event)
        }
    }

    /// Hit-test: returns the displayLines index for the line under the mouse event.
    private func displayLineIndex(at event: NSEvent) -> Int? {
        guard let textView = clientView as? NSTextView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return nil }

        let locationInRuler = convert(event.locationInWindow, from: nil)
        let visibleRect = scrollView?.documentVisibleRect ?? bounds

        let lines = textView.string.components(separatedBy: "\n")
        var charOffset = 0

        for (idx, line) in lines.enumerated() {
            let lineLength = line.utf16.count + (idx < lines.count - 1 ? 1 : 0)
            let lineStart = charOffset
            charOffset += lineLength

            guard idx < displayLines.count else { continue }

            let lineGlyphRange = layoutManager.glyphRange(
                forCharacterRange: NSRange(location: lineStart, length: max(1, lineLength - 1)),
                actualCharacterRange: nil
            )
            var lineRect = layoutManager.boundingRect(forGlyphRange: lineGlyphRange, in: textContainer)
            lineRect.origin.y += textView.textContainerInset.height

            let y = lineRect.minY - visibleRect.minY + convert(NSPoint.zero, from: textView).y
            let hitRect = NSRect(x: 0, y: y, width: bounds.width, height: lineRect.height)

            if hitRect.contains(locationInRuler) {
                return idx
            }
        }
        return nil
    }
}