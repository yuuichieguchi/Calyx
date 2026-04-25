import AppKit
import SwiftUI
import GhosttyKit
import OSLog
import Security

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
    var trackedFullScreen: Bool = false
    var preFullScreenFrame: NSRect? = nil
    var isClosingForShutdown: Bool = false
    private var browserControllers: [UUID: BrowserTabController] = [:]
    private var diffStates: [UUID: DiffLoadState] = [:]
    private var diffTasks: [UUID: Task<Void, Never>] = [:]
    private var refreshTask: Task<Void, Never>?
    private var loadMoreTask: Task<Void, Never>?
    private var expandTasks: [String: Task<Void, Never>] = [:]
    private var hasMoreCommits = true
    private var reviewStores: [UUID: DiffReviewStore] = [:]
    private var clipboardConfirmationController: ClipboardConfirmationController?
    private var composeOverlayTargetSurfaceID: UUID?

    // MARK: - Computed Properties

    private var activeTab: Tab? {
        windowSession.activeGroup?.activeTab
    }

    private var activeRegistry: SurfaceRegistry? {
        activeTab?.registry
    }

    private var activeBrowserController: BrowserTabController? {
        guard let tab = activeTab, case .browser = tab.content else { return nil }
        return browserController(for: tab.id)
    }

    var activeBrowserControllerForExternal: BrowserTabController? {
        activeBrowserController
    }

    private var activeDiffState: DiffLoadState? {
        guard let tab = activeTab, case .diff = tab.content else { return nil }
        return diffStates[tab.id]
    }

    private var activeDiffSource: DiffSource? {
        guard let tab = activeTab, case .diff(let source) = tab.content else { return nil }
        return source
    }

    private var activeDiffReviewStore: DiffReviewStore? {
        guard let tab = activeTab, case .diff = tab.content else { return nil }
        return reviewStores[tab.id]
    }

    private var totalReviewCommentCount: Int {
        reviewStores.values.filter { $0.hasUnsubmittedComments }.reduce(0) { $0 + $1.comments.count }
    }

    private var reviewFileCount: Int {
        reviewStores.values.filter { $0.hasUnsubmittedComments }.count
    }

    private func browserController(for tabID: UUID) -> BrowserTabController? {
        if let existing = browserControllers[tabID] { return existing }
        guard let tab = windowSession.groups.flatMap(\.tabs).first(where: { $0.id == tabID }),
              case .browser(let url) = tab.content else { return nil }
        let controller = BrowserTabController(url: url)
        wireBrowserCallbacks(controller: controller, tab: tab)
        browserControllers[tabID] = controller
        return controller
    }

    func browserController(forExternal tabID: UUID) -> BrowserTabController? {
        browserController(for: tabID)
    }

    private func wireBrowserCallbacks(controller: BrowserTabController, tab: Tab) {
        controller.browserView.onTitleChanged = { [weak tab] title in
            tab?.title = title
        }
        controller.browserView.onURLChanged = { [weak self, weak tab] url in
            guard let tab else { return }
            tab.content = .browser(url: url)
            self?.requestSave()
        }
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
        // Cmd+Shift+E → compose overlay (keyCode 14 = E)
        manager.register(modifiers: [.command, .shift], keyCode: 14) { [weak self] in
            self?.toggleComposeOverlay()
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
        commandRegistry.register(Command(id: "edit.find", title: "Find in Terminal", shortcut: "Cmd+F", category: "Edit") { [weak self] in
            guard let controller = self?.focusedController else { return }
            controller.performAction("start_search")
        })
        commandRegistry.register(Command(
            id: "edit.compose",
            title: "Compose Input",
            shortcut: "Cmd+Shift+E",
            category: "Edit"
        ) { [weak self] in
            self?.toggleComposeOverlay()
        })
        commandRegistry.register(Command(id: "browser.open", title: "Open Browser Tab", category: "Browser") { [weak self] in
            self?.promptAndOpenBrowserTab()
        })
        commandRegistry.register(Command(id: "browser.back", title: "Browser Back", category: "Browser") { [weak self] in
            guard case .browser = self?.activeTab?.content else { return }
            self?.activeBrowserController?.goBack()
        })
        commandRegistry.register(Command(id: "browser.forward", title: "Browser Forward", category: "Browser") { [weak self] in
            guard case .browser = self?.activeTab?.content else { return }
            self?.activeBrowserController?.goForward()
        })
        commandRegistry.register(Command(id: "browser.reload", title: "Browser Reload", category: "Browser") { [weak self] in
            guard case .browser = self?.activeTab?.content else { return }
            self?.activeBrowserController?.reload()
        })
        commandRegistry.register(Command(id: "git.showChanges", title: "Show Git Changes", category: "Git") { [weak self] in
            self?.windowSession.sidebarMode = .changes
            self?.windowSession.showSidebar = true
            self?.refreshGitStatus()
            self?.refreshHostingView()
        })
        commandRegistry.register(Command(id: "git.refresh", title: "Refresh Git Changes", category: "Git") { [weak self] in
            self?.refreshGitStatus()
        })
        commandRegistry.register(Command(id: "ipc.enable", title: "Enable AI Agent IPC", category: "IPC", isAvailable: {
            !CalyxMCPServer.shared.isRunning
        }) { [weak self] in
            self?.enableIPC()
        })
        commandRegistry.register(Command(id: "ipc.disable", title: "Disable AI Agent IPC", category: "IPC", isAvailable: {
            CalyxMCPServer.shared.isRunning
        }) { [weak self] in
            self?.disableIPC()
        })
        commandRegistry.register(Command(id: "cli.install", title: "Install CLI to PATH", category: "System") {
            let appPath = Bundle.main.bundlePath
            let cliSource = "\(appPath)/Contents/Resources/bin/calyx"
            let cliDest = "/usr/local/bin/calyx"

            // Check if source exists
            guard FileManager.default.fileExists(atPath: cliSource) else {
                let alert = NSAlert()
                alert.messageText = "CLI Not Found"
                alert.informativeText = "CLI binary not found in app bundle. Please rebuild the app."
                alert.alertStyle = .warning
                alert.addButton(withTitle: "OK")
                alert.runModal()
                return
            }

            // Use AppleScript to create symlink with admin privileges
            let script = "do shell script \"ln -sf '\(cliSource)' '\(cliDest)'\" with administrator privileges"
            var error: NSDictionary?
            if let appleScript = NSAppleScript(source: script) {
                appleScript.executeAndReturnError(&error)
                if let error {
                    let alert = NSAlert()
                    alert.messageText = "Installation Failed"
                    alert.informativeText = error[NSAppleScript.errorMessage] as? String ?? "Unknown error"
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                } else {
                    let alert = NSAlert()
                    alert.messageText = "CLI Installed"
                    alert.informativeText = "The 'calyx' command is now available. Run 'calyx browser --help' to get started."
                    alert.alertStyle = .informational
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                }
            }
        })
        commandRegistry.register(Command(id: "tab.jumpToUnread", title: "Jump to Unread Tab", shortcut: "Cmd+Shift+U", category: "Tabs", isAvailable: { [weak self] in
            guard let self else { return false }
            return self.windowSession.groups.flatMap(\.tabs).contains { $0.unreadNotifications > 0 }
        }) { [weak self] in
            self?.jumpToMostRecentUnreadTab()
        })
        commandRegistry.register(Command(
            id: "review.submitAll",
            title: "Submit All Review Comments",
            category: "Git",
            isAvailable: { [weak self] in (self?.reviewFileCount ?? 0) >= 2 }
        ) { [weak self] in
            self?.submitAllDiffReviews()
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
        container.onActiveLeafChange = { [weak self] leafID in
            self?.activeTab?.splitTree.focusedLeafID = leafID
            self?.requestSave()
        }
        self.splitContainerView = container

        let mainContent = buildMainContentView()
        let hosting = NSHostingView(rootView: mainContent)
        hosting.frame = contentView.bounds
        hosting.autoresizingMask = [.width, .height]
        contentView.addSubview(hosting)
        self.hostingView = hosting

        // Title bar glass is now handled by SwiftUI overlay in MainContentView
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

        guard let surfaceID = tab.registry.createSurface(app: app, config: config, pwd: tab.pwd) else {
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
            activeBrowserController: activeBrowserController,
            activeDiffState: activeDiffState,
            activeDiffSource: activeDiffSource,
            activeDiffReviewStore: activeDiffReviewStore,
            sidebarMode: Binding(
                get: { [weak self] in self?.windowSession.sidebarMode ?? .tabs },
                set: { [weak self] in
                    self?.windowSession.sidebarMode = $0
                    if $0 == .changes {
                        self?.refreshGitStatus()
                    }
                }
            ),
            gitChangesState: windowSession.gitChangesState,
            gitEntries: windowSession.gitEntries,
            gitCommits: windowSession.gitCommits,
            expandedCommitIDs: windowSession.expandedCommitIDs,
            commitFiles: windowSession.commitFiles,
            onTabSelected: { [weak self] tabID in self?.switchToTab(id: tabID) },
            onGroupSelected: { [weak self] groupID in self?.switchToGroup(id: groupID) },
            onNewTab: { [weak self] in self?.createNewTab() },
            onNewGroup: { [weak self] in self?.createNewGroup() },
            onCloseTab: { [weak self] tabID in self?.closeTab(id: tabID) },
            onGroupRenamed: { [weak self] in self?.requestSave() },
            onTabRenamed: { [weak self] in self?.requestSave() },
            onToggleSidebar: { [weak self] in self?.toggleSidebar() },
            onDismissCommandPalette: { [weak self] in self?.dismissCommandPalette() },
            onWorkingFileSelected: { [weak self] entry in self?.handleWorkingFileSelected(entry) },
            onCommitFileSelected: { [weak self] entry in self?.handleCommitFileSelected(entry) },
            onRefreshGitStatus: { [weak self] in self?.refreshGitStatus() },
            onLoadMoreCommits: { [weak self] in self?.loadMoreCommits() },
            onExpandCommit: { [weak self] hash in self?.expandCommit(hash: hash) },
            onSidebarWidthChanged: { [weak self] width in self?.windowSession.sidebarWidth = width },
            onCollapseToggled: { [weak self] in self?.requestSave() },
            onCloseAllTabsInGroup: { [weak self] groupID in self?.closeAllTabsInGroup(id: groupID) },
            onMoveTab: { [weak self] groupID, fromIndex, toIndex in
                guard let self,
                      let group = self.windowSession.groups.first(where: { $0.id == groupID })
                else { return }
                group.moveTab(fromIndex: fromIndex, toIndex: toIndex)
                self.refreshHostingView()
                self.requestSave()
            },
            onSidebarDragCommitted: { [weak self] in self?.requestSave() },
            onSubmitReview: { [weak self] in
                guard let self, let tab = self.activeTab else { return }
                self.submitDiffReview(tabID: tab.id)
            },
            onDiscardReview: { [weak self] in
                guard let self, let tab = self.activeTab else { return }
                if let store = self.reviewStores[tab.id] {
                    store.clearAll()
                    self.refreshHostingView()
                }
            },
            onSubmitAllReviews: { [weak self] in
                self?.submitAllDiffReviews()
            },
            onDiscardAllReviews: { [weak self] in
                self?.discardAllDiffReviews()
            },
            onComposeOverlaySend: { [weak self] text in self?.sendComposeText(text) ?? false },
            onDismissComposeOverlay: { [weak self] in self?.dismissComposeOverlay() },
            totalReviewCommentCount: totalReviewCommentCount,
            reviewFileCount: reviewFileCount
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
            container.onActiveLeafChange = { [weak self] leafID in
                self?.activeTab?.splitTree.focusedLeafID = leafID
                self?.requestSave()
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
        tab.clearUnreadNotifications()
        return true
    }

    // MARK: - Tab Activation Helpers

    private func activateCurrentTab() {
        guard let tab = activeTab else { return }
        refreshHostingView()
        switch tab.content {
        case .terminal:
            tab.registry.resumeAll()
            rebuildSplitContainer()
            updateTerminalLayout()
            focusActiveTabImmediately()  // best-effort synchronous focus
            restoreFocus()               // async safety net (handles post-layout focus loss)
        case .browser:
            DispatchQueue.main.async { [weak self] in
                if let bv = self?.browserController(for: tab.id)?.browserView {
                    self?.window?.makeFirstResponder(bv)
                }
            }
        case .diff:
            break  // Diff tabs don't need special activation
        }
        retargetComposeOverlayIfNeeded()
    }

    private func deactivateCurrentTab() {
        dismissComposeOverlay()
        guard let tab = activeTab else { return }
        if case .terminal = tab.content {
            focusedController?.setFocus(false)
            tab.registry.pauseAll()
        }
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
        retargetComposeOverlayIfNeeded()
        requestSave()
    }

    func createBrowserTab(url: URL) {
        guard let group = windowSession.activeGroup else { return }
        let tab = Tab(title: url.host() ?? url.absoluteString, content: .browser(url: url))

        deactivateCurrentTab()

        group.addTab(tab)
        group.activeTabID = tab.id

        let controller = BrowserTabController(url: url)
        wireBrowserCallbacks(controller: controller, tab: tab)
        browserControllers[tab.id] = controller

        refreshHostingView()
        DispatchQueue.main.async { [weak self] in
            self?.window?.makeFirstResponder(controller.browserView)
        }
        requestSave()
    }

    func promptAndOpenBrowserTab() {
        let alert = NSAlert()
        alert.messageText = "Open Browser Tab"
        alert.informativeText = "Enter a URL:"
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Cancel")

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        textField.placeholderString = "https://example.com"
        alert.accessoryView = textField

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }

        var input = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return }

        // Normalize: add https:// if no scheme
        if !input.contains("://") {
            input = "https://" + input
        }

        guard let url = URL(string: input),
              let scheme = url.scheme,
              BrowserSecurity.isAllowedTopLevelScheme(scheme) else {
            let errorAlert = NSAlert()
            errorAlert.messageText = "Invalid URL"
            errorAlert.informativeText = "Only http and https URLs are allowed."
            errorAlert.alertStyle = .warning
            errorAlert.runModal()
            return
        }

        createBrowserTab(url: url)
    }

    private func closeTab(id tabID: UUID) {
        // Prevent double execution
        guard !closingTabIDs.contains(tabID) else { return }

        guard let group = windowSession.groups.first(where: { g in
            g.tabs.contains(where: { $0.id == tabID })
        }) else { return }
        guard let tab = group.tabs.first(where: { $0.id == tabID }) else { return }

        closingTabIDs.insert(tabID)

        // Quit confirmation: if this is the last tab in the last group, closing it
        // would terminate the app. Confirm BEFORE destroying anything.
        if group.tabs.count == 1 && windowSession.groups.count == 1 {
            if let appDelegate = NSApp.delegate as? AppDelegate,
               appDelegate.closingWouldTerminate(self),
               !appDelegate.isTerminationConfirmed {
                if !appDelegate.confirmQuitIfNeeded() {
                    closingTabIDs.remove(tabID)
                    return
                }
            }
        }

        // Check for unsent review comments
        if let store = reviewStores[tabID], store.hasUnsubmittedComments {
            let alert = NSAlert()
            alert.messageText = "Unsent Review Comments"
            alert.informativeText = "This diff tab has \(store.comments.count) unsent review comment(s). Closing will discard them."
            alert.addButton(withTitle: "Discard & Close")
            alert.addButton(withTitle: "Cancel")
            let response = alert.runModal()
            if response != .alertFirstButtonReturn {
                closingTabIDs.remove(tabID)
                return
            }
        }

        // Clean up browser controller if present
        browserControllers.removeValue(forKey: tabID)

        // Clean up diff state
        diffTasks[tabID]?.cancel()
        diffTasks.removeValue(forKey: tabID)
        diffStates.removeValue(forKey: tabID)
        reviewStores.removeValue(forKey: tabID)

        // Destroy all surfaces in the tab
        for surfaceID in tab.registry.allIDs {
            tab.registry.destroySurface(surfaceID)
        }

        let result = windowSession.removeTab(id: tabID, fromGroup: group.id)

        switch result {
        case .switchedTab, .switchedGroup:
            activateCurrentTab()
        case .windowShouldClose:
            if let appDelegate = NSApp.delegate as? AppDelegate,
               appDelegate.closingWouldTerminate(self) {
                appDelegate.isTerminationConfirmed = true
            }
            window?.close()
        }

        refreshHostingView()
        requestSave()
        closingTabIDs.remove(tabID)
    }

    func switchToTab(id tabID: UUID) {
        guard let targetGroup = windowSession.groups.first(where: { group in
            group.tabs.contains(where: { $0.id == tabID })
        }) else {
            logger.warning("Attempted to switch to non-existent tab: \(tabID)")
            return
        }
        let sameGroup = windowSession.activeGroupID == targetGroup.id
        let sameTab = sameGroup && targetGroup.activeTabID == tabID
        guard !sameTab else { return }

        deactivateCurrentTab()
        windowSession.activeGroupID = targetGroup.id
        targetGroup.activeTabID = tabID
        activateCurrentTab()
    }

    func switchToGroup(id groupID: UUID) {
        guard windowSession.groups.contains(where: { $0.id == groupID }) else {
            logger.warning("Attempted to switch to non-existent group: \(groupID)")
            return
        }
        guard windowSession.activeGroupID != groupID else { return }

        dismissComposeOverlay()
        deactivateCurrentTab()
        windowSession.activeGroupID = groupID
        activateCurrentTab()
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

        let newColor = TabGroupColor.nextColor(excluding: windowSession.groups.map { $0.color })
        let group = TabGroup(
            name: "Group \(windowSession.groups.count + 1)",
            color: newColor,
            tabs: [tab],
            activeTabID: tab.id
        )

        windowSession.addGroup(group)
        windowSession.activeGroupID = group.id

        rebuildSplitContainer()
        updateLayout()
        refreshHostingView()

        restoreFocus()
        retargetComposeOverlayIfNeeded()
        requestSave()
    }

    private func closeActiveGroup() {
        guard let group = windowSession.activeGroup else { return }

        // Mark all tabs as closing to prevent notification handler from double-deleting
        let tabIDs = group.tabs.map { $0.id }
        for tabID in tabIDs {
            closingTabIDs.insert(tabID)
        }

        // Quit confirmation: if this is the last group, closing it would terminate
        // the app. Confirm BEFORE destroying anything.
        if windowSession.groups.count == 1 {
            if let appDelegate = NSApp.delegate as? AppDelegate,
               appDelegate.closingWouldTerminate(self),
               !appDelegate.isTerminationConfirmed {
                if !appDelegate.confirmQuitIfNeeded() {
                    for tabID in tabIDs {
                        closingTabIDs.remove(tabID)
                    }
                    return
                }
            }
        }

        // Clean up browser controllers for all tabs in this group
        for tabID in tabIDs {
            browserControllers.removeValue(forKey: tabID)
        }
        // Clean up diff states for all tabs in this group
        for tabID in tabIDs {
            diffTasks[tabID]?.cancel()
            diffTasks.removeValue(forKey: tabID)
            diffStates.removeValue(forKey: tabID)
        }
        for tabID in tabIDs {
            reviewStores.removeValue(forKey: tabID)
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
            activateCurrentTab()
            refreshHostingView()
            requestSave()
        case .windowShouldClose:
            if let appDelegate = NSApp.delegate as? AppDelegate,
               appDelegate.closingWouldTerminate(self) {
                appDelegate.isTerminationConfirmed = true
            }
            window?.close()
            requestSave()
        }
    }

    private func closeAllTabsInGroup(id groupID: UUID) {
        guard let group = windowSession.groups.first(where: { $0.id == groupID }) else { return }

        let wasActiveGroup = (groupID == windowSession.activeGroupID)
        let tabIDs = group.tabs.map { $0.id }
        for tabID in tabIDs {
            closingTabIDs.insert(tabID)
        }

        // Quit confirmation: if this is the last group, closing it would terminate
        // the app. Confirm BEFORE destroying anything.
        if windowSession.groups.count == 1 {
            if let appDelegate = NSApp.delegate as? AppDelegate,
               appDelegate.closingWouldTerminate(self),
               !appDelegate.isTerminationConfirmed {
                if !appDelegate.confirmQuitIfNeeded() {
                    for tabID in tabIDs {
                        closingTabIDs.remove(tabID)
                    }
                    return
                }
            }
        }

        if wasActiveGroup {
            deactivateCurrentTab()
        }

        for tabID in tabIDs {
            browserControllers.removeValue(forKey: tabID)
            diffTasks[tabID]?.cancel()
            diffTasks.removeValue(forKey: tabID)
            diffStates.removeValue(forKey: tabID)
            reviewStores.removeValue(forKey: tabID)
        }

        for tab in group.tabs {
            for surfaceID in tab.registry.allIDs {
                tab.registry.destroySurface(surfaceID)
            }
        }

        let result = windowSession.removeGroup(id: groupID)

        for tabID in tabIDs {
            closingTabIDs.remove(tabID)
        }

        switch result {
        case .switchedTab(_, _), .switchedGroup(_, _):
            if wasActiveGroup {
                activateCurrentTab()
            }
            refreshHostingView()
            requestSave()
        case .windowShouldClose:
            if let appDelegate = NSApp.delegate as? AppDelegate,
               appDelegate.closingWouldTerminate(self) {
                appDelegate.isTerminationConfirmed = true
            }
            window?.close()
            requestSave()
        }
    }

    private func switchToNextGroup() {
        deactivateCurrentTab()
        windowSession.nextGroup()
        activateCurrentTab()
    }

    private func switchToPreviousGroup() {
        deactivateCurrentTab()
        windowSession.previousGroup()
        activateCurrentTab()
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
        guard let tab = activeTab else { return }
        switch tab.content {
        case .terminal:
            restoreFocus()
        case .browser:
            if let bv = activeBrowserController?.browserView {
                window?.makeFirstResponder(bv)
            }
        case .diff:
            break
        }
    }

    @objc func toggleComposeOverlay() {
        if windowSession.showComposeOverlay {
            dismissComposeOverlay()
        } else {
            guard let tab = activeTab, case .terminal = tab.content else { return }
            composeOverlayTargetSurfaceID = focusedController?.id
            windowSession.showComposeOverlay = true
            refreshHostingView()
        }
    }

    private func retargetComposeOverlayIfNeeded() {
        guard windowSession.showComposeOverlay else { return }
        composeOverlayTargetSurfaceID = focusedController?.id
    }

    private func dismissComposeOverlay() {
        guard windowSession.showComposeOverlay else { return }
        windowSession.showComposeOverlay = false
        composeOverlayTargetSurfaceID = nil
        refreshHostingView()
        if case .terminal = activeTab?.content {
            restoreFocus()
        }
    }

    @discardableResult
    private func sendComposeText(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }

        let targetController: GhosttySurfaceController?
        if let targetID = composeOverlayTargetSurfaceID,
           let tab = activeTab,
           let controller = tab.registry.controller(for: targetID) {
            targetController = controller
        } else {
            targetController = focusedController
        }

        guard let controller = targetController else { return false }

        // Check if the target is an AI agent (same detection as sendReviewToAgent)
        let isAgent = activeTab.map { tab -> Bool in
            guard case .terminal = tab.content else { return false }
            return Self.isAIAgentTitle(tab.title)
        } ?? false

        controller.sendText(text)

        var keyEvent = ghostty_input_key_s()
        keyEvent.keycode = 0x24
        keyEvent.mods = GHOSTTY_MODS_NONE
        keyEvent.consumed_mods = GHOSTTY_MODS_NONE
        keyEvent.text = nil
        keyEvent.unshifted_codepoint = 0
        keyEvent.composing = false

        if isAgent {
            // AI agent: same timing as sendReviewToAgent (confirm paste + submit)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                keyEvent.action = GHOSTTY_ACTION_PRESS
                controller.sendKey(keyEvent)
                keyEvent.action = GHOSTTY_ACTION_RELEASE
                controller.sendKey(keyEvent)

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    keyEvent.action = GHOSTTY_ACTION_PRESS
                    controller.sendKey(keyEvent)
                    keyEvent.action = GHOSTTY_ACTION_RELEASE
                    controller.sendKey(keyEvent)
                }
            }
        } else {
            // Regular terminal: single Enter, immediate
            keyEvent.action = GHOSTTY_ACTION_PRESS
            controller.sendKey(keyEvent)
            keyEvent.action = GHOSTTY_ACTION_RELEASE
            controller.sendKey(keyEvent)
        }
        return true
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
            activeTab?.clearUnreadNotifications()
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
        center.addObserver(self, selector: #selector(handleGotoTabNotification(_:)),
                           name: .ghosttyGotoTab, object: nil)
        center.addObserver(self, selector: #selector(handleConfirmClipboardNotification(_:)),
                           name: .ghosttyConfirmClipboard, object: nil)
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
            let wasActiveTab = (owningTab.id == activeTab?.id)
            let result = windowSession.removeTab(id: owningTab.id, fromGroup: owningGroup.id)
            if wasActiveTab {
                switch result {
                case .switchedTab, .switchedGroup:
                    activateCurrentTab()
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
            tab.title = title
            window?.title = tab.titleOverride ?? title
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

    @objc private func handleGotoTabNotification(_ notification: Notification) {
        guard let surfaceView = notification.object as? SurfaceView else { return }
        guard findTab(for: surfaceView) != nil else { return }
        guard let rawValue = notification.userInfo?["tab"] as? Int32 else { return }

        switch rawValue {
        case GHOSTTY_GOTO_TAB_NEXT.rawValue:
            selectNextTab(nil)
        case GHOSTTY_GOTO_TAB_PREVIOUS.rawValue:
            selectPreviousTab(nil)
        case GHOSTTY_GOTO_TAB_LAST.rawValue:
            let lastIndex = (windowSession.activeGroup?.tabs.count ?? 1) - 1
            selectTabByIndex(lastIndex)
        default:
            if rawValue >= 0 {
                selectTabByIndex(Int(rawValue))
            }
        }
    }

    @objc private func handleConfirmClipboardNotification(_ notification: Notification) {
        guard let surfaceView = notification.object as? SurfaceView else { return }
        guard belongsToThisWindow(surfaceView) else { return }
        guard let userInfo = notification.userInfo else { return }
        guard let contents = userInfo["contents"] as? String else { return }
        guard let surface = userInfo["surface"] as? ghostty_surface_t else { return }
        guard let requestRaw = userInfo["request"] as? ghostty_clipboard_request_e else { return }
        guard let request = ClipboardRequest.from(requestRaw) else { return }
        let state = userInfo["state"] as? UnsafeMutableRawPointer

        let controller = ClipboardConfirmationController(
            surface: surface,
            contents: contents,
            request: request,
            state: state
        )
        self.clipboardConfirmationController = controller

        guard let parentWindow = window, let sheet = controller.window else {
            // Cannot present confirmation UI; cancel the paste to avoid hanging.
            // Pass empty string with confirmed=true to avoid re-triggering unsafe paste detection.
            "".withCString { ptr in
                GhosttyFFI.surfaceCompleteClipboardRequest(surface, data: ptr, state: state, confirmed: true)
            }
            return
        }
        parentWindow.beginSheet(sheet) { [weak self] _ in
            self?.clipboardConfirmationController = nil
        }
    }

    @objc private func handleDesktopNotification(_ notification: Notification) {
        guard let surfaceView = notification.object as? SurfaceView else { return }
        guard let (owningTab, _) = findTab(for: surfaceView) else { return }
        guard let title = notification.userInfo?["title"] as? String else { return }
        let body = notification.userInfo?["body"] as? String ?? ""

        let isActiveAndVisible = owningTab.id == activeTab?.id && (window?.isKeyWindow ?? false)
        guard !isActiveAndVisible else { return }

        let isFirstUnread = owningTab.unreadNotifications == 0
        owningTab.unreadNotifications += 1
        owningTab.lastNotificationTime = Date()

        NotificationManager.shared.sendNotification(title: title, body: body, tabID: owningTab.id)

        if isFirstUnread {
            NotificationManager.shared.bounceDockIcon()
        }
    }

    func applyCurrentGhosttyConfig() {
        guard let config = GhosttyAppController.shared.configManager.config else { return }

        for group in windowSession.groups {
            for tab in group.tabs {
                tab.registry.applyConfig(config)
            }
        }
    }

    // MARK: - Menu Actions

    @objc func jumpToMostRecentUnreadTab() {
        var mostRecentTab: Tab?
        var mostRecentTime: Date?

        for group in windowSession.groups {
            for tab in group.tabs {
                guard tab.unreadNotifications > 0,
                      let time = tab.lastNotificationTime else { continue }
                if mostRecentTime == nil || time > mostRecentTime! {
                    mostRecentTab = tab
                    mostRecentTime = time
                }
            }
        }

        guard let target = mostRecentTab else {
            NSSound.beep()
            return
        }

        switchToTab(id: target.id)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(jumpToMostRecentUnreadTab) {
            return windowSession.groups.flatMap(\.tabs).contains { $0.unreadNotifications > 0 }
        }
        return true
    }

    @objc func newTab(_ sender: Any?) {
        createNewTab()
    }

    @objc func closeTab(_ sender: Any?) {
        guard let tab = activeTab, let group = windowSession.activeGroup else { return }
        closeTab(id: tab.id)
        _ = group // silence warning
    }

    @objc func newBrowserTab(_ sender: Any?) {
        promptAndOpenBrowserTab()
    }

    @objc func selectNextTab(_ sender: Any?) {
        deactivateCurrentTab()
        windowSession.nextTab()
        activateCurrentTab()
    }

    @objc func selectPreviousTab(_ sender: Any?) {
        deactivateCurrentTab()
        windowSession.previousTab()
        activateCurrentTab()
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

    func selectTab(at index: Int) {
        selectTabByIndex(index)
    }

    private func selectTabByIndex(_ index: Int) {
        guard index >= 0 else { return }
        deactivateCurrentTab()
        windowSession.selectTab(at: index)
        activateCurrentTab()
    }

    // MARK: - Session Persistence

    func activateRestoredSession() {
        isRestoring = false
        // Pause all non-active terminal tabs
        for group in windowSession.groups {
            for tab in group.tabs {
                if tab.id != windowSession.activeGroup?.activeTabID {
                    if case .terminal = tab.content {
                        tab.registry.pauseAll()
                    }
                }
            }
        }
        activateCurrentTab()
    }

    func windowSnapshot() -> WindowSnapshot {
        let frame: NSRect
        if trackedFullScreen {
            frame = preFullScreenFrame ?? window?.frame ?? .zero
        } else {
            frame = window?.frame ?? .zero
        }
        let groups = windowSession.groups.map { group in
            let tabs = group.tabs.compactMap { tab -> TabSnapshot? in
                // Skip diff tabs — they are not persisted
                if case .diff = tab.content { return nil }
                let browserURL: URL?
                switch tab.content {
                case .terminal:
                    browserURL = nil
                case .browser(let configuredURL):
                    browserURL = browserControllers[tab.id]?.browserState.url ?? configuredURL
                case .diff:
                    return nil  // Already handled above, but needed for exhaustive switch
                }
                return TabSnapshot(
                    id: tab.id,
                    title: tab.title,
                    titleOverride: tab.titleOverride,
                    pwd: tab.pwd,
                    splitTree: tab.splitTree,
                    browserURL: browserURL
                )
            }
            return TabGroupSnapshot(
                id: group.id,
                name: group.name,
                color: group.color.rawValue,
                tabs: tabs,
                activeTabID: group.activeTabID,
                isCollapsed: group.isCollapsed
            )
        }
        return WindowSnapshot(
            id: windowSession.id,
            frame: frame,
            groups: groups,
            activeGroupID: windowSession.activeGroupID,
            showSidebar: windowSession.showSidebar,
            sidebarWidth: windowSession.sidebarWidth,
            isFullScreen: trackedFullScreen
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

    /// Exposes the focused surface controller for UI testing only.
    var focusedControllerForTesting: GhosttySurfaceController? {
        focusedController
    }

    // MARK: - NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) {
        GhosttyAppController.shared.setFocus(true)
        if case .browser = activeTab?.content {
            if let bv = activeBrowserController?.browserView {
                window?.makeFirstResponder(bv)
            }
        } else if case .diff = activeTab?.content {
            // No special focus needed for diff tabs
        } else {
            focusedController?.setFocus(true)
            restoreFocus()
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        GhosttyAppController.shared.setFocus(false)
        focusedController?.setFocus(false)
        if windowSession.showCommandPalette {
            dismissCommandPalette()
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let appDelegate = NSApp.delegate as? AppDelegate,
              appDelegate.closingWouldTerminate(self) else {
            return true
        }

        // Already confirmed (from Cmd+Q → applicationShouldTerminate)
        if appDelegate.isTerminationConfirmed {
            isClosingForShutdown = true
            return true
        }

        // Last-window close via X button: run confirmations
        if !appDelegate.confirmQuitIfNeeded() {
            return false
        }

        appDelegate.isTerminationConfirmed = true
        isClosingForShutdown = true
        return true
    }

    func windowDidChangeBackingProperties(_ notification: Notification) {
        guard let window = self.window, let tab = activeTab else { return }
        let scale = window.backingScaleFactor
        for id in tab.registry.allIDs {
            tab.registry.controller(for: id)?.setContentScale(scale)
        }
    }

    func windowWillClose(_ notification: Notification) {
        if let appDelegate = NSApp.delegate as? AppDelegate,
           appDelegate.isClosingLastManagedWindow(self) {
            // Persist current session before this final window is removed from AppDelegate.
            appDelegate.saveImmediately()
        }

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

        browserControllers.removeAll()

        for (_, task) in diffTasks { task.cancel() }
        diffTasks.removeAll()
        diffStates.removeAll()
        reviewStores.removeAll()
        for (_, task) in expandTasks { task.cancel() }
        expandTasks.removeAll()
        refreshTask?.cancel()
        loadMoreTask?.cancel()

        if let appDelegate = NSApp.delegate as? AppDelegate {
            appDelegate.removeWindowController(self)
        }
    }

    func windowDidResize(_ notification: Notification) {
        // SplitContainerView handles resize via autoresizingMask + resizeSubviews
    }

    func windowWillEnterFullScreen(_ notification: Notification) {
        preFullScreenFrame = window?.frame
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        trackedFullScreen = true
        if !isRestoring {
            requestSave()
        }
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        // Preserve tracked fullscreen state during close sequence so shutdown snapshot records fullscreen.
        guard !isClosingForShutdown else { return }
        trackedFullScreen = false
        preFullScreenFrame = nil
        if !isRestoring {
            requestSave()
        }
    }

    // MARK: - Git Source Control

    private func refreshGitStatus() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            guard let self else { return }

            let workDir = self.findWorkDir()
            guard let workDir else {
                self.windowSession.gitChangesState = .error("No working directory found")
                self.refreshHostingView()
                return
            }

            self.windowSession.gitChangesState = .loading
            self.refreshHostingView()

            do {
                let repoRoot = try await GitService.repoRoot(workDir: workDir)
                guard !Task.isCancelled else { return }

                self.windowSession.repoRoots[workDir] = repoRoot

                async let statusResult = GitService.gitStatus(workDir: repoRoot)
                async let logResult = GitService.commitLog(workDir: repoRoot, maxCount: 100, skip: 0)

                let (entries, commits) = try await (statusResult, logResult)
                guard !Task.isCancelled else { return }

                self.windowSession.gitEntries = entries
                self.windowSession.gitCommits = commits
                self.hasMoreCommits = true
                self.windowSession.expandedCommitIDs = []
                self.windowSession.commitFiles = [:]
                self.windowSession.gitChangesState = .loaded
                self.refreshHostingView()
            } catch let error as GitService.GitError {
                guard !Task.isCancelled else { return }
                if case .notARepository = error {
                    self.windowSession.gitChangesState = .notRepository
                } else {
                    self.windowSession.gitChangesState = .error(error.localizedDescription)
                }
                self.refreshHostingView()
            } catch {
                guard !Task.isCancelled else { return }
                self.windowSession.gitChangesState = .error(error.localizedDescription)
                self.refreshHostingView()
            }
        }
    }

    private func loadMoreCommits() {
        guard hasMoreCommits else { return }
        guard loadMoreTask == nil || loadMoreTask?.isCancelled == true else { return }
        loadMoreTask = Task { [weak self] in
            guard let self else { return }
            let currentCount = self.windowSession.gitCommits.count

            guard let workDir = self.findWorkDir(),
                  let repoRoot = self.windowSession.repoRoots[workDir] else { return }

            do {
                let moreCommits = try await GitService.commitLog(
                    workDir: repoRoot, maxCount: 50, skip: currentCount
                )
                guard !Task.isCancelled else { return }
                guard !moreCommits.isEmpty else {
                    self.hasMoreCommits = false
                    return
                }

                self.windowSession.gitCommits.append(contentsOf: moreCommits)
                self.refreshHostingView()
            } catch {
                // Silently ignore load-more errors
            }
            self.loadMoreTask = nil
        }
    }

    private func expandCommit(hash: String) {
        if windowSession.expandedCommitIDs.contains(hash) {
            windowSession.expandedCommitIDs.remove(hash)
            refreshHostingView()
            return
        }

        windowSession.expandedCommitIDs.insert(hash)
        refreshHostingView()

        if windowSession.commitFiles[hash] != nil { return }

        guard let workDir = findWorkDir(),
              let repoRoot = windowSession.repoRoots[workDir] else { return }

        expandTasks[hash] = Task { [weak self] in
            guard let self else { return }
            do {
                let files = try await GitService.commitFiles(hash: hash, workDir: repoRoot)
                self.windowSession.commitFiles[hash] = files
                self.refreshHostingView()
            } catch {
                // Silently ignore
            }
            self.expandTasks.removeValue(forKey: hash)
        }
    }

    private func handleWorkingFileSelected(_ entry: GitFileEntry) {
        guard let workDir = findWorkDir(),
              let repoRoot = windowSession.repoRoots[workDir] else { return }

        let source: DiffSource
        if entry.isStaged {
            source = .staged(path: entry.path, workDir: repoRoot)
        } else if entry.status == .untracked {
            source = .untracked(path: entry.path, workDir: repoRoot)
        } else {
            source = .unstaged(path: entry.path, workDir: repoRoot)
        }

        openDiffTab(source: source)
    }

    private func handleCommitFileSelected(_ entry: CommitFileEntry) {
        guard let workDir = findWorkDir(),
              let repoRoot = windowSession.repoRoots[workDir] else { return }

        let source: DiffSource = .commit(hash: entry.commitHash, path: entry.path, workDir: repoRoot)
        openDiffTab(source: source)
    }

    private func openDiffTab(source: DiffSource) {
        // Dedup: check if same source already open
        if let group = windowSession.activeGroup {
            for tab in group.tabs {
                if case .diff(let existingSource) = tab.content, existingSource == source {
                    switchToTab(id: tab.id)
                    return
                }
            }
        }

        guard let group = windowSession.activeGroup else { return }

        let fileName: String
        switch source {
        case .unstaged(let path, _), .staged(let path, _), .commit(_, let path, _), .untracked(let path, _):
            fileName = (path as NSString).lastPathComponent
        }

        let tab = Tab(title: fileName, content: .diff(source: source))
        deactivateCurrentTab()
        group.addTab(tab)
        group.activeTabID = tab.id

        diffStates[tab.id] = .loading
        let reviewStore = DiffReviewStore()
        reviewStore.onCommentsChanged = { [weak self] in self?.refreshHostingView() }
        reviewStores[tab.id] = reviewStore
        refreshHostingView()

        let tabID = tab.id
        diffTasks[tabID] = Task { [weak self] in
            guard let self else { return }
            do {
                let rawDiff = try await GitService.fileDiff(source: source)
                guard !Task.isCancelled else { return }

                let path: String
                switch source {
                case .unstaged(let p, _), .staged(let p, _), .commit(_, let p, _), .untracked(let p, _):
                    path = p
                }
                let parsed = DiffParser.parse(rawDiff, path: path)
                guard !Task.isCancelled else { return }

                // Verify tab still exists
                guard self.windowSession.groups.flatMap(\.tabs).contains(where: { $0.id == tabID }) else { return }

                self.diffStates[tabID] = .success(parsed)
                self.refreshHostingView()
            } catch {
                guard !Task.isCancelled else { return }
                self.diffStates[tabID] = .error(error.localizedDescription)
                self.refreshHostingView()
            }
        }
    }

    private func findWorkDir() -> String? {
        // 1. Active terminal tab's pwd
        if let tab = activeTab, case .terminal = tab.content, let pwd = tab.pwd {
            return pwd
        }
        // 2. Any terminal tab in same group
        if let group = windowSession.activeGroup {
            for tab in group.tabs {
                if case .terminal = tab.content, let pwd = tab.pwd {
                    return pwd
                }
            }
        }
        // 3. Any terminal tab in any group
        for group in windowSession.groups {
            for tab in group.tabs {
                if case .terminal = tab.content, let pwd = tab.pwd {
                    return pwd
                }
            }
        }
        // 4. Fallback from cached repo roots
        return windowSession.repoRoots.values.first
    }

    // MARK: - IPC

    private func enableIPC() {
        do {
            // Generate token: 32 random bytes as hex
            var bytes = [UInt8](repeating: 0, count: 32)
            let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
            guard status == errSecSuccess else {
                showIPCAlert(title: "IPC Error", message: "Failed to generate secure token.")
                return
            }
            let token = bytes.map { String(format: "%02x", $0) }.joined()

            // Start server first to get the port
            try CalyxMCPServer.shared.start(token: token)
            let port = CalyxMCPServer.shared.port

            // Write config to all available agent tools
            let result = IPCConfigManager.enableIPC(port: port, token: token)

            if !result.anySucceeded {
                CalyxMCPServer.shared.stop()
                showIPCAlert(
                    title: "IPC Error",
                    message: "MCP server running on port \(port).\nNo agent configs found. Configure manually if needed."
                )
                return
            }

            showIPCAlert(
                title: "IPC Enabled",
                message: "MCP server running on port \(port).\n\(configStatusMessage(result))\nRestart agent instances to connect."
            )
        } catch {
            showIPCAlert(title: "IPC Error", message: error.localizedDescription)
        }
    }

    private func disableIPC() {
        CalyxMCPServer.shared.stop()
        let result = IPCConfigManager.disableIPC()
        showIPCAlert(
            title: "IPC Disabled",
            message: "MCP server stopped.\n\(configStatusMessage(result))"
        )
    }

    private func configStatusMessage(_ result: IPCConfigResult) -> String {
        func label(_ status: ConfigStatus, name: String) -> String {
            switch status {
            case .success:
                return "\(name): configured"
            case .skipped(let reason):
                return "\(name): \(reason) (skipped)"
            case .failed(let error):
                return "\(name): error - \(error.localizedDescription)"
            }
        }
        return [
            label(result.claudeCode, name: "Claude Code"),
            label(result.codex, name: "Codex"),
            label(result.openCode, name: "OpenCode"),
            label(result.hermes, name: "Hermes"),
        ].joined(separator: "\n")
    }

    // MARK: - AI Agent Tab Detection

    /// Returns true if a terminal tab title indicates it is running one of the
    /// supported AI agents (Claude Code, Codex, OpenCode, Hermes). Centralizes
    /// the title-substring check used by both compose and review send paths.
    /// Keep the agent list in sync with `IPCConfigResult` axes.
    private static func isAIAgentTitle(_ title: String) -> Bool {
        title.localizedCaseInsensitiveContains("claude") ||
        title.localizedCaseInsensitiveContains("codex") ||
        title.localizedCaseInsensitiveContains("opencode") ||
        title.localizedCaseInsensitiveContains("hermes")
    }

    private func sendReviewToAgent(_ payload: String) -> ReviewSendResult {
        // Find terminal tabs running a supported AI agent.
        let agentTabs = windowSession.groups.flatMap(\.tabs).filter {
            guard case .terminal = $0.content else { return false }
            return Self.isAIAgentTitle($0.title)
        }

        guard !agentTabs.isEmpty else {
            showIPCAlert(title: "No AI Agent", message: "No terminal tabs running Claude Code, Codex, OpenCode, or Hermes found. Start an AI agent first.")
            return .failed
        }

        // Select target tab
        let targetTab: Tab
        if agentTabs.count == 1 {
            targetTab = agentTabs[0]
        } else {
            let alert = NSAlert()
            alert.messageText = "Select AI Agent Tab"
            alert.informativeText = "Choose which AI agent instance to send the review to:"
            alert.addButton(withTitle: "Send")
            alert.addButton(withTitle: "Cancel")

            let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
            for (i, tab) in agentTabs.enumerated() {
                let groupName = windowSession.groups.first { $0.tabs.contains { $0.id == tab.id } }?.name ?? ""
                let label = "\(tab.titleOverride ?? tab.title) — \(groupName) (#\(i + 1))"
                popup.addItem(withTitle: label)
            }
            alert.accessoryView = popup

            let response = alert.runModal()
            guard response == .alertFirstButtonReturn else { return .cancelled }

            let selectedIndex = popup.indexOfSelectedItem
            guard selectedIndex >= 0, selectedIndex < agentTabs.count else { return .failed }
            targetTab = agentTabs[selectedIndex]
        }

        // Send review text to terminal PTY via ghostty surface
        guard let focusedID = targetTab.splitTree.focusedLeafID,
              let controller = targetTab.registry.controller(for: focusedID) else {
            showIPCAlert(title: "Send Failed", message: "Could not access terminal surface.")
            return .failed
        }

        controller.sendText(payload)
        // Send Enter twice as key events: first to confirm paste, second to submit
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            var keyEvent = ghostty_input_key_s()
            keyEvent.keycode = 0x24 // macOS keycode for Return/Enter
            keyEvent.mods = GHOSTTY_MODS_NONE
            keyEvent.consumed_mods = GHOSTTY_MODS_NONE
            keyEvent.text = nil
            keyEvent.unshifted_codepoint = 0
            keyEvent.composing = false

            // First Enter
            keyEvent.action = GHOSTTY_ACTION_PRESS
            controller.sendKey(keyEvent)
            keyEvent.action = GHOSTTY_ACTION_RELEASE
            controller.sendKey(keyEvent)

            // Second Enter
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                keyEvent.action = GHOSTTY_ACTION_PRESS
                controller.sendKey(keyEvent)
                keyEvent.action = GHOSTTY_ACTION_RELEASE
                controller.sendKey(keyEvent)
            }
        }

        // Switch to the target terminal tab
        switchToTab(id: targetTab.id)

        return .sent
    }

    private func submitDiffReview(tabID: UUID) {
        guard let store = reviewStores[tabID], store.hasUnsubmittedComments else { return }

        // Get file path from tab
        guard let tab = windowSession.groups.flatMap(\.tabs).first(where: { $0.id == tabID }),
              case .diff(let source) = tab.content else { return }
        let filePath: String
        switch source {
        case .unstaged(let p, _), .staged(let p, _), .commit(_, let p, _), .untracked(let p, _):
            filePath = p
        }

        let payload = store.formatForSubmission(filePath: filePath)
        let result = sendReviewToAgent(payload)

        if result == .sent {
            store.clearAll()
            refreshHostingView()
        }
    }

    private func submitAllDiffReviews() {
        // Collect all review stores with comments, paired with their DiffSource
        let entries: [(source: DiffSource, store: DiffReviewStore)] = reviewStores.compactMap { tabID, store in
            guard store.hasUnsubmittedComments else { return nil }
            guard let tab = windowSession.groups.flatMap(\.tabs).first(where: { $0.id == tabID }),
                  case .diff(let source) = tab.content else { return nil }
            return (source: source, store: store)
        }
        guard !entries.isEmpty else { return }

        let payload = DiffReviewStore.formatAllForSubmission(entries)
        let result = sendReviewToAgent(payload)

        if result == .sent {
            for entry in entries { entry.store.clearAll() }
            refreshHostingView()
        }
    }

    private func discardAllDiffReviews() {
        let storesWithComments = reviewStores.values.filter { $0.hasUnsubmittedComments }
        guard !storesWithComments.isEmpty else { return }

        let alert = NSAlert()
        alert.messageText = "Discard All Review Comments"
        alert.informativeText = "This will discard \(totalReviewCommentCount) comment(s) across \(reviewFileCount) file(s)."
        alert.addButton(withTitle: "Discard All")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }

        for store in storesWithComments { store.clearAll() }
        refreshHostingView()
    }

    private func showIPCAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

}
