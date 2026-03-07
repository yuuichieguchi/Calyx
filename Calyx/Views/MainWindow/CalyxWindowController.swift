import AppKit
import GhosttyKit
import OSLog

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.calyx.terminal",
    category: "CalyxWindowController"
)

@MainActor
class CalyxWindowController: NSWindowController, NSWindowDelegate {
    private(set) var splitTree: SplitTree = SplitTree()
    private let registry = SurfaceRegistry()
    private var splitContainerView: SplitContainerView?

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
        registerNotificationObservers()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Setup

    private func setupTerminalSurface() {
        guard let app = GhosttyAppController.shared.app,
              let window = self.window,
              let contentView = window.contentView else {
            logger.error("Failed to set up terminal surface: app or window not available")
            return
        }

        // Create the split container view
        let container = SplitContainerView(registry: registry)
        container.frame = contentView.bounds
        container.autoresizingMask = [.width, .height]
        container.onRatioChange = { [weak self] leafID, delta, direction in
            self?.handleDividerDrag(leafID: leafID, delta: delta, direction: direction)
        }
        contentView.addSubview(container)
        self.splitContainerView = container

        // Create the first surface
        var config = GhosttyFFI.surfaceConfigNew()
        config.scale_factor = Double(window.backingScaleFactor)

        guard let surfaceID = registry.createSurface(app: app, config: config) else {
            logger.error("Failed to create initial surface")
            return
        }

        // Build initial single-leaf tree
        splitTree = SplitTree(leafID: surfaceID)
        container.updateLayout(tree: splitTree)

        // Make the surface the first responder
        if let surfaceView = registry.view(for: surfaceID) {
            window.makeFirstResponder(surfaceView)
        }
    }

    private func registerNotificationObservers() {
        let center = NotificationCenter.default

        center.addObserver(self, selector: #selector(handleNewSplitNotification(_:)),
                           name: .ghosttyNewSplit, object: nil)
        center.addObserver(self, selector: #selector(handleCloseSurfaceNotification(_:)),
                           name: .ghosttyCloseSurface, object: nil)
        center.addObserver(self, selector: #selector(handleGotoSplitNotification(_:)),
                           name: .ghosttyGotoSplit, object: nil)
        center.addObserver(self, selector: #selector(handleResizeSplitNotification(_:)),
                           name: .ghosttyResizeSplit, object: nil)
        center.addObserver(self, selector: #selector(handleEqualizeSplitsNotification(_:)),
                           name: .ghosttyEqualizeSplits, object: nil)
        center.addObserver(self, selector: #selector(handleSetTitleNotification(_:)),
                           name: .ghosttySetTitle, object: nil)
    }

    // MARK: - Tab Operations

    func createNewTab(inheritedConfig: Any? = nil) {
        guard let app = GhosttyAppController.shared.app,
              let window = self.window else { return }

        var config: ghostty_surface_config_s
        if let inherited = inheritedConfig as? ghostty_surface_config_s {
            config = inherited
        } else {
            config = GhosttyFFI.surfaceConfigNew()
        }
        config.scale_factor = Double(window.backingScaleFactor)

        guard let surfaceID = registry.createSurface(app: app, config: config) else {
            logger.error("Failed to create surface for new tab")
            return
        }

        // For now, create a new split tree with a single leaf for the new tab
        // Full tab model integration will use the Tab/TabGroup session model
        let newTree = SplitTree(leafID: surfaceID)

        // Store the old tree's surfaces as occluded
        for id in splitTree.allLeafIDs() {
            registry.controller(for: id)?.setOcclusion(true)
        }

        splitTree = newTree
        splitContainerView?.updateLayout(tree: splitTree)

        if let surfaceView = registry.view(for: surfaceID) {
            window.makeFirstResponder(surfaceView)
        }
    }

    // MARK: - Split Operations

    private func handleDividerDrag(leafID: UUID, delta: Double, direction: SplitDirection) {
        guard let contentView = window?.contentView else { return }
        splitTree = splitTree.resize(
            node: leafID,
            by: delta,
            direction: direction,
            bounds: contentView.bounds.size,
            minSize: 50
        )
        splitContainerView?.updateLayout(tree: splitTree)
    }

    @objc private func handleNewSplitNotification(_ notification: Notification) {
        guard let surfaceView = notification.object as? SurfaceView else { return }
        guard let surfaceID = registry.id(for: surfaceView) else { return }
        guard belongsToThisWindow(surfaceView) else { return }

        guard let app = GhosttyAppController.shared.app else { return }

        let direction = notification.userInfo?["direction"] as? ghostty_action_split_direction_e
        let splitDir: SplitDirection
        switch direction {
        case GHOSTTY_SPLIT_DIRECTION_RIGHT, GHOSTTY_SPLIT_DIRECTION_LEFT:
            splitDir = .horizontal
        case GHOSTTY_SPLIT_DIRECTION_DOWN, GHOSTTY_SPLIT_DIRECTION_UP:
            splitDir = .vertical
        default:
            splitDir = .horizontal
        }

        // Create inherited config if available
        var config: ghostty_surface_config_s
        if let inheritedConfig = notification.userInfo?["inherited_config"] as? ghostty_surface_config_s {
            config = inheritedConfig
        } else {
            config = GhosttyFFI.surfaceConfigNew()
        }
        if let window = self.window {
            config.scale_factor = Double(window.backingScaleFactor)
        }

        guard let newSurfaceID = registry.createSurface(app: app, config: config) else {
            logger.error("Failed to create split surface")
            return
        }

        let (newTree, _) = splitTree.insert(at: surfaceID, direction: splitDir, newID: newSurfaceID)
        splitTree = newTree

        splitContainerView?.updateLayout(tree: splitTree)

        if let newView = registry.view(for: newSurfaceID) {
            window?.makeFirstResponder(newView)
        }
    }

