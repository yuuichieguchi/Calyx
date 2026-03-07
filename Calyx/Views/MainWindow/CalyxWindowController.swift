import AppKit
import GhosttyKit
import OSLog

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.calyx.terminal",
    category: "CalyxWindowController"
)

@MainActor
class CalyxWindowController: NSWindowController, NSWindowDelegate {
    private var surfaceView: SurfaceView?
    private var surfaceController: GhosttySurfaceController?

    convenience init() {
        let window = CalyxWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        self.init(window: window)
        window.delegate = self
        window.center()
        setupTerminalSurface()
    }

    private func setupTerminalSurface() {
        guard let app = GhosttyAppController.shared.app,
              let window = self.window,
              let contentView = window.contentView else {
            logger.error("Failed to set up terminal surface: app or window not available")
            return
        }

        // Create the SurfaceView filling the window content area
        let surfaceView = SurfaceView(frame: contentView.bounds)
        surfaceView.autoresizingMask = [.width, .height]

        // Ensure the view has a CAMetalLayer before creating the ghostty surface.
        // SurfaceView is expected to set wantsLayer = true and override makeBackingLayer()
        // to return a CAMetalLayer in its own implementation. We force layer creation here.
        surfaceView.wantsLayer = true
        _ = surfaceView.layer

        contentView.addSubview(surfaceView)
        self.surfaceView = surfaceView

        // Build the surface configuration
        var config = GhosttyFFI.surfaceConfigNew()
        config.platform_tag = GHOSTTY_PLATFORM_MACOS
        config.platform.macos.nsview = Unmanaged.passUnretained(surfaceView).toOpaque()
        config.scale_factor = Double(window.backingScaleFactor)

        // Create the surface controller that manages the ghostty_surface_t
        let controller = GhosttySurfaceController(app: app, baseConfig: config, view: surfaceView)
        surfaceView.surfaceController = controller
        self.surfaceController = controller

        // Make the surface view the first responder so it receives keyboard input
        window.makeFirstResponder(surfaceView)
    }

    // MARK: - NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) {
        surfaceController?.setFocus(true)
    }

    func windowDidResignKey(_ notification: Notification) {
        surfaceController?.setFocus(false)
    }

    func windowDidChangeBackingProperties(_ notification: Notification) {
        guard let window = self.window else { return }
        surfaceController?.setContentScale(window.backingScaleFactor)
    }

    func windowWillClose(_ notification: Notification) {
        // Notify the surface to close gracefully
        surfaceController?.requestClose()

        // Remove ourselves from the app delegate's tracking
        if let appDelegate = NSApp.delegate as? AppDelegate {
            appDelegate.removeWindowController(self)
        }
    }

    func windowDidResize(_ notification: Notification) {
        guard let window = self.window,
              let contentView = window.contentView else { return }
        let size = contentView.bounds.size
        let scale = window.backingScaleFactor
        surfaceController?.updateSize(
            width: UInt32(size.width * scale),
            height: UInt32(size.height * scale)
        )
    }
}
