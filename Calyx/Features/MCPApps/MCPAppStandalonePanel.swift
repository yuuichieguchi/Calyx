//
//  MCPAppStandalonePanel.swift
//  Calyx
//
//  The window of a pane-less invocation's view, titled
//  "<tool> · <server> · <client>".
//

import AppKit

@MainActor
final class MCPAppStandalonePanel: NSPanel {
    static let defaultSize = NSSize(width: 520, height: 420)

    let viewID: UUID
    /// Called when the user closes the panel.
    var onUserClose: (() -> Void)?

    init(viewID: UUID, pane: MCPAppViewPane) {
        self.viewID = viewID
        super.init(
            contentRect: NSRect(origin: .zero, size: Self.defaultSize),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        isReleasedWhenClosed = false
        isRestorable = false
        hidesOnDeactivate = false
        level = .normal
        let container = NSView()
        container.setAccessibilityElement(true)
        container.setAccessibilityRole(.group)
        container.setAccessibilityIdentifier(AccessibilityID.MCPApps.standalonePanel(viewID))
        pane.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(pane)
        NSLayoutConstraint.activate([
            pane.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            pane.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            pane.topAnchor.constraint(equalTo: container.topAnchor),
            pane.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        contentView = container
        center()
    }

    override func close() {
        let handler = onUserClose
        onUserClose = nil
        super.close()
        handler?()
    }

    /// Closes without reporting a user close (the store already removed the view).
    func dismiss() {
        onUserClose = nil
        super.close()
    }

    /// Fullscreen for a panel fills the visible frame of its screen.
    func setFillsScreen(_ fills: Bool) {
        guard let screen else { return }
        if fills {
            setFrame(screen.visibleFrame, display: true, animate: true)
        } else {
            setContentSize(Self.defaultSize)
            center()
        }
    }
}
