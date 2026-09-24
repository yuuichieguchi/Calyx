//
//  MCPAppPiPWindow.swift
//  Calyx
//
//  The picture-in-picture window of a view: a floating, non-activating
//  child window of the pane's window, modeled on `ApprovalPanelWindow`.
//

import AppKit

@MainActor
final class MCPAppPiPWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Called when the user closes the window.
    var onUserClose: (() -> Void)?

    init(size: NSSize) {
        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        level = .floating
        collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle]
        isRestorable = false
        isReleasedWhenClosed = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        identifier = NSUserInterfaceItemIdentifier("com.calyx.mcpApps.pip")
    }

    /// Shows `pane` in the bottom-right corner of `parent`.
    func present(_ pane: MCPAppViewPane, over parent: NSWindow) {
        pane.translatesAutoresizingMaskIntoConstraints = true
        pane.autoresizingMask = [.width, .height]
        let container = NSView()
        pane.frame = container.bounds
        container.addSubview(pane)
        contentView = container
        let margin: CGFloat = 16
        let parentFrame = parent.frame
        setFrameOrigin(NSPoint(x: parentFrame.maxX - frame.width - margin, y: parentFrame.minY + margin))
        parent.addChildWindow(self, ordered: .above)
        orderFront(nil)
        pane.frame = container.bounds
    }

    override func close() {
        let handler = onUserClose
        onUserClose = nil
        super.close()
        handler?()
    }

    /// Hands the pane back and closes, without reporting a user close.
    func dismiss() {
        onUserClose = nil
        parent?.removeChildWindow(self)
        orderOut(nil)
        contentView = nil
    }
}
