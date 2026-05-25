// SearchBarView.swift
// Calyx
//
// In-terminal search bar for scrollback search (Cmd+F).

@preconcurrency import AppKit
import os

private let logger = Logger(subsystem: "com.calyx.terminal", category: "SearchBar")

@MainActor
class SearchBarView: NSView, NSTextFieldDelegate {

    // MARK: - Static Helpers

    static func formatMatchCount(total: Int, selected: Int) -> String {
        if total == -1 { return "" }
        if total == 0 { return "No matches" }
        if selected >= 1, selected <= total { return "\(selected) of \(total)" }
        return "\(total) matches"
    }

    // MARK: - Properties

    weak var sender: SearchQuerySender?

    private(set) var matchTotal: Int = -1
    private(set) var matchSelected: Int = -1

    private let searchField = NSTextField()
    private let matchCountLabel = NSTextField(labelWithString: "")
    private let previousButton = NSButton()
    private let nextButton = NSButton()
    private let closeButton = NSButton()

    private var searchDebounce: DispatchWorkItem?
    var lastSubmittedQuery: String = ""

    // MARK: - Init

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupView()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: - Setup

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.85).cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor
    }

    private func setupView() {
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 0.5

        setAccessibilityIdentifier(AccessibilityID.Search.container)

        // Search field
        searchField.placeholderString = "Search…"
        searchField.isBordered = true
        searchField.bezelStyle = .roundedBezel
        searchField.font = .systemFont(ofSize: 13)
        searchField.delegate = self
        searchField.setAccessibilityIdentifier(AccessibilityID.Search.searchField)
        addSubview(searchField)

        // Match count label
        matchCountLabel.font = .systemFont(ofSize: 11)
        matchCountLabel.textColor = .secondaryLabelColor
        matchCountLabel.alignment = .center
        matchCountLabel.setAccessibilityIdentifier(AccessibilityID.Search.matchCount)
        addSubview(matchCountLabel)

        // Previous button (chevron.up)
        configureButton(previousButton, symbolName: "chevron.up",
                       accessibilityID: AccessibilityID.Search.previousButton,
                       action: #selector(previousMatch))
        addSubview(previousButton)

        // Next button (chevron.down)
        configureButton(nextButton, symbolName: "chevron.down",
                       accessibilityID: AccessibilityID.Search.nextButton,
                       action: #selector(nextMatch))
        addSubview(nextButton)

        // Close button (xmark)
        configureButton(closeButton, symbolName: "xmark",
                       accessibilityID: AccessibilityID.Search.closeButton,
                       action: #selector(closeSearch))
        addSubview(closeButton)
    }

    private func configureButton(_ button: NSButton, symbolName: String, accessibilityID: String, action: Selector) {
        button.bezelStyle = .accessoryBarAction
        button.isBordered = false
        if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) {
            button.image = image
        }
        button.imagePosition = .imageOnly
        button.target = self
        button.action = action
        button.setAccessibilityIdentifier(accessibilityID)
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        let h = bounds.height
        let padding: CGFloat = 6
        let buttonSize: CGFloat = 24

        // Close button on the right
        closeButton.frame = NSRect(x: bounds.width - buttonSize - padding, y: (h - buttonSize) / 2,
                                   width: buttonSize, height: buttonSize)

        // Next button
        nextButton.frame = NSRect(x: closeButton.frame.minX - buttonSize - 2, y: (h - buttonSize) / 2,
                                  width: buttonSize, height: buttonSize)

        // Previous button
        previousButton.frame = NSRect(x: nextButton.frame.minX - buttonSize - 2, y: (h - buttonSize) / 2,
                                      width: buttonSize, height: buttonSize)

        // Match count label
        let labelWidth: CGFloat = 80
        matchCountLabel.frame = NSRect(x: previousButton.frame.minX - labelWidth - 4, y: (h - 16) / 2,
                                       width: labelWidth, height: 16)

        // Search field fills remaining space
        let fieldX: CGFloat = padding
        let fieldWidth = matchCountLabel.frame.minX - fieldX - 4
        searchField.frame = NSRect(x: fieldX, y: (h - 22) / 2, width: max(fieldWidth, 100), height: 22)
    }

    // MARK: - Public Methods

    func resetSearchState() {
        matchTotal = -1
        matchSelected = -1
        lastSubmittedQuery = ""
        searchDebounce?.cancel()
        searchDebounce = nil
        updateMatchCountLabel()
    }

    func focusSearchField() {
        window?.makeFirstResponder(searchField)
    }

    func setSearchText(_ text: String) {
        searchField.stringValue = text
    }

    var searchText: String {
        searchField.stringValue
    }

    func updateMatchTotal(_ total: Int) {
        matchTotal = total
        // Validate matchSelected against new total
        if matchTotal >= 0, matchSelected > matchTotal {
            matchSelected = -1
        }
        updateMatchCountLabel()
    }

    func updateMatchSelected(_ selected: Int) {
        // Validate: if total is known and selected is out of range, treat as unknown
        if matchTotal >= 0, selected > matchTotal {
            matchSelected = -1
        } else {
            matchSelected = selected
        }
        updateMatchCountLabel()
    }

    // MARK: - Private

    private func updateMatchCountLabel() {
        matchCountLabel.stringValue = Self.formatMatchCount(total: matchTotal, selected: matchSelected)
    }

    // MARK: - Button Actions

    @objc private func previousMatch() {
        // ghostty's navigate_search:next moves toward the top of the buffer,
        // which is what users expect from chevron.up / Find Previous.
        if sender?.performAction("navigate_search:next") != true {
            logger.warning("navigate_search:next failed")
        }
    }

    @objc private func nextMatch() {
        // chevron.down / Find Next → toward the bottom of the buffer.
        if sender?.performAction("navigate_search:previous") != true {
            logger.warning("navigate_search:previous failed")
        }
    }

    @objc private func closeSearch() {
        if sender?.performAction("end_search") != true {
            logger.warning("end_search failed")
        }
    }

    // MARK: - NSTextFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        // IME composition guard
        if let editor = searchField.currentEditor() as? NSTextView, editor.hasMarkedText() { return }

        let text = searchField.stringValue

        // Skip if query unchanged
        if text == lastSubmittedQuery { return }

        // Reset match state immediately (stale display prevention)
        matchTotal = -1
        matchSelected = -1
        updateMatchCountLabel()

        // Debounce 100ms
        searchDebounce?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lastSubmittedQuery = text
            if self.sender?.performSearch(query: text) != true {
                logger.warning("performSearch failed")
            }
        }
        searchDebounce = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: workItem)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(cancelOperation(_:)) {
            // Escape → end search
            if sender?.performAction("end_search") != true {
                logger.warning("end_search failed")
            }
            return true
        }
        if commandSelector == #selector(insertNewline(_:)) {
            // Return → next match (toward bottom of buffer)
            if sender?.performAction("navigate_search:previous") != true {
                logger.warning("navigate_search:previous failed")
            }
            return true
        }
        return false
    }

    // MARK: - Key Equivalents

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // Cmd+G → next match (toward bottom of buffer)
        if flags == .command, event.charactersIgnoringModifiers == "g" {
            if sender?.performAction("navigate_search:previous") != true {
                logger.warning("navigate_search:previous failed")
            }
            return true
        }

        // Cmd+Shift+G → previous match (toward top of buffer)
        if flags == [.command, .shift], event.charactersIgnoringModifiers == "G" {
            if sender?.performAction("navigate_search:next") != true {
                logger.warning("navigate_search:next failed")
            }
            return true
        }

        // Cmd+F → refocus search field
        if flags == .command, event.charactersIgnoringModifiers == "f" {
            focusSearchField()
            return true
        }

        return super.performKeyEquivalent(with: event)
    }
}
