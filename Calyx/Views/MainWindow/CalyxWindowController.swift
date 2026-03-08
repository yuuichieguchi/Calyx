import AppKit
import SwiftUI
import GhosttyKit
import OSLog

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.calyx.terminal",
    category: "CalyxWindowController"
)

@MainActor
class CalyxWindowController: NSWindowController, NSWindowDelegate {
    private(set) var windowSession: WindowSession
    private var splitContainerView: SplitContainerView?
    private var hostingView: NSHostingView<MainContentView>?
    private let commandRegistry = CommandRegistry()
    private var closingTabIDs: Set<UUID> = []
    private var focusRequestID: UInt64 = 0
    private var isRestoring = false

    // MARK: - Computed Properties

    private var activeTab: Tab? {
        windowSession.activeGroup?.activeTab
    }

    private var activeRegistry: SurfaceRegistry? {
        activeTab?.registry
    }

    // MARK: - Initialization

    convenience init(windowSession: WindowSession) {
        let window = CalyxWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        self.init(window: window, windowSession: windowSession)
    }

    init(window: NSWindow, windowSession: WindowSession, restoring: Bool = false) {
        self.windowSession = windowSession
        self.isRestoring = restoring
        super.init(window: window)
        window.delegate = self
        window.center()
        setupShortcutManager()
        setupCommandRegistry()
        setupUI()
        if !restoring { setupTerminalSurface() }
        registerNotificationObservers()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Setup

    private func setupShortcutManager() {
        guard let calyxWindow = window as? CalyxWindow else { return }
        let manager = ShortcutManager()

        // Ctrl+Shift+] → next group (keyCode 30 = ])
        manager.register(modifiers: [.control, .shift], keyCode: 30) { [weak self] in
            self?.switchToNextGroup()
        }
        // Ctrl+Shift+[ → previous group (keyCode 33 = [)
        manager.register(modifiers: [.control, .shift], keyCode: 33) { [weak self] in
            self?.switchToPreviousGroup()
        }
        // Ctrl+Shift+N → new group (keyCode 45 = N)
        manager.register(modifiers: [.control, .shift], keyCode: 45) { [weak self] in
            self?.createNewGroup()
        }
        // Ctrl+Shift+W → close group (keyCode 13 = W)
        manager.register(modifiers: [.control, .shift], keyCode: 13) { [weak self] in
            self?.closeActiveGroup()
        }

        calyxWindow.shortcutManager = manager
    }

    private func setupCommandRegistry() {
        commandRegistry.register(Command(id: "tab.new", title: "New Tab", shortcut: "Cmd+T", category: "Tabs") { [weak self] in
            self?.createNewTab()
        })
        commandRegistry.register(Command(id: "tab.close", title: "Close Tab", shortcut: "Cmd+W", category: "Tabs") { [weak self] in
            guard let self, let tab = self.activeTab else { return }
            self.closeTab(id: tab.id)
        })
        commandRegistry.register(Command(id: "tab.next", title: "Next Tab", shortcut: "Cmd+Shift+]", category: "Tabs") { [weak self] in
            self?.selectNextTab(nil)
        })
        commandRegistry.register(Command(id: "tab.previous", title: "Previous Tab", shortcut: "Cmd+Shift+[", category: "Tabs") { [weak self] in
            self?.selectPreviousTab(nil)
        })
        commandRegistry.register(Command(id: "group.new", title: "New Group", shortcut: "Ctrl+Shift+N", category: "Groups") { [weak self] in
            self?.createNewGroup()
        })
        commandRegistry.register(Command(id: "group.close", title: "Close Group", shortcut: "Ctrl+Shift+W", category: "Groups") { [weak self] in
            self?.closeActiveGroup()
        })
        commandRegistry.register(Command(id: "group.next", title: "Next Group", shortcut: "Ctrl+Shift+]", category: "Groups") { [weak self] in
            self?.switchToNextGroup()
        })
        commandRegistry.register(Command(id: "group.previous", title: "Previous Group", shortcut: "Ctrl+Shift+[", category: "Groups") { [weak self] in
            self?.switchToPreviousGroup()
        })
        commandRegistry.register(Command(id: "view.sidebar", title: "Toggle Sidebar", shortcut: "Cmd+Opt+S", category: "View") { [weak self] in
            self?.toggleSidebar()
        })
        commandRegistry.register(Command(id: "view.fullscreen", title: "Toggle Full Screen", shortcut: "Ctrl+Cmd+F", category: "View") { [weak self] in
            self?.window?.toggleFullScreen(nil)
        })
        commandRegistry.register(Command(id: "window.new", title: "New Window", shortcut: "Cmd+N", category: "Window") {
            if let appDelegate = NSApp.delegate as? AppDelegate {
                appDelegate.createNewWindow()
            }
        })
    }

    private func setupUI() {
        guard let window = self.window,
              let contentView = window.contentView else { return }

        // Create the split container (shared across tabs — we swap its tree)
        let container = SplitContainerView(registry: SurfaceRegistry())
        container.onRatioChange = { [weak self] leafID, delta, direction in
            self?.handleDividerDrag(leafID: leafID, delta: delta, direction: direction)
        }
        self.splitContainerView = container

        let mainContent = buildMainContentView()
        let hosting = NSHostingView(rootView: mainContent)
        hosting.frame = contentView.bounds
        hosting.autoresizingMask = [.width, .height]
        contentView.addSubview(hosting)
        self.hostingView = hosting
    }

    private func setupTerminalSurface() {
        guard let tab = activeTab else {
            logger.error("No active tab during setup")
            return
        }

        guard let app = GhosttyAppController.shared.app,
              let window = self.window else {
            logger.error("Failed to set up terminal surface: app or window not available")
            return
        }

        var config = GhosttyFFI.surfaceConfigNew()
        config.scale_factor = Double(window.backingScaleFactor)

        guard let surfaceID = tab.registry.createSurface(app: app, config: config) else {
            logger.error("Failed to create initial surface")
            return
        }

        tab.splitTree = SplitTree(leafID: surfaceID)

        // Create a SplitContainerView bound to this tab's registry
        rebuildSplitContainer()
        updateLayout()

        if let surfaceView = tab.registry.view(for: surfaceID) {
            window.makeFirstResponder(surfaceView)
        }
    }

    // MARK: - Content View Building

    private func buildMainContentView() -> MainContentView {
        return MainContentView(
            windowSession: windowSession,
            commandRegistry: commandRegistry,
            splitContainerView: splitContainerView ?? SplitContainerView(registry: SurfaceRegistry()),
            onTabSelected: { [weak self] tabID in self?.switchToTab(id: tabID) },
            onGroupSelected: { [weak self] groupID in self?.switchToGroup(id: groupID) },
            onNewTab: { [weak self] in self?.createNewTab() },
            onNewGroup: { [weak self] in self?.createNewGroup() },
            onCloseTab: { [weak self] tabID in self?.closeTab(id: tabID) },
            onToggleSidebar: { [weak self] in self?.toggleSidebar() },
            onDismissCommandPalette: { [weak self] in self?.dismissCommandPalette() }
        )
    }

    private func refreshHostingView() {
        hostingView?.rootView = buildMainContentView()
    }

    // MARK: - Split Container Management

    private func rebuildSplitContainer() {
        guard let tab = activeTab else { return }
        if let container = splitContainerView {
            container.updateRegistry(tab.registry)
        } else {
            let container = SplitContainerView(registry: tab.registry)
            container.onRatioChange = { [weak self] leafID, delta, direction in
                self?.handleDividerDrag(leafID: leafID, delta: delta, direction: direction)
            }
            self.splitContainerView = container
        }
    }

    private func updateTerminalLayout() {
        guard let tab = activeTab, let container = splitContainerView else { return }
        container.updateLayout(tree: tab.splitTree)
    }

    private func updateLayout() {
        updateTerminalLayout()
    }

    @discardableResult
    private func focusActiveTabImmediately() -> Bool {
        guard let tab = activeTab,
              let focusedID = tab.splitTree.focusedLeafID,
              let focusView = tab.registry.view(for: focusedID) else {
            return false
        }

        let becameFirstResponder = window?.makeFirstResponder(focusView) ?? false
        guard becameFirstResponder else { return false }

        tab.registry.controller(for: focusedID)?.setFocus(true)
        tab.registry.controller(for: focusedID)?.refresh()
        focusView.needsDisplay = true
        tab.unreadNotifications = 0
        return true
    }

    // MARK: - Tab Operations

    func createNewTab(inheritedConfig: Any? = nil) {
        guard let app = GhosttyAppController.shared.app,
              let window = self.window,
              let group = windowSession.activeGroup else { return }

        let tab = Tab()

        var config: ghostty_surface_config_s
        if let inherited = inheritedConfig as? ghostty_surface_config_s {
            config = inherited
        } else {
            config = GhosttyFFI.surfaceConfigNew()
        }
        config.scale_factor = Double(window.backingScaleFactor)

        guard let surfaceID = tab.registry.createSurface(app: app, config: config) else {
            logger.error("Failed to create surface for new tab")
            return
        }

        tab.splitTree = SplitTree(leafID: surfaceID)

        // Pause current tab
        activeTab?.registry.pauseAll()

        group.addTab(tab)
        group.activeTabID = tab.id

        rebuildSplitContainer()
        updateLayout()
        refreshHostingView()

        restoreFocus()
        requestSave()
    }

    private func closeTab(id tabID: UUID) {
        // Prevent double execution
        guard !closingTabIDs.contains(tabID) else { return }

        guard let group = windowSession.groups.first(where: { g in
            g.tabs.contains(where: { $0.id == tabID })
        }) else { return }
        guard let tab = group.tabs.first(where: { $0.id == tabID }) else { return }

        closingTabIDs.insert(tabID)

        // Destroy all surfaces in the tab
        for surfaceID in tab.registry.allIDs {
            tab.registry.destroySurface(surfaceID)
        }

        let result = windowSession.removeTab(id: tabID, fromGroup: group.id)

        switch result {
        case .switchedTab(_, let newTabID):
            switchToTab(id: newTabID)
        case .switchedGroup(let newGroupID, _):
            switchToGroup(id: newGroupID)
        case .windowShouldClose:
            window?.close()
        }

        refreshHostingView()
        requestSave()
        closingTabIDs.remove(tabID)
    }

    func switchToTab(id tabID: UUID) {
        guard let group = windowSession.activeGroup else { return }
        guard group.tabs.contains(where: { $0.id == tabID }) else {
            logger.warning("Attempted to switch to non-existent tab: \(tabID)")
            return
        }
        guard group.activeTabID != tabID else { return }

        focusedController?.setFocus(false)

        group.activeTabID = tabID

        rebuildSplitContainer()
        updateTerminalLayout()
        if !focusActiveTabImmediately() {
            restoreFocus()
        }
    }

    func switchToGroup(id groupID: UUID) {
        guard windowSession.groups.contains(where: { $0.id == groupID }) else {
            logger.warning("Attempted to switch to non-existent group: \(groupID)")
            return
        }
        guard windowSession.activeGroupID != groupID else { return }

        focusedController?.setFocus(false)

        windowSession.activeGroupID = groupID

        rebuildSplitContainer()
        updateTerminalLayout()
        if !focusActiveTabImmediately() {
            restoreFocus()
        }
    }

    // MARK: - Group Operations

    func createNewGroup() {
        guard let app = GhosttyAppController.shared.app,
              let window = self.window else { return }

        let tab = Tab()

        var config = GhosttyFFI.surfaceConfigNew()
        config.scale_factor = Double(window.backingScaleFactor)

        guard let surfaceID = tab.registry.createSurface(app: app, config: config) else {
            logger.error("Failed to create surface for new group")
            return
        }

        tab.splitTree = SplitTree(leafID: surfaceID)

        // Pause current tab
        activeTab?.registry.pauseAll()

        let groupColors: [TabGroupColor] = TabGroupColor.allCases
        let colorIndex = windowSession.groups.count % groupColors.count
        let group = TabGroup(
            name: "Group \(windowSession.groups.count + 1)",
            color: groupColors[colorIndex],
            tabs: [tab],
            activeTabID: tab.id
        )

        windowSession.addGroup(group)
        windowSession.activeGroupID = group.id

        rebuildSplitContainer()
        updateLayout()
        refreshHostingView()

        restoreFocus()
        requestSave()
    }

    private func closeActiveGroup() {
        guard let group = windowSession.activeGroup else { return }

        // Mark all tabs as closing to prevent notification handler from double-deleting
        let tabIDs = group.tabs.map { $0.id }
        for tabID in tabIDs {
            closingTabIDs.insert(tabID)
        }

        // Destroy all surfaces in all tabs of this group
        for tab in group.tabs {
            for surfaceID in tab.registry.allIDs {
                tab.registry.destroySurface(surfaceID)
            }
        }

        let result = windowSession.removeGroup(id: group.id)

        for tabID in tabIDs {
            closingTabIDs.remove(tabID)
        }

        switch result {
        case .switchedTab(_, _), .switchedGroup(_, _):
            rebuildSplitContainer()
            updateLayout()
            activeTab?.registry.resumeAll()
            refreshHostingView()
            restoreFocus()
            requestSave()
        case .windowShouldClose:
            window?.close()
            requestSave()
        }
    }

    private func switchToNextGroup() {
        activeTab?.registry.pauseAll()
        windowSession.nextGroup()
        rebuildSplitContainer()
        updateLayout()
        activeTab?.registry.resumeAll()
        restoreFocus()
    }

    private func switchToPreviousGroup() {
        activeTab?.registry.pauseAll()
        windowSession.previousGroup()
        rebuildSplitContainer()
        updateLayout()
        activeTab?.registry.resumeAll()
        restoreFocus()
    }

    @objc func toggleSidebar() {
        windowSession.showSidebar.toggle()
        requestSave()
    }

    @objc func toggleCommandPalette() {
        if windowSession.showCommandPalette {
            dismissCommandPalette()
        } else {
            windowSession.showCommandPalette = true
        }
    }

    private func dismissCommandPalette() {
        guard windowSession.showCommandPalette else { return }
        windowSession.showCommandPalette = false
        restoreFocus()
    }

    private func restoreFocus() {
        focusRequestID &+= 1
        let requestID = focusRequestID
        let startTime = CACurrentMediaTime()

        DispatchQueue.main.async { [weak self] in
            self?.attemptFocusRestore(requestID: requestID, startTime: startTime)
        }
    }

    private static let focusRestoreTimeout: Double = 0.5

    private func attemptFocusRestore(requestID: UInt64, startTime: Double) {
        guard requestID == focusRequestID else { return }

        let elapsed = CACurrentMediaTime() - startTime

        // Non-key window → skip; windowDidBecomeKey will call restoreFocus()
        guard window?.isKeyWindow == true else { return }

        guard let tab = activeTab,
              let focusedID = tab.splitTree.focusedLeafID,
              let focusView = tab.registry.view(for: focusedID) else { return }

        let inWindow = focusView.window === self.window
        let hasSuperview = focusView.superview != nil

        // View must be attached to THIS window's hierarchy
        guard inWindow, hasSuperview else {
            guard elapsed < Self.focusRestoreTimeout else {
                splitContainerView?.onDeferredLayoutComplete = { [weak self] in
                    guard let self, requestID == self.focusRequestID else { return }
                    self.attemptFocusRestore(requestID: requestID, startTime: CACurrentMediaTime())
                }
                return
            }
            // Retry with 10ms backoff
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { [weak self] in
                self?.attemptFocusRestore(requestID: requestID, startTime: startTime)
            }
            return
        }

        let result = window?.makeFirstResponder(focusView) ?? false
        if result {
            tab.registry.controller(for: focusedID)?.setFocus(true)
            tab.registry.controller(for: focusedID)?.refresh()
            focusView.needsDisplay = true
            activeTab?.unreadNotifications = 0
        }
    }

    // MARK: - Split Operations

    private func handleDividerDrag(leafID: UUID, delta: Double, direction: SplitDirection) {
        guard let tab = activeTab, let contentView = window?.contentView else { return }
        tab.splitTree = tab.splitTree.resize(
            node: leafID,
            by: delta,
            direction: direction,
            bounds: contentView.bounds.size,
            minSize: 50
        )
        splitContainerView?.updateLayout(tree: tab.splitTree)
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
        center.addObserver(self, selector: #selector(handleSetPwdNotification(_:)),
                           name: .ghosttySetPwd, object: nil)
        center.addObserver(self, selector: #selector(handleDesktopNotification(_:)),
                           name: .ghosttyDesktopNotification, object: nil)
    }

    // MARK: - Notification Handlers

    @objc private func handleNewSplitNotification(_ notification: Notification) {
        guard let surfaceView = notification.object as? SurfaceView else { return }
        guard let tab = activeTab else { return }
        guard let surfaceID = tab.registry.id(for: surfaceView) else { return }
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

        var config: ghostty_surface_config_s
        if let inheritedConfig = notification.userInfo?["inherited_config"] as? ghostty_surface_config_s {
            config = inheritedConfig
        } else {
            config = GhosttyFFI.surfaceConfigNew()
        }
        if let window = self.window {
            config.scale_factor = Double(window.backingScaleFactor)
        }

        guard let newSurfaceID = tab.registry.createSurface(app: app, config: config) else {
            logger.error("Failed to create split surface")
            return
        }

        let (newTree, _) = tab.splitTree.insert(at: surfaceID, direction: splitDir, newID: newSurfaceID)
        tab.splitTree = newTree

        splitContainerView?.updateLayout(tree: tab.splitTree)

        if let newView = tab.registry.view(for: newSurfaceID) {
            window?.makeFirstResponder(newView)
        }
    }

    @objc private func handleCloseSurfaceNotification(_ notification: Notification) {
        guard let surfaceView = notification.object as? SurfaceView else { return }
        guard belongsToThisWindow(surfaceView) else { return }

        // Find the tab that owns this surface (may be a background tab)
        guard let (owningTab, owningGroup) = findTab(for: surfaceView) else { return }
        guard let surfaceID = owningTab.registry.id(for: surfaceView) else { return }

        // Surface-level cleanup: update split tree and destroy surface
        let (newTree, focusTarget) = owningTab.splitTree.remove(surfaceID)
        owningTab.registry.destroySurface(surfaceID)
        owningTab.splitTree = newTree

        // If closeTab is handling this tab, skip tab removal (closeTab will do it)
        if closingTabIDs.contains(owningTab.id) {
            return
        }

        // Below runs only for process-initiated closes (e.g. `exit` command)
        if owningTab.splitTree.isEmpty {
            let result = windowSession.removeTab(id: owningTab.id, fromGroup: owningGroup.id)
            if owningTab.id == activeTab?.id {
                switch result {
                case .switchedTab(_, let newTabID):
                    switchToTab(id: newTabID)
                case .switchedGroup(let newGroupID, _):
                    switchToGroup(id: newGroupID)
                case .windowShouldClose:
                    window?.close()
                }
            } else {
                refreshHostingView()
            }
            requestSave()
            return
        }

        if owningTab.id == activeTab?.id {
            splitContainerView?.updateLayout(tree: owningTab.splitTree)
            if let focusID = focusTarget, let focusView = owningTab.registry.view(for: focusID) {
                window?.makeFirstResponder(focusView)
            }
            requestSave()
        }
    }

    @objc private func handleGotoSplitNotification(_ notification: Notification) {
        guard let surfaceView = notification.object as? SurfaceView else { return }
        guard let tab = activeTab else { return }
        guard let surfaceID = tab.registry.id(for: surfaceView) else { return }
        guard belongsToThisWindow(surfaceView) else { return }

        let direction = notification.userInfo?["direction"] as? ghostty_action_goto_split_e

        let focusDir: FocusDirection
        switch direction {
        case GHOSTTY_GOTO_SPLIT_PREVIOUS: focusDir = .previous
        case GHOSTTY_GOTO_SPLIT_NEXT: focusDir = .next
        case GHOSTTY_GOTO_SPLIT_LEFT: focusDir = .spatial(.left)
        case GHOSTTY_GOTO_SPLIT_RIGHT: focusDir = .spatial(.right)
        case GHOSTTY_GOTO_SPLIT_UP: focusDir = .spatial(.up)
        case GHOSTTY_GOTO_SPLIT_DOWN: focusDir = .spatial(.down)
        default: focusDir = .next
        }

        guard let targetID = tab.splitTree.focusTarget(for: focusDir, from: surfaceID) else { return }
        tab.splitTree.focusedLeafID = targetID

        if let targetView = tab.registry.view(for: targetID) {
            window?.makeFirstResponder(targetView)
        }
    }

    @objc private func handleResizeSplitNotification(_ notification: Notification) {
        guard let surfaceView = notification.object as? SurfaceView else { return }
        guard let tab = activeTab else { return }
        guard let surfaceID = tab.registry.id(for: surfaceView) else { return }
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
        tab.splitTree = tab.splitTree.resize(
            node: surfaceID,
            by: amount,
            direction: direction,
            bounds: contentView.bounds.size,
            minSize: 50
        )
        splitContainerView?.updateLayout(tree: tab.splitTree)
    }

    @objc private func handleEqualizeSplitsNotification(_ notification: Notification) {
        if let surfaceView = notification.object as? SurfaceView {
            guard belongsToThisWindow(surfaceView) else { return }
        }

        guard let tab = activeTab else { return }
        tab.splitTree = tab.splitTree.equalize()
        splitContainerView?.updateLayout(tree: tab.splitTree)
    }

    @objc private func handleSetTitleNotification(_ notification: Notification) {
        guard let surfaceView = notification.object as? SurfaceView else { return }
        guard belongsToThisWindow(surfaceView) else { return }
        guard let title = notification.userInfo?["title"] as? String else { return }
        guard let tab = activeTab else { return }

        if let focusedID = tab.splitTree.focusedLeafID,
           let focusedView = tab.registry.view(for: focusedID),
           focusedView === surfaceView {
            window?.title = title
            tab.title = title
            refreshHostingView()
        }
    }

    @objc private func handleSetPwdNotification(_ notification: Notification) {
        guard let surfaceView = notification.object as? SurfaceView else { return }
        guard belongsToThisWindow(surfaceView) else { return }
        guard let pwd = notification.userInfo?["pwd"] as? String else { return }
        guard let (owningTab, _) = findTab(for: surfaceView) else { return }
        owningTab.pwd = pwd
        requestSave()
    }

    @objc private func handleDesktopNotification(_ notification: Notification) {
        guard let surfaceView = notification.object as? SurfaceView else { return }
        guard belongsToThisWindow(surfaceView) else { return }
        guard let title = notification.userInfo?["title"] as? String else { return }
        let body = notification.userInfo?["body"] as? String ?? ""
        guard let (owningTab, _) = findTab(for: surfaceView) else { return }

        let isActiveAndVisible = owningTab.id == activeTab?.id && (window?.isKeyWindow ?? false)
        guard !isActiveAndVisible else { return }

        let isFirstUnread = owningTab.unreadNotifications == 0
        owningTab.unreadNotifications += 1

        NotificationManager.shared.sendNotification(title: title, body: body, tabID: owningTab.id)

        if isFirstUnread {
            NotificationManager.shared.bounceDockIcon()
        }
    }

    // MARK: - Menu Actions

    @objc func newTab(_ sender: Any?) {
        createNewTab()
    }

    @objc func closeTab(_ sender: Any?) {
        guard let tab = activeTab, let group = windowSession.activeGroup else { return }
        closeTab(id: tab.id)
        _ = group // silence warning
    }

    @objc func selectNextTab(_ sender: Any?) {
        focusedController?.setFocus(false)
        windowSession.nextTab()
        rebuildSplitContainer()
        updateTerminalLayout()
        if !focusActiveTabImmediately() {
            restoreFocus()
        }
    }

    @objc func selectPreviousTab(_ sender: Any?) {
        focusedController?.setFocus(false)
        windowSession.previousTab()
        rebuildSplitContainer()
        updateTerminalLayout()
        if !focusActiveTabImmediately() {
            restoreFocus()
        }
    }

    @objc func selectTab1(_ sender: Any?) { selectTabByIndex(0) }
    @objc func selectTab2(_ sender: Any?) { selectTabByIndex(1) }
    @objc func selectTab3(_ sender: Any?) { selectTabByIndex(2) }
    @objc func selectTab4(_ sender: Any?) { selectTabByIndex(3) }
    @objc func selectTab5(_ sender: Any?) { selectTabByIndex(4) }
    @objc func selectTab6(_ sender: Any?) { selectTabByIndex(5) }
    @objc func selectTab7(_ sender: Any?) { selectTabByIndex(6) }
    @objc func selectTab8(_ sender: Any?) { selectTabByIndex(7) }
    @objc func selectTab9(_ sender: Any?) { selectTabByIndex(8) }

    private func selectTabByIndex(_ index: Int) {
        focusedController?.setFocus(false)
        windowSession.selectTab(at: index)
        rebuildSplitContainer()
        updateTerminalLayout()
        if !focusActiveTabImmediately() {
            restoreFocus()
        }
    }

    // MARK: - Session Persistence

    func activateRestoredSession() {
        isRestoring = false
        // Pause all tabs except the active one
        for group in windowSession.groups {
            for tab in group.tabs {
                if tab.id != windowSession.activeGroup?.activeTabID {
                    tab.registry.pauseAll()
                }
            }
        }
        rebuildSplitContainer()
        updateLayout()
        restoreFocus()
    }

    func windowSnapshot() -> WindowSnapshot {
        let frame = window?.frame ?? .zero
        let snap = windowSession.snapshot()
        return WindowSnapshot(
            id: snap.id,
            frame: frame,
            groups: snap.groups,
            activeGroupID: snap.activeGroupID,
            showSidebar: snap.showSidebar
        )
    }

    private func requestSave() {
        DispatchQueue.main.async {
            if let appDelegate = NSApp.delegate as? AppDelegate {
                appDelegate.requestSave()
            }
        }
    }

    // MARK: - Helpers

    private func belongsToThisWindow(_ view: NSView) -> Bool {
        view.window === self.window
    }

    private func findTab(for surfaceView: SurfaceView) -> (Tab, TabGroup)? {
        for group in windowSession.groups {
            for tab in group.tabs {
                if tab.registry.id(for: surfaceView) != nil {
                    return (tab, group)
                }
            }
        }
        return nil
    }

    private var focusedController: GhosttySurfaceController? {
        guard let tab = activeTab,
              let focusedID = tab.splitTree.focusedLeafID else { return nil }
        return tab.registry.controller(for: focusedID)
    }

    // MARK: - NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) {
        GhosttyAppController.shared.setFocus(true)
        focusedController?.setFocus(true)
        restoreFocus()
    }

    func windowDidResignKey(_ notification: Notification) {
        GhosttyAppController.shared.setFocus(false)
        focusedController?.setFocus(false)
        if windowSession.showCommandPalette {
            dismissCommandPalette()
        }
    }

    func windowDidChangeBackingProperties(_ notification: Notification) {
        guard let window = self.window, let tab = activeTab else { return }
        let scale = window.backingScaleFactor
        for id in tab.registry.allIDs {
            tab.registry.controller(for: id)?.setContentScale(scale)
        }
    }

    func windowWillClose(_ notification: Notification) {
        // Mark all tabs as closing to prevent notification handler interference
        for group in windowSession.groups {
            for tab in group.tabs {
                closingTabIDs.insert(tab.id)
            }
        }

        // Destroy all surfaces in all tabs
        for group in windowSession.groups {
            for tab in group.tabs {
                for id in tab.registry.allIDs {
                    tab.registry.destroySurface(id)
                }
            }
        }

        if let appDelegate = NSApp.delegate as? AppDelegate {
            appDelegate.removeWindowController(self)
        }
    }

    func windowDidResize(_ notification: Notification) {
        // SplitContainerView handles resize via autoresizingMask + resizeSubviews
    }
}
