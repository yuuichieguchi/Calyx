// CommandPaletteView.swift
// Calyx
//
// Overlay panel at top of window for command palette UI.
// Glass styling is applied on the SwiftUI side via .glassEffect(.regular).

import AppKit
import os

private let logger = Logger(subsystem: "com.calyx.terminal", category: "CommandPalette")

@MainActor
class CommandPaletteView: NSView, NSTableViewDelegate, NSTableViewDataSource, NSTextFieldDelegate {

    // MARK: - Properties

    private let registry: CommandRegistry
    private let searchField = NSTextField()
    private let resultsScrollView = NSScrollView()
    private let resultsTableView = NSTableView()

    private var filteredCommands: [Command] = []
    private var selectedIndex = 0

    var onDismiss: (() -> Void)?

    // MARK: - Initializers

    init(registry: CommandRegistry) {
        self.registry = registry
        super.init(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        setupView()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: - View Lifecycle

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        window.makeFirstResponder(searchField)
    }

    // MARK: - Setup

    private func setupView() {
        wantsLayer = true

        // Search field
        searchField.placeholderString = "Type a command..."
        searchField.isBordered = false
        searchField.focusRingType = .none
        searchField.drawsBackground = false
        searchField.backgroundColor = .clear
        searchField.font = .systemFont(ofSize: 16)
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false
        addSubview(searchField)

        // Table column
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("command"))
        column.title = ""
        resultsTableView.addTableColumn(column)
        resultsTableView.headerView = nil
        resultsTableView.selectionHighlightStyle = .regular
        resultsTableView.backgroundColor = .clear
        resultsTableView.delegate = self
        resultsTableView.dataSource = self
        resultsTableView.target = self
        resultsTableView.action = #selector(tableViewClicked(_:))

        // Scroll view
        resultsScrollView.documentView = resultsTableView
        resultsScrollView.hasVerticalScroller = true
        resultsScrollView.drawsBackground = false
        resultsScrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(resultsScrollView)

        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            searchField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            searchField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            searchField.heightAnchor.constraint(equalToConstant: 32),

            resultsScrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 4),
            resultsScrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            resultsScrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            resultsScrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        searchField.setAccessibilityIdentifier(AccessibilityID.CommandPalette.searchField)
        resultsTableView.setAccessibilityIdentifier(AccessibilityID.CommandPalette.resultsTable)
        self.setAccessibilityIdentifier(AccessibilityID.CommandPalette.container)

        updateResults()
    }

    // MARK: - Results

    private func updateResults() {
        let query = searchField.stringValue
        filteredCommands = registry.search(query: query)
        selectedIndex = 0
        resultsTableView.reloadData()

        if !filteredCommands.isEmpty {
            resultsTableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            resultsTableView.scrollRowToVisible(0)
        }
    }

    // MARK: - Execution & Dismiss

    func executeSelected() {
        guard filteredCommands.indices.contains(selectedIndex) else { return }
        let command = filteredCommands[selectedIndex]
        registry.recordUsage(command.id)
        dismiss()
        command.handler()
    }

    private func dismiss() {
        onDismiss?()
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        filteredCommands.count
    }

    // MARK: - NSTableViewDelegate

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard filteredCommands.indices.contains(row) else { return nil }
        let command = filteredCommands[row]

        let cellIdentifier = NSUserInterfaceItemIdentifier("CommandCell")
        let cell: NSTableCellView

        if let reused = tableView.makeView(withIdentifier: cellIdentifier, owner: nil) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = cellIdentifier

            let titleLabel = NSTextField(labelWithString: "")
            titleLabel.font = .systemFont(ofSize: 14)
            titleLabel.lineBreakMode = .byTruncatingTail
            titleLabel.translatesAutoresizingMaskIntoConstraints = false

            let shortcutLabel = NSTextField(labelWithString: "")
            shortcutLabel.font = .systemFont(ofSize: 12)
            shortcutLabel.textColor = .secondaryLabelColor
            shortcutLabel.alignment = .right
            shortcutLabel.lineBreakMode = .byClipping
            shortcutLabel.translatesAutoresizingMaskIntoConstraints = false
            shortcutLabel.setContentHuggingPriority(.required, for: .horizontal)
            shortcutLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

            cell.addSubview(titleLabel)
            cell.addSubview(shortcutLabel)
            cell.textField = titleLabel

            NSLayoutConstraint.activate([
                titleLabel.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                titleLabel.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: shortcutLabel.leadingAnchor, constant: -8),

                shortcutLabel.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                shortcutLabel.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])

            // Tag the shortcut label so we can find it later for reuse.
            shortcutLabel.tag = 1001
        }

        cell.textField?.stringValue = command.title

        if let shortcutLabel = cell.viewWithTag(1001) as? NSTextField {
            shortcutLabel.stringValue = command.shortcut ?? ""
        }

        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = resultsTableView.selectedRow
        guard row >= 0 else { return }
        selectedIndex = row
    }

    @objc private func tableViewClicked(_ sender: Any?) {
        guard resultsTableView.clickedRow >= 0 else { return }
        selectedIndex = resultsTableView.clickedRow
        executeSelected()
    }

    // MARK: - NSTextFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        updateResults()
    }

    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveUp(_:)):
            if selectedIndex > 0 {
                selectedIndex -= 1
                resultsTableView.selectRowIndexes(IndexSet(integer: selectedIndex), byExtendingSelection: false)
                resultsTableView.scrollRowToVisible(selectedIndex)
            }
            return true

        case #selector(NSResponder.moveDown(_:)):
            if selectedIndex < filteredCommands.count - 1 {
                selectedIndex += 1
                resultsTableView.selectRowIndexes(IndexSet(integer: selectedIndex), byExtendingSelection: false)
                resultsTableView.scrollRowToVisible(selectedIndex)
            }
            return true

        case #selector(NSResponder.insertNewline(_:)):
            executeSelected()
            return true

        case #selector(NSResponder.cancelOperation(_:)):
            dismiss()
            return true

        default:
            return false
        }
    }

    // MARK: - Key Event Fallback

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 0x35: // Escape
            dismiss()
        default:
            super.keyDown(with: event)
        }
    }
}
