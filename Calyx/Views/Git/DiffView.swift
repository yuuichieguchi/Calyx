// DiffView.swift
// Calyx
//
// AppKit-based diff viewer with line number gutter and syntax coloring.

import AppKit

@MainActor
final class DiffView: NSView {
    private let scrollView = NSScrollView()
    private let textView = NSTextView()
    private let lineNumberView = DiffLineNumberView()
    private(set) var currentDiff: FileDiff?

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

        lineNumberView.diffLines = diff.lines
        let attributed = buildAttributedString(from: diff)
        textView.textStorage?.setAttributedString(attributed)

        if diff.isTruncated {
            appendTruncationBanner()
        }

        lineNumberView.needsDisplay = true
    }

    private func displayBinaryMessage() {
        lineNumberView.diffLines = []
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

    private func buildAttributedString(from diff: FileDiff) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let boldFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .bold)

        for (index, line) in diff.lines.enumerated() {
            // Truncate very long lines (minified files)
            var text = line.text
            if text.count > 10_000 {
                text = String(text.prefix(10_000)) + " [truncated]"
            }

            if index > 0 {
                result.append(NSAttributedString(string: "\n"))
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
        }

        return result
    }
}

// MARK: - Line Number Ruler

@MainActor
final class DiffLineNumberView: NSRulerView {
    var diffLines: [DiffLine] = []

    override var requiredThickness: CGFloat { 80 }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView = clientView as? NSTextView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return }

        let visibleRect = scrollView?.documentVisibleRect ?? bounds
        let font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        let lineNumberColor = NSColor.secondaryLabelColor

        // Background
        NSColor.controlBackgroundColor.withAlphaComponent(0.5).setFill()
        rect.fill()

        // Separator line
        NSColor.separatorColor.setStroke()
        let separatorX = bounds.maxX - 0.5
        NSBezierPath.strokeLine(from: NSPoint(x: separatorX, y: rect.minY),
                                to: NSPoint(x: separatorX, y: rect.maxY))

        let content = textView.string as NSString
        guard content.length > 0 else { return }

        let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: textContainer)
        let charRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)

        // Map visual lines to diff lines
        var lineIndex = 0
        var charOffset = 0
        let lines = textView.string.components(separatedBy: "\n")

        for (idx, line) in lines.enumerated() {
            let lineLength = line.utf16.count + (idx < lines.count - 1 ? 1 : 0) // +1 for \n
            let lineStart = charOffset
            charOffset += lineLength

            guard lineStart < charRange.upperBound else { break }
            guard charOffset > charRange.location else {
                lineIndex = idx + 1
                continue
            }

            guard idx < diffLines.count else { break }
            let diffLine = diffLines[idx]

            let lineGlyphRange = layoutManager.glyphRange(forCharacterRange: NSRange(location: lineStart, length: max(1, lineLength - 1)), actualCharacterRange: nil)
            var lineRect = layoutManager.boundingRect(forGlyphRange: lineGlyphRange, in: textContainer)
            lineRect.origin.y += textView.textContainerInset.height

            // Draw old line number (left column)
            if let oldNum = diffLine.oldLineNumber {
                let str = "\(oldNum)" as NSString
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .foregroundColor: lineNumberColor,
                ]
                let size = str.size(withAttributes: attrs)
                let x = 34 - size.width
                let y = lineRect.minY - visibleRect.minY + convert(NSPoint.zero, from: textView).y
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
                let y = lineRect.minY - visibleRect.minY + convert(NSPoint.zero, from: textView).y
                str.draw(at: NSPoint(x: x, y: y), withAttributes: attrs)
            }
        }
    }
}