    @objc private func handleCloseSurfaceNotification(_ notification: Notification) {
        guard let surfaceView = notification.object as? SurfaceView else { return }
        guard let surfaceID = registry.id(for: surfaceView) else { return }
        guard belongsToThisWindow(surfaceView) else { return }

        let (newTree, focusTarget) = splitTree.remove(surfaceID)
        registry.destroySurface(surfaceID)
        splitTree = newTree

        if splitTree.isEmpty {
            // Last pane closed — close the window
            window?.close()
            return
        }

        splitContainerView?.updateLayout(tree: splitTree)

        if let focusID = focusTarget, let focusView = registry.view(for: focusID) {
            window?.makeFirstResponder(focusView)
        }
    }

    @objc private func handleGotoSplitNotification(_ notification: Notification) {
        guard let surfaceView = notification.object as? SurfaceView else { return }
        guard let surfaceID = registry.id(for: surfaceView) else { return }
        guard belongsToThisWindow(surfaceView) else { return }

        let direction = notification.userInfo?["direction"] as? ghostty_action_goto_split_e

        let focusDir: FocusDirection
        switch direction {
        case GHOSTTY_GOTO_SPLIT_PREVIOUS:
            focusDir = .previous
        case GHOSTTY_GOTO_SPLIT_NEXT:
            focusDir = .next
        case GHOSTTY_GOTO_SPLIT_LEFT:
            focusDir = .spatial(.left)
        case GHOSTTY_GOTO_SPLIT_RIGHT:
            focusDir = .spatial(.right)
        case GHOSTTY_GOTO_SPLIT_UP:
            focusDir = .spatial(.up)
        case GHOSTTY_GOTO_SPLIT_DOWN:
            focusDir = .spatial(.down)
        default:
            focusDir = .next
        }

        guard let targetID = splitTree.focusTarget(for: focusDir, from: surfaceID) else { return }
        splitTree.focusedLeafID = targetID

        if let targetView = registry.view(for: targetID) {
            window?.makeFirstResponder(targetView)
        }
    }

    @objc private func handleResizeSplitNotification(_ notification: Notification) {
        guard let surfaceView = notification.object as? SurfaceView else { return }
        guard let surfaceID = registry.id(for: surfaceView) else { return }
        guard belongsToThisWindow(surfaceView) else { return }
        guard let contentView = window?.contentView else { return }

        guard let resize = notification.userInfo?["resize"] as? ghostty_action_resize_split_s else { return }

        let direction: SplitDirection
        switch resize.direction {
        case GHOSTTY_RESIZE_SPLIT_LEFT, GHOSTTY_RESIZE_SPLIT_RIGHT:
            direction = .horizontal
        case GHOSTTY_RESIZE_SPLIT_UP, GHOSTTY_RESIZE_SPLIT_DOWN:
            direction = .vertical
        default:
            direction = .horizontal
        }

        let sign: Double
        switch resize.direction {
        case GHOSTTY_RESIZE_SPLIT_RIGHT, GHOSTTY_RESIZE_SPLIT_DOWN:
            sign = 1.0
        default:
            sign = -1.0
        }

        let amount = Double(resize.amount) * sign
        splitTree = splitTree.resize(
            node: surfaceID,
            by: amount,
            direction: direction,
            bounds: contentView.bounds.size,
            minSize: 50
        )
        splitContainerView?.updateLayout(tree: splitTree)
    }

    @objc private func handleEqualizeSplitsNotification(_ notification: Notification) {
        if let surfaceView = notification.object as? SurfaceView {
            guard belongsToThisWindow(surfaceView) else { return }
        }

        splitTree = splitTree.equalize()
        splitContainerView?.updateLayout(tree: splitTree)
    }

    @objc private func handleSetTitleNotification(_ notification: Notification) {
        guard let surfaceView = notification.object as? SurfaceView else { return }
        guard belongsToThisWindow(surfaceView) else { return }
        guard let title = notification.userInfo?["title"] as? String else { return }

        // Update window title from focused surface
        if let focusedID = splitTree.focusedLeafID,
           let focusedView = registry.view(for: focusedID),
           focusedView === surfaceView {
            window?.title = title
        }
    }

    // MARK: - Helpers

    private func belongsToThisWindow(_ view: NSView) -> Bool {
        view.window === self.window
    }

    private var focusedController: GhosttySurfaceController? {
        guard let focusedID = splitTree.focusedLeafID else { return nil }
        return registry.controller(for: focusedID)
    }

    // MARK: - NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) {
        focusedController?.setFocus(true)
    }

    func windowDidResignKey(_ notification: Notification) {
        focusedController?.setFocus(false)
    }

    func windowDidChangeBackingProperties(_ notification: Notification) {
        guard let window = self.window else { return }
        let scale = window.backingScaleFactor
        for id in registry.allIDs {
            registry.controller(for: id)?.setContentScale(scale)
        }
    }

    func windowWillClose(_ notification: Notification) {
        // Destroy all surfaces
        for id in registry.allIDs {
            registry.destroySurface(id)
        }

        if let appDelegate = NSApp.delegate as? AppDelegate {
            appDelegate.removeWindowController(self)
        }
    }

    func windowDidResize(_ notification: Notification) {
        // SplitContainerView handles resize via autoresizingMask + resizeSubviews
    }
}
