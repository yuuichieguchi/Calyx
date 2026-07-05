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

    /// Set when the user has already confirmed quit (prevents double-prompting
    /// between windowShouldClose and applicationShouldTerminate).
    var isTerminationConfirmed = false

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

    /// Reads and clears `isTerminationConfirmed` — set ahead of time by
    /// `windowShouldClose` when the last-window close path already ran
    /// its own pre-close confirm-quit prompt, so this method doesn't
    /// prompt a second time for the same termination. See
    /// `windowShouldClose` for that last-window pre-close prompt path.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if ProcessInfo.processInfo.arguments.contains("--uitesting") {
            markAllControllersClosingForShutdown()
            return .terminateNow
        }

        // Already confirmed (from windowShouldClose on last-window close path)
        if isTerminationConfirmed {
            isTerminationConfirmed = false
            markAllControllersClosingForShutdown()
            return .terminateNow
        }

        // Cmd+Q path: run confirmations
        if !confirmQuitIfNeeded() {
            return .terminateCancel
        }

        isTerminationConfirmed = true
        // Flag all controllers so windowDidExitFullScreen preserves tracking state
        // during app teardown (the red-button / Cmd+W path sets its own flag).
        markAllControllersClosingForShutdown()
        return .terminateNow
    }

    private func markAllControllersClosingForShutdown() {
        for wc in windowControllers {
            wc.isClosingForShutdown = true
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Give any kill(id:) calls dispatched by an explicit pane/tab
        // close that raced with this quit a short, bounded window to
        // actually finish (see SessionKillTracker's header comment) —
        // otherwise a kill's Task could be torn down mid-Process-spawn,
        // silently leaving the calyx-session running as an orphan even
        // though the user asked to end it. Runs regardless of
        // windowControllers/appSession state below, since kills can be
        // in flight even after every window has already closed.
        var killsDrained = false
        Task {
            await SessionKillTracker.drain(timeoutSeconds: 2.0)
            killsDrained = true
        }
        let killDrainDeadline = Date().addingTimeInterval(2.5)
        while !killsDrained, Date() < killDrainDeadline {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        }

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

    /// Session Browser's "Attach" action for a *running* session with
    /// no live surface in this process (`SessionBrowserRow.isOrphan`):
    /// opens a new window whose sole tab reattaches to `sessionID`.
    /// Reuses `restoreTabSurfaces`/`fallbackCreateSurface` — the same
    /// machinery a snapshot restore uses — with a placeholder leaf UUID
    /// standing in for the "old leaf" `tab.sessionRefs` key
    /// `restoreTabSurfaces` expects, so this is exactly the single-tab,
    /// single-leaf case of a snapshot restore rather than a second,
    /// parallel code path.
    #if DEBUG
    /// Test seam (P4 round-4 fix RED phase): when non-nil, consulted
    /// right where `attachWindow` is about to construct a real window
    /// and ghostty surface — invoked instead of that real work, which
    /// never runs. Driving `attachWindow` end-to-end with a live
    /// surface is unsafe from this test host (confirmed empirically:
    /// it hangs the XCTest process indefinitely — no other test in
    /// this suite creates a real ghostty surface or calls
    /// `showWindow`). This seam lets `AppDelegateAttachWindowTests`
    /// observe WHETHER `attachWindow` reaches its window-creation step
    /// at all — exactly what F6's double-attach guard must prevent for
    /// an already-attached sessionID — without ever performing that
    /// real, unsafe-to-test work. Does not affect production behavior:
    /// `nil` (the default) leaves this line as a no-op; every guard
    /// ABOVE this point (including the fix this seam was added for)
    /// still runs for real, unmodified. DO NOT use from production
    /// code.
    var _attachWindowCreationHookForTesting: (() -> Void)?
    #endif

    func attachWindow(sessionID: String, cwd: String?) {
        guard let app = GhosttyAppController.shared.app else { return }

        // F6 (S1, HIGH, r4-fix-spec.md): a sessionID already registered
        // in SessionSurfaceMap already has a live surface somewhere in
        // this process. This covers the session browser's double-click/
        // stale-row race (rows only refresh on poll, and this method has
        // no debounce of its own). Focus that existing surface's window
        // instead of creating a second one. Checked BEFORE the
        // test-creation hook below, so AppDelegateAttachWindowTests can
        // observe the guard firing without ever reaching real window/
        // surface creation.
        if SessionSurfaceMap.shared.surfaceID(for: sessionID) != nil {
            focusWindowForExistingSession(sessionID: sessionID)
            return
        }

        #if DEBUG
        if let hook = _attachWindowCreationHookForTesting {
            hook()
            return
        }
        #endif

        let placeholderLeafID = UUID()
        let tab = Tab(
            pwd: cwd,
            splitTree: SplitTree(leafID: placeholderLeafID),
            sessionRefs: [placeholderLeafID: SessionRef(sessionID: sessionID)]
        )
        let windowSession = WindowSession(initialTab: tab)
        let (window, wc) = makeRestoringWindowController(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            windowSession: windowSession
        )

        let sessions = fetchSessionsForAgentResume()
        let restored = restoreTabSurfaces(tab: tab, app: app, window: window, sessions: sessions)
        guard restored || fallbackCreateSurface(tab: tab, app: app, window: window) else {
            cleanupFailedWindow(window, windowSession, wc, message: "Failed to attach window for session \(sessionID)")
            return
        }

        wc.activateRestoredSession()
        wc.showWindow(nil)
    }

    /// F6: brings the window already hosting `sessionID`'s live surface
    /// to the front, instead of `attachWindow` creating a second one for
    /// the same session.
    private func focusWindowForExistingSession(sessionID: String) {
        guard let surfaceID = SessionSurfaceMap.shared.surfaceID(for: sessionID) else { return }
        guard let wc = windowControllers.first(where: { controller in
            controller.windowSession.groups.contains { group in
                group.tabs.contains { $0.registry.contains(surfaceID) }
            }
        }) else { return }
        wc.showWindow(nil)
    }

    /// F11 (V13, WARNING, r4-fix-spec.md): the window-construction +
    /// registration boilerplate shared identically by `attachWindow` and
    /// `restoreWindow`. Does NOT cover the tab-restoration control flow
    /// around it (single guard vs. loop+accumulator) or the fullscreen
    /// branch, which genuinely differ and must stay separate (see
    /// r4-verdicts.md V13). Registers `windowSession` with `appSession`
    /// and appends the new controller to `windowControllers` as a side
    /// effect, exactly matching both callers' prior inline code.
    private func makeRestoringWindowController(
        contentRect: NSRect,
        windowSession: WindowSession
    ) -> (window: CalyxWindow, controller: CalyxWindowController) {
        appSession.addWindow(windowSession)
        let window = CalyxWindow(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        let wc = CalyxWindowController(window: window, windowSession: windowSession, restoring: true)
        windowControllers.append(wc)
        return (window, wc)
    }

    /// F11 (V13, WARNING): the failure-cleanup triple shared identically
    /// by `attachWindow` and `restoreWindow` when no surface could be
    /// restored at all. Closes the just-created (never shown) window,
    /// undoes its `appSession`/`windowControllers` registration, and
    /// logs `message`. Logged `.public` (matching this file's other
    /// session-ID log statements, e.g. `performReconnect`'s); the
    /// `.private` this exact line used before extraction was an
    /// inconsistency, not a deliberate secrecy decision, since every
    /// other session-ID log statement in this codebase already uses
    /// `.public`.
    private func cleanupFailedWindow(
        _ window: CalyxWindow,
        _ windowSession: WindowSession,
        _ wc: CalyxWindowController,
        message: String
    ) {
        window.close()
        appSession.removeWindow(id: windowSession.id)
        windowControllers.removeAll { $0 === wc }
        logger.error("\(message, privacy: .public)")
    }

    func removeWindowController(_ controller: CalyxWindowController) {
        appSession.removeWindow(id: controller.windowSession.id)
        windowControllers.removeAll { $0 === controller }
        if !windowControllers.isEmpty {
            requestSave()
        } else if quickTerminalController == nil {
            NSApp.terminate(nil)
        }
    }

    func isClosingLastManagedWindow(_ controller: CalyxWindowController) -> Bool {
        windowControllers.count == 1 && windowControllers.first === controller
    }

    /// True when closing `controller` would empty the last managed
    /// window and no quick terminal is open to keep the app alive —
    /// i.e. closing it would terminate the app. Consulted by
    /// `CalyxWindowController`'s close paths (`windowShouldClose`,
    /// `closeTab`, `closeActiveGroup`, `closeAllTabsInGroup`,
    /// `confirmQuitBeforeCloseIfWouldTerminate`) to decide whether a
    /// pre-teardown confirm-quit prompt is needed at all.
    func closingWouldTerminate(_ controller: CalyxWindowController) -> Bool {
        isClosingLastManagedWindow(controller) && quickTerminalController == nil
    }

    /// Distinguishes the two confirm-quit wordings: `.killProcesses`
    /// (the default — a real process is about to be killed) vs.
    /// `.detachOnly` (the session will keep running headless in the
    /// daemon, detached rather than killed). Passed through by
    /// `CalyxWindowController.confirmQuitBeforeCloseIfWouldTerminate`
    /// from whichever close path is asking (kill vs. detach semantics).
    enum ConfirmQuitMode {
        case killProcesses
        case detachOnly
    }

    /// Set for the duration of `confirmQuitIfNeeded`'s `alert.runModal()`
    /// call (see Patch 2's header comment there). While `true`, other
    /// MainActor entry points that could mutate window/tab state out
    /// from under an in-flight confirm-quit prompt, currently
    /// `CalyxWindowController.handleShowChildExitedNotification` and
    /// `handleSessionReconnectDecision`, defer their work instead of
    /// acting immediately (see each's doc comment). The `didSet` below
    /// posts `.calyxConfirmingQuitDidEnd` on the `true` -> `false`
    /// transition so every live `CalyxWindowController` can replay
    /// whatever it deferred (F4, r4-fix-spec.md). This fires for both
    /// the real `alert.runModal()` return path below AND the
    /// `_setConfirmingQuitForTesting` test seam, since both assign this
    /// same property.
    private(set) var isConfirmingQuit: Bool = false {
        didSet {
            guard oldValue, !isConfirmingQuit else { return }
            NotificationCenter.default.post(name: .calyxConfirmingQuitDidEnd, object: nil)
        }
    }

    #if DEBUG
    /// Test seam (P4 round-4 fix RED phase): lets tests simulate the
    /// `isConfirmingQuit` gate flipping on/off without driving a real,
    /// blocking `NSAlert.runModal()` through `confirmQuitIfNeeded` —
    /// mirrors `SurfaceRegistry._testInsert`'s naming/gating convention.
    /// Production code only ever toggles `isConfirmingQuit` itself, from
    /// within `confirmQuitIfNeeded`'s own bracket. DO NOT use from
    /// production code.
    func _setConfirmingQuitForTesting(_ value: Bool) {
        isConfirmingQuit = value
    }
    #endif

    /// Returns true if the app should proceed with quit, false if user
    /// cancelled. Called both from `applicationShouldTerminate` (the
    /// Cmd+Q / "Quit Calyx" path) and, via
    /// `CalyxWindowController.confirmQuitBeforeCloseIfWouldTerminate`,
    /// from individual close paths (`windowShouldClose`, `closeTab`,
    /// `closeActiveGroup`, `closeAllTabsInGroup`,
    /// `closeFocusedSessionSurface`, `handleReconnectGiveUp`) BEFORE
    /// they tear anything down, when closing would terminate the app —
    /// see `closingWouldTerminate`. `mode` selects the wording: a
    /// kill-semantics close (default) warns that a running process is
    /// about to end; a detach-semantics close (`.detachOnly`) explains
    /// the session will keep running headless instead.
    func confirmQuitIfNeeded(_ mode: ConfirmQuitMode = .killProcesses) -> Bool {
        // Check for running processes
        guard let app = GhosttyAppController.shared.app,
              ghostty_app_needs_confirm_quit(app) else {
            return true
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Quit Calyx?"
        switch mode {
        case .killProcesses:
            alert.informativeText = "A process is still running. Do you want to quit?"
        case .detachOnly:
            alert.informativeText = "The session will be detached and remain running in the background. The daemon will keep it alive for later reattachment. Do you want to quit?"
        }
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")

        isConfirmingQuit = true
        let response = alert.runModal()
        isConfirmingQuit = false

        return response != .alertSecondButtonReturn
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

        // Split actions live directly under File to match Ghostty's menu structure.
        let splitRightItem = NSMenuItem(
            title: "Split Right",
            action: #selector(SurfaceView.splitRight(_:)),
            keyEquivalent: "d")
        splitRightItem.keyEquivalentModifierMask = [.command]
        fileMenu.addItem(splitRightItem)

        let splitLeftItem = NSMenuItem(
            title: "Split Left",
            action: #selector(SurfaceView.splitLeft(_:)),
            keyEquivalent: "")
        fileMenu.addItem(splitLeftItem)

        let splitDownItem = NSMenuItem(
            title: "Split Down",
            action: #selector(SurfaceView.splitDown(_:)),
            keyEquivalent: "d")
        splitDownItem.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(splitDownItem)

        let splitUpItem = NSMenuItem(
            title: "Split Up",
            action: #selector(SurfaceView.splitUp(_:)),
            keyEquivalent: "")
        fileMenu.addItem(splitUpItem)

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

        editMenu.addItem(.separator())

        // Parent "Find" submenu item has no action of its own — clicking it
        // only expands the submenu (which exposes Find…, Find Next, Find
        // Previous). Earlier revisions wired #selector(performFindAction:) on
        // the parent as a workaround for XCUI predicate-based firstMatch
        // landing on the submenu parent before its child; that workaround was
        // unsafe (AppKit could fire the parent action alongside submenu
        // expansion) and has been replaced with a tightened predicate in the
        // UI tests that selects "Find…" directly.
        let findMenuItem = NSMenuItem(
            title: "Find",
            action: nil,
            keyEquivalent: "")
        let findMenu = NSMenu(title: "Find")
        findMenuItem.submenu = findMenu

        let findStartItem = NSMenuItem(
            title: "Find…",
            action: #selector(SurfaceView.performFindAction(_:)),
            keyEquivalent: "f")
        findStartItem.keyEquivalentModifierMask = [.command]
        findMenu.addItem(findStartItem)

        let findNextItem = NSMenuItem(
            title: "Find Next",
            action: #selector(SurfaceView.findNext(_:)),
            keyEquivalent: "g")
        findNextItem.keyEquivalentModifierMask = [.command]
        findMenu.addItem(findNextItem)

        let findPreviousItem = NSMenuItem(
            title: "Find Previous",
            action: #selector(SurfaceView.findPrevious(_:)),
            keyEquivalent: "g")
        findPreviousItem.keyEquivalentModifierMask = [.command, .shift]
        findMenu.addItem(findPreviousItem)

        editMenu.addItem(findMenuItem)

        editMenu.addItem(.separator())
        let composeItem = NSMenuItem(
            title: "Compose Input",
            action: #selector(CalyxWindowController.toggleComposeOverlay),
            keyEquivalent: "e"
        )
        composeItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(composeItem)

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

        viewMenu.addItem(.separator())

        let paletteItem = NSMenuItem(
            title: "Command Palette",
            action: #selector(CalyxWindowController.toggleCommandPalette),
            keyEquivalent: "p"
        )
        paletteItem.keyEquivalentModifierMask = [.command, .shift]
        viewMenu.addItem(paletteItem)

        viewMenu.addItem(.separator())

        viewMenu.addItem(
            withTitle: "Quick Terminal",
            action: #selector(handleToggleQuickTerminal),
            keyEquivalent: ""
        )

        // Window menu
        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenuItem.submenu = windowMenu
        NSApp.windowsMenu = windowMenu

        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())

        // Use a custom selector instead of NSWindow.toggleFullScreen(_:) so
        // AppKit doesn't rewrite the menu title to "Enter/Exit Full Screen".
        // Matches Ghostty's `toggleGhosttyFullScreen:` approach.
        let fullScreenItem = NSMenuItem(
            title: "Toggle Full Screen",
            action: #selector(CalyxWindowController.toggleFullScreen(_:)),
            keyEquivalent: "f"
        )
        fullScreenItem.keyEquivalentModifierMask = [.command, .control]
        windowMenu.addItem(fullScreenItem)

        windowMenu.addItem(.separator())

        let focusSplitMenuItem = NSMenuItem(title: "Focus Split", action: nil, keyEquivalent: "")
        let focusSplitMenu = NSMenu(title: "Focus Split")
        focusSplitMenuItem.submenu = focusSplitMenu

        let focusUpItem = NSMenuItem(
            title: "Focus Split Up",
            action: #selector(SurfaceView.focusSplitUp(_:)),
            keyEquivalent: String(Unicode.Scalar(NSUpArrowFunctionKey)!))
        focusUpItem.keyEquivalentModifierMask = [.command, .option]
        focusSplitMenu.addItem(focusUpItem)

        let focusDownItem = NSMenuItem(
            title: "Focus Split Down",
            action: #selector(SurfaceView.focusSplitDown(_:)),
            keyEquivalent: String(Unicode.Scalar(NSDownArrowFunctionKey)!))
        focusDownItem.keyEquivalentModifierMask = [.command, .option]
        focusSplitMenu.addItem(focusDownItem)

        let focusLeftItem = NSMenuItem(
            title: "Focus Split Left",
            action: #selector(SurfaceView.focusSplitLeft(_:)),
            keyEquivalent: String(Unicode.Scalar(NSLeftArrowFunctionKey)!))
        focusLeftItem.keyEquivalentModifierMask = [.command, .option]
        focusSplitMenu.addItem(focusLeftItem)

        let focusRightItem = NSMenuItem(
            title: "Focus Split Right",
            action: #selector(SurfaceView.focusSplitRight(_:)),
            keyEquivalent: String(Unicode.Scalar(NSRightArrowFunctionKey)!))
        focusRightItem.keyEquivalentModifierMask = [.command, .option]
        focusSplitMenu.addItem(focusRightItem)

        windowMenu.addItem(focusSplitMenuItem)

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

        // Cmd+1-9 tab selection — collapsed into a submenu so the Window menu
        // doesn't carry 9 sibling rows.
        let selectTabMenuItem = NSMenuItem(title: "Select Tab", action: nil, keyEquivalent: "")
        let selectTabMenu = NSMenu(title: "Select Tab")
        selectTabMenuItem.submenu = selectTabMenu
        for i in 1...9 {
            let item = NSMenuItem(title: "Tab \(i)", action: #selector(selectTabByNumber(_:)), keyEquivalent: "\(i)")
            item.target = self
            item.tag = i - 1
            selectTabMenu.addItem(item)
        }
        windowMenu.addItem(selectTabMenuItem)

        windowMenu.addItem(.separator())

        let groupMenuItem = NSMenuItem(title: "Group", action: nil, keyEquivalent: "")
        let groupMenu = NSMenu(title: "Group")
        groupMenuItem.submenu = groupMenu

        let newGroupItem = NSMenuItem(
            title: "New Group",
            action: #selector(CalyxWindowController.newGroup(_:)),
            keyEquivalent: "n")
        newGroupItem.keyEquivalentModifierMask = [.control, .shift]
        groupMenu.addItem(newGroupItem)

        let closeGroupItem = NSMenuItem(
            title: "Close Group",
            action: #selector(CalyxWindowController.closeGroup(_:)),
            keyEquivalent: "w")
        closeGroupItem.keyEquivalentModifierMask = [.control, .shift]
        groupMenu.addItem(closeGroupItem)

        groupMenu.addItem(.separator())

        let nextGroupItem = NSMenuItem(
            title: "Next Group",
            action: #selector(CalyxWindowController.nextGroup(_:)),
            keyEquivalent: "]")
        nextGroupItem.keyEquivalentModifierMask = [.control, .shift]
        groupMenu.addItem(nextGroupItem)

        let prevGroupItem = NSMenuItem(
            title: "Previous Group",
            action: #selector(CalyxWindowController.previousGroup(_:)),
            keyEquivalent: "[")
        prevGroupItem.keyEquivalentModifierMask = [.control, .shift]
        groupMenu.addItem(prevGroupItem)

        windowMenu.addItem(groupMenuItem)

        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")

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

        // F10 (V11, WARNING, r4-fix-spec.md): one listAll() subprocess
        // for the whole restore pass, instead of one per surface (see
        // fetchSessionsForAgentResume's doc comment).
        let sessions = fetchSessionsForAgentResume()
        var restoredAny = false

        for windowSnap in snapshot.windows {
            if restoreWindow(windowSnap, sessions: sessions) {
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

    private func restoreWindow(_ windowSnap: WindowSnapshot, sessions: [String: SessionInfo]) -> Bool {
        guard let app = GhosttyAppController.shared.app else { return false }

        // Clamp window frame to screen
        let screenFrame = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let clampedSnap = windowSnap.clampedToScreen(screenFrame: screenFrame)

        // Create WindowSession from snapshot
        let windowSession = WindowSession(snapshot: clampedSnap)
        let (window, wc) = makeRestoringWindowController(contentRect: clampedSnap.frame, windowSession: windowSession)

        // Restore surfaces for each tab
        var anyTabRestored = false
        for group in windowSession.groups {
            for tab in group.tabs {
                // Browser tabs don't need surface restoration
                if case .browser = tab.content {
                    anyTabRestored = true
                    continue
                }
                if restoreTabSurfaces(tab: tab, app: app, window: window, sessions: sessions) {
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
            cleanupFailedWindow(window, windowSession, wc, message: "Failed to restore any tabs for window \(windowSnap.id)")
            return false
        }

        if clampedSnap.isFullScreen {
            // Keep isRestoring=true until the window finishes entering fullscreen,
            // then activate. This prevents windowDidEnterFullScreen from triggering
            // a save that captures an intermediate (non-fullscreen) frame.
            let box = FullScreenRestoreBox()
            box.activate = { [weak wc, weak box] in
                guard let box, !box.didActivate else { return }
                box.didActivate = true
                if let token = box.observer {
                    NotificationCenter.default.removeObserver(token)
                    box.observer = nil
                }
                wc?.activateRestoredSession()
            }
            box.observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didEnterFullScreenNotification,
                object: window,
                queue: .main
            ) { [weak box] _ in
                MainActor.assumeIsolated {
                    box?.activate?()
                }
            }

            // Safety timeout: if fullscreen transition never completes, activate anyway.
            // Strong-capture `box` so its lifetime extends until this closure fires.
            // The notification callback above is [weak box]; it only fires if box is
            // still alive via this strong reference. After activate() runs (either via
            // notification or timeout), didActivate guards against double-invocation.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [box] in
                MainActor.assumeIsolated {
                    box.activate?()
                }
            }

            wc.showWindow(nil)

            // toggleFullScreen must be scheduled after the current run-loop cycle
            // so the window is fully shown before AppKit begins the transition.
            DispatchQueue.main.async { [weak wc] in
                MainActor.assumeIsolated {
                    wc?.window?.toggleFullScreen(nil)
                }
            }
        } else {
            wc.activateRestoredSession()
            wc.showWindow(nil)
        }

        return true
    }

    /// Holds the mutable observer / activation state for the fullscreen-restore
    /// coordination in `restoreWindow`. A reference-typed box lets multiple
    /// escaping closures (notification callback, timeout) share a single
    /// one-shot activation flag without inout captures.
    @MainActor
    private final class FullScreenRestoreBox {
        var observer: NSObjectProtocol?
        var didActivate: Bool = false
        var activate: (() -> Void)?
    }

    private func restoreTabSurfaces(tab: Tab, app: ghostty_app_t, window: NSWindow, sessions: [String: SessionInfo]) -> Bool {
        let oldLeafIDs = tab.splitTree.allLeafIDs()
        guard !oldLeafIDs.isEmpty else { return false }

        // Reject any persisted SessionRef whose sessionID isn't shaped
        // like a genuine ULID before it ever reaches calyx-session
        // attach — a corrupted/malicious sessions.json value must not
        // run arbitrary daemon-side lookups. The rejected leaf simply
        // restores as an ordinary passthrough shell below
        // (createSurfaceWithPwd only synthesizes an attach command when
        // tab.sessionRefs still has an entry for that leaf).
        for (leafID, sessionRef) in tab.sessionRefs where !SessionRef.isValidULID(sessionRef.sessionID) {
            tab.sessionRefs.removeValue(forKey: leafID)
        }

        var mapping: [UUID: UUID] = [:]

        for oldID in oldLeafIDs {
            guard let newID = createSurfaceWithPwd(tab: tab, app: app, window: window, oldLeafID: oldID, sessions: sessions) else {
                continue
            }
            mapping[oldID] = newID
            if let sessionRef = tab.sessionRefs[oldID] {
                SessionSurfaceMap.shared.register(sessionID: sessionRef.sessionID, surfaceID: newID)
            }
        }

        // All leaves must be restored for split integrity
        if mapping.count == oldLeafIDs.count {
            tab.splitTree = tab.splitTree.remapLeafIDs(mapping)
            tab.sessionRefs = tab.sessionRefs.remappingKeys(mapping)
            return true
        }

        // Partial failure: destroy any surfaces we created (undoing
        // their SessionSurfaceMap registration too) and return false
        for (oldID, newID) in mapping {
            if let sessionRef = tab.sessionRefs[oldID] {
                SessionSurfaceMap.shared.unregister(sessionID: sessionRef.sessionID)
            }
            tab.registry.destroySurface(newID)
        }
        return false
    }

    private func fallbackCreateSurface(tab: Tab, app: ghostty_app_t, window: NSWindow) -> Bool {
        guard let newID = createSurfaceWithPwd(tab: tab, app: app, window: window) else {
            return false
        }
        tab.splitTree = SplitTree(leafID: newID)
        // The whole original tree failed to restore, so none of the
        // old leaf UUIDs survive into this brand-new single-leaf tree —
        // drop every now-orphaned SessionRef rather than let it linger
        // (and get written back out by the next snapshot) pointing at a
        // leaf that no longer exists.
        tab.pruneSessionRefs()
        return true
    }

    /// Creates one surface for `tab` during restore. When `oldLeafID`
    /// names a leaf that had a `SessionRef` in the snapshot
    /// (`tab.sessionRefs`, carried over by `Tab.init(snapshot:)`
    /// regardless of the current `SessionSettings
    /// .persistentSessionsEnabled` toggle — a session that already
    /// exists in the daemon must not be orphaned just because the user
    /// has since turned the feature off), creates the surface with an
    /// attach command instead of a plain shell so `restoreTabSurfaces`
    /// can reconnect it. `fallbackCreateSurface`'s single-surface,
    /// whole-tree-failed path calls this with the default `oldLeafID:
    /// nil`, so it always falls back to a plain passthrough surface —
    /// matching this method's pre-feature behavior exactly for that
    /// rare failure case (and never reaches `offerAgentResume` below,
    /// since that needs a `sessionRefs` entry keyed by `oldLeafID`).
    private func createSurfaceWithPwd(
        tab: Tab, app: ghostty_app_t, window: NSWindow, oldLeafID: UUID? = nil, sessions: [String: SessionInfo] = [:]
    ) -> UUID? {
        var config = GhosttyFFI.surfaceConfigNew()
        config.scale_factor = Double(window.backingScaleFactor)

        if let oldLeafID, let sessionRef = tab.sessionRefs[oldLeafID],
           let command = SessionCommandSynthesizer.reattachCommand(sessionID: sessionRef.sessionID, cwd: tab.pwd ?? NSHomeDirectory()) {
            guard let surfaceID = tab.registry.createSurface(app: app, config: config, pwd: tab.pwd, command: command) else {
                return nil
            }
            offerAgentResume(tab: tab, surfaceID: surfaceID, sessionID: sessionRef.sessionID, sessions: sessions)
            return surfaceID
        }
        return tab.registry.createSurface(app: app, config: config, pwd: tab.pwd)
    }

    /// F10 (V11, WARNING, r4-fix-spec.md): fetches the daemon's session
    /// list once, keyed by session ID, gated on
    /// `SessionSettings.agentResumeEnabled` (off, the default, spawns no
    /// subprocess at all, the same gate `offerAgentResume` itself used
    /// to check before spawning its own `Task`). `offerAgentResume` used
    /// to call `SessionDaemonClient.shared.listAll()` itself, once per
    /// restored surface: N concurrent `calyx-session ls --all --json`
    /// subprocesses at launch for N restored persistent-session
    /// surfaces, each decoding the full ledger just to pick out one ID.
    /// Shared by `restoreSession` (one call for the whole restore pass)
    /// and `attachWindow` (one call for the single session being
    /// attached).
    private func fetchSessionsForAgentResume() -> [String: SessionInfo] {
        guard SessionSettings.agentResumeEnabled else { return [:] }
        var sessionsByID: [String: SessionInfo] = [:]
        var done = false
        Task {
            let sessions = await SessionDaemonClient.shared.listAll()
            sessionsByID = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
            done = true
        }
        let deadline = Date().addingTimeInterval(2.0)
        while !done, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        }
        return sessionsByID
    }

    /// P4: once a reattached persistent-session surface exists, checks
    /// the daemon's per-session meta (`AgentSessionMetaBridge`'s
    /// recording, resolved from the caller-supplied `sessions`, i.e.
    /// `fetchSessionsForAgentResume`'s result (F10), rather than this
    /// method querying the daemon itself) for a resumable agent CLI
    /// session and, if `SessionSettings.agentResumeEnabled`, types
    /// `SessionResumePlanner.initialInput` into the live surface via
    /// `sendText`. The `sendText` call is deliberately left as its own
    /// fire-and-forget `Task`, not tracked the way
    /// `SessionKillTracker.track`'s callers are, since dropping it on
    /// quit is intentional and harmless: it's a resume command not yet
    /// typed into a surface that's being quit anyway, not state that
    /// needs to survive teardown.
    ///
    /// Deliberately uses `GhosttySurfaceController.sendText` (which
    /// resolves to ghostty's `textCallback` -> `completeClipboardPaste`)
    /// rather than `ghostty_surface_config_s.initial_input`: the
    /// `initial_input` path only queues bytes into the surface's pty at
    /// creation time, before `calyx-session attach`'s reattach
    /// connection is even established, which is unverified — this
    /// method waits for a live, reattached surface first, at the cost
    /// of one caveat verified against ghostty's core (`Surface
    /// .textCallback`): pasted text goes through the same completion
    /// path a real clipboard paste does, and most shells' bracketed
    /// paste handling does not treat a pasted trailing newline as
    /// Return — so this reliably reproduces "propose" mode
    /// (`agentResumeAutoExecute == false`, no trailing newline, user
    /// presses Return themselves) but "auto-execute" mode's trailing
    /// newline may not actually submit the command. Flagged in this
    /// feature's P4 handoff as needing live verification.
    ///
    /// Not `private` (P4 round-4 fix RED phase): `AppDelegateOfferAgentResumeTests`
    /// calls this directly to drive its decode/selection/sendText
    /// pipeline without a live daemon round-trip, matching this file's
    /// existing `attachWindow` direct-drive precedent.
    func offerAgentResume(tab: Tab, surfaceID: UUID, sessionID: String, sessions: [String: SessionInfo]) {
        guard SessionSettings.agentResumeEnabled else { return }
        guard let info = sessions[sessionID] else { return }
        let resumable = info.meta.compactMap { key, value -> (kind: String, agentSessionID: String)? in
            guard let kind = SessionResumePlanner.decodeMetaKey(key) else { return nil }
            return (kind, value)
        }.first
        guard let resumable else { return }
        guard let input = SessionResumePlanner.initialInput(
            agentKind: resumable.kind,
            agentSessionID: resumable.agentSessionID,
            autoExecute: SessionSettings.agentResumeAutoExecute
        ) else { return }

        #if DEBUG
        if let hook = _offerAgentResumeSendTextHookForTesting {
            Task { hook(surfaceID, input) }
            return
        }
        #endif
        Task {
            guard let controller = tab.registry.controller(for: surfaceID) else { return }
            controller.sendText(input)
        }
    }

    #if DEBUG
    /// Test seam (P4 round-4 fix, F14): when non-nil, called instead of
    /// `tab.registry.controller(for: surfaceID)?.sendText(_:)` inside
    /// `offerAgentResume`'s fire-and-forget `Task`. Lets
    /// `AppDelegateOfferAgentResumeTests` observe the exact text
    /// `offerAgentResume` computed without a live ghostty surface
    /// controller (`SurfaceRegistry.controller(for:)` only resolves
    /// real, ghostty-backed entries; a `_testInsert`-only fixture,
    /// this codebase's existing no-live-surface test pattern, never has
    /// one). `nil` (the default) leaves production behavior unchanged.
    /// DO NOT use from production code.
    var _offerAgentResumeSendTextHookForTesting: ((UUID, String) -> Void)?
    #endif

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
        if ProcessInfo.processInfo.arguments.contains("--uitesting")
            || TestEnvironment.isTestHost { return }
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

    /// Action produced by `matchKeyEvent` when an `NSEvent` matches one of the
    /// shortcuts handled by `installKeyMonitor`. The enum is exposed as a pure,
    /// Equatable value so the matching logic can be unit-tested in isolation
    /// from `AppDelegate`'s window-controller state (see
    /// `CalyxTests/AppDelegateKeyMonitorTests.swift`).
    ///
    /// Cases:
    /// - `commandPalette`: Cmd+Shift+P — toggle the command palette.
    /// - `unreadTab`:      Cmd+Shift+U — jump to most recent unread tab.
    /// - `nextTab`:        Cmd+Shift+] — select next tab (Issue #27).
    /// - `previousTab`:    Cmd+Shift+[ — select previous tab (Issue #27).
    /// - `selectTab(Int)`: Cmd+1..Cmd+9 — select tab at 0-based index.
    /// - `debugSelect`:    Ctrl+Shift+D — UI-testing-only debug hook.
    enum KeyMonitorAction: Equatable, Sendable {
        case commandPalette
        case unreadTab
        case nextTab
        case previousTab
        case selectTab(Int)
        case debugSelect
    }

    /// Translate a key-down `NSEvent` into a `KeyMonitorAction` that the local
    /// event monitor should dispatch. Returns `nil` for any event that should
    /// flow through to the first responder / main menu unchanged.
    ///
    /// This method is a pure function — it does not touch window-controller
    /// state — so it can be driven directly from unit tests that fabricate
    /// synthetic `NSEvent`s (see `AppDelegateKeyMonitorTests`).
    ///
    /// Modifier matching uses strict equality after intersecting with
    /// `[.command, .shift, .control, .option]` so that incidental flags such
    /// as `.capsLock`, `.numericPad`, or `.function` do not prevent a match.
    ///
    /// - Parameters:
    ///   - event: The incoming `.keyDown` event.
    ///   - isUITesting: Whether the process was launched with `--uitesting`.
    ///     The `Ctrl+Shift+D` debug-select hook is only active in that mode.
    /// - Returns: The action to perform, or `nil` to pass the event through.
    static func matchKeyEvent(_ event: NSEvent, isUITesting: Bool) -> KeyMonitorAction? {
        let mods = event.modifierFlags.intersection([.command, .shift, .control, .option])
        let chars = event.charactersIgnoringModifiers
        let lowered = chars?.lowercased()

        // Cmd+Shift+P — command palette
        if mods == [.command, .shift], lowered == "p" {
            return .commandPalette
        }

        // Cmd+Shift+U — jump to most recent unread tab
        if mods == [.command, .shift], lowered == "u" {
            return .unreadTab
        }

        // Cmd+Shift+] — select next tab (Issue #27).
        // Must be handled here (not just via the Window menu's key equivalent)
        // because `NSTextView` in diff tabs would otherwise consume the event
        // for its built-in `alignRight:` binding before the main menu fires.
        //
        // Matched by keyCode (not `charactersIgnoringModifiers`) because
        // `charactersIgnoringModifiers` APPLIES Shift (per Apple docs: "as if
        // no modifier key had been pressed, except for Shift"). So a real
        // `Cmd+Shift+]` keystroke reports `"}"`, not `"]"`. KeyCode matching
        // is also the project's convention for bracket shortcuts — the
        // sibling `Ctrl+Shift+]` / `Ctrl+Shift+[` group-navigation
        // shortcuts are bound on the Window > Group menu items
        // (see `AppDelegate.setupMainMenu`) using the same physical keys.
        // kVK_ANSI_RightBracket = 30 (from HIToolbox/Events.h).
        if mods == [.command, .shift], event.keyCode == 30 {
            return .nextTab
        }

        // Cmd+Shift+[ — select previous tab (Issue #27).
        // Parallel reasoning to `.nextTab`: `NSTextView`'s `alignLeft:`
        // binding would otherwise swallow the event on diff tabs.
        // kVK_ANSI_LeftBracket = 33 (from HIToolbox/Events.h).
        if mods == [.command, .shift], event.keyCode == 33 {
            return .previousTab
        }

        // Cmd+1..Cmd+9 — select tab at 0-based index (no shift).
        if mods == [.command],
           let chars,
           chars.count == 1,
           let scalar = chars.unicodeScalars.first,
           scalar.value >= 49, scalar.value <= 57 {
            return .selectTab(Int(scalar.value - 49))
        }

        // Ctrl+Shift+D — UI-testing-only debug-select hook.
        if isUITesting, mods == [.control, .shift], lowered == "d" {
            return .debugSelect
        }

        return nil
    }

    private func installKeyMonitor() {
        let isUITesting = ProcessInfo.processInfo.arguments.contains("--uitesting")

        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            guard let action = AppDelegate.matchKeyEvent(event, isUITesting: isUITesting) else {
                return event
            }

            // All window-targeted actions require a key window. If none, fall
            // through so the event can still reach the responder chain / menu.
            let keyWC = self.windowControllers.first(where: { $0.window?.isKeyWindow == true })

            switch action {
            case .debugSelect:
                // Reads selection parameters from the pasteboard and simulates
                // a mouse drag via ghostty FFI to create a terminal selection.
                // Does not require a key window.
                self.performDebugSelect()
                return nil
            case .commandPalette, .unreadTab, .nextTab, .previousTab, .selectTab:
                // All window-targeted actions require a key window. If none,
                // fall through so the event can still reach the responder
                // chain / menu.
                guard let wc = keyWC else { return event }
                switch action {
                case .commandPalette:        wc.toggleCommandPalette()
                case .unreadTab:             wc.jumpToMostRecentUnreadTab()
                case .nextTab:               wc.selectNextTab(nil)
                case .previousTab:           wc.selectPreviousTab(nil)
                case .selectTab(let index):  wc.selectTab(at: index)
                case .debugSelect:           break // unreachable; handled above
                }
                return nil // consume the event
            }
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

    @objc private func selectTabByNumber(_ sender: NSMenuItem) {
        guard let wc = windowControllers.first(where: { $0.window?.isKeyWindow == true }) else { return }
        wc.selectTab(at: sender.tag)
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
}

// MARK: - Notification Names

extension Notification.Name {
    /// Posted when `AppDelegate.isConfirmingQuit` transitions from
    /// `true` to `false` (see that property's `didSet`): the
    /// confirm-quit gate has cleared, whether via a real
    /// `NSAlert.runModal()` return or the `_setConfirmingQuitForTesting`
    /// test seam. `CalyxWindowController` observes this to replay events
    /// it deferred while the gate was up (F4, r4-fix-spec.md); see
    /// `drainDeferredReconnectEvents()`.
    static let calyxConfirmingQuitDidEnd = Notification.Name("com.calyx.session.confirmingQuitDidEnd")
}
