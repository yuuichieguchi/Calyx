import Cocoa

class QuickTerminalWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override init(
        contentRect: NSRect,
        styleMask style: NSWindow.StyleMask,
        backing backingStoreType: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        // Keep .titled (required for glass effect) but add .nonactivatingPanel
        var adjustedStyle = style
        adjustedStyle.insert(.nonactivatingPanel)
        adjustedStyle.insert(.fullSizeContentView)
        super.init(contentRect: contentRect, styleMask: adjustedStyle, backing: backingStoreType, defer: flag)

        self.identifier = .init(rawValue: "com.calyx.quickTerminal")
        self.setAccessibilitySubrole(.floatingWindow)
        self.isRestorable = false
        self.titlebarAppearsTransparent = true
        self.titleVisibility = .hidden
        self.isOpaque = false
        self.backgroundColor = .clear
    }
}
