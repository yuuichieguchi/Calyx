// GhosttyApp.swift
// Calyx
//
// Manages the ghostty_app_t singleton lifecycle and runtime callbacks.

@preconcurrency import AppKit
import GhosttyKit
import os

private let logger = Logger(subsystem: "com.calyx.terminal", category: "GhosttyApp")

// MARK: - GhosttyAppController

@MainActor
final class GhosttyAppController {

    /// Singleton instance.
    static let shared = GhosttyAppController()

    /// The readiness state of the app controller.
    enum Readiness {
        case loading
        case ready
        case error
    }

    /// Current readiness state.
    private(set) var readiness: Readiness = .loading

    /// The underlying ghostty app handle.
    nonisolated(unsafe) private(set) var app: ghostty_app_t? = nil

    /// The global configuration manager.
    private(set) var configManager: GhosttyConfigManager

    /// True if the app needs confirmation before quitting.
    var needsConfirmQuit: Bool {
        guard let app else { return false }
        return GhosttyFFI.appNeedsConfirmQuit(app)
    }

    // MARK: - Initialization

    private init() {
        // Initialize the ghostty library.
        guard GhosttyFFI.initialize() else {
            logger.critical("ghostty_init failed")
            self.configManager = GhosttyConfigManager()
            self.readiness = .error
            return
        }

        // Load configuration.
        self.configManager = GhosttyConfigManager()
        guard configManager.isLoaded, let config = configManager.config else {
            logger.critical("Failed to load configuration")
            self.readiness = .error
            return
        }

        // Create the runtime config with our callbacks.
        // We pass `self` as userdata via Unmanaged so C callbacks can recover it.
        var runtimeConfig = ghostty_runtime_config_s(
            userdata: Unmanaged.passUnretained(self).toOpaque(),
            supports_selection_clipboard: false,
            wakeup_cb: ghosttyWakeupCallback,
            action_cb: ghosttyActionCallback,
            read_clipboard_cb: ghosttyReadClipboardCallback,
            confirm_read_clipboard_cb: ghosttyConfirmReadClipboardCallback,
            write_clipboard_cb: ghosttyWriteClipboardCallback,
            close_surface_cb: ghosttyCloseSurfaceCallback
        )

        // Create the ghostty app.
        guard let newApp = GhosttyFFI.appNew(&runtimeConfig, config: config) else {
            logger.critical("ghostty_app_new failed")
            handleAppCreationFailure(config: config)
            return
        }

        self.app = newApp
        self.readiness = .ready

        // Set initial focus state.
        GhosttyFFI.appSetFocus(newApp, focused: NSApp.isActive)

        // Register for system notifications.
        registerNotifications()

        logger.info("GhosttyAppController initialized successfully")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        if let app {
            GhosttyFFI.appFree(app)
        }
    }

    // MARK: - App Operations

    /// Tick the ghostty event loop. Called from the wakeup callback.
    func tick() {
        guard let app else { return }
        GhosttyFFI.appTick(app)
    }

    /// Set the app focus state.
    func setFocus(_ focused: Bool) {
        guard let app else { return }
        GhosttyFFI.appSetFocus(app, focused: focused)
    }

    /// Set the color scheme for the entire app.
    func setColorScheme(_ scheme: ghostty_color_scheme_e) {
        guard let app else { return }
        GhosttyFFI.appSetColorScheme(app, scheme: scheme)
    }

    /// Notify ghostty that the keyboard layout has changed.
    func keyboardChanged() {
        guard let app else { return }
        GhosttyFFI.appKeyboardChanged(app)
    }

    /// Reload configuration from disk.
    func reloadConfig(soft: Bool = false) {
        guard let app else { return }

        if soft {
            guard let config = configManager.config else { return }
            GhosttyFFI.appUpdateConfig(app, config: config)
            return
        }

        let newConfigManager = GhosttyConfigManager()
        guard newConfigManager.isLoaded, let newConfig = newConfigManager.config else {
            logger.warning("Failed to reload configuration")
            return
        }

        GhosttyFFI.appUpdateConfig(app, config: newConfig)
        // Set config manager after updating so old config memory stays valid during update.
        self.configManager = newConfigManager
    }

    /// Request the surface to close.
    func requestClose(surface: ghostty_surface_t) {
        GhosttyFFI.surfaceRequestClose(surface)
    }

    // MARK: - Private

