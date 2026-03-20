// ComposeOverlayView.swift
// Calyx
//
// Transparent text editor overlay for composing terminal input.

import AppKit
import os

private let logger = Logger(subsystem: "com.calyx.terminal", category: "ComposeOverlay")

/// NSTextView subclass that notifies when IME composition state changes.
@MainActor
private class ComposeTextView: NSTextView {
    var onMarkedTextChanged: (() -> Void)?

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        onMarkedTextChanged?()
    }

    override func unmarkText() {
        super.unmarkText()
        onMarkedTextChanged?()
    }


}

@MainActor
class ComposeOverlayView: NSView {

    // MARK: - Properties

    private let scrollView = NSScrollView()
    private(set) var textView: NSTextView = ComposeTextView()
    private let placeholderLabel = NSTextField(labelWithString: "Compose...")

    var onSend: ((String) -> Bool)?
    var onDismiss: (() -> Void)?

    // MARK: - Initializers

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupView()
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    convenience init() {
        self.init(frame: NSRect(x: 0, y: 0, width: 400, height: 120))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: - View Lifecycle

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        window?.makeFirstResponder(textView)
    }

    // MARK: - Setup

    override var isOpaque: Bool { false }

    private func setupView() {
        // Text view setup
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        textView.textColor = .labelColor
        textView.insertionPointColor = .labelColor
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.delegate = self
        (textView as? ComposeTextView)?.onMarkedTextChanged = { [weak self] in
            self?.updatePlaceholder()
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(textViewDidChangeNotification(_:)),
            name: NSText.didChangeNotification,
            object: textView
        )

        // Scroll view
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.contentView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        // Placeholder
        placeholderLabel.textColor = .placeholderTextColor
        placeholderLabel.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        placeholderLabel.isBordered = false
        placeholderLabel.drawsBackground = false
        placeholderLabel.isEditable = false
        placeholderLabel.isSelectable = false
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(placeholderLabel)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            placeholderLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 13),
            placeholderLabel.topAnchor.constraint(equalTo: topAnchor, constant: 10),
        ])

        setAccessibilityIdentifier(AccessibilityID.Compose.container)
        textView.setAccessibilityIdentifier(AccessibilityID.Compose.textView)
        placeholderLabel.setAccessibilityIdentifier(AccessibilityID.Compose.placeholder)
    }

    // MARK: - Key Handling (overrides on the view itself for when textView doesn't handle)

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Escape dismiss
        if event.keyCode == 53 {
            onDismiss?()
            return true
        }
        // Cmd+Shift+E toggle (even when textView has focus)
        if event.modifierFlags.contains([.command, .shift]),
           event.charactersIgnoringModifiers?.lowercased() == "e" {
            onDismiss?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    // MARK: - NSResponder overrides (called by NSTextView delegate forwarding)

    override func insertNewline(_ sender: Any?) {
        // Trim only for emptiness check; send raw text to preserve user formatting.
        let trimmed = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let sent = onSend?(textView.string) ?? false
        if sent {
            textView.string = ""
            updatePlaceholder()
        }
    }

    override func insertNewlineIgnoringFieldEditor(_ sender: Any?) {
        textView.insertNewlineIgnoringFieldEditor(sender)
        updatePlaceholder()
    }

    override func cancelOperation(_ sender: Any?) {
        onDismiss?()
    }

    // MARK: - Placeholder

    @objc private func textViewDidChangeNotification(_ notification: Notification) {
        updatePlaceholder()
    }

    private func updatePlaceholder() {
        placeholderLabel.isHidden = !textView.string.isEmpty || textView.hasMarkedText()
    }
}

// MARK: - NSTextViewDelegate

extension ComposeOverlayView: NSTextViewDelegate {

    func textDidChange(_ notification: Notification) {
        updatePlaceholder()
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                insertNewlineIgnoringFieldEditor(nil)
            } else {
                insertNewline(nil)
            }
            return true
        case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            insertNewlineIgnoringFieldEditor(nil)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            cancelOperation(nil)
            return true
        default:
            return false
        }
    }
}
