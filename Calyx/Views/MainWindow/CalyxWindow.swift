import AppKit

@MainActor
class CalyxWindow: NSWindow {
    override init(
        contentRect: NSRect,
        styleMask style: NSWindow.StyleMask,
        backing backingStoreType: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)
        setupWindow()
    }

    private func setupWindow() {
        title = "Calyx"
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        minSize = NSSize(width: 400, height: 300)
        isReleasedWhenClosed = false

        // Enable full-size content view so the terminal renders
        // behind the titlebar area.
        styleMask.insert(.fullSizeContentView)

        // Allow the window to be tabbed using the system tabbing behavior.
        tabbingMode = .preferred
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func sendEvent(_ event: NSEvent) {
        // Phase 1: pass through to super.
        // Future phases will intercept Cmd/Ctrl shortcuts here
        // for keybind processing before the view hierarchy.
        super.sendEvent(event)
    }
}
