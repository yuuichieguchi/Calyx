import AppKit

@MainActor
class CalyxWindow: NSWindow {

    var shortcutManager: ShortcutManager?

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

        styleMask.insert(.fullSizeContentView)
        tabbingMode = .preferred
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown,
           let manager = shortcutManager,
           manager.shouldIntercept(event: event, firstResponder: firstResponder) {
            if manager.handleEvent(event) {
                return
            }
        }

        super.sendEvent(event)
    }
}
