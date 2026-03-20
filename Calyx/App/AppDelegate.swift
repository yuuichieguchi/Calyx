import AppKit
import GhosttyKit
import OSLog

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.calyx.terminal",
    category: "AppDelegate"
)

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var appSession = AppSession()
    private(set) var browserTabBroker = BrowserTabBroker()
    private var windowControllers: [CalyxWindowController] = []
    private var pendingURLs: [URL] = []
    private var quickTerminalController: QuickTerminalController?

    var allWindowControllers: [CalyxWindowController] {
        windowControllers
    }

    // MARK: - NSApplicationDelegate

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Add CLI to PATH for terminals launched within Calyx
        if let binPath = Bundle.main.resourceURL?.appendingPathComponent("bin").path {
            let currentPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
            setenv("PATH", "\(binPath):\(currentPath)", 1)
        }

        let controller = GhosttyAppController.shared
        guard controller.readiness == .ready else {
            logger.critical("GhosttyAppController initialization failed")
            let alert = NSAlert()
            alert.messageText = "Failed to Initialize"
            alert.informativeText = "Terminal engine initialization failed. The application will now exit."
            alert.alertStyle = .critical
            alert.runModal()
            NSApp.terminate(nil)
            return
        }

        if let app = controller.app {
            let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let scheme: ghostty_color_scheme_e = isDark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT
            ghostty_app_set_color_scheme(app, scheme)
        }

        setupMainMenu()
        registerNotificationObservers()
        installKeyMonitor()
        installGlobalEventTap()

        browserTabBroker.appDelegate = self
        let browserHandler = BrowserToolHandler(broker: browserTabBroker)
        BrowserServer.shared.toolHandler = browserHandler
        BrowserServer.shared.start()
        NSApp.servicesProvider = self

        let isUITesting = ProcessInfo.processInfo.arguments.contains("--uitesting")
        if isUITesting || !restoreSession() {
            if pendingURLs.isEmpty {
                createNewWindow()
            }
        }
        // Process any URLs that arrived before launch completed
        if !pendingURLs.isEmpty {
            let urls = pendingURLs
            pendingURLs = []
            application(NSApp, open: urls)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        quickTerminalController == nil
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let app = GhosttyAppController.shared.app else {
            return .terminateNow
        }

        if ghostty_app_needs_confirm_quit(app) {
            let alert = NSAlert()
            alert.messageText = "Quit Calyx?"
            alert.informativeText = "A process is still running. Do you want to quit?"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Quit")
            alert.addButton(withTitle: "Cancel")

            let response = alert.runModal()
            if response == .alertSecondButtonReturn {
                return .terminateCancel
            }
        }

        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Last-window close path already persists synchronously in windowWillClose.
        // Avoid overwriting with an empty snapshot during app teardown.
        if windowControllers.isEmpty || appSession.windows.isEmpty {
            return
        }

        let snapshot = buildSnapshot()
        var done = false
        Task {
            await SessionPersistenceActor.shared.saveImmediately(snapshot)
            await SessionPersistenceActor.shared.resetRecoveryCounter()
            done = true
        }
        let deadline = Date().addingTimeInterval(1.0)
        while !done, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        }
        windowControllers.removeAll()
    }

    func applicationDidChangeOcclusionState(_ notification: Notification) {
        if let app = GhosttyAppController.shared.app {
            let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let scheme: ghostty_color_scheme_e = isDark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT
            ghostty_app_set_color_scheme(app, scheme)
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        let directories = urls.compactMap { url -> String? in
            guard url.isFileURL else {
                logger.warning("Ignoring non-file URL: \(url)")
                return nil
            }
            let resolved = url.resolvingSymlinksInPath().standardizedFileURL
            let path = resolved.path

            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else {
                logger.warning("Path does not exist: \(path)")
                return nil
            }
            let dirPath = isDir.boolValue ? path : resolved.deletingLastPathComponent().path
            guard FileManager.default.isReadableFile(atPath: dirPath) else {
                logger.warning("Directory not readable: \(dirPath)")
                return nil
            }
            return dirPath
        }

        guard !directories.isEmpty else { return }

        guard GhosttyAppController.shared.readiness == .ready else {
            pendingURLs.append(contentsOf: urls)
            return
        }

        for dir in directories {
            openWindowAtPath(dir)
        }
    }

    // MARK: - Notification Observers

    private func registerNotificationObservers() {
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(handleNewTab(_:)), name: .ghosttyNewTab, object: nil)
        center.addObserver(self, selector: #selector(handleNewWindow(_:)), name: .ghosttyNewWindow, object: nil)
    }

    @objc private func handleNewTab(_ notification: Notification) {
        // Find the window controller that owns the source surface
        guard let surfaceView = notification.object as? SurfaceView,
              let window = surfaceView.window,
              let wc = windowControllers.first(where: { $0.window === window }) else {
            // No source — create tab in the key window's controller
            if let keyWC = windowControllers.first(where: { $0.window?.isKeyWindow == true }) {
                keyWC.createNewTab(inheritedConfig: notification.userInfo?["inherited_config"])
            }
            return
        }
        wc.createNewTab(inheritedConfig: notification.userInfo?["inherited_config"])
    }

    @objc private func handleNewWindow(_ notification: Notification) {
        createNewWindow()
    }

    // MARK: - Window Management

    @objc func createNewWindow() {
        let initialTab = Tab()
        let windowSession = WindowSession(initialTab: initialTab)
        appSession.addWindow(windowSession)

        let wc = CalyxWindowController(windowSession: windowSession)
        windowControllers.append(wc)
        wc.showWindow(nil)
    }

    func toggleQuickTerminal() {
        if quickTerminalController == nil {
            quickTerminalController = QuickTerminalController()
        }
        quickTerminalController?.toggle()
    }

    func openWindowAtPath(_ pwd: String) {
        let initialTab = Tab(pwd: pwd)
        let windowSession = WindowSession(initialTab: initialTab)
        appSession.addWindow(windowSession)
        let wc = CalyxWindowController(windowSession: windowSession)
        windowControllers.append(wc)
        wc.showWindow(nil)
    }

    func removeWindowController(_ controller: CalyxWindowController) {
        appSession.removeWindow(id: controller.windowSession.id)
        windowControllers.removeAll { $0 === controller }
        if !windowControllers.isEmpty {
            requestSave()
        }
    }

    func isClosingLastManagedWindow(_ controller: CalyxWindowController) -> Bool {
        windowControllers.count == 1 && windowControllers.first === controller
    }

    func applyCurrentGhosttyConfigToAllWindows() {
        for controller in windowControllers {
            controller.applyCurrentGhosttyConfig()
        }
    }

    // MARK: - Main Menu

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        // Application menu
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu

        appMenu.addItem(withTitle: "About Calyx", action: #selector(showAboutPanel), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Preferences…", action: #selector(openPreferences(_:)), keyEquivalent: ",")
        if !UpdateController.shared.isHomebrew {
            let updateItem = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates(_:)), keyEquivalent: "")
            appMenu.addItem(updateItem)
        }
        appMenu.addItem(.separator())

        let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu(title: "Services")
        servicesItem.submenu = servicesMenu
        NSApp.servicesMenu = servicesMenu
        appMenu.addItem(servicesItem)

        let secureInputItem = NSMenuItem(title: "Secure Keyboard Entry", action: #selector(toggleSecureInput(_:)), keyEquivalent: "")
        appMenu.addItem(secureInputItem)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Calyx", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthersItem = NSMenuItem(title: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthersItem.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthersItem)
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Calyx", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // File menu
        let fileMenuItem = NSMenuItem()
        mainMenu.addItem(fileMenuItem)
        let fileMenu = NSMenu(title: "File")
        fileMenuItem.submenu = fileMenu

        fileMenu.addItem(withTitle: "New Window", action: #selector(createNewWindow), keyEquivalent: "n")
        fileMenu.addItem(withTitle: "New Tab", action: #selector(CalyxWindowController.newTab(_:)), keyEquivalent: "t")
        fileMenu.addItem(withTitle: "New Browser Tab", action: #selector(CalyxWindowController.newBrowserTab(_:)), keyEquivalent: "")
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Close Tab", action: #selector(CalyxWindowController.closeTab(_:)), keyEquivalent: "w")

        // Edit menu
        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenuItem.submenu = editMenu

        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        // View menu
        let viewMenuItem = NSMenuItem()
        mainMenu.addItem(viewMenuItem)
        let viewMenu = NSMenu(title: "View")
        viewMenuItem.submenu = viewMenu

        let toggleSidebarItem = NSMenuItem(
            title: "Toggle Sidebar",
            action: #selector(CalyxWindowController.toggleSidebar),
            keyEquivalent: "s"
        )
        toggleSidebarItem.keyEquivalentModifierMask = [.command, .option]
        viewMenu.addItem(toggleSidebarItem)

        let fullScreenItem = NSMenuItem(
            title: "Toggle Full Screen",
            action: #selector(NSWindow.toggleFullScreen(_:)),
            keyEquivalent: "f"
        )
        fullScreenItem.keyEquivalentModifierMask = [.command, .control]
        viewMenu.addItem(fullScreenItem)

        viewMenu.addItem(.separator())

        let paletteItem = NSMenuItem(
            title: "Command Palette",
            action: #selector(CalyxWindowController.toggleCommandPalette),
            keyEquivalent: "p"
        )
        paletteItem.keyEquivalentModifierMask = [.command, .shift]
        viewMenu.addItem(paletteItem)

        // Window menu
        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenuItem.submenu = windowMenu
        NSApp.windowsMenu = windowMenu

        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())

        // Tab navigation via menu
        let nextTabItem = NSMenuItem(title: "Select Next Tab", action: #selector(CalyxWindowController.selectNextTab(_:)), keyEquivalent: "]")
        nextTabItem.keyEquivalentModifierMask = [.command, .shift]
        windowMenu.addItem(nextTabItem)

        let prevTabItem = NSMenuItem(title: "Select Previous Tab", action: #selector(CalyxWindowController.selectPreviousTab(_:)), keyEquivalent: "[")
        prevTabItem.keyEquivalentModifierMask = [.command, .shift]
        windowMenu.addItem(prevTabItem)

        let jumpUnreadItem = NSMenuItem(title: "Jump to Unread Tab", action: #selector(CalyxWindowController.jumpToMostRecentUnreadTab), keyEquivalent: "u")
        jumpUnreadItem.keyEquivalentModifierMask = [.command, .shift]
        windowMenu.addItem(jumpUnreadItem)

        windowMenu.addItem(.separator())

        // Cmd+1-9 tab selection
        for i in 1...9 {
            let item = NSMenuItem(title: "Select Tab \(i)", action: #selector(selectTabByNumber(_:)), keyEquivalent: "\(i)")
            item.target = self
            item.tag = i - 1
            windowMenu.addItem(item)
        }

        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Toggle Quick Terminal", action: #selector(handleToggleQuickTerminal), keyEquivalent: "")

        NSApp.mainMenu = mainMenu
    }

    // MARK: - Session Persistence

    func requestSave() {
        let snapshot = buildSnapshot()
        Task {
            await SessionPersistenceActor.shared.save(snapshot)
        }
    }

    func saveImmediately() {
        let snapshot = buildSnapshot()
        var done = false
        Task {
            await SessionPersistenceActor.shared.saveImmediately(snapshot)
            done = true
        }
        let deadline = Date().addingTimeInterval(1.0)
        while !done, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        }
    }

    private func buildSnapshot() -> SessionSnapshot {
        SessionSnapshot(
            windows: windowControllers.map { $0.windowSnapshot() }
        )
    }

    private func restoreSession() -> Bool {
        // Crash-loop detection
        var recoveryCount = 0
        var snapshot: SessionSnapshot?
        var done = false

        Task {
            recoveryCount = await SessionPersistenceActor.shared.incrementRecoveryCounter()
            if recoveryCount <= SessionPersistenceActor.maxRecoveryAttempts {
                snapshot = await SessionPersistenceActor.shared.restore()
            }
            done = true
        }
        let deadline = Date().addingTimeInterval(2.0)
        while !done, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        }

        guard let snapshot, !snapshot.windows.isEmpty else {
            logger.info("No session to restore (count=\(recoveryCount))")
            return false
        }

        if recoveryCount > SessionPersistenceActor.maxRecoveryAttempts {
            logger.warning("Crash loop detected (\(recoveryCount) attempts), skipping restore")
            return false
        }

        var restoredAny = false

        for windowSnap in snapshot.windows {
            if restoreWindow(windowSnap) {
                restoredAny = true
            }
        }

        if !restoredAny {
            logger.warning("Failed to restore any windows")
            return false
        }

        // Reset recovery counter after successful restore (delayed to confirm stability)
        Task {
            try? await Task.sleep(for: .seconds(5))
            await SessionPersistenceActor.shared.resetRecoveryCounter()
        }

        return true
    }

    private func restoreWindow(_ windowSnap: WindowSnapshot) -> Bool {
        guard let app = GhosttyAppController.shared.app else { return false }

        // Clamp window frame to screen
        let screenFrame = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let clampedSnap = windowSnap.clampedToScreen(screenFrame: screenFrame)

        // Create WindowSession from snapshot
        let windowSession = WindowSession(snapshot: clampedSnap)
        appSession.addWindow(windowSession)

        // Create window with the restored frame
        let window = CalyxWindow(
            contentRect: clampedSnap.frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        let wc = CalyxWindowController(window: window, windowSession: windowSession, restoring: true)
        windowControllers.append(wc)

        // Restore surfaces for each tab
        var anyTabRestored = false
        for group in windowSession.groups {
            for tab in group.tabs {
                // Browser tabs don't need surface restoration
                if case .browser = tab.content {
                    anyTabRestored = true
                    continue
                }
                if restoreTabSurfaces(tab: tab, app: app, window: window) {
                    anyTabRestored = true
                } else {
                    // Fallback: create a single new surface for this tab
                    if fallbackCreateSurface(tab: tab, app: app, window: window) {
                        anyTabRestored = true
                    }
                }
            }
        }

        if !anyTabRestored {
            // Complete failure — clean up the window
            window.close()
            appSession.removeWindow(id: windowSession.id)
            windowControllers.removeAll { $0 === wc }
            logger.error("Failed to restore any tabs for window \(windowSnap.id)")
            return false
        }

        wc.activateRestoredSession()
        wc.showWindow(nil)

        return true
    }

    private func restoreTabSurfaces(tab: Tab, app: ghostty_app_t, window: NSWindow) -> Bool {
        let oldLeafIDs = tab.splitTree.allLeafIDs()
        guard !oldLeafIDs.isEmpty else { return false }

        var mapping: [UUID: UUID] = [:]

        for oldID in oldLeafIDs {
            guard let newID = createSurfaceWithPwd(tab: tab, app: app, window: window) else {
                continue
            }
            mapping[oldID] = newID
        }

        // All leaves must be restored for split integrity
        if mapping.count == oldLeafIDs.count {
            tab.splitTree = tab.splitTree.remapLeafIDs(mapping)
            return true
        }

        // Partial failure: destroy any surfaces we created and return false
        for newID in mapping.values {
            tab.registry.destroySurface(newID)
        }
        return false
    }

    private func fallbackCreateSurface(tab: Tab, app: ghostty_app_t, window: NSWindow) -> Bool {
        guard let newID = createSurfaceWithPwd(tab: tab, app: app, window: window) else {
            return false
        }
        tab.splitTree = SplitTree(leafID: newID)
        return true
    }

    private func createSurfaceWithPwd(tab: Tab, app: ghostty_app_t, window: NSWindow) -> UUID? {
        var config = GhosttyFFI.surfaceConfigNew()
        config.scale_factor = Double(window.backingScaleFactor)
        return tab.registry.createSurface(app: app, config: config, pwd: tab.pwd)
    }

    // MARK: - Finder Services

    @objc func openInCalyx(
        _ pboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString>
    ) {
        guard let urls = pboard.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true
        ]) as? [URL], !urls.isEmpty else {
            error.pointee = "No folder selected" as NSString
            return
        }
        application(NSApp, open: urls)
    }

    // MARK: - Global Keybinds

    /// Enable the global CGEvent tap if ghostty has global keybindings configured.
    /// This allows keybindings like quick terminal toggle to work from any app.
    private func installGlobalEventTap() {
        guard let app = GhosttyAppController.shared.app else {
            logger.warning("installGlobalEventTap: no ghostty app available")
            return
        }
        let hasGlobal = GhosttyFFI.appHasGlobalKeybinds(app)
        logger.info("installGlobalEventTap: hasGlobalKeybinds=\(hasGlobal)")
        if hasGlobal {
            // Delay slightly on fresh launch to avoid burying the Accessibility
            // permissions dialog behind initial windows.
            DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(2)) {
                GlobalEventTap.shared.enable(app: app)
            }
        }
    }

    // MARK: - Actions

    private func installKeyMonitor() {
        let isUITesting = ProcessInfo.processInfo.arguments.contains("--uitesting")

        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let mods = event.modifierFlags.intersection([.command, .shift, .control, .option])
            if mods == [.command, .shift],
               event.charactersIgnoringModifiers?.lowercased() == "p" {
                if let wc = self?.windowControllers.first(where: { $0.window?.isKeyWindow == true }) {
                    wc.toggleCommandPalette()
                    return nil // consume the event
                }
            }

            if mods == [.command, .shift],
               event.charactersIgnoringModifiers?.lowercased() == "u" {
                if let wc = self?.windowControllers.first(where: { $0.window?.isKeyWindow == true }) {
                    wc.jumpToMostRecentUnreadTab()
                    return nil
                }
            }

            if mods == [.command],
               let chars = event.charactersIgnoringModifiers,
               let scalar = chars.unicodeScalars.first,
               chars.count == 1,
               scalar.value >= 49 && scalar.value <= 57 {
                let index = Int(scalar.value - 49)
                if let wc = self?.windowControllers.first(where: { $0.window?.isKeyWindow == true }) {
                    wc.selectTab(at: index)
                    return nil // consume the event
                }
            }

            // Debug Select: Ctrl+Shift+D — only in UI testing mode.
            // Reads selection parameters from the pasteboard and simulates a mouse drag
            // via ghostty FFI to create a terminal selection.
            if isUITesting,
               mods == [.control, .shift],
               event.charactersIgnoringModifiers?.lowercased() == "d" {
                self?.performDebugSelect()
                return nil
            }

            return event
        }
    }

    // MARK: - UI Testing Support

    /// Simulates a mouse drag on the focused terminal surface to create a text selection.
    /// Reads selection parameters (fromCol, toCol, row) from the general pasteboard as JSON.
    /// Only available when launched with --uitesting flag.
    private func debugLog(_ msg: String) {
        let logPath = "/tmp/calyx_debug_select.log"
        let entry = "\(Date()): \(msg)\n"
        if let fh = FileHandle(forWritingAtPath: logPath) {
            fh.seekToEndOfFile()
            fh.write(entry.data(using: .utf8) ?? Data())
            fh.closeFile()
        } else {
            FileManager.default.createFile(atPath: logPath, contents: entry.data(using: .utf8))
        }
    }

    private func performDebugSelect() {
        let pbContent = NSPasteboard.general.string(forType: .string)
        debugLog("performDebugSelect called, pasteboard=\(pbContent ?? "nil")")

        guard let jsonStr = pbContent,
              let data = jsonStr.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Int],
              let fromCol = json["fromCol"],
              let toCol = json["toCol"],
              let row = json["row"] else {
            debugLog("FAIL: JSON parse failed")
            return
        }

        debugLog("Parsed: fromCol=\(fromCol), toCol=\(toCol), row=\(row)")

        guard let wc = windowControllers.first(where: { $0.window?.isKeyWindow == true }) else {
            debugLog("FAIL: no key window")
            return
        }
        guard let controller = wc.focusedControllerForTesting else {
            debugLog("FAIL: no focused controller")
            return
        }
        guard let surface = controller.surface else {
            debugLog("FAIL: no surface")
            return
        }

        // Try cellSize from controller first, fallback to surfaceSize from FFI.
        let cellSize = controller.cellSize
        let surfSize = GhosttyFFI.surfaceSize(surface)
        let cachedCS = controller.surfaceView?.cachedCellSize ?? .zero
        debugLog("cellSize=\(cellSize), surfSize.cell_width_px=\(surfSize.cell_width_px), surfSize.cell_height_px=\(surfSize.cell_height_px), cachedCellSize=\(cachedCS)")

        // Use cellSize if available, otherwise compute from surfaceSize (pixel values
        // divided by backing scale factor to get view-point coordinates).
        let cellW: Double
        let cellH: Double
        if cellSize.width > 0, cellSize.height > 0 {
            cellW = Double(cellSize.width)
            cellH = Double(cellSize.height)
        } else if surfSize.cell_width_px > 0, surfSize.cell_height_px > 0 {
            let scale = controller.surfaceView?.window?.backingScaleFactor ?? 2.0
            cellW = Double(surfSize.cell_width_px) / Double(scale)
            cellH = Double(surfSize.cell_height_px) / Double(scale)
            debugLog("Using surfaceSize with scale=\(scale): cellW=\(cellW), cellH=\(cellH)")
        } else {
            debugLog("FAIL: both cellSize and surfaceSize are zero")
            return
        }

        let startX = (Double(fromCol) + 0.5) * cellW
        let endX = (Double(toCol) + 0.5) * cellW
        let y = (Double(row) + 0.5) * cellH

        debugLog("Drag: startX=\(startX), endX=\(endX), y=\(y)")

        // Simulate drag: move to start, press, move to end, release.
        GhosttyFFI.surfaceMousePos(surface, x: startX, y: y, mods: GHOSTTY_MODS_NONE)
        _ = GhosttyFFI.surfaceMouseButton(surface, state: GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_LEFT, mods: GHOSTTY_MODS_NONE)

        GhosttyFFI.surfaceMousePos(surface, x: endX, y: y, mods: GHOSTTY_MODS_NONE)

        _ = GhosttyFFI.surfaceMouseButton(surface, state: GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_LEFT, mods: GHOSTTY_MODS_NONE)

        let hasSelection = GhosttyFFI.surfaceHasSelection(surface)
        debugLog("After drag: hasSelection=\(hasSelection)")

        // Also try to read text from the entire row for diagnostics.
        do {
            let fullStartX = 0.5 * cellW
            let fullEndX = 80.0 * cellW
            GhosttyFFI.surfaceMousePos(surface, x: fullStartX, y: y, mods: GHOSTTY_MODS_NONE)
            _ = GhosttyFFI.surfaceMouseButton(surface, state: GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_LEFT, mods: GHOSTTY_MODS_NONE)
            GhosttyFFI.surfaceMousePos(surface, x: fullEndX, y: y, mods: GHOSTTY_MODS_NONE)
            _ = GhosttyFFI.surfaceMouseButton(surface, state: GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_LEFT, mods: GHOSTTY_MODS_NONE)

            var fullText = ghostty_text_s()
            if GhosttyFFI.surfaceReadSelection(surface, text: &fullText) {
                let fullLen = Int(fullText.text_len)
                if fullLen > 0, let ptr = fullText.text {
                    let uint8Ptr = UnsafeRawPointer(ptr).assumingMemoryBound(to: UInt8.self)
                    let buf = UnsafeBufferPointer(start: uint8Ptr, count: fullLen)
                    let fullStr = String(decoding: buf, as: UTF8.self)
                    debugLog("Full row \(row) text: '\(fullStr)' (len=\(fullLen))")
                } else {
                    debugLog("Full row \(row): empty (len=\(fullLen))")
                }
                var mutableFullText = fullText
                GhosttyFFI.surfaceFreeText(surface, text: &mutableFullText)
            }

            // Restore original selection
            GhosttyFFI.surfaceMousePos(surface, x: startX, y: y, mods: GHOSTTY_MODS_NONE)
            _ = GhosttyFFI.surfaceMouseButton(surface, state: GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_LEFT, mods: GHOSTTY_MODS_NONE)
            GhosttyFFI.surfaceMousePos(surface, x: endX, y: y, mods: GHOSTTY_MODS_NONE)
            _ = GhosttyFFI.surfaceMouseButton(surface, state: GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_LEFT, mods: GHOSTTY_MODS_NONE)
        }

        if hasSelection {
            var text = ghostty_text_s()
            let readOK = GhosttyFFI.surfaceReadSelection(surface, text: &text)
            debugLog("readSelection returned \(readOK), text_len=\(text.text_len), text.text=\(text.text == nil ? "nil" : "non-nil")")
            if readOK {
                let len = Int(text.text_len)
                if len > 0, let ptr = text.text {
                    let uint8Ptr = UnsafeRawPointer(ptr).assumingMemoryBound(to: UInt8.self)
                    let buf = UnsafeBufferPointer(start: uint8Ptr, count: len)
                    let selectedText = String(decoding: buf, as: UTF8.self)
                    debugLog("Selected text: '\(selectedText)' (len=\(len))")
                } else {
                    debugLog("readSelection text is nil or empty, len=\(len)")
                }
                var mutableText = text
                GhosttyFFI.surfaceFreeText(surface, text: &mutableText)
            }
        }

        debugLog("Debug select complete")
    }

    @objc private func showAboutPanel() {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        NSApp.orderFrontStandardAboutPanel(options: [
            .version: "",
            .applicationVersion: version
        ])
    }

    @objc private func openPreferences(_ sender: Any?) {
        SettingsWindowController.shared.showSettings()
    }

    @objc private func checkForUpdates(_ sender: Any?) {
        UpdateController.shared.checkForUpdates()
    }

    @objc private func toggleSecureInput(_ sender: NSMenuItem) {
        let input = SecureInput.shared
        input.global.toggle()
        UserDefaults.standard.set(input.global, forKey: "SecureInput")
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleSecureInput(_:)) {
            menuItem.state = SecureInput.shared.global ? .on : .off
            return true
        }
        return true
    }

    @objc private func handleToggleQuickTerminal() {
        toggleQuickTerminal()
    }

    @objc private func selectTabByNumber(_ sender: NSMenuItem) {
        guard let wc = windowControllers.first(where: { $0.window?.isKeyWindow == true }) else { return }
        wc.selectTab(at: sender.tag)
    }
}