    /// Handle failure of ghostty_app_new by showing an alert and retrying with default config.
    private func handleAppCreationFailure(config: ghostty_config_t) {
        let alert = NSAlert()
        alert.messageText = "Terminal Initialization Failed"
        alert.informativeText = "Failed to create the terminal engine. The app will attempt to start with default configuration."
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Retry with Defaults")
        alert.addButton(withTitle: "Quit")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            // Retry with a fresh default config.
            let freshConfig = GhosttyConfigManager()
            guard freshConfig.isLoaded, let cfg = freshConfig.config else {
                self.readiness = .error
                return
            }

            var runtimeConfig = ghostty_runtime_config_s(
                userdata: Unmanaged.passUnretained(self).toOpaque(),
                supports_selection_clipboard: false,
                wakeup_cb: ghosttyWakeupCallback,
                action_cb: ghosttyActionCallback,
                read_clipboard_cb: ghosttyReadClipboardCallback,
                confirm_read_clipboard_cb: ghosttyConfirmReadClipboardCallback,
                write_clipboard_cb: ghosttyWriteClipboardCallback,
                close_surface_cb: ghosttyCloseSurfaceCallback
            )

            if let retryApp = GhosttyFFI.appNew(&runtimeConfig, config: cfg) {
                self.configManager = freshConfig
                self.app = retryApp
                self.readiness = .ready
                GhosttyFFI.appSetFocus(retryApp, focused: NSApp.isActive)
                registerNotifications()
            } else {
                self.readiness = .error
            }
        } else {
            self.readiness = .error
        }
    }

    /// Register for system notifications.
    private func registerNotifications() {
        let center = NotificationCenter.default

        center.addObserver(
            self,
            selector: #selector(keyboardSelectionDidChange),
            name: NSTextInputContext.keyboardSelectionDidChangeNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(applicationDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(applicationDidResignActive),
            name: NSApplication.didResignActiveNotification,
            object: nil
        )
    }

    // MARK: - Notification Handlers

    @objc private func keyboardSelectionDidChange(_ notification: Notification) {
        keyboardChanged()
    }

    @objc private func applicationDidBecomeActive(_ notification: Notification) {
        setFocus(true)
    }

    @objc private func applicationDidResignActive(_ notification: Notification) {
        setFocus(false)
    }

    // MARK: - Helpers

    /// Recover SurfaceView from a ghostty surface's userdata.
    static func surfaceView(from surface: ghostty_surface_t) -> SurfaceView? {
        guard let ud = GhosttyFFI.surfaceUserdata(surface) else { return nil }
        return Unmanaged<SurfaceView>.fromOpaque(ud).takeUnretainedValue()
    }

    /// Recover SurfaceView from raw userdata pointer.
    static func surfaceView(fromUserdata userdata: UnsafeMutableRawPointer) -> SurfaceView {
        Unmanaged<SurfaceView>.fromOpaque(userdata).takeUnretainedValue()
    }

    /// Recover GhosttyAppController from raw userdata pointer.
    static func appController(from userdata: UnsafeMutableRawPointer) -> GhosttyAppController {
        Unmanaged<GhosttyAppController>.fromOpaque(userdata).takeUnretainedValue()
    }
}

// MARK: - C Callback Functions

/// These are file-level functions with @convention(c) calling convention
/// that can be used as ghostty runtime callbacks.

/// Wakeup callback - dispatches to main queue to call tick().
/// This is called from an arbitrary thread.
private func ghosttyWakeupCallback(_ userdata: UnsafeMutableRawPointer?) {
    guard let userdata else { return }
    nonisolated(unsafe) let ud = userdata
    DispatchQueue.main.async {
        let controller = GhosttyAppController.appController(from: ud)
        controller.tick()
    }
}

/// Action callback - routes to GhosttyActionRouter.
/// Called from the main thread during tick.
private func ghosttyActionCallback(
    _ app: ghostty_app_t?,
    _ target: ghostty_target_s,
    _ action: ghostty_action_s
) -> Bool {
    guard let app else { return false }
    nonisolated(unsafe) let safeApp = app
    let safeTarget = target
    let safeAction = action
    return MainActor.assumeIsolated {
        GhosttyActionRouter.handleAction(app: safeApp, target: safeTarget, action: safeAction)
    }
}

/// Read clipboard callback - reads from NSPasteboard.
private func ghosttyReadClipboardCallback(
    _ userdata: UnsafeMutableRawPointer?,
    _ location: ghostty_clipboard_e,
    _ state: UnsafeMutableRawPointer?
) {
    guard let userdata else { return }
    nonisolated(unsafe) let safeUserdata = userdata
    nonisolated(unsafe) let safeState = state
    MainActor.assumeIsolated {
        let surfaceView = GhosttyAppController.surfaceView(fromUserdata: safeUserdata)
        guard let surface = surfaceView.surfaceController?.surface else { return }

        let pasteboard: NSPasteboard
        switch location {
        case GHOSTTY_CLIPBOARD_SELECTION:
            // macOS does not have a selection clipboard in the X11 sense.
            // We use a custom pasteboard for compatibility.
            pasteboard = .init(name: .init("com.calyx.selection"))
        default:
            pasteboard = .general
        }

        let str = pasteboard.string(forType: .string) ?? ""
        str.withCString { ptr in
            GhosttyFFI.surfaceCompleteClipboardRequest(surface, data: ptr, state: safeState, confirmed: false)
        }
    }
}

