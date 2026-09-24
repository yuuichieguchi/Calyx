//
//  MCPAppDockView.swift
//  Calyx
//
//  The inline dock to the right of one pane's terminal. With more than one
//  view, a segmented switcher above the card picks which one shows. The
//  split container sets the dock's frame; the dock does not ask for a size.
//

import AppKit

@MainActor
final class MCPAppDockView: NSView {
    static let switcherHeight: CGFloat = 26

    let surfaceID: UUID
    private(set) var panes: [MCPAppViewPane] = []
    private(set) var selectedViewID: UUID?
    private let switcher = NSSegmentedControl()

    init(surfaceID: UUID) {
        self.surfaceID = surfaceID
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityIdentifier(AccessibilityID.MCPApps.dock(surfaceID))
        switcher.segmentStyle = .rounded
        switcher.trackingMode = .selectOne
        switcher.controlSize = .small
        switcher.target = self
        switcher.action = #selector(switcherChanged)
        switcher.setAccessibilityIdentifier(AccessibilityID.MCPApps.dockSwitcher)
        addSubview(switcher)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    /// The size of the card area: the dock without the switcher strip.
    var cardSize: CGSize {
        CGSize(width: bounds.width, height: bounds.height - shownSwitcherHeight)
    }

    /// Adds a pane and shows it.
    func add(_ pane: MCPAppViewPane) {
        guard !panes.contains(where: { $0 === pane }) else { return }
        panes.append(pane)
        select(pane.viewID)
    }

    func remove(viewID: UUID) {
        guard let index = panes.firstIndex(where: { $0.viewID == viewID }) else { return }
        panes[index].removeFromSuperview()
        panes.remove(at: index)
        if selectedViewID == viewID {
            selectedViewID = nil
            if let last = panes.last { select(last.viewID) }
        }
        rebuildSwitcher()
        needsLayout = true
    }

    func select(_ viewID: UUID) {
        guard let pane = panes.first(where: { $0.viewID == viewID }) else { return }
        selectedPane?.removeFromSuperview()
        selectedViewID = viewID
        addSubview(pane)
        rebuildSwitcher()
        needsLayout = true
    }

    /// Titles for the switcher, in pane order.
    func setTitle(_ title: String, forViewID viewID: UUID) {
        guard let index = panes.firstIndex(where: { $0.viewID == viewID }), index < switcher.segmentCount else { return }
        switcher.setLabel(title, forSegment: index)
    }

    override func layout() {
        super.layout()
        let top = shownSwitcherHeight
        switcher.isHidden = top == 0
        if top > 0 {
            switcher.frame = NSRect(x: 6, y: 2, width: bounds.width - 12, height: Self.switcherHeight - 4)
        }
        selectedPane?.frame = NSRect(x: 0, y: top, width: bounds.width, height: max(0, bounds.height - top))
    }

    // MARK: - Private

    /// The switcher shows with more than one view.
    private var shownSwitcherHeight: CGFloat {
        panes.count > 1 ? Self.switcherHeight : 0
    }

    private var selectedPane: MCPAppViewPane? {
        panes.first { $0.viewID == selectedViewID }
    }

    private func rebuildSwitcher() {
        switcher.segmentCount = panes.count
        for (index, pane) in panes.enumerated() {
            if switcher.label(forSegment: index)?.isEmpty ?? true {
                switcher.setLabel("View \(index + 1)", forSegment: index)
            }
            switcher.setWidth(0, forSegment: index)
            if pane.viewID == selectedViewID { switcher.selectedSegment = index }
        }
    }

    @objc private func switcherChanged() {
        let index = switcher.selectedSegment
        guard panes.indices.contains(index) else { return }
        select(panes[index].viewID)
    }
}
