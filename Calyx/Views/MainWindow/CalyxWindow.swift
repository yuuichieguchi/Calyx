import AppKit

@MainActor
class CalyxWindow: NSWindow {

    var shortcutManager: ShortcutManager?

    nonisolated(unsafe) private var doubleClickZoomMonitor: Any?

    override init(
        contentRect: NSRect,
        styleMask style: NSWindow.StyleMask,
        backing backingStoreType: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)
        setupWindow()
    }

    deinit {
        if let monitor = doubleClickZoomMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    private func setupWindow() {
        title = "Calyx"
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        minSize = NSSize(width: 400, height: 300)
        isReleasedWhenClosed = false

        styleMask.insert(.fullSizeContentView)
        tabbingMode = .disallowed

        isOpaque = false
        backgroundColor = .clear

        doubleClickZoomMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self else { return event }
            guard event.window === self else { return event }
            guard event.clickCount == 2 else { return event }
            guard !self.styleMask.contains(.fullScreen) else { return event }

            let titleBarHeight = max(self.frame.height - self.contentLayoutRect.height, 28.0)
            let trafficLightFrames: [NSRect] = [
                self.standardWindowButton(.closeButton),
                self.standardWindowButton(.miniaturizeButton),
                self.standardWindowButton(.zoomButton),
            ].compactMap { $0 }.map { $0.convert($0.bounds, to: nil) }

            if CalyxWindow.shouldPerformZoom(
                pointInWindow: event.locationInWindow,
                windowSize: self.frame.size,
                titleBarHeight: titleBarHeight,
                trafficLightFrames: trafficLightFrames
            ) {
                self.performZoom(nil)
                return nil
            }
            return event
        }
    }

    nonisolated static func shouldPerformZoom(
        pointInWindow: NSPoint,
        windowSize: CGSize,
        titleBarHeight: CGFloat,
        trafficLightFrames: [NSRect]
    ) -> Bool {
        let titleBarBottomY = windowSize.height - titleBarHeight
        if pointInWindow.y < titleBarBottomY {
            return false
        }
        for rect in trafficLightFrames where rect.contains(pointInWindow) {
            return false
        }
        return true
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