/// Confirm read clipboard callback.
private func ghosttyConfirmReadClipboardCallback(
    _ userdata: UnsafeMutableRawPointer?,
    _ string: UnsafePointer<CChar>?,
    _ state: UnsafeMutableRawPointer?,
    _ request: ghostty_clipboard_request_e
) {
    guard let userdata else { return }
    nonisolated(unsafe) let safeUserdata = userdata
    nonisolated(unsafe) let safeString = string
    nonisolated(unsafe) let safeState = state
    MainActor.assumeIsolated {
        let surfaceView = GhosttyAppController.surfaceView(fromUserdata: safeUserdata)
        guard let surface = surfaceView.surfaceController?.surface else { return }

        // For Phase 1, we auto-confirm clipboard reads.
        // A proper implementation would show a confirmation dialog.
        guard let str = safeString else {
            "".withCString { ptr in
                GhosttyFFI.surfaceCompleteClipboardRequest(surface, data: ptr, state: safeState, confirmed: true)
            }
            return
        }

        GhosttyFFI.surfaceCompleteClipboardRequest(surface, data: str, state: safeState, confirmed: true)
    }
}

/// Write clipboard callback - writes to NSPasteboard.
private func ghosttyWriteClipboardCallback(
    _ userdata: UnsafeMutableRawPointer?,
    _ string: UnsafePointer<CChar>?,
    _ location: ghostty_clipboard_e,
    _ confirm: Bool
) {
    guard let string else { return }
    guard let valueStr = String(cString: string, encoding: .utf8) else { return }

    MainActor.assumeIsolated {
        let pasteboard: NSPasteboard
        switch location {
        case GHOSTTY_CLIPBOARD_SELECTION:
            pasteboard = .init(name: .init("com.calyx.selection"))
        default:
            pasteboard = .general
        }

        // For Phase 1, we always write without confirmation.
        pasteboard.declareTypes([.string], owner: nil)
        pasteboard.setString(valueStr, forType: .string)
    }
}

/// Close surface callback - posts a notification so the window controller can handle it.
private func ghosttyCloseSurfaceCallback(
    _ userdata: UnsafeMutableRawPointer?,
    _ processAlive: Bool
) {
    guard let userdata else { return }
    nonisolated(unsafe) let safeUserdata = userdata
    MainActor.assumeIsolated {
        let surfaceView = GhosttyAppController.surfaceView(fromUserdata: safeUserdata)

        NotificationCenter.default.post(
            name: .ghosttyCloseSurface,
            object: surfaceView,
            userInfo: ["process_alive": processAlive]
        )
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let ghosttyCloseSurface = Notification.Name("com.calyx.ghostty.closeSurface")
    static let ghosttyNewWindow = Notification.Name("com.calyx.ghostty.newWindow")
    static let ghosttyNewTab = Notification.Name("com.calyx.ghostty.newTab")
    static let ghosttyNewSplit = Notification.Name("com.calyx.ghostty.newSplit")
    static let ghosttyCloseTab = Notification.Name("com.calyx.ghostty.closeTab")
    static let ghosttyCloseWindow = Notification.Name("com.calyx.ghostty.closeWindow")
    static let ghosttySetTitle = Notification.Name("com.calyx.ghostty.setTitle")
    static let ghosttySetPwd = Notification.Name("com.calyx.ghostty.setPwd")
    static let ghosttyCellSizeChange = Notification.Name("com.calyx.ghostty.cellSizeChange")
    static let ghosttyInitialSize = Notification.Name("com.calyx.ghostty.initialSize")
    static let ghosttySizeLimit = Notification.Name("com.calyx.ghostty.sizeLimit")
    static let ghosttyConfigChange = Notification.Name("com.calyx.ghostty.configChange")
    static let ghosttyColorChange = Notification.Name("com.calyx.ghostty.colorChange")
    static let ghosttyToggleFullscreen = Notification.Name("com.calyx.ghostty.toggleFullscreen")
    static let ghosttyRendererHealth = Notification.Name("com.calyx.ghostty.rendererHealth")
    static let ghosttyRingBell = Notification.Name("com.calyx.ghostty.ringBell")
    static let ghosttyShowChildExited = Notification.Name("com.calyx.ghostty.showChildExited")
}
