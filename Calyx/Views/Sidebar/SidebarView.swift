// SidebarView.swift
// Calyx
//
// AppKit NSView showing tab groups and their tabs in a sidebar.

import AppKit
import os

private let logger = Logger(subsystem: "com.calyx.terminal", category: "SidebarView")

@MainActor
class SidebarView: NSView {

    var groups: [TabGroup] = [] {
        didSet { needsDisplay = true }
    }
    var activeGroupID: UUID?

    var onGroupSelected: ((UUID) -> Void)?
    var onTabSelected: ((UUID, UUID) -> Void)?  // (groupID, tabID)

    private let scrollView = NSScrollView()
    private let outlineView = NSOutlineView()

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
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        column.title = "Groups"
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.selectionHighlightStyle = .sourceList

        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
}
