// TabBarView.swift
// Calyx
//
// AppKit NSView showing a horizontal tab strip for the active tab group.

import AppKit
import os

private let logger = Logger(subsystem: "com.calyx.terminal", category: "TabBarView")

@MainActor
class TabBarView: NSView {

    var tabs: [Tab] = [] {
        didSet { rebuildTabButtons() }
    }
    var activeTabID: UUID? {
        didSet { updateSelection() }
    }

    var onTabSelected: ((UUID) -> Void)?
    var onTabClosed: ((UUID) -> Void)?

    private var tabButtons: [UUID: NSButton] = [:]
    private let stackView = NSStackView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupView()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func setupView() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        stackView.orientation = .horizontal
        stackView.spacing = 1
        stackView.distribution = .fill
        stackView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stackView)

        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(equalTo: leadingAnchor),
            stackView.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            stackView.topAnchor.constraint(equalTo: topAnchor),
            stackView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private func rebuildTabButtons() {
        stackView.arrangedSubviews.forEach { $0.removeFromSuperview() }
        tabButtons.removeAll()

        for tab in tabs {
            let button = NSButton(title: tab.title, target: self, action: #selector(tabClicked(_:)))
            button.bezelStyle = .toolbar
            button.isBordered = true
            button.tag = tab.id.hashValue
            button.identifier = NSUserInterfaceItemIdentifier(tab.id.uuidString)
            stackView.addArrangedSubview(button)
            tabButtons[tab.id] = button
        }

        updateSelection()
    }

    private func updateSelection() {
        for (id, button) in tabButtons {
            button.state = id == activeTabID ? .on : .off
        }
    }

    @objc private func tabClicked(_ sender: NSButton) {
        guard let identifier = sender.identifier?.rawValue,
              let uuid = UUID(uuidString: identifier) else { return }
        onTabSelected?(uuid)
    }
}
