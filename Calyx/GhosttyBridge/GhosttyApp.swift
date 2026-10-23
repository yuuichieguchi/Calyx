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

    /// Monotonic reload generation counter for config reload tracking.
    private var reloadGeneration: Int = 0

    /// Coordinator for debounced config reload.
    private var reloadCoordinator: ConfigReloadCoordinator?

    /// File watcher for ghostty config file.
    private var configFileWatcher: ConfigFileWatcher?

    private var systemAppearanceObservation: NSKeyValueObservation?

    /// True if the app needs confirmation before quitting.
    var needsConfirmQuit: Bool {
        guard let app else { return false }
        return GhosttyFFI.appNeedsConfirmQuit(app)
    }

    /// Trusted paste content injected by the compose overlay.
    /// When set, the next clipboard read will use this instead of NSPasteboard.
    var trustedPasteContent: String? = nil

    // MARK: - Initialization

    private init() {
        guard GhosttyFFI.initialize() else {
            logger.critical("ghostty_init failed")
            self.configManager = GhosttyConfigManager()
            self.readiness = .error
            return
        }

        self.configManager = GhosttyConfigManager()
        guard configManager.isLoaded, let config = configManager.config else {
            logger.critical("Failed to load configuration")
            self.readiness = .error
            return
        }

        var runtimeConfig: ghostty_runtime_config_s = ghostty_runtime_config_s(
            userdata: Unmanaged.passUnretained(self).toOpaque(),
            supports_selection_clipboard: false,
            wakeup_cb: ghosttyWakeupCallback,
            action_cb: ghosttyActionCallback,
            read_clipboard_cb: ghosttyReadClipboardCallback,
            confirm_read_clipboard_cb: ghosttyConfirmReadClipboardCallback,
            write_clipboard_cb: ghosttyWriteClipboardCallback,
            close_surface_cb: ghosttyCloseSurfaceCallback
        )

        guard let newApp = GhosttyFFI.appNew(&runtimeConfig, config: config) else {
            logger.critical("ghostty_app_new failed")
            handleAppCreationFailure(config: config)
            return
        }

        self.app = newApp
        self.readiness = .ready

        GhosttyFFI.appSetFocus(newApp, focused: NSApp.isActive)

        registerNotifications()

        let adapter = ReloadDepsAdapter(controller: self)
        self.reloadCoordinator = ConfigReloadCoordinator(deps: adapter)

        self.configFileWatcher = ConfigFileWatcher { [weak self] in
            self?.reloadConfig()
        }

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

    func startFollowingSystemAppearance() {
        systemAppearanceObservation = NSApp.observe(\.effectiveAppearance, options: [.initial, .new]) { [weak self] application, _ in
            MainActor.assumeIsolated {
                self?.applyColorScheme(GhosttyColorScheme.scheme(for: application.effectiveAppearance))
            }
        }
    }

    private func applyColorScheme(_ scheme: ghostty_color_scheme_e) {
        guard let app else { return }
        GhosttyColorSchemeBroadcaster.broadcast(
            scheme,
            setAppScheme: { GhosttyFFI.appSetColorScheme(app, scheme: $0) },
            receivers: SurfaceLocator.shared.allControllers()
        )
    }

    /// Notify ghostty that the keyboard layout has changed.
    func keyboardChanged() {
        guard let app else { return }
        GhosttyFFI.appKeyboardChanged(app)
    }

    func reloadConfig() {
        guard let app else { return }

        let newConfigManager = GhosttyConfigManager()
        guard newConfigManager.isLoaded, let newConfig = newConfigManager.config else {
            logger.warning("Config reload failed — keeping previous config")
            return
        }

        let previousConfigManager = self.configManager
        self.configManager = newConfigManager
        withExtendedLifetime((previousConfigManager, newConfigManager)) {
            GhosttyFFI.appUpdateConfig(app, config: newConfig)
        }

        if let appDelegate = NSApp.delegate as? AppDelegate {
            appDelegate.applyCurrentGhosttyConfigToAllWindows()
        }
    }

    func reapplyCurrentConfig() {
        guard let app else { return }
        let currentConfigManager = configManager
        guard let config = currentConfigManager.config else { return }
        withExtendedLifetime(currentConfigManager) {
            GhosttyFFI.appUpdateConfig(app, config: config)
        }
    }

    func reapplyCurrentConfig(to surfaceController: GhosttySurfaceController) {
        let currentConfigManager = configManager
        guard let config = currentConfigManager.config else { return }
        withExtendedLifetime(currentConfigManager) {
            surfaceController.updateConfig(config)
        }
    }

    func reloadConfigFromDisk(for surfaceController: GhosttySurfaceController) {
        let freshConfigManager = GhosttyConfigManager()
        guard freshConfigManager.isLoaded, let config = freshConfigManager.config else {
            logger.warning("Surface config reload failed — keeping previous config")
            return
        }
        withExtendedLifetime(freshConfigManager) {
            surfaceController.updateConfig(config)
        }
    }

    func adoptAppliedConfig(_ config: ghostty_config_t) {
        configManager = GhosttyConfigManager(clone: config)
    }

    /// Request the surface to close.
    func requestClose(surface: ghostty_surface_t) {
        GhosttyFFI.surfaceRequestClose(surface)
    }

    // MARK: - Config Reload Adapter

    /// Adapter bridging ConfigReloadDeps to GhosttyAppController internals.
    private final class ReloadDepsAdapter: ConfigReloadDeps {
        private weak let controller: GhosttyAppController?

        init(controller: GhosttyAppController) {
            self.controller = controller
        }

        func loadConfigFromDisk() -> Int? {
            guard let controller, let app = controller.app else { return nil }

            let newConfigManager = GhosttyConfigManager()
            guard newConfigManager.isLoaded, let newConfig = newConfigManager.config else {
                logger.warning("Config reload failed — keeping previous config")
                for diag in newConfigManager.diagnostics {
                    logger.warning("Config diagnostic: \(diag)")
                }
                return nil
            }

            let previousConfigManager = controller.configManager
            controller.configManager = newConfigManager
            withExtendedLifetime((previousConfigManager, newConfigManager)) {
                GhosttyFFI.appUpdateConfig(app, config: newConfig)
            }
            controller.reloadGeneration += 1
            logger.info("Config reloaded from disk (generation \(controller.reloadGeneration))")
            return controller.reloadGeneration
        }

        func propagateConfigToAllWindows() {
            if let appDelegate = NSApp.delegate as? AppDelegate {
                appDelegate.applyCurrentGhosttyConfigToAllWindows()
            }
        }
    }

    // MARK: - Private

    private func handleAppCreationFailure(config: ghostty_config_t) {
        let alert = NSAlert()
        alert.messageText = "Terminal Initialization Failed"
        alert.informativeText = "Failed to create the terminal engine. The app will attempt to start with default configuration."
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Retry with Defaults")
        alert.addButton(withTitle: "Quit")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            let freshConfig = GhosttyConfigManager()
            guard freshConfig.isLoaded, let cfg = freshConfig.config else {
                self.readiness = .error
                return
            }

            var runtimeConfig: ghostty_runtime_config_s = ghostty_runtime_config_s(
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

                let adapter = ReloadDepsAdapter(controller: self)
                self.reloadCoordinator = ConfigReloadCoordinator(deps: adapter)
                self.configFileWatcher = ConfigFileWatcher { [weak self] in
                    self?.reloadConfig()
                }
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
/// If the clipboard content is potentially unsafe (contains newlines or
/// bracketed-paste-end sequences), we show a confirmation dialog directly
/// as a sheet on the surface's window. This bypasses NotificationCenter
/// to avoid type-casting issues with C types in userInfo dictionaries.
private func ghosttyReadClipboardCallback(
    _ userdata: UnsafeMutableRawPointer?,
    _ location: ghostty_clipboard_e,
    _ state: UnsafeMutableRawPointer?
) -> Bool {
    guard let userdata else { return false }
    nonisolated(unsafe) let safeUserdata = userdata
    nonisolated(unsafe) let safeState = state
    MainActor.assumeIsolated {
        let surfaceView = GhosttyAppController.surfaceView(fromUserdata: safeUserdata)
        guard let surface = surfaceView.surfaceController?.surface else { return }

        // Check for trusted paste content (from compose overlay).
        let appController = GhosttyAppController.shared
        if let trusted = appController.trustedPasteContent {
            appController.trustedPasteContent = nil
            trusted.withCString { ptr in
                GhosttyFFI.surfaceCompleteClipboardRequest(surface, data: ptr, state: safeState, confirmed: true)
            }
            return
        }

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
    return true
}

/// Confirm read clipboard callback - posts notification to show confirmation UI.
private func ghosttyConfirmReadClipboardCallback(
    _ userdata: UnsafeMutableRawPointer?,
    _ string: UnsafePointer<CChar>?,
    _ state: UnsafeMutableRawPointer?,
    _ request: ghostty_clipboard_request_e
) {
    guard let userdata else { return }
    nonisolated(unsafe) let safeUserdata = userdata
    nonisolated(unsafe) let safeState = state
    // Copy the string to a Swift String since the C memory may be freed after callback returns.
    let contents: String
    if let string {
        contents = String(cString: string)
    } else {
        contents = ""
    }
    MainActor.assumeIsolated {
        let surfaceView = GhosttyAppController.surfaceView(fromUserdata: safeUserdata)
        guard let surface = surfaceView.surfaceController?.surface else { return }

        NotificationCenter.default.post(
            name: .ghosttyConfirmClipboard,
            object: surfaceView,
            userInfo: [
                "contents": contents,
                "surface": surface,
                "state": safeState as Any,
                "request": request,
            ]
        )
    }
}

/// Write clipboard callback - writes to NSPasteboard.
private func ghosttyWriteClipboardCallback(
    _ userdata: UnsafeMutableRawPointer?,
    _ location: ghostty_clipboard_e,
    _ contents: UnsafePointer<ghostty_clipboard_content_s>?,
    _ contentsLen: Int,
    _ confirm: Bool
) {
    guard let contents, contentsLen > 0 else { return }

    // Find the first entry with a text/plain mime type, or fall back to the first entry.
    var valueStr: String?
    for i in 0..<contentsLen {
        let entry = contents[i]
        if let mime = entry.mime, let data = entry.data {
            let mimeStr = String(cString: mime)
            if mimeStr == "text/plain" {
                valueStr = String(cString: data)
                break
            }
        }
    }
    // Fallback: use the first entry's data if no text/plain was found.
    if valueStr == nil, let data = contents[0].data {
        valueStr = String(cString: data)
    }

    guard let valueStr else { return }

    MainActor.assumeIsolated {
        let pasteboard: NSPasteboard
        switch location {
        case GHOSTTY_CLIPBOARD_SELECTION:
            pasteboard = .init(name: .init("com.calyx.selection"))
        default:
            pasteboard = .general
        }

        // Write to clipboard (confirmation for writes would be handled separately if needed).
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
    static let ghosttyGotoSplit = Notification.Name("com.calyx.ghostty.gotoSplit")
    static let ghosttyResizeSplit = Notification.Name("com.calyx.ghostty.resizeSplit")
    static let ghosttyEqualizeSplits = Notification.Name("com.calyx.ghostty.equalizeSplits")
    static let ghosttyDesktopNotification = Notification.Name("com.calyx.ghostty.desktopNotification")
    static let ghosttyStartSearch = Notification.Name("com.calyx.ghostty.startSearch")
    static let ghosttyEndSearch = Notification.Name("com.calyx.ghostty.endSearch")
    static let ghosttySearchTotal = Notification.Name("com.calyx.ghostty.searchTotal")
    static let ghosttySearchSelected = Notification.Name("com.calyx.ghostty.searchSelected")
    static let ghosttyGotoTab = Notification.Name("com.calyx.ghostty.gotoTab")
    static let ghosttyConfirmClipboard = Notification.Name("com.calyx.ghostty.confirmClipboard")
    /// Posted for `GHOSTTY_ACTION_PROGRESS_REPORT` (OSC 9;4), an in-band
    /// signal for `AgentRegistry.handleProgressReport`'s Herdr-layer-2
    /// fallback. `userInfo["active"]` is `true` for `SET`/`INDETERMINATE`,
    /// `false` for `REMOVE`/`ERROR`/`PAUSE`.
    static let ghosttyProgressReport = Notification.Name("com.calyx.ghostty.progressReport")
    /// Posted for `GHOSTTY_ACTION_COMMAND_FINISHED` (OSC 133 C/D pairing),
    /// a pane-exit fallback for `AgentRegistry.handleGhosttyCommandFinished`
    /// covering shells Calyx's own `/command-event` shell integration
    /// does not reach. `object` is the triggering `SurfaceView`;
    /// `userInfo["exit_code"]` is an `Int32?` (`GhosttyActionRouter
    /// .commandFinishedExitCode`'s converted payload -- `nil` when
    /// ghostty reported no exit code).
    static let ghosttyCommandFinished = Notification.Name("com.calyx.ghostty.commandFinished")
    static let smoothScrollSettingChanged = Notification.Name("com.calyx.smoothScrollSettingChanged")
    /// Posted by every `DiffLayoutSettings` setter.
    static let diffLayoutSettingChanged = Notification.Name("com.calyx.diffLayoutSettingChanged")

    // MARK: - Second Missing-Observer Investigation
    //
    // `GHOSTTY_ACTION_SET_TAB_TITLE` / `COPY_TITLE_TO_CLIPBOARD` /
    // `TOGGLE_COMMAND_PALETTE` / `MOVE_TAB` / `TOGGLE_MAXIMIZE` /
    // `RESET_WINDOW_SIZE`, all posted by `GhosttyActionRouter` and
    // observed by `CalyxWindowController.registerNotificationObservers()`.

    /// `GHOSTTY_ACTION_SET_TAB_TITLE`. `object` is the triggering
    /// `SurfaceView`; `userInfo["title"]` is a `String` (may be empty,
    /// meaning "clear back to the default").
    static let ghosttySetTabTitle = Notification.Name("com.calyx.ghostty.setTabTitle")
    /// `GHOSTTY_ACTION_COPY_TITLE_TO_CLIPBOARD`. `object` is the
    /// triggering `SurfaceView`; no `userInfo`.
    static let ghosttyCopyTitleToClipboard = Notification.Name("com.calyx.ghostty.copyTitleToClipboard")
    /// `GHOSTTY_ACTION_TOGGLE_COMMAND_PALETTE`. `object` is the
    /// triggering `SurfaceView`; no `userInfo`.
    static let ghosttyToggleCommandPalette = Notification.Name("com.calyx.ghostty.toggleCommandPalette")
    /// `GHOSTTY_ACTION_TOGGLE_TAB_OVERVIEW`, repurposed to toggle Mission
    /// Map. `object` is the triggering `SurfaceView`, or `nil` when the
    /// action did not come from a surface; no `userInfo`.
    static let ghosttyToggleTabOverview = Notification.Name("com.calyx.ghostty.toggleTabOverview")
    /// `GHOSTTY_ACTION_MOVE_TAB`. `object` is the triggering
    /// `SurfaceView`; `userInfo["amount"]` is an `Int`
    /// (`ghostty_action_move_tab_s.amount`, `ssize_t`).
    static let ghosttyMoveTab = Notification.Name("com.calyx.ghostty.moveTab")
    /// `GHOSTTY_ACTION_TOGGLE_MAXIMIZE`. `object` is the triggering
    /// `SurfaceView`; no `userInfo`.
    static let ghosttyToggleMaximize = Notification.Name("com.calyx.ghostty.toggleMaximize")
    /// `GHOSTTY_ACTION_RESET_WINDOW_SIZE`. `object` is the triggering
    /// `SurfaceView`; no `userInfo`.
    static let ghosttyResetWindowSize = Notification.Name("com.calyx.ghostty.resetWindowSize")

    // MARK: - Prompt Title (GitHub issue #42)

    /// `GHOSTTY_ACTION_PROMPT_TITLE` (`prompt_tab_title`/
    /// `prompt_surface_title` keybinds). `object` is the triggering
    /// `SurfaceView`; `userInfo["scope"]` is a `String` — `TitlePromptScope`'s
    /// raw value (`"surface"` or `"tab"`), not the raw
    /// `ghostty_action_prompt_title_e` (`GhosttyActionRouter.handlePromptTitle`
    /// converts it before posting so the C type never crosses the
    /// notification boundary).
    static let ghosttyPromptTitle = Notification.Name("com.calyx.ghostty.promptTitle")

    // MARK: - Split Zoom (GHOSTTY_ACTION_TOGGLE_SPLIT_ZOOM)

    /// `GHOSTTY_ACTION_TOGGLE_SPLIT_ZOOM`. `object` is the triggering
    /// `SurfaceView`; no `userInfo` — mirrors `.ghosttyEqualizeSplits`'s
    /// no-payload shape. See `CalyxWindowController.processToggleSplitZoom
    /// (surfaceView:)` and `Calyx/Models/SplitTree.swift`'s own
    /// "MARK: - Zoom" section for the full contract.
    static let ghosttyToggleSplitZoom = Notification.Name("com.calyx.ghostty.toggleSplitZoom")
}
