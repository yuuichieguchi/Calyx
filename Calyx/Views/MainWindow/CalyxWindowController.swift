import AppKit
import SwiftUI
import GhosttyKit
import OSLog
import Security

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.calyx.terminal",
    category: "CalyxWindowController"
)

/// Reconnect-flashing-bug fix: narrow `#if DEBUG` override hook for
/// `CalyxWindowController.reconnectEstablishGraceMilliseconds`,
/// mirroring `SessionDaemonClientBoundTimeoutOverrides`'s identical
/// shape/reasoning exactly. `nil` (the default) means "use the
/// production value" (2000ms); a test sets a tiny, distinguishable
/// value so it can assert the grace-period wait's plumbing without
/// waiting out the real one. `nonisolated(unsafe)` is sound because the
/// only production reader is that computed property, and every test
/// that sets it resets it back to `nil` in its own `tearDown()`.
#if DEBUG
enum CalyxWindowControllerReconnectGraceOverrides {
    nonisolated(unsafe) static var reconnectEstablishGraceMilliseconds: UInt64?
}
#endif

/// Round-18 finding G6: what `performReconnect`'s grace `Task` learns from
/// `reconnectGraceProbe(sessionID:)` before calling `markEstablished`. Time
/// alone (the grace-period wait) plus surface identity alone is not
/// positive evidence the replacement is actually connected -- an attach
/// process that dies SLOWER than the grace window keeps resetting the
/// attempt count every cycle without ever advancing it, so `.giveUp` never
/// fires. `.established` requires the daemon to report the session
/// `Running` with at least one attached client; anything else, including a
/// probe failure, is `.notEstablished`.
enum ReconnectGraceProbeResult: Sendable, Equatable {
    case established
    case notEstablished
}

@MainActor
class CalyxWindowController: NSWindowController, NSWindowDelegate {
    private(set) var windowSession: WindowSession
    private var splitContainerView: SplitContainerView?
    private var hostingView: NSHostingView<MainContentView>?
    private var wasOccluded = false
    /// Not `private` (P4): `SessionCommandPaletteTests` reads
    /// `allCommands` directly (via `@testable import Calyx`) to assert
    /// `session.attach`/`session.detach`/`session.kill` are registered
    /// with the right `isAvailable` gate — matching the existing
    /// direct-query test style (`route(request:)`, `_testInsert`) this
    /// codebase favors over driving real UI. No other production code
    /// outside this file reads it.
    let commandRegistry = CommandRegistry()
    private var closingTabIDs: Set<UUID> = []
    #if DEBUG
    /// Test seam (P4 round-4 fix RED phase): read-only observability
    /// into `closingTabIDs`, so tests can confirm a close path inserted
    /// a tab's id into it at the right point in its sequence, mirrors
    /// `SurfaceRegistry._testInsert`'s naming/gating convention. DO NOT
    /// use from production code.
    var _closingTabIDsForTesting: Set<UUID> { closingTabIDs }
    #endif
    private var focusRequestID: UInt64 = 0
    private var isRestoring = false
    var trackedFullScreen: Bool = false
    var preFullScreenFrame: NSRect? = nil
    /// R6-G (r6-fix-spec.md, round-5 review finding I2): despite the
    /// name, this means only "THIS window's teardown is proceeding and
    /// must preserve tracking state (SessionSurfaceMap/tab.sessionRefs)
    /// into the snapshot instead of killing/detaching it", not "the app
    /// is quitting". `closeLastWindow` sets it even for a non-
    /// terminating close (a quick terminal keeps the app alive), so a
    /// caller that needs to know whether the whole APP is terminating
    /// must consult `isAppActuallyTerminating` instead (or in addition),
    /// never this flag alone. Every reader was re-audited against this
    /// meaning in round 5; see each reader's own doc comment.
    var isClosingForShutdown: Bool = false
    private var browserControllers: [UUID: BrowserTabController] = [:]
    private var diffStates: [UUID: DiffLoadState] = [:]
    private var diffTasks: [UUID: Task<Void, Never>] = [:]
    private var refreshTask: Task<Void, Never>?
    private var loadMoreTask: Task<Void, Never>?
    /// Herdr layer-2 screen-classification poll (see
    /// `startScreenPollTask`). Runs for the window's lifetime, cancelled
    /// in `windowWillClose`.
    private var screenPollTask: Task<Void, Never>?
    private var expandTasks: [String: Task<Void, Never>] = [:]
    /// R14-B sweep addendum item 2 (r14-fix-spec.md): tracks
    /// `processChildExited`'s per-surface reconnect-decision `Task`,
    /// keyed by surface ID like `diffTasks`/`expandTasks` above, so
    /// `windowWillClose` can cancel it the same way it cancels every
    /// other per-window `Task` instead of leaving it as the sole
    /// untracked fire-and-forget one -- consistency/resource hygiene
    /// (R14-B's longer 15s `sessionStateBoundTimeoutSeconds` bound
    /// triples how long an orphaned one could linger).
    private var childExitedTasks: [UUID: Task<Void, Never>] = [:]
    #if DEBUG
    /// Test seam (P4 round-16 fix RED phase): read-only observability
    /// into `childExitedTasks`, mirroring `_closingTabIDsForTesting`'s
    /// naming/gating convention, so tests can await a tracked Task's
    /// `.value` and then confirm it removed its own entry. DO NOT use
    /// from production code.
    var _childExitedTasksForTesting: [UUID: Task<Void, Never>] { childExitedTasks }
    #endif
    /// Reconnect-flashing-bug fix: `performReconnect`'s deferred-reset
    /// confirmation `Task` per replacement surface, keyed by the NEW
    /// surfaceID (not sessionID) so two different reconnects never
    /// collide on the same key. See `performReconnect`'s doc comment for
    /// why the `markEstablished(sessionID:)` reset itself is deferred
    /// behind a grace period rather than firing immediately. Cancelled
    /// and cleared in `windowWillClose` alongside `childExitedTasks`'s
    /// other siblings, per this file's established per-window `Task`-
    /// dictionary discipline.
    private var reconnectEstablishGraceTasks: [UUID: Task<Void, Never>] = [:]
    private var hasMoreCommits = true
    private var reviewStores: [UUID: DiffReviewStore] = [:]
    private var clipboardConfirmationController: ClipboardConfirmationController?
    private var composeOverlayTargetSurfaceID: UUID?
    /// Decides reconnect vs. close for this window's persistent-session
    /// surfaces on `GHOSTTY_ACTION_SHOW_CHILD_EXITED` (wired in
    /// `handleShowChildExitedNotification`). One instance per window
    /// controller is enough — decisions are keyed by surface UUID, and
    /// each surface only ever belongs to one window.
    private lazy var sessionReconnectCoordinator = SessionReconnectCoordinator(
        daemonClient: SessionDaemonClient.shared,
        surfaceMap: .shared,
        onDecision: { [weak self] surfaceID, decision in
            self?.handleSessionReconnectDecision(surfaceID: surfaceID, decision: decision)
        }
    )
    #if DEBUG
    /// Test seam (reconnect-flashing-bug RED phase): when non-nil,
    /// called INSTEAD of the real `tab.registry.createSurface(...)` FFI
    /// call inside `performReconnect`, mirroring `AppDelegate
    /// ._createSurfaceWithPwdHookForTesting`'s exact style/reasoning (a
    /// real ghostty surface is confirmed unsafe to construct in this
    /// test host, see `AppDelegateAttachWindowTests`'s header comment
    /// for the hang this caused). Returns the UUID to report as the
    /// newly created replacement surface (simulating success), or
    /// `nil` to simulate surface-creation failure. `nil` (the default)
    /// leaves production behavior unchanged: every guard/step around
    /// this call in `performReconnect`, including the `markEstablished`
    /// timing under test, remains real, unmodified production code. DO
    /// NOT use from production code.
    var _performReconnectSurfaceCreationHookForTesting: (() -> UUID?)?

    /// Test seam (round-18 G6 RED phase): when non-nil, called INSTEAD of
    /// the real `SessionDaemonClient.shared.listAllBounded()` daemon query
    /// inside `reconnectGraceProbe(sessionID:)`, mirroring
    /// `_performReconnectSurfaceCreationHookForTesting`'s exact
    /// hook-first/real-fallback style. A throwing hook is fail-closed by
    /// construction: `reconnectGraceProbe(sessionID:)` treats it exactly
    /// like an explicit `.notEstablished` answer. `nil` (the default)
    /// leaves production behavior unchanged. DO NOT use from production
    /// code.
    var _reconnectGraceProbeForTesting: (() async throws -> ReconnectGraceProbeResult)?

    /// Test seam: read-only access to `sessionReconnectCoordinator`,
    /// mirroring `_childExitedTasksForTesting`'s/`_closingTabIDsForTesting`'s
    /// read-only-accessor convention, so a test can inspect
    /// `attemptCounts` (and, via `SessionReconnectCoordinator
    /// ._testSeedAttemptCount(sessionID:count:)`, seed it) without a
    /// live daemon round-trip. DO NOT use from production code.
    var _sessionReconnectCoordinatorForTesting: SessionReconnectCoordinator { sessionReconnectCoordinator }
    #endif
    /// Surface UUIDs currently being destroyed as part of
    /// `performReconnect`'s surface swap (populated right before, and
    /// cleared right after, its `destroySurface` call). Consulted by
    /// `killSessionIfPersistent` via `SessionCloseKillPolicy` — defense
    /// in depth on top of `performReconnect`'s own ordering (re-pointing
    /// `SessionSurfaceMap` before destroying the old surface) — so a
    /// `destroySurface` call that synchronously re-enters
    /// `handleCloseSurfaceNotification` (ghostty's `close_surface`
    /// callback fires from inside `requestClose()`) can never self-kill
    /// the very session `performReconnect` is reconnecting to.
    private var reconnectingSurfaceIDs: Set<UUID> = []

    /// F4 (V05, HIGH, r4-fix-spec.md): a `.childExited` notification,
    /// `.decision`, or (R6-A, r6-fix-spec.md) `.closeSurface`
    /// notification deferred by `handleShowChildExitedNotification`/
    /// `handleSessionReconnectDecision`/`handleCloseSurfaceNotification`
    /// while `AppDelegate.isConfirmingQuit` was `true`, instead of being
    /// dropped outright. A dropped `SHOW_CHILD_EXITED` notification has
    /// no recovery path (one-shot, never re-emitted, see ghostty's
    /// `Surface.zig:1202`), a dropped `.giveUp` decision silently
    /// downgrades the pane's eventual keypress-close to kill semantics
    /// instead of the intended detach (see r4-verdicts.md V05), and a
    /// dropped `close_surface` relies entirely on the user pressing a
    /// key to self-heal (r5-verdicts.md V2/V3). Drained by
    /// `drainDeferredReconnectEvents()`, scheduled on a fresh MainActor
    /// turn once the gate clears (see `handleConfirmingQuitDidEnd`'s doc
    /// comment).
    private enum DeferredReconnectEvent {
        case childExited(surfaceView: SurfaceView)
        case decision(surfaceID: UUID, decision: SessionReconnectDecision)
        case closeSurface(surfaceView: SurfaceView)
    }
    private var deferredReconnectEvents: [DeferredReconnectEvent] = []

    /// R6-A (r6-fix-spec.md item 3): true while THIS window's own
    /// teardown (`isClosingForShutdown`) or the app itself
    /// (`isAppActuallyTerminating`) is shutting down. Consulted by the
    /// deferred-event drain and its handlers so a decision is never
    /// replayed, or a fresh one processed, on top of quit teardown that
    /// already preserved tracking state into the snapshot (r5-
    /// verdicts.md V5), see `windowWillClose`'s own preserve branch.
    private var isShuttingDown: Bool {
        isClosingForShutdown || isAppActuallyTerminating
    }

    /// R6-D (r6-fix-spec.md): true once the app is genuinely quitting,
    /// not just this window closing. A thin forward (R8-C, r8-fix-
    /// spec.md) to `AppDelegate.isTerminating`, the one canonical query
    /// (see its own doc comment for why both of its component flags
    /// participate): round-5 review (I2) found the per-window
    /// `isClosingForShutdown` flag alone is not a safe "app terminating"
    /// discriminator (`closeLastWindow` sets it even for a non-
    /// terminating close, see that flag's own doc comment). Used by
    /// `windowWillClose`'s destroy loop to decide whether to run the
    /// normal kill/detach close policy (app not terminating) or preserve
    /// tracking state into the snapshot exactly as before (app
    /// terminating).
    private var isAppActuallyTerminating: Bool {
        (NSApp.delegate as? AppDelegate)?.isTerminating ?? false
    }

    // MARK: - Computed Properties

    private var activeTab: Tab? {
        windowSession.activeGroup?.activeTab
    }

    private var activeRegistry: SurfaceRegistry? {
        activeTab?.registry
    }

    /// Gate shared by the `session.detach`/`session.kill` command
    /// palette entries: `true` only when the focused pane (the active
    /// tab's `splitTree.focusedLeafID`) has a tracked `SessionRef` —
    /// an ordinary (non-persistent) pane, or no focused leaf at all,
    /// has nothing to detach or kill.
    private var focusedPaneHasTrackedSession: Bool {
        guard let tab = activeTab, let leafID = tab.splitTree.focusedLeafID else { return false }
        return tab.sessionRefs[leafID] != nil
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

    #if DEBUG
    /// Test seam (round 12, R12-C RED phase, sweep addendum item 3):
    /// registers `controller` as tabID's live BrowserTabController
    /// without driving a full navigation through the real
    /// BrowserView/WebKit stack, so windowSnapshot()'s live-browserURL-
    /// override branch (which reads `browserControllers`) can be
    /// exercised directly against a URL that deliberately differs from
    /// the tab's configured `content` URL. Mirrors
    /// `_closingTabIDsForTesting`'s naming/gating convention. DO NOT use
    /// from production code.
    func _setBrowserControllerForTesting(tabID: UUID, controller: BrowserTabController) {
        browserControllers[tabID] = controller
    }
    #endif

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
        setupCommandRegistry()
        setupUI()
        if !restoring { setupTerminalSurface() }
        registerNotificationObservers()
        startScreenPollTask()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Setup

    private func setupCommandRegistry() {
        commandRegistry.register(PaletteCommand(id: "tab.new", title: "New Tab", shortcut: "Cmd+T", category: "Tabs") { [weak self] in
            self?.createNewTab()
        })
        commandRegistry.register(PaletteCommand(id: "tab.close", title: "Close Tab", shortcut: "Cmd+W", category: "Tabs") { [weak self] in
            guard let self, let tab = self.activeTab else { return }
            self.closeTab(id: tab.id)
        })
        commandRegistry.register(PaletteCommand(id: "tab.next", title: "Next Tab", shortcut: "Cmd+Shift+]", category: "Tabs") { [weak self] in
            self?.selectNextTab(nil)
        })
        commandRegistry.register(PaletteCommand(id: "tab.previous", title: "Previous Tab", shortcut: "Cmd+Shift+[", category: "Tabs") { [weak self] in
            self?.selectPreviousTab(nil)
        })
        commandRegistry.register(PaletteCommand(id: "group.new", title: "New Group", shortcut: "Ctrl+Shift+N", category: "Groups") { [weak self] in
            self?.createNewGroup()
        })
        commandRegistry.register(PaletteCommand(id: "group.close", title: "Close Group", shortcut: "Ctrl+Shift+W", category: "Groups") { [weak self] in
            self?.closeActiveGroup()
        })
        commandRegistry.register(PaletteCommand(id: "group.next", title: "Next Group", shortcut: "Ctrl+Shift+]", category: "Groups") { [weak self] in
            self?.switchToNextGroup()
        })
        commandRegistry.register(PaletteCommand(id: "group.previous", title: "Previous Group", shortcut: "Ctrl+Shift+[", category: "Groups") { [weak self] in
            self?.switchToPreviousGroup()
        })
        commandRegistry.register(PaletteCommand(id: "view.sidebar", title: "Toggle Sidebar", shortcut: "Cmd+Opt+S", category: "View") { [weak self] in
            self?.toggleSidebar()
        })
        commandRegistry.register(PaletteCommand(id: "view.fullscreen", title: "Toggle Full Screen", shortcut: "Ctrl+Cmd+F", category: "View") { [weak self] in
            self?.window?.toggleFullScreen(nil)
        })
        commandRegistry.register(PaletteCommand(id: "window.new", title: "New Window", shortcut: "Cmd+N", category: "Window") {
            if let appDelegate = NSApp.delegate as? AppDelegate {
                appDelegate.createNewWindow()
            }
        })
        commandRegistry.register(PaletteCommand(id: "edit.find", title: "Find in Terminal", shortcut: "Cmd+F", category: "Edit") { [weak self] in
            guard let controller = self?.focusedController else { return }
            controller.performAction("start_search")
        })
        commandRegistry.register(PaletteCommand(
            id: "edit.compose",
            title: "Compose Input",
            shortcut: "Cmd+Shift+E",
            category: "Edit"
        ) { [weak self] in
            self?.toggleComposeOverlay()
        })
        commandRegistry.register(PaletteCommand(id: "browser.open", title: "Open Browser Tab", category: "Browser") { [weak self] in
            self?.promptAndOpenBrowserTab()
        })
        commandRegistry.register(PaletteCommand(id: "browser.back", title: "Browser Back", category: "Browser") { [weak self] in
            guard case .browser = self?.activeTab?.content else { return }
            self?.activeBrowserController?.goBack()
        })
        commandRegistry.register(PaletteCommand(id: "browser.forward", title: "Browser Forward", category: "Browser") { [weak self] in
            guard case .browser = self?.activeTab?.content else { return }
            self?.activeBrowserController?.goForward()
        })
        commandRegistry.register(PaletteCommand(id: "browser.reload", title: "Browser Reload", category: "Browser") { [weak self] in
            guard case .browser = self?.activeTab?.content else { return }
            self?.activeBrowserController?.reload()
        })
        commandRegistry.register(PaletteCommand(id: "git.showChanges", title: "Show Git Changes", category: "Git") { [weak self] in
            self?.windowSession.sidebarMode = .changes
            self?.windowSession.showSidebar = true
            self?.refreshGitStatus()
            self?.refreshHostingView()
        })
        commandRegistry.register(PaletteCommand(id: "git.refresh", title: "Refresh Git Changes", category: "Git") { [weak self] in
            self?.refreshGitStatus()
        })
        commandRegistry.register(PaletteCommand(id: "ipc.enable", title: "Enable AI Agent IPC", category: "IPC", isAvailable: {
            !CalyxMCPServer.shared.isRunning
        }) { [weak self] in
            self?.enableIPC()
        })
        commandRegistry.register(PaletteCommand(id: "ipc.disable", title: "Disable AI Agent IPC", category: "IPC", isAvailable: {
            CalyxMCPServer.shared.isRunning
        }) { [weak self] in
            self?.disableIPC()
        })
        commandRegistry.register(PaletteCommand(id: "cli.install", title: "Install CLI to PATH", category: "System") {
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
        commandRegistry.register(PaletteCommand(id: "tab.jumpToUnread", title: "Jump to Unread Tab", shortcut: "Cmd+Shift+U", category: "Tabs", isAvailable: { [weak self] in
            guard let self else { return false }
            return self.windowSession.groups.flatMap(\.tabs).contains { $0.unreadNotifications > 0 }
        }) { [weak self] in
            self?.jumpToMostRecentUnreadTab()
        })
        commandRegistry.register(PaletteCommand(
            id: "review.submitAll",
            title: "Submit All Review Comments",
            category: "Git",
            isAvailable: { [weak self] in (self?.reviewFileCount ?? 0) >= 2 }
        ) { [weak self] in
            self?.submitAllDiffReviews()
        })
        commandRegistry.register(PaletteCommand(
            id: "session.attach",
            title: "Attach Session…",
            category: "Sessions"
        ) {
            SessionBrowserWindowController.shared.showBrowser()
        })
        commandRegistry.register(PaletteCommand(
            id: "session.detach",
            title: "Detach Session",
            category: "Sessions",
            isAvailable: { [weak self] in self?.focusedPaneHasTrackedSession ?? false }
        ) { [weak self] in
            self?.closeFocusedSessionSurface(killSessions: false)
        })
        commandRegistry.register(PaletteCommand(
            id: "session.kill",
            title: "Kill Session",
            category: "Sessions",
            isAvailable: { [weak self] in self?.focusedPaneHasTrackedSession ?? false }
        ) { [weak self] in
            self?.closeFocusedSessionSurface(killSessions: true)
        })
    }

    private func setupUI() {
        guard let window = self.window,
              let contentView = window.contentView else { return }

        // Create the split container (shared across tabs — we swap its tree)
        let container = SplitContainerView(registry: SurfaceRegistry())
        container.onTargetRatioChange = { [weak self] firstChildID, secondChildID, targetRatio, direction, splitRect in
            self?.handleDividerDrag(
                firstChildFirstLeafID: firstChildID,
                secondChildFirstLeafID: secondChildID,
                targetRatio: targetRatio,
                direction: direction,
                splitRect: splitRect
            )
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

        guard let surfaceID = createManagedSurface(
            tab: tab, app: app, config: config,
            passthroughPwd: tab.pwd, spawnCwd: tab.pwd ?? NSHomeDirectory(), origin: .tab
        ) else {
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

    // MARK: - Session Persistence

    /// Applies `SessionSpawnPlanner`'s decision for a freshly-created
    /// terminal surface. `.passthrough` (the default — feature off, or
    /// `origin == .quickTerminal`) creates the surface exactly as
    /// before this feature existed, via `passthroughPwd` — every
    /// existing call site's pre-feature `pwd` argument, unchanged, so
    /// the OFF path has zero observable difference. `.persistent`
    /// creates it with the synthesized attach command instead, and
    /// records the new session in `tab.sessionRefs` (persisted into
    /// `TabSnapshot.sessionRefs` at save time) and
    /// `SessionSurfaceMap.shared` (so `/agent-event` routing, the
    /// close=kill path below, and `SessionReconnectCoordinator` can all
    /// find it later). `spawnCwd`/`inheritedCwd` are only read when a
    /// plan actually turns out `.persistent`; they have no effect while
    /// the feature is off. `inheritedCwd` (only ever non-nil from
    /// `handleNewSplitNotification`) takes priority — see
    /// `SessionSpawnContext`'s doc comment — since ghostty has no
    /// surface-level pwd getter (only the async `GHOSTTY_ACTION_PWD` ->
    /// `.ghosttySetPwd` report this codebase already tracks into
    /// `tab.pwd`), so `tab.pwd` is the best available approximation of
    /// the split's specific origin surface, not necessarily its exact
    /// live cwd if the tab has multiple panes in different directories.
    private func createManagedSurface(
        tab: Tab,
        app: ghostty_app_t,
        config: ghostty_surface_config_s,
        passthroughPwd: String?,
        spawnCwd: String,
        inheritedCwd: String? = nil,
        origin: SessionSpawnOrigin
    ) -> UUID? {
        let context = SessionSpawnContext(cwd: spawnCwd, inheritedCwd: inheritedCwd, origin: origin)
        switch SessionSpawnPlanner.plan(for: context) {
        case .passthrough:
            return tab.registry.createSurface(app: app, config: config, pwd: passthroughPwd)
        case .persistent(let sessionID, let command):
            let ghosttyPwd = inheritedCwd ?? spawnCwd
            guard let surfaceID = tab.registry.createSurface(app: app, config: config, pwd: ghosttyPwd, command: command) else {
                return nil
            }
            tab.sessionRefs[surfaceID] = SessionRef(sessionID: sessionID)
            SessionSurfaceMap.shared.register(sessionID: sessionID, surfaceID: surfaceID)
            return surfaceID
        }
    }

    /// Explicit-close half of the close=kill / quit=detach contract: a
    /// user-initiated pane/tab close ends the underlying calyx-session
    /// too (rather than leaving it running headless forever), and drops
    /// its now-stale `SessionSurfaceMap` entry and `tab.sessionRefs`
    /// entry so neither routing nor the next snapshot still reference a
    /// leaf that no longer exists. Called from `closeTab(id:)`,
    /// `closeActiveGroup()`, `closeAllTabsInGroup(id:)`, and
    /// `handleCloseSurfaceNotification` right before/alongside
    /// `SurfaceRegistry.destroySurface(_:)` — including reentrant calls
    /// `destroySurface` triggers synchronously via ghostty's
    /// `close_surface` callback, which is exactly why the actual kill
    /// decision is delegated to `SessionCloseKillPolicy` rather than
    /// just checking `hasSession`: a review found this method reachable,
    /// unconditionally, from two unsafe reentrant paths —
    /// `performReconnect` (which destroys the OLD surface to make room
    /// for the reconnected one — must not self-kill) and
    /// `windowWillClose`/quit teardown (must detach, not kill, so the
    /// session survives to be reattached on next launch; `isTerminating`
    /// reuses `isClosingForShutdown`, which `AppDelegate
    /// .markAllControllersClosingForShutdown()` / `windowShouldClose`
    /// both set before any surface is destroyed).
    ///
    /// `isTerminating` (R8-C, r8-fix-spec.md; consolidates r7-
    /// verdicts.md's I1/A2/C2 dormant discriminator-mismatch finding):
    /// REQUIRED (R10-C item 3, r10-fix-spec.md, no default; the stale
    /// doc this replaces claimed "every caller except `windowWillClose`"
    /// read `isClosingForShutdown` via a `nil` default, but in fact 4 of
    /// this method's 5 call sites already passed an explicit value
    /// before this fix, only `closeSurfaceAndCleanUp` relied on the
    /// default). `tearDownSurfaces` (R8-F) passes its own `isTerminating`
    /// parameter straight through for `closeTab`/`closeActiveGroup`/
    /// `closeAllTabsInGroup` (always `false`) and `windowWillClose`
    /// (its own already-computed discriminator); `closeSurfaceAndCleanUp`
    /// now passes this window's own `isClosingForShutdown` explicitly
    /// too, so the outer "is the app actually terminating" gate and this
    /// policy call always visibly agree, with no caller left relying on
    /// an implicit default.
    private func killSessionIfPersistent(tab: Tab, surfaceID: UUID, isTerminating: Bool) {
        let sessionID = SessionSurfaceMap.shared.sessionID(for: surfaceID)
        guard SessionCloseKillPolicy.shouldKill(
            hasSession: sessionID != nil,
            isTerminating: isTerminating,
            isReconnectSwap: reconnectingSurfaceIDs.contains(surfaceID)
        ), let sessionID else {
            return
        }
        SessionSurfaceMap.shared.unregister(sessionID: sessionID)
        tab.sessionRefs[surfaceID] = nil
        sessionReconnectCoordinator.markClosed(sessionID: sessionID)
        SessionKillTracker.track {
            await SessionDaemonClient.shared.kill(id: sessionID)
        }
    }

    /// `session.detach` command palette action's per-surface half:
    /// drops `surfaceID`'s `SessionSurfaceMap`/`tab.sessionRefs`
    /// tracking exactly like `killSessionIfPersistent` above, but never
    /// calls `daemonClient.kill` — the underlying calyx-session keeps
    /// running headless, reattachable later from the session browser or
    /// a future restore. A no-op for a surface with no tracked session.
    ///
    /// Routes through `SessionCloseKillPolicy.shouldDetach` (F9, V10,
    /// r4-fix-spec.md) exactly like `killSessionIfPersistent` routes
    /// through `shouldKill`, replacing the inline `!isClosingForShutdown`
    /// check this method used to have (review finding: it used to have
    /// no guard at all) so detach isn't the one call site still reasoning
    /// about reentrancy/teardown state ad hoc. During quit/last-window-close
    /// teardown, `tab.sessionRefs` must survive untouched into the
    /// snapshot `applicationWillTerminate`/`windowWillClose` save, not be
    /// cleared here first: without that, a `.giveUp`/`session.detach`
    /// teardown racing Cmd+Q could clear `SessionRef` before that
    /// snapshot is built, permanently losing this session's tracking
    /// even though it survives in the daemon.
    ///
    /// R10-C item 3 (r10-fix-spec.md): unlike `killSessionIfPersistent`,
    /// takes no `isTerminating` parameter, since every call site left it
    /// at its default, so it was dead: this always reads this window's own
    /// `isClosingForShutdown` directly instead.
    private func detachSessionIfPersistent(tab: Tab, surfaceID: UUID) {
        let sessionID = SessionSurfaceMap.shared.sessionID(for: surfaceID)
        guard SessionCloseKillPolicy.shouldDetach(
            hasSession: sessionID != nil,
            isTerminating: isClosingForShutdown,
            isReconnectSwap: reconnectingSurfaceIDs.contains(surfaceID)
        ), let sessionID else {
            return
        }
        SessionSurfaceMap.shared.unregister(sessionID: sessionID)
        tab.sessionRefs[surfaceID] = nil
        sessionReconnectCoordinator.markClosed(sessionID: sessionID)
    }

    /// R8-F (r8-fix-spec.md, item F1): shared per-tab teardown loop for
    /// `closeTab`/`closeActiveGroup`/`closeAllTabsInGroup`/`windowWillClose`,
    /// which used to each run their own copy of "kill every persistent
    /// surface, then destroy it". `isTerminating` is passed straight
    /// through to `killSessionIfPersistent` (R8-C): an explicit tab/
    /// group close always passes `false` (never mid-quit at this point,
    /// `isClosingForShutdown` is still unset here even for the last-
    /// window case, see `closeLastWindow`'s own doc comment for when it
    /// gets set); `windowWillClose` passes its own already-computed
    /// `isAppActuallyTerminating`, so its outer gate and this loop's
    /// inner kill decision always read the same value.
    private func tearDownSurfaces(in tab: Tab, isTerminating: Bool) {
        for surfaceID in tab.registry.allIDs {
            killSessionIfPersistent(tab: tab, surfaceID: surfaceID, isTerminating: isTerminating)
            tab.registry.destroySurface(surfaceID)
        }
    }

    /// Pre-teardown quit-confirmation gate shared by every close path
    /// that can empty the last managed window: bails out early (with
    /// `true`, nothing to confirm) unless `AppDelegate.closingWouldTerminate`
    /// says closing this window would terminate the app AND the quit
    /// hasn't already been confirmed once (`isTerminationConfirmed`) —
    /// avoids double-prompting when, e.g., a Cmd+Q already confirmed
    /// termination and this close path is now running as part of that
    /// same teardown. `mode` selects `confirmQuitIfNeeded`'s wording for
    /// whichever semantics this particular close uses (kill vs. detach).
    /// Returns `false` only when the user cancelled the prompt.
    private func confirmQuitBeforeCloseIfWouldTerminate(mode: AppDelegate.ConfirmQuitMode = .killProcesses) -> Bool {
        guard let appDelegate = NSApp.delegate as? AppDelegate,
              appDelegate.closingWouldTerminate(self),
              !appDelegate.isTerminationConfirmed else {
            return true
        }
        return appDelegate.confirmQuitIfNeeded(mode)
    }

    /// Marks `AppDelegate.isTerminationConfirmed` so the subsequent
    /// `windowShouldClose` -> `applicationShouldTerminate` cascade
    /// triggered by `window?.close()` doesn't prompt a second time for
    /// the same already-confirmed quit. A no-op unless closing this
    /// window would actually terminate the app (see `closingWouldTerminate`).
    private func markTerminationConfirmedIfWouldTerminate() {
        guard let appDelegate = NSApp.delegate as? AppDelegate,
              appDelegate.closingWouldTerminate(self) else { return }
        appDelegate.isTerminationConfirmed = true
    }

    /// R10-C item 4 (r10-fix-spec.md): the two-statement pair shared,
    /// identically, by `closeLastWindow`'s default
    /// (`markTerminationConfirmed: true`) path and `windowShouldClose`'s
    /// success path. Marks termination already confirmed (a no-op
    /// unless closing this window would actually terminate the app, see
    /// `markTerminationConfirmedIfWouldTerminate`), THEN sets
    /// `isClosingForShutdown`. Order matters: `isClosingForShutdown`
    /// must be set eagerly, before `window?.close()` (or the caller's
    /// own subsequent teardown) runs, see `closeLastWindow`'s own doc
    /// comment for why.
    private func markTerminationConfirmedAndSetClosingForShutdown() {
        markTerminationConfirmedIfWouldTerminate()
        isClosingForShutdown = true
    }

    /// Shared `.windowShouldClose` case body (F7/F8, r4-fix-spec.md) for
    /// the four close paths that can empty the last managed window
    /// (`closeTab`, `closeActiveGroup`, `closeAllTabsInGroup`,
    /// `closeSurfaceAndCleanUp`): marks termination confirmed (when
    /// `markTerminationConfirmed`, a no-op unless closing this window
    /// would actually terminate the app, see `markTerminationConfirmedIfWouldTerminate`),
    /// sets `isClosingForShutdown` eagerly, then closes the window.
    /// `isClosingForShutdown` must be set BEFORE `window?.close()`,
    /// exactly like `windowShouldClose`'s own eager set: without this,
    /// `windowDidExitFullScreen`'s stale-snapshot guard (which checks
    /// `isClosingForShutdown`) is dead code during this teardown, and
    /// the fullscreen tracking flags/frame get incorrectly cleared
    /// mid-close.
    private func closeLastWindow(markTerminationConfirmed: Bool = true) {
        if markTerminationConfirmed {
            markTerminationConfirmedAndSetClosingForShutdown()
        } else {
            isClosingForShutdown = true
        }
        window?.close()
    }

    /// True when `tab` is the sole tab of the sole group of this window
    /// AND has exactly one pane (a single, unsplit leaf) — i.e. closing
    /// this one pane empties the tab, the group, and the window all at
    /// once. Used by `closeFocusedSessionSurface`/`handleReconnectGiveUp`
    /// to decide whether their pre-teardown confirm-quit gate applies.
    private func isLastPaneEverywhere(tab: Tab, group: TabGroup) -> Bool {
        !tab.splitTree.isEmpty && !tab.splitTree.isSplit
            && group.tabs.count == 1
            && windowSession.groups.count == 1
    }

    /// `session.detach`/`session.kill` command palette actions' shared
    /// implementation: tears down only the focused pane's surface, via
    /// the same single-surface `closeSurfaceAndCleanUp` path
    /// `closeDeadPersistentSessionSurface` uses, instead of the whole
    /// tab. Fixes a review finding: both commands used to call
    /// `closeTab(id:)` (with a since-removed `killSessions` parameter),
    /// which destroys EVERY surface in the active tab even though
    /// `focusedPaneHasTrackedSession` only checks the ONE focused pane
    /// — invoking either command on a
    /// multi-pane tab silently tore down untracked sibling panes too.
    /// A no-op if there is no active tab, no focused leaf, or the
    /// focused leaf has no tracked session (re-checked here, not just
    /// via the palette's `isAvailable` gate, in case focus moved to an
    /// untracked pane between the palette listing this command and the
    /// user invoking it).
    ///
    /// When this is the last pane everywhere (`isLastPaneEverywhere`),
    /// gates on `confirmQuitBeforeCloseIfWouldTerminate` BEFORE tearing
    /// anything down — cancelling leaves the pane/session untouched.
    /// The flag itself is not set here (see `closeSurfaceAndCleanUp`'s
    /// `markTerminationConfirmedOnWindowClose` parameter): it's set only
    /// once teardown actually reaches the `.windowShouldClose` case, so
    /// a reentrant/interrupted teardown that doesn't reach that point
    /// never leaves `isTerminationConfirmed` stuck `true`.
    ///
    /// F2 (V02, CRITICAL, r4-fix-spec.md): inserts `tab.id` into
    /// `closingTabIDs` BEFORE consulting the confirm-quit gate (mirroring
    /// `closeTab`'s own insert-then-confirm-then-remove-on-cancel
    /// pattern), so a synchronous reentrant `close_surface` callback for
    /// this same tab, whether firing mid-modal or from inside
    /// `closeSurfaceAndCleanUp`'s own `destroySurface` call below, hits
    /// that method's reentrancy guard instead of tearing the tab down a
    /// second time. `closeSurfaceAndCleanUp` is told
    /// `callerAlreadyClaimedClosingTabIDs: true` since this method (not
    /// that one) owns the insert/remove lifecycle for this call.
    private func closeFocusedSessionSurface(killSessions: Bool) {
        guard let group = windowSession.activeGroup,
              let tab = group.activeTab,
              let surfaceID = tab.splitTree.focusedLeafID,
              tab.sessionRefs[surfaceID] != nil else { return }
        guard !closingTabIDs.contains(tab.id) else { return }

        closingTabIDs.insert(tab.id)

        let isLastPane = isLastPaneEverywhere(tab: tab, group: group)
        if isLastPane {
            guard confirmQuitBeforeCloseIfWouldTerminate(mode: killSessions ? .killProcesses : .detachOnly) else {
                closingTabIDs.remove(tab.id)
                return
            }
        }

        closeSurfaceAndCleanUp(
            tab: tab, group: group, surfaceID: surfaceID,
            killSessions: killSessions,
            markTerminationConfirmedOnWindowClose: isLastPane,
            callerAlreadyClaimedClosingTabIDs: true
        )
        closingTabIDs.remove(tab.id)
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
            onComposeOverlayEscapePressed: { [weak self] in self?.forwardEscapeToTerminal() },
            totalReviewCommentCount: totalReviewCommentCount,
            reviewFileCount: reviewFileCount
        )
    }

    private func refreshHostingView() {
        hostingView?.rootView = buildMainContentView()
    }

    private func recreateHostingView() {
        guard let contentView = window?.contentView else { return }
        let mainContent = buildMainContentView()
        let newHosting = NSHostingView(rootView: mainContent)
        newHosting.frame = contentView.bounds
        newHosting.autoresizingMask = [.width, .height]
        contentView.addSubview(newHosting)
        newHosting.layoutSubtreeIfNeeded()
        hostingView?.removeFromSuperview()
        self.hostingView = newHosting
    }

    // MARK: - Split Container Management

    private func rebuildSplitContainer() {
        guard let tab = activeTab else { return }
        if let container = splitContainerView {
            container.updateRegistry(tab.registry)
        } else {
            let container = SplitContainerView(registry: tab.registry)
            container.onTargetRatioChange = { [weak self] firstChildID, secondChildID, targetRatio, direction, splitRect in
                self?.handleDividerDrag(
                    firstChildFirstLeafID: firstChildID,
                    secondChildFirstLeafID: secondChildID,
                    targetRatio: targetRatio,
                    direction: direction,
                    splitRect: splitRect
                )
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

        guard let surfaceID = createManagedSurface(
            tab: tab, app: app, config: config,
            passthroughPwd: nil, spawnCwd: activeTab?.pwd ?? NSHomeDirectory(), origin: .tab
        ) else {
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
            guard confirmQuitBeforeCloseIfWouldTerminate() else {
                closingTabIDs.remove(tabID)
                return
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

        // Destroy all surfaces in the tab, killing any persistent
        // session each was attached to (R8-F, tearDownSurfaces): an
        // explicit tab close, unlike quitting the app, ends the session
        // rather than detaching it. (`session.detach`/`session.kill` no
        // longer route through this method, see `closeFocusedSessionSurface`.)
        tearDownSurfaces(in: tab, isTerminating: false)

        let result = windowSession.removeTab(id: tabID, fromGroup: group.id)

        switch result {
        case .switchedTab, .switchedGroup:
            activateCurrentTab()
        case .windowShouldClose:
            closeLastWindow()
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

        guard let surfaceID = createManagedSurface(
            tab: tab, app: app, config: config,
            passthroughPwd: nil, spawnCwd: activeTab?.pwd ?? NSHomeDirectory(), origin: .tab
        ) else {
            logger.error("Failed to create surface for new group")
            return
        }

        tab.splitTree = SplitTree(leafID: surfaceID)

        // Pause current tab
        activeTab?.registry.pauseAll()

        let newColor = TabGroupColor.nextColor(excluding: windowSession.groups.map { $0.color })
        let group = TabGroup(
            name: WindowSession.nextDefaultGroupName(existing: windowSession.groups.map(\.name)),
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
            guard confirmQuitBeforeCloseIfWouldTerminate() else {
                for tabID in tabIDs {
                    closingTabIDs.remove(tabID)
                }
                return
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

        // Destroy all surfaces in all tabs of this group (killing any
        // persistent sessions, see closeTab(id:)'s equivalent comment,
        // R8-F tearDownSurfaces)
        for tab in group.tabs {
            tearDownSurfaces(in: tab, isTerminating: false)
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
            closeLastWindow()
            requestSave()
        }
    }

    /// Not `private` (P4 round-4 fix RED phase): `CalyxWindowControllerCloseArmsTests`
    /// calls this directly to verify `isClosingForShutdown` timing (F7)
    /// without needing a live `MainContentView`/`onCloseAllTabsInGroup`
    /// SwiftUI wiring to reach it, matching this file's existing
    /// `handleSessionReconnectDecision` precedent for the same reason.
    func closeAllTabsInGroup(id groupID: UUID) {
        guard let group = windowSession.groups.first(where: { $0.id == groupID }) else { return }

        let wasActiveGroup = (groupID == windowSession.activeGroupID)
        let tabIDs = group.tabs.map { $0.id }
        for tabID in tabIDs {
            closingTabIDs.insert(tabID)
        }

        // Quit confirmation: if this is the last group, closing it would terminate
        // the app. Confirm BEFORE destroying anything.
        if windowSession.groups.count == 1 {
            guard confirmQuitBeforeCloseIfWouldTerminate() else {
                for tabID in tabIDs {
                    closingTabIDs.remove(tabID)
                }
                return
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
            tearDownSurfaces(in: tab, isTerminating: false)
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
            closeLastWindow()
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

    private func forwardEscapeToTerminal() {
        guard let tab = activeTab, case .terminal = tab.content else { return }
        let targetID = composeOverlayTargetSurfaceID ?? tab.splitTree.focusedLeafID
        guard let targetID,
              let controller = tab.registry.controller(for: targetID) else { return }

        var escEvent = ghostty_input_key_s()
        escEvent.action = GHOSTTY_ACTION_PRESS
        escEvent.keycode = 0x35
        escEvent.mods = GHOSTTY_MODS_NONE
        escEvent.consumed_mods = GHOSTTY_MODS_NONE
        escEvent.text = nil
        escEvent.unshifted_codepoint = 0
        escEvent.composing = false
        controller.sendKey(escEvent)

        escEvent.action = GHOSTTY_ACTION_RELEASE
        controller.sendKey(escEvent)
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

    private func handleDividerDrag(
        firstChildFirstLeafID: UUID,
        secondChildFirstLeafID: UUID,
        targetRatio: Double,
        direction: SplitDirection,
        splitRect: CGRect
    ) {
        guard let tab = activeTab,
              let container = splitContainerView,
              container.bounds.width > 0,
              container.bounds.height > 0 else { return }

        // Bound the absolute ratio against the LOCAL split rect, not the
        // outer container — otherwise dragging the inner divider of a
        // nested split would resize the wrong axis fraction (Bug C).
        let localSize = splitRect.size
        guard localSize.width > 0, localSize.height > 0 else { return }

        tab.splitTree = tab.splitTree.setRatio(
            firstChildFirstLeafID: firstChildFirstLeafID,
            secondChildFirstLeafID: secondChildFirstLeafID,
            direction: direction,
            to: targetRatio,
            bounds: localSize,
            minSize: 50
        )
        container.updateLayout(tree: tab.splitTree)
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
        center.addObserver(self, selector: #selector(handleProgressReportNotification(_:)),
                           name: .ghosttyProgressReport, object: nil)
        center.addObserver(self, selector: #selector(handleDesktopNotification(_:)),
                           name: .ghosttyDesktopNotification, object: nil)
        center.addObserver(self, selector: #selector(handleGotoTabNotification(_:)),
                           name: .ghosttyGotoTab, object: nil)
        center.addObserver(self, selector: #selector(handleConfirmClipboardNotification(_:)),
                           name: .ghosttyConfirmClipboard, object: nil)
        center.addObserver(self, selector: #selector(handleFocusSurfaceNotification(_:)),
                           name: .calyxFocusSurface, object: nil)
        center.addObserver(self, selector: #selector(handleSurfaceDestroyedForAgentMonitor(_:)),
                           name: .calyxSurfaceDestroyed, object: nil)
        center.addObserver(self, selector: #selector(handleShowChildExitedNotification(_:)),
                           name: .ghosttyShowChildExited, object: nil)
        center.addObserver(self, selector: #selector(handleConfirmingQuitDidEnd(_:)),
                           name: .calyxConfirmingQuitDidEnd, object: nil)
    }

    // MARK: - Screen State Polling (Herdr Layer 2)

    /// Starts the window-lifetime poll loop that feeds `ScreenStateClassifier`
    /// results into `AgentRegistry.handleScreenClassification` — the
    /// fallback for panes hooks haven't reported on (or aren't wired up
    /// at all). Mirrors `AgentRegistry.sweepTask`'s `while !Task.isCancelled`
    /// shape, but — unlike that task, started/stopped by IPC server
    /// lifecycle — this one runs for the whole life of the window: there's
    /// no property-observation hook on `WindowSession.sidebarMode` /
    /// `showSidebar` to react to (they're mutated from many call sites:
    /// palette commands, the sidebar's SwiftUI binding, toggles), so each
    /// tick instead checks the relevant gates itself and skips the
    /// (expensive — `ghostty_surface_read_text` is documented as costly)
    /// per-surface read entirely unless warranted.
    private func startScreenPollTask() {
        screenPollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                self?.pollScreenClassificationIfAgentsSidebarVisible()
            }
        }
    }

    /// Three gates, cheapest first, before the expensive per-surface
    /// `ghostty_surface_read_text` call:
    /// (a) `AgentRegistry.isServerRunning` — IPC disabled means no
    ///     Agents sidebar row can be shown at all, so classifying screens
    ///     into the registry in the background would only produce
    ///     entries that immediately (and confusingly) populate the
    ///     sidebar the moment IPC is re-enabled.
    /// (b) Per-surface: a `.hooks`-sourced entry is authoritative —
    ///     `handleScreenClassification` already no-ops for one, but
    ///     skipping here avoids the read itself, not just its effect.
    /// (c) `AgentRegistry.isAgentsSidebarVisibleAnywhere` (rather than
    ///     this window's own `sidebarMode`/`showSidebar`) — see that
    ///     property's doc comment for the cross-window gap this closes.
    private func pollScreenClassificationIfAgentsSidebarVisible() {
        guard AgentRegistry.shared.isServerRunning else { return }
        guard AgentRegistry.shared.isAgentsSidebarVisibleAnywhere else { return }

        for group in windowSession.groups {
            for tab in group.tabs {
                for surfaceID in tab.registry.allIDs {
                    guard AgentRegistry.shared.entries[surfaceID]?.source != .hooks else { continue }
                    guard let surface = tab.registry.controller(for: surfaceID)?.surface else { continue }
                    guard let bottomText = GhosttySurfaceSelectionReader(surface: surface)
                        .readActiveBottomText(rows: 12) else { continue }

                    let kind = AgentRegistry.shared.entries[surfaceID]?.kind ?? AgentEntry.claudeCodeKind
                    let state = ScreenStateClassifier.classify(bottomText: bottomText, kind: kind)
                    AgentRegistry.shared.handleScreenClassification(surfaceID: surfaceID, state: state)
                }
            }
        }
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

        guard let newSurfaceID = createManagedSurface(
            tab: tab, app: app, config: config,
            passthroughPwd: nil, spawnCwd: tab.pwd ?? NSHomeDirectory(), inheritedCwd: tab.pwd, origin: .tab
        ) else {
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

    /// R6-A (r6-fix-spec.md items 1/2, r5-verdicts.md V2/V3): defers
    /// (rather than immediately tearing down) a `close_surface`
    /// notification while `AppDelegate.isConfirmingQuit` is true, via
    /// the same `deferOrRun` choke point `handleShowChildExitedNotification`/
    /// `handleSessionReconnectDecision` use, mirroring their existing
    /// deferral instead of relying on ghostty's own keypress self-
    /// healing (`Surface.close()` refires on any encodable keypress
    /// while child_exited). Replayed by `drainDeferredReconnectEvents()`
    /// once the gate clears. Deliberately does NOT also bail on
    /// `isShuttingDown` (unlike `handleSessionReconnectDecision`/
    /// `handleReconnectGiveUp`/`processChildExited`): `closeSurfaceAndCleanUp`'s
    /// own `closingTabIDs` reentrancy guard already protects the actual-
    /// teardown case (see that method's doc comment), and this
    /// notification also fires for an ordinary, unrelated pane
    /// genuinely closing during quit, which must still tear down
    /// normally rather than be silently dropped.
    @objc private func handleCloseSurfaceNotification(_ notification: Notification) {
        guard let surfaceView = notification.object as? SurfaceView else { return }
        deferOrRun(.closeSurface(surfaceView: surfaceView)) { [weak self] in
            self?.processCloseSurface(surfaceView: surfaceView)
        }
    }

    /// The actual `close_surface` teardown `handleCloseSurfaceNotification`
    /// runs immediately, or `drainDeferredReconnectEvents()` replays
    /// later. Finds the tab that owns `surfaceView` (may be a background
    /// tab) and, since this notification fires for every ghostty-driven
    /// surface close, including a persistent-session pane whose user,
    /// having seen `SessionReconnectCoordinator` give up (or having
    /// decided not to wait), presses a key on the dead pane, ghostty's
    /// own close_surface callback then fires with process_alive=false
    /// (see SessionReconnectCoordinator.swift's header comment). In
    /// every case this notification fires, the pane is being explicitly
    /// torn down, so `closeSurfaceAndCleanUp` kills the underlying
    /// session the same as
    /// closeTab(id:)/closeActiveGroup()/closeAllTabsInGroup(id:) do. A
    /// stale surfaceView (already closed some other way) is a safe
    /// no-op via `findTab`'s lookup.
    private func processCloseSurface(surfaceView: SurfaceView) {
        guard let (owningTab, owningGroup) = findTab(for: surfaceView) else { return }
        guard let surfaceID = owningTab.registry.id(for: surfaceView) else { return }
        closeSurfaceAndCleanUp(tab: owningTab, group: owningGroup, surfaceID: surfaceID)
    }

    /// Shared surface-teardown sequence: kill (or, when `killSessions`
    /// is `false`, merely detach — see `detachSessionIfPersistent`'s
    /// doc comment) any persistent session attached to `surfaceID`,
    /// remove the leaf from `tab`'s split tree, destroy the surface,
    /// and — if that leaves the tab with no leaves at all — remove the
    /// tab (closing the window if it was the last one). Used by:
    /// `handleCloseSurfaceNotification` (a ghostty-driven close, e.g.
    /// `exit` in a plain pane, or a key press acknowledging a dead
    /// persistent-session pane — kill semantics, default);
    /// `closeDeadPersistentSessionSurface` (`SessionReconnectCoordinator`
    /// confirming, via the daemon, that a persistent session's process
    /// really did exit — kill semantics, default); `handleReconnectGiveUp`
    /// (reconnect attempts exhausted — detach semantics,
    /// `killSessions: false`, since the daemon may still be legitimately
    /// running); and `closeFocusedSessionSurface` (`session.detach`/
    /// `session.kill` command palette actions, either semantics per
    /// which command fired).
    ///
    /// Quit confirmation, when needed, is the caller's responsibility
    /// BEFORE calling this method (see `confirmQuitBeforeCloseIfWouldTerminate`
    /// and each caller above) — this method only marks
    /// `AppDelegate.isTerminationConfirmed` (via
    /// `markTerminationConfirmedOnWindowClose`, when the caller already
    /// confirmed) once teardown actually reaches the `.windowShouldClose`
    /// case below, so a reentrant/interrupted teardown that never
    /// reaches that point never leaves the flag stuck `true`.
    ///
    /// `callerAlreadyClaimedClosingTabIDs` (F2, r4-fix-spec.md): set by
    /// `closeFocusedSessionSurface`/`handleReconnectGiveUp`, the two
    /// callers that insert `tab.id` into `closingTabIDs` themselves
    /// BEFORE calling this method (so a mid-modal reentrant close can
    /// already be blocked before teardown starts; see each of their doc
    /// comments). Without this, this method's OWN reentrancy guard right
    /// below would immediately bail out on their very first, legitimate
    /// call, since it can't otherwise distinguish "the caller already
    /// claimed this tab and is calling me directly" from "someone else
    /// is mid-teardown and this is an unwanted reentrant call". Every
    /// other caller (`handleCloseSurfaceNotification`,
    /// `closeDeadPersistentSessionSurface`) takes the default `false`
    /// and is subject to the guard exactly as before.
    ///
    /// R6-I (r6-fix-spec.md, altitude finding I1): the pairing contract
    /// is that `callerAlreadyClaimedClosingTabIDs: true` implies
    /// `closingTabIDs.contains(tab.id)` is ALREADY true by the time this
    /// method is called, checked by a DEBUG-only assertion below. A
    /// caller that passes `true` without having actually inserted first
    /// would otherwise silently no-op (this method's own guard would
    /// never fire, but neither would the reentrancy protection it
    /// exists for); both current callers were verified correctly
    /// paired (see round 5's I1 finding).
    private func closeSurfaceAndCleanUp(
        tab: Tab,
        group: TabGroup,
        surfaceID: UUID,
        killSessions: Bool = true,
        markTerminationConfirmedOnWindowClose: Bool = false,
        callerAlreadyClaimedClosingTabIDs: Bool = false
    ) {
        // If closeTab/closeActiveGroup/closeAllTabsInGroup is already
        // driving this tab's teardown, this call is a reentrant one —
        // ghostty's close_surface callback firing synchronously from
        // inside `destroySurface`'s `requestClose()` — and that owning
        // method's own loop already kills/detaches every surface and
        // will remove the tab/group wholesale once it finishes.
        // Checked first (review finding), before any of the kill/
        // detach/split-tree work below, which would otherwise run
        // redundantly for every surface in the tab being closed.
        #if DEBUG
        assert(!callerAlreadyClaimedClosingTabIDs || closingTabIDs.contains(tab.id),
               "callerAlreadyClaimedClosingTabIDs was true but tab.id is not actually in " +
               "closingTabIDs, the caller must insert it BEFORE calling this method, see " +
               "that parameter's own doc comment")
        #endif
        guard callerAlreadyClaimedClosingTabIDs || !closingTabIDs.contains(tab.id) else { return }

        if killSessions {
            // R10-C item 3 (r10-fix-spec.md): isTerminating is now
            // required, passed explicitly rather than relying on the
            // (removed) default of this window's own isClosingForShutdown.
            killSessionIfPersistent(tab: tab, surfaceID: surfaceID, isTerminating: isClosingForShutdown)
        } else {
            detachSessionIfPersistent(tab: tab, surfaceID: surfaceID)
        }
        let (newTree, focusTarget) = tab.splitTree.remove(surfaceID)
        tab.registry.destroySurface(surfaceID)
        tab.splitTree = newTree

        // Below runs only for process-initiated closes (e.g. `exit` command)
        if tab.splitTree.isEmpty {
            let wasActiveTab = (tab.id == activeTab?.id)
            let result = windowSession.removeTab(id: tab.id, fromGroup: group.id)
            if wasActiveTab {
                switch result {
                case .switchedTab, .switchedGroup:
                    activateCurrentTab()
                case .windowShouldClose:
                    closeLastWindow(markTerminationConfirmed: markTerminationConfirmedOnWindowClose)
                }
            } else {
                refreshHostingView()
            }
            requestSave()
            return
        }

        if tab.id == activeTab?.id {
            splitContainerView?.updateLayout(tree: tab.splitTree)
            if let focusID = focusTarget, let focusView = tab.registry.view(for: focusID) {
                window?.makeFirstResponder(focusView)
            }
            requestSave()
        }
    }

    // MARK: - Session Reconnect

    /// `GHOSTTY_ACTION_SHOW_CHILD_EXITED` for a persistent-session
    /// surface: hand off to `sessionReconnectCoordinator`, which queries
    /// the daemon (macOS never reports a trustworthy exit code for this
    /// action — see `SessionDaemonClient.swift`'s header comment) and
    /// decides reconnect vs. close vs. give up via
    /// `handleSessionReconnectDecision`. A no-op for an ordinary
    /// (non-persistent-session) surface, since the coordinator's own
    /// `surfaceMap.sessionID(for:)` lookup finds nothing for one.
    ///
    /// Also a no-op once `isClosingForShutdown` is set (review finding):
    /// `windowWillClose`'s teardown destroys every surface in the
    /// window, which can itself trigger this same notification for a
    /// persistent-session surface — without this guard, that could
    /// enqueue a `.giveUp`/`.closePane` decision that races the
    /// in-flight quit teardown and reaches `detachSessionIfPersistent`/
    /// `killSessionIfPersistent` after (or racing) the snapshot save,
    /// even though `SessionCloseKillPolicy`/`detachSessionIfPersistent`'s
    /// own `isClosingForShutdown` checks are the last line of defense
    /// against that outcome.
    ///
    /// F4 (V05, HIGH, r4-fix-spec.md): while `isConfirmingQuit` is true,
    /// defers this event instead of dropping it (see
    /// `deferredReconnectEvents`'s doc comment), replayed once the gate
    /// clears via `drainDeferredReconnectEvents()`. `processChildExited`'s
    /// own entry guard (R6-A item 3) covers the shutdown-suppression
    /// case that used to live here, so this method itself only needs
    /// `deferOrRun`'s isConfirmingQuit choke point.
    @objc private func handleShowChildExitedNotification(_ notification: Notification) {
        guard let surfaceView = notification.object as? SurfaceView else { return }
        guard belongsToThisWindow(surfaceView) else { return }
        deferOrRun(.childExited(surfaceView: surfaceView)) { [weak self] in
            self?.processChildExited(surfaceView: surfaceView)
        }
    }

    /// R6-A (r6-fix-spec.md item 3): bails out while this window or the
    /// app itself is shutting down (`isShuttingDown`), replacing the
    /// narrower `isClosingForShutdown`-only guard that used to live in
    /// `handleShowChildExitedNotification`. `windowWillClose`'s teardown
    /// intentionally preserves tracking state into the snapshot, so
    /// kicking off a fresh reconnect decision on top of that is both
    /// unnecessary and dangerous (r5-verdicts.md V5).
    ///
    /// Not `private` (P4 round-16 fix RED phase, mirroring
    /// `handleSessionReconnectDecision`'s own "Not `private`" doc
    /// comment): `CalyxWindowControllerChildExitedTasksTests` calls
    /// this directly to drive `childExitedTasks`'s insert without
    /// needing a real `GHOSTTY_ACTION_SHOW_CHILD_EXITED` notification
    /// and a `SurfaceView` actually attached to the window (which
    /// `handleShowChildExitedNotification`'s `belongsToThisWindow`
    /// guard would otherwise require).
    func processChildExited(surfaceView: SurfaceView) {
        guard !isShuttingDown else { return }
        guard let surfaceID = findTab(for: surfaceView)?.0.registry.id(for: surfaceView) else { return }

        // R14-B sweep addendum item 2 (r14-fix-spec.md): tracked in
        // `childExitedTasks`, cancelled alongside its `diffTasks`/
        // `expandTasks` siblings in `windowWillClose`, instead of being
        // left as an untracked fire-and-forget `Task`.
        //
        // R16-2 (r16-fix-spec.md): cancel-before-replace guards against
        // a same-key re-insert leaking the previous Task (cheap
        // insurance even though surfaceIDs are one-shot in practice);
        // the Task itself removes its own entry once it completes,
        // mirroring `expandTasks[hash]`'s self-removing Task
        // (`expandCommit(hash:)`) -- otherwise a completed entry is
        // retained forever.
        childExitedTasks[surfaceID]?.cancel()
        childExitedTasks[surfaceID] = Task { [weak self] in
            guard let self else { return }
            await self.sessionReconnectCoordinator.childExited(surfaceID: surfaceID)
            self.childExitedTasks.removeValue(forKey: surfaceID)
        }
    }

    /// R6-A (r6-fix-spec.md item 4): single choke point pairing the
    /// isConfirmingQuit guard with the deferred-event enqueue, so a
    /// future handler cannot separate them (altitude finding I3). Runs
    /// `body` immediately unless `AppDelegate.isConfirmingQuit` is true,
    /// in which case `event` is appended to `deferredReconnectEvents`
    /// instead (replayed once the gate clears, see
    /// `drainDeferredReconnectEvents`'s doc comment). A replay that
    /// re-enters this same primitive (directly, or via a public handler
    /// that calls it) re-defers instead of applying early when it lands
    /// during a second, already-active modal (r5-verdicts.md V1's back-
    /// to-back-modals case).
    private func deferOrRun(_ event: DeferredReconnectEvent, _ body: () -> Void) {
        guard !((NSApp.delegate as? AppDelegate)?.isConfirmingQuit ?? false) else {
            deferredReconnectEvents.append(event)
            return
        }
        body()
    }

    /// Replays events deferred by `handleShowChildExitedNotification`/
    /// `handleSessionReconnectDecision`/`handleCloseSurfaceNotification`
    /// while `AppDelegate.isConfirmingQuit` was `true`, once the gate
    /// clears. Called from that flag's own `didSet` (see its doc
    /// comment), which covers both the real `confirmQuitIfNeeded` return
    /// path and the `_setConfirmingQuitForTesting` test seam.
    ///
    /// R6-A (r6-fix-spec.md items 2/3, r5-verdicts.md V1/V5): scheduled
    /// on a fresh MainActor turn (rather than run synchronously inside
    /// the `didSet`) so the caller's own stack (e.g.
    /// `confirmQuitIfNeeded` -> `windowShouldClose`) has fully unwound,
    /// and its own post-modal bookkeeping (e.g. `closingTabIDs.subtract`)
    /// has run, before any replay lands. A deferred event whose surface
    /// no longer resolves in this window (closed some other way while
    /// the gate was up) is a safe no-op: `findTab`/`findTabAndGroup`
    /// (reached via `processChildExited`/`handleSessionReconnectDecision`'s
    /// own existing lookups) already treat a stale ID that way.
    @objc private func handleConfirmingQuitDidEnd(_ notification: Notification) {
        Task { @MainActor [weak self] in
            self?.drainDeferredReconnectEvents()
        }
    }

    /// R6-A (r6-fix-spec.md item 3): bails out entirely, without
    /// touching the queue, while this window or the app itself is
    /// shutting down (`isShuttingDown`): replaying on top of quit
    /// teardown that already preserved tracking state into the snapshot
    /// is both unnecessary and dangerous (r5-verdicts.md V5).
    ///
    /// R8-G item G4 (r8-fix-spec.md): all three cases below follow the
    /// SAME single pattern, replaying exactly what a live, real-time
    /// occurrence of that event would have done, with the SAME gating.
    /// For `.decision`, that means calling the public
    /// `handleSessionReconnectDecision` handler directly: its own
    /// `isShuttingDown` guard re-applies "for free" before it re-enters
    /// `deferOrRun`. For `.childExited`/`.closeSurface`, it means
    /// calling their PRIVATE processing function
    /// (`processChildExited`/`processCloseSurface`) wrapped in
    /// `deferOrRun` here, rather than their `@objc` public handler
    /// (`handleShowChildExitedNotification`/`handleCloseSurfaceNotification`),
    /// since those need an actual `Notification` to unwrap and this
    /// call site already has the unwrapped `SurfaceView`; that
    /// difference is purely mechanical, NOT a gating difference, since
    /// each public handler's own gating lives in the exact function this
    /// replays: `processChildExited` re-checks `isShuttingDown` itself
    /// (so it's exactly as gated as `handleShowChildExitedNotification`,
    /// which calls nothing else first), and `handleCloseSurfaceNotification`
    /// deliberately has NO `isShuttingDown` gate of its own (see its own
    /// doc comment), so `processCloseSurface` having none either is the
    /// SAME behavior, not a missing one.
    private func drainDeferredReconnectEvents() {
        guard !isShuttingDown else { return }
        guard !deferredReconnectEvents.isEmpty else { return }
        let events = deferredReconnectEvents
        deferredReconnectEvents.removeAll()
        for event in events {
            switch event {
            case .childExited(let surfaceView):
                deferOrRun(event) { [weak self] in self?.processChildExited(surfaceView: surfaceView) }
            case .decision(let surfaceID, let decision):
                handleSessionReconnectDecision(surfaceID: surfaceID, decision: decision)
            case .closeSurface(let surfaceView):
                deferOrRun(event) { [weak self] in self?.processCloseSurface(surfaceView: surfaceView) }
            }
        }
    }

    /// Not `private` (P4 review fix): `SessionReconnectGiveUpTests`
    /// calls this directly to drive the `.giveUp` case end-to-end
    /// without needing a live daemon to actually exhaust
    /// `maxReconnectAttempts` — matching the existing direct-query test
    /// style (`commandRegistry`, `_testInsert`) this codebase favors
    /// over driving real UI. The real production call site remains
    /// `sessionReconnectCoordinator`'s `onDecision` closure.
    func handleSessionReconnectDecision(surfaceID: UUID, decision: SessionReconnectDecision) {
        // R6-A (r6-fix-spec.md item 3, r5-verdicts.md V5): bail out
        // entirely while this window or the app itself is shutting
        // down, BEFORE even considering deferral: a decision arriving
        // (or replaying) once the app is genuinely terminating must
        // never be queued either, since windowWillClose's teardown
        // already preserved tracking state into the snapshot.
        guard !isShuttingDown else { return }

        // A `.giveUp`/`.closePane` decision already in flight (queried from
        // the daemon before a confirm-quit modal started) must not dispatch
        // into teardown while that modal is pumping the MainActor — see
        // `AppDelegate.isConfirmingQuit`'s header comment. F4 (V05, HIGH,
        // r4-fix-spec.md): deferred, not dropped, replayed once the gate
        // clears (see `deferredReconnectEvents`'s doc comment).
        deferOrRun(.decision(surfaceID: surfaceID, decision: decision)) { [weak self] in
            self?.dispatchReconnectDecision(surfaceID: surfaceID, decision: decision)
        }
    }

    private func dispatchReconnectDecision(surfaceID: UUID, decision: SessionReconnectDecision) {
        switch decision {
        case .closePane:
            closeDeadPersistentSessionSurface(surfaceID: surfaceID)
        case .reconnect(let sessionID, let attempt):
            scheduleReconnect(surfaceID: surfaceID, sessionID: sessionID, attempt: attempt)
        case .giveUp:
            handleReconnectGiveUp(surfaceID: surfaceID)
        }
    }

    /// The daemon confirmed the session's child process actually
    /// exited — close the pane exactly as an ordinary ghostty-driven
    /// close would (see `closeSurfaceAndCleanUp`'s doc comment).
    private func closeDeadPersistentSessionSurface(surfaceID: UUID) {
        guard let (tab, group) = findTabAndGroup(surfaceID: surfaceID) else { return }
        closeSurfaceAndCleanUp(tab: tab, group: group, surfaceID: surfaceID)
    }

    /// Reconnect attempts for `surfaceID`'s session exceeded
    /// `maxReconnectAttempts` (`SessionReconnectDecision.giveUp`).
    /// Unlike `.closePane` (the daemon confirmed the session's process
    /// actually exited, so a full kill is correct), the daemon here was
    /// only ever reported unreachable — the underlying `calyx-session`
    /// daemon may still be legitimately running (e.g. slow to start),
    /// so this closes the pane with DETACH, not kill, semantics: the
    /// session survives, reattachable later from the session browser
    /// (`calyx-session ls --all` still lists it) or a future restore.
    ///
    /// Deliberately closes the pane now, through the same
    /// `closeSurfaceAndCleanUp` path `closeDeadPersistentSessionSurface`
    /// uses (with `killSessions: false`), rather than leaving it open:
    /// review found that leaving a dead pane open did not prevent the
    /// last-pane/last-window quit cascade it was meant to avoid — it
    /// only deferred that same cascade to whenever the user next
    /// pressed a key on the dead pane, and ghostty may not even render
    /// an informative screen by then on a fast/abnormal exit. Closing
    /// deterministically here keeps cascade timing consistent with
    /// every other session-ending path.
    ///
    /// When this would empty the last tab/group/window, gates on
    /// `confirmQuitBeforeCloseIfWouldTerminate(mode: .detachOnly)` BEFORE
    /// tearing anything down, exactly like `closeFocusedSessionSurface` —
    /// cancelling leaves this (already-dead) pane in place rather than
    /// forcing the app closed. `.detachOnly` wording, since the session
    /// survives in the daemon either way.
    ///
    /// F1 (V01, CRITICAL, r4-fix-spec.md): the confirm-quit gate above
    /// is structurally a no-op for THIS specific surface. ghostty
    /// always reports a `.giveUp`-triggering surface as already
    /// `child_exited`, so `ghostty_app_needs_confirm_quit` can never be
    /// true for it (see r4-verdicts.md V01), meaning that when this
    /// surface is the last pane app-wide, the gate would silently let
    /// termination proceed with no modal ever shown at all. So when
    /// `isLastPaneEverywhere` AND closing it would actually terminate
    /// the app, this method no longer consults the gate or closes the
    /// pane at all: it does detach bookkeeping only (clearing
    /// `SessionSurfaceMap`/`tab.sessionRefs` tracking) and leaves the
    /// leaf in the split tree. The surface still shows ghostty's own
    /// child-exited state; a later keypress on it closes it through the
    /// ordinary `handleCloseSurfaceNotification` path, with
    /// `hasSession` now `false`, so no kill call and no data loss, and
    /// app termination at that point is the user's own, explicit choice
    /// (the same UX as ghostty's built-in wait-after-command). The
    /// two-pane (and any other non-last-pane-everywhere) case below is
    /// unchanged: closing deterministically is safe there because it
    /// can never empty the window.
    ///
    /// F2 (V02, CRITICAL): the remaining close branch inserts `tab.id`
    /// into `closingTabIDs` before tearing the surface down, mirroring
    /// `closeFocusedSessionSurface`'s own insert (see its doc comment).
    ///
    /// A no-op if the pane was already closed by the user in the
    /// meantime (`findTabAndGroup` returns `nil`).
    ///
    /// R6-A (r6-fix-spec.md item 3, r5-verdicts.md V5): bails out
    /// entirely while this window or the app itself is shutting down,
    /// for the same reason `handleSessionReconnectDecision`'s identical
    /// guard does (this method is also reachable directly, from tests
    /// and potentially future callers, not only via that dispatcher).
    ///
    /// R6-B (r6-fix-spec.md): the kept-pane (last-pane-everywhere)
    /// branch now also shows a persistent in-pane overlay (see
    /// `showReconnectGiveUpOverlay`'s doc comment): the macOS
    /// notification alone can silently vanish (permission not granted),
    /// and ghostty's own child-exited text is suppressed for this
    /// surface, leaving no other in-app signal.
    ///
    /// R6-K (r6-fix-spec.md): the two sequential `if isLastPane` checks
    /// (F1's closingWouldTerminate special case, then the ordinary
    /// confirm-quit gate) are merged into one, since the first always
    /// returns, so the second only ever ran when the first didn't fire.
    private func handleReconnectGiveUp(surfaceID: UUID) {
        guard !isShuttingDown else { return }
        guard let (tab, group) = findTabAndGroup(surfaceID: surfaceID) else { return }
        guard !closingTabIDs.contains(tab.id) else { return }

        let isLastPane = isLastPaneEverywhere(tab: tab, group: group)

        if isLastPane {
            if (NSApp.delegate as? AppDelegate)?.closingWouldTerminate(self) == true {
                logger.info("Reconnect exhausted for last pane app-wide; detaching without closing (see F1)")
                detachSessionIfPersistent(tab: tab, surfaceID: surfaceID)
                showReconnectGiveUpOverlay(tab: tab, surfaceID: surfaceID)
                sendReconnectGiveUpNotification(tabID: tab.id)
                return
            }
            guard confirmQuitBeforeCloseIfWouldTerminate(mode: .detachOnly) else {
                logger.info("User cancelled quit prompt for exhausted-reconnect pane; leaving pane in place")
                return
            }
        }

        closingTabIDs.insert(tab.id)

        let sessionID = SessionSurfaceMap.shared.sessionID(for: surfaceID)
        logger.error("Reconnect attempts exhausted for session \(sessionID ?? "unknown", privacy: .public); detaching and closing pane")
        sendReconnectGiveUpNotification(tabID: tab.id)

        closeSurfaceAndCleanUp(
            tab: tab, group: group, surfaceID: surfaceID,
            killSessions: false, markTerminationConfirmedOnWindowClose: isLastPane,
            callerAlreadyClaimedClosingTabIDs: true
        )
        closingTabIDs.remove(tab.id)
    }

    /// F5 (V06, MEDIUM, r4-fix-spec.md): shared give-up notification
    /// text for both of `handleReconnectGiveUp`'s branches. Corrected
    /// per r4-verdicts.md V06: the prior wording claimed scrollback and
    /// running commands were lost, and that only a brand-new session
    /// with the same ID was possible, both false in the reachable
    /// cases this fires for. `SessionReconnectCoordinator` feeds
    /// `.giveUp` from both `.running` and `.unreachable` daemon states
    /// (i.e. even when the daemon just confirmed the session is alive),
    /// the daemon-side PTY is `setsid()`'d (surviving the attach
    /// process disconnecting), and the session browser's `attach()`
    /// reattaches the SAME session, not a new one.
    private func sendReconnectGiveUpNotification(tabID: UUID) {
        NotificationManager.shared.sendNotification(
            title: "Session unreachable",
            body: "Calyx couldn't reattach this session, but it may still be running with its state intact. " +
                  "Reattach it from the session browser once the daemon is reachable again.",
            tabID: tabID
        )
    }

    /// R6-B (r6-fix-spec.md, r5-verdicts.md V6): a Calyx-side, persistent
    /// in-pane indication for `handleReconnectGiveUp`'s last-pane-
    /// everywhere branch, which keeps the pane open (detach bookkeeping
    /// only) instead of closing it. Ghostty's own child-exited text is
    /// suppressed for every surface (`GhosttyAction.swift`'s
    /// `show_child_exited` handling always returns `true`), the child
    /// process is dead so `sendText` goes nowhere, and the macOS
    /// notification alone can silently vanish if permission was never
    /// granted, so this overlay is the only remaining in-app signal. A
    /// no-op if the surface no longer resolves, or already has an
    /// overlay (idempotent against a duplicate call). Removed
    /// automatically once the surface is destroyed, since the overlay is
    /// a subview of the surface's own view.
    private func showReconnectGiveUpOverlay(tab: Tab, surfaceID: UUID) {
        guard let surfaceView = tab.registry.view(for: surfaceID) else { return }
        guard !surfaceView.subviews.contains(where: { $0 is GiveUpOverlayView }) else { return }
        let overlay = GiveUpOverlayView(frame: surfaceView.bounds)
        overlay.autoresizingMask = [.width, .height]
        surfaceView.addSubview(overlay)
    }

    /// Waits out `attempt`'s backoff delay, then re-attaches. A stale
    /// `surfaceID` (the pane was closed by the user in the meantime) is
    /// handled by `performReconnect`'s own `findTab` lookup coming back
    /// `nil`.
    private func scheduleReconnect(surfaceID: UUID, sessionID: String, attempt: Int) {
        let delaySeconds = Self.reconnectBackoffSeconds(forAttempt: attempt)
        Task { [weak self] in
            if delaySeconds > 0 {
                try? await Task.sleep(for: .seconds(delaySeconds))
            }
            self?.performReconnect(oldSurfaceID: surfaceID, sessionID: sessionID)
        }
    }

    /// Re-runs `calyx-session attach --create` for `sessionID` in a
    /// fresh surface, then swaps it in for `oldSurfaceID` everywhere
    /// that referenced it: the split tree (`SplitTree.remapLeafIDs`,
    /// the same contract `AppDelegate.restoreTabSurfaces` uses),
    /// `tab.sessionRefs` (`remappingKeys`, so the next snapshot points
    /// at the live leaf), and `SessionSurfaceMap` (`replaceSurface`).
    /// `attach --create`'s idempotency is what makes this safe to retry
    /// on a daemon that turned out to be merely unreachable rather than
    /// truly gone.
    ///
    /// CRITICAL ordering (review finding): `SurfaceRegistry
    /// .destroySurface(_:)` synchronously re-enters ghostty's
    /// `close_surface` callback (`handleCloseSurfaceNotification` ->
    /// `closeSurfaceAndCleanUp`) from inside `requestClose()`, *before*
    /// this method returns. The remap/replace calls below run BEFORE
    /// `destroySurface(oldSurfaceID)` specifically so that reentrant
    /// call observes state that already points at `newSurfaceID`:
    /// `SessionSurfaceMap.shared.sessionID(for: oldSurfaceID)` is
    /// already `nil` (so `killSessionIfPersistent` naturally does not
    /// kill), and `oldSurfaceID` is already absent from `tab.splitTree`
    /// (so `SplitTree.remove(_:)` — verified by inspection — treats a
    /// leaf ID it can't find as a no-op and returns an unchanged tree
    /// with `focusTarget == nil`, so the reentrant `closeSurfaceAndCleanUp`
    /// tail becomes a harmless redundant layout refresh, not tree
    /// corruption). `reconnectingSurfaceIDs` adds a second, independent
    /// layer of defense in `killSessionIfPersistent` regardless of this
    /// ordering.
    /// Thin wrapper around the one actually-unsafe-to-test call
    /// `performReconnect` makes (`tab.registry.createSurface`, a real
    /// ghostty FFI surface), mirroring `AppDelegate.createRegistrySurface`'s
    /// identical wrapper/reasoning, so
    /// `_performReconnectSurfaceCreationHookForTesting` can intercept
    /// exactly that call and nothing else.
    private func createReconnectSurface(
        tab: Tab, app: ghostty_app_t, config: ghostty_surface_config_s, pwd: String?, command: String?
    ) -> UUID? {
        #if DEBUG
        if let hook = _performReconnectSurfaceCreationHookForTesting {
            return hook()
        }
        #endif
        return tab.registry.createSurface(app: app, config: config, pwd: pwd, command: command)
    }

    /// Round-18 G6: positive-evidence check `performReconnect`'s grace
    /// `Task` consults immediately before `markEstablished`, alongside
    /// (not instead of) the existing surface-identity check -- see that
    /// call site's doc comment for why time and surface identity alone
    /// are insufficient. Mirrors `createReconnectSurface`'s
    /// hook-first/real-fallback shape: under `#if DEBUG`, a set
    /// `_reconnectGraceProbeForTesting` hook is consulted first, with a
    /// throwing hook collapsed to `.notEstablished` (fail-closed) rather
    /// than propagated. The real fallback reuses the existing bounded
    /// `listAllBounded()` race (already used by
    /// `SessionBrowserModel.refresh()`/`AppDelegate
    /// .fetchSessionsForAgentResume()`) against the same
    /// `SessionDaemonClient.shared` singleton `sessionReconnectCoordinator`
    /// already wires in, rather than adding a second daemon-query
    /// primitive. `.established` requires a matching `SessionInfo` whose
    /// `state == .running` AND `attachedClients >= 1`; a missing match,
    /// `.exited`, zero attached clients, or `listAllBounded()`'s own
    /// already-bounded degrade-to-`[]` all fall through to
    /// `.notEstablished` for free.
    private func reconnectGraceProbe(sessionID: String) async -> ReconnectGraceProbeResult {
        #if DEBUG
        if let hook = _reconnectGraceProbeForTesting {
            return (try? await hook()) ?? .notEstablished
        }
        #endif
        let sessions = await SessionDaemonClient.shared.listAllBounded()
        guard let match = sessions.first(where: { $0.id == sessionID }) else {
            return .notEstablished
        }
        return (match.state == .running && match.attachedClients >= 1) ? .established : .notEstablished
    }

    private func performReconnect(oldSurfaceID: UUID, sessionID: String) {
        guard let tab = findTab(surfaceID: oldSurfaceID) else { return }
        guard let app = GhosttyAppController.shared.app, let window = self.window else { return }
        guard let command = SessionCommandSynthesizer.reattachCommand(sessionID: sessionID, cwd: tab.pwd ?? NSHomeDirectory()) else {
            logger.error("No calyx-session binary resolvable; cannot reconnect session \(sessionID, privacy: .public)")
            return
        }

        var config = GhosttyFFI.surfaceConfigNew()
        config.scale_factor = Double(window.backingScaleFactor)

        guard let newSurfaceID = createReconnectSurface(tab: tab, app: app, config: config, pwd: tab.pwd, command: command) else {
            logger.error("Failed to create reconnect surface for session \(sessionID, privacy: .public)")
            return
        }

        let mapping = [oldSurfaceID: newSurfaceID]
        tab.splitTree = tab.splitTree.remapLeafIDs(mapping)
        tab.sessionRefs = tab.sessionRefs.remappingKeys(mapping)
        SessionSurfaceMap.shared.replaceSurface(old: oldSurfaceID, new: newSurfaceID)

        reconnectingSurfaceIDs.insert(oldSurfaceID)
        tab.registry.destroySurface(oldSurfaceID)
        reconnectingSurfaceIDs.remove(oldSurfaceID)

        // HIGH-SPEED RECONNECT FLASHING BUG (see
        // SessionReconnectAttemptResetTimingTests's header comment):
        // resetting sessionID's attempt count immediately here, right
        // after the swap, used to mean a replacement surface whose
        // attach process dies right away against a still-unreachable
        // daemon is followed by another childExited decision that gets
        // treated as attempt 1 again (0s backoff, see
        // `reconnectBackoffSeconds(forAttempt:)`) instead of attempt 2+
        // -- backoff never grows and `maxReconnectAttempts` is never
        // reached, so `giveUp` never fires: an infinite full-speed
        // reconnect loop (the user-visible pane flashing). Deferring the
        // reset behind a grace period instead lets a replacement that
        // keeps dying accumulate attempts normally; only a replacement
        // that survives past the grace period resets the count, so a
        // later, unrelated disconnect still starts backing off from
        // attempt 1 again (`markEstablished`'s original purpose).
        //
        // Round-18 finding G6: time alone still proved insufficient -- an
        // attach process that dies SLOWER than the grace window (e.g. a
        // ~2.5s die/respawn cycle against a daemon that keeps answering
        // `.running`/`.unreachable`) got its attempt count reset every
        // single cycle by the surface-identity check alone, since the
        // surface itself was never swapped out again in that scenario.
        // The count never advanced past 1, so `.giveUp` never fired: an
        // unbounded reconnect loop at roughly the grace window's own
        // cadence. Establishment now also requires
        // `reconnectGraceProbe(sessionID:)` to report the daemon sees the
        // session running with at least one attached client. A probe
        // failure is fail-closed: skipping a legitimate reset only delays
        // backoff recovery, while wrongly resetting reopens the unbounded
        // loop.
        //
        // The `.cancel()` below is cheap insurance, not the real
        // mechanism: newSurfaceID is a fresh UUID on every call, so this
        // key was never registered before and the cancel never actually
        // matches an in-flight task. Superseded grace tasks are not
        // proactively cancelled; they are outlived and neutralized by
        // the SessionSurfaceMap re-check once the wait elapses: if this
        // replacement was itself already swapped out again by a second
        // reconnect within the grace window,
        // `SessionSurfaceMap.shared.surfaceID(for:)` no longer equals
        // newSurfaceID, so that second attempt now owns the attempt
        // count, and this stale confirmation must not wrongly reset it
        // out from under an unrelated, still-in-progress retry.
        reconnectEstablishGraceTasks[newSurfaceID]?.cancel()
        reconnectEstablishGraceTasks[newSurfaceID] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Self.reconnectEstablishGraceMilliseconds))
            guard let self else { return }
            if !Task.isCancelled, SessionSurfaceMap.shared.surfaceID(for: sessionID) == newSurfaceID,
               await self.reconnectGraceProbe(sessionID: sessionID) == .established {
                self.sessionReconnectCoordinator.markEstablished(sessionID: sessionID)
            }
            self.reconnectEstablishGraceTasks.removeValue(forKey: newSurfaceID)
        }

        if tab.id == activeTab?.id {
            splitContainerView?.updateLayout(tree: tab.splitTree)
            if let newView = tab.registry.view(for: newSurfaceID) {
                window.makeFirstResponder(newView)
            }
        }
        requestSave()
    }

    /// Exponential backoff for reconnect attempts, capped at 30s:
    /// attempt 1 reconnects immediately (0s); attempts 2-6 wait
    /// 1/2/4/8/16s; attempt 7+ waits the 30s cap. Keeps a persistently
    /// unreachable daemon from spinning the pane in a tight retry loop
    /// while still reconnecting instantly for the common case (the
    /// attach process merely disconnected once).
    private static func reconnectBackoffSeconds(forAttempt attempt: Int) -> Double {
        guard attempt > 1 else { return 0 }
        return min(30.0, pow(2.0, Double(attempt - 2)))
    }

    /// How long `performReconnect`'s confirmation `Task` waits before
    /// resetting a replacement surface's session's attempt count (see
    /// that method's doc comment for why the reset is deferred at all).
    /// Production default 2000ms: long enough that a replacement whose
    /// attach process dies right away (the flashing bug's own failure
    /// mode) is very unlikely to still look "alive" by the time this
    /// fires, without leaving a legitimately-recovered session's attempt
    /// count wrongly nonzero for long after it's actually fine again.
    /// Same `#if DEBUG`-only override seam as `SessionDaemonClientProtocol
    /// .daemonQueryBoundTimeoutSeconds`.
    private static var reconnectEstablishGraceMilliseconds: UInt64 {
        #if DEBUG
        if let override = CalyxWindowControllerReconnectGraceOverrides.reconnectEstablishGraceMilliseconds {
            return override
        }
        #endif
        return 2000
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

        // Refuse to compute a ratio against zero-sized bounds — `resize`
        // would otherwise divide by zero and pin a NaN/Inf into the tree
        // (Bug D).
        guard let container = splitContainerView,
              container.bounds.width > 0,
              container.bounds.height > 0 else { return }

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
            bounds: container.bounds.size,
            minSize: 50
        )
        container.updateLayout(tree: tab.splitTree)
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

        // Feed the title-heuristic fallback for every pane's title change,
        // not just the tab's focused surface — a background split running
        // Claude Code still needs to report into the Agents sidebar.
        if let surfaceID = surfaceView.surfaceController?.id {
            AgentRegistry.shared.handleTitleChange(surfaceID: surfaceID, title: title)
        }

        guard let tab = activeTab else { return }

        if let focusedID = tab.splitTree.focusedLeafID,
           let focusedView = tab.registry.view(for: focusedID),
           focusedView === surfaceView {
            tab.title = title
            window?.title = tab.titleOverride ?? title
            refreshHostingView()
        }
    }

    /// OSC 9;4 progress-report signal (`GHOSTTY_ACTION_PROGRESS_REPORT`,
    /// forwarded as `.ghosttyProgressReport`) — feeds the Herdr layer-2
    /// fallback for every pane, not just the tab's focused surface,
    /// mirroring `handleSetTitleNotification`'s title-heuristic feed
    /// above.
    @objc private func handleProgressReportNotification(_ notification: Notification) {
        guard let surfaceView = notification.object as? SurfaceView else { return }
        guard belongsToThisWindow(surfaceView) else { return }
        guard let isActive = notification.userInfo?["active"] as? Bool else { return }
        guard let surfaceID = surfaceView.surfaceController?.id else { return }

        AgentRegistry.shared.handleProgressReport(surfaceID: surfaceID, isActive: isActive)
    }

    /// Resolves an Agents sidebar row click to a surface owned by this
    /// window and focuses it. A no-op in every other window's controller
    /// (its `windowSession` won't resolve the surface), and a no-op for
    /// QuickTerminal-hosted panes, which aren't part of any `windowSession`
    /// (out of scope for v1 — the row is still shown, just not focusable).
    @objc private func handleFocusSurfaceNotification(_ notification: Notification) {
        guard let surfaceID = notification.userInfo?["surfaceID"] as? UUID else { return }
        guard let tab = findTab(surfaceID: surfaceID) else { return }

        switchToTab(id: tab.id)
        if let view = tab.registry.view(for: surfaceID) {
            window?.makeFirstResponder(view)
        }
        // Every window's controller observes this notification, but only
        // the one that actually resolves the surface (above) should come
        // to the front — otherwise clicking a sidebar row for a pane in a
        // background window would focus that pane without raising its
        // window, leaving it invisible behind the current one.
        window?.makeKeyAndOrderFront(nil)
    }

    /// Relays `.calyxSurfaceDestroyed` (posted by `SurfaceRegistry`) into
    /// `AgentRegistry`. Every window's controller observes this
    /// independently; `AgentRegistry.handleSurfaceDestroyed` is idempotent,
    /// so the redundant calls across windows are harmless.
    @objc private func handleSurfaceDestroyedForAgentMonitor(_ notification: Notification) {
        guard let surfaceID = notification.userInfo?["surfaceID"] as? UUID else { return }
        AgentRegistry.shared.handleSurfaceDestroyed(surfaceID: surfaceID)
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

    @objc func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(jumpToMostRecentUnreadTab) {
            return windowSession.groups.flatMap(\.tabs).contains { $0.unreadNotifications > 0 }
        }
        // When the in-terminal search bar is presented, focus moves to its
        // text field and SurfaceView is no longer in the responder chain, so
        // we expose findNext:/findPrevious: here as a fallback target. The
        // validation gates them to "search bar visible" to mirror the
        // SurfaceView-side check.
        if menuItem.action == #selector(findNext(_:)) || menuItem.action == #selector(findPrevious(_:)) {
            return focusedSurfaceHasVisibleSearchBar
        }
        // Next/Previous Tab — only enabled when the active group has more
        // than one tab to switch between.
        if menuItem.action == #selector(selectNextTab(_:))
            || menuItem.action == #selector(selectPreviousTab(_:)) {
            return (windowSession.activeGroup?.tabs.count ?? 0) > 1
        }
        // Next/Previous Group — only enabled when more than one group exists.
        if menuItem.action == #selector(nextGroup(_:))
            || menuItem.action == #selector(previousGroup(_:)) {
            return windowSession.groups.count > 1
        }
        // Focus Split (4 directions) — only enabled when the active tab has
        // been split (i.e., its SplitTree root is a .split node).
        if menuItem.action == #selector(SurfaceView.focusSplitLeft(_:))
            || menuItem.action == #selector(SurfaceView.focusSplitRight(_:))
            || menuItem.action == #selector(SurfaceView.focusSplitUp(_:))
            || menuItem.action == #selector(SurfaceView.focusSplitDown(_:)) {
            return activeTab?.splitTree.isSplit ?? false
        }
        return true
    }

    private var focusedSurfaceHasVisibleSearchBar: Bool {
        guard let surfaceView = focusedController?.surfaceView else { return false }
        return SurfaceScrollView.enclosing(surfaceView.superview)?.isSearchBarPresented ?? false
    }

    // MARK: - Menu Actions (Group)

    @objc func newGroup(_ sender: Any?) { createNewGroup() }
    @objc func closeGroup(_ sender: Any?) { closeActiveGroup() }
    @objc func nextGroup(_ sender: Any?) { switchToNextGroup() }
    @objc func previousGroup(_ sender: Any?) { switchToPreviousGroup() }

    // MARK: - Menu Actions (Full Screen)

    // Wrapping NSWindow.toggleFullScreen via a custom selector keeps the
    // menu title fixed at "Toggle Full Screen" (AppKit only rewrites the
    // title to Enter/Exit when the direct NSWindow selector is used).
    @objc func toggleFullScreen(_ sender: Any?) {
        window?.toggleFullScreen(sender)
    }

    // MARK: - Menu Actions (Find)

    @objc func performFindAction(_ sender: Any?) {
        focusedController?.performAction("start_search")
    }

    @objc func findNext(_ sender: Any?) {
        // ghostty's `navigate_search:previous` moves toward the bottom of the
        // buffer, which is the conventional Find Next direction.
        focusedController?.performAction("navigate_search:previous")
    }

    @objc func findPrevious(_ sender: Any?) {
        focusedController?.performAction("navigate_search:next")
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

    /// R12-C (r12-fix-spec.md): delegates TabSnapshot/TabGroupSnapshot
    /// construction to the tested `Tab.snapshot()`/`TabGroup.snapshot()`
    /// extension chain (SessionSnapshot.swift) instead of duplicating a
    /// second, hand-kept-in-sync builder here. Only the live-window-only
    /// inputs stay local: `frame`/`isFullScreen`
    /// (`trackedFullScreen`/`preFullScreenFrame`), and the live
    /// `browserURL` override from `browserControllers`, threaded through
    /// as the `browserURLOverride` closure the chain already supports.
    /// Diff-tab exclusion and the live-URL-over-configured-URL
    /// precedence are therefore inherited from that chain unchanged.
    func windowSnapshot() -> WindowSnapshot {
        let frame: NSRect
        if trackedFullScreen {
            frame = preFullScreenFrame ?? window?.frame ?? .zero
        } else {
            frame = window?.frame ?? .zero
        }
        let groups = windowSession.groups.map { group in
            group.snapshot(browserURLOverride: { tabID in browserControllers[tabID]?.browserState.url })
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

    /// Finds the tab (in this window) whose `SurfaceRegistry` owns
    /// `surfaceID`. Used by `handleFocusSurfaceNotification` to resolve an
    /// Agents sidebar row click — each window's controller independently
    /// checks its own `windowSession`, so only the owning window acts.
    private func findTab(surfaceID: UUID) -> Tab? {
        for group in windowSession.groups {
            for tab in group.tabs where tab.registry.contains(surfaceID) {
                return tab
            }
        }
        return nil
    }

    /// R6-E (r6-fix-spec.md, A2): activates the tab (and, by extension
    /// via `switchToTab(id:)`, its group) containing `surfaceID`,
    /// reusing this controller's existing tab-switch logic rather than
    /// reimplementing containment (reuse finding F3f). A no-op if no tab
    /// in this window contains `surfaceID`. Not `private`:
    /// `AppDelegate.focusWindowForExistingSession` calls this directly
    /// so the session browser's "Attach" action for an already-live
    /// surface in a background tab actually shows it, not just the
    /// window with whatever tab happened to already be active.
    func activateTabContaining(surfaceID: UUID) {
        guard let tab = findTab(surfaceID: surfaceID) else { return }
        switchToTab(id: tab.id)
    }

    /// Like `findTab(surfaceID:)`, but also returns the owning group —
    /// needed by `closeDeadPersistentSessionSurface` and
    /// `handleReconnectGiveUp` to remove the tab via
    /// `WindowSession.removeTab(id:fromGroup:)` when a persistent
    /// session's pane closes and empties the tab's split tree.
    private func findTabAndGroup(surfaceID: UUID) -> (Tab, TabGroup)? {
        for group in windowSession.groups {
            for tab in group.tabs where tab.registry.contains(surfaceID) {
                return (tab, group)
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

    /// Last-window pre-close prompt path: if closing this window would
    /// terminate the app (`AppDelegate.closingWouldTerminate`), runs the
    /// confirm-quit gate BEFORE returning `true`, i.e. before AppKit
    /// proceeds to tear the window down — cancelling here leaves the
    /// window (and everything in it) untouched. On success, marks
    /// `isTerminationConfirmed` so the `applicationShouldTerminate` this
    /// close eventually cascades into (via `windowWillClose` ->
    /// `removeWindowController` -> `NSApp.terminate(nil)`) doesn't
    /// prompt a second time. Not gated when this isn't the last managed
    /// window, or a quick terminal is open, or the quit was already
    /// confirmed elsewhere (e.g. Cmd+Q racing this same close).
    ///
    /// F3 (V03, HIGH, r4-fix-spec.md): pre-populates `closingTabIDs`
    /// with every tab in this window BEFORE `confirmQuitIfNeeded` can run
    /// its modal: the one close path that didn't already do this. An
    /// unrelated pane's process can exit synchronously mid-modal
    /// (ghostty's `close_surface` callback, delivered via a main-queue
    /// dispatch that runs while `NSAlert.runModal()` pumps the run
    /// loop), and without this, `closeSurfaceAndCleanUp`'s reentrancy
    /// guard is empty and doesn't fire (see r4-verdicts.md V03).
    /// Removed again on the cancel path; left in place on success, since
    /// `windowWillClose` (which runs right after) re-populates it anyway
    /// as part of its own teardown.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let appDelegate = NSApp.delegate as? AppDelegate,
              appDelegate.closingWouldTerminate(self) else {
            return true
        }

        let allTabIDs = windowSession.groups.flatMap { $0.tabs.map(\.id) }
        closingTabIDs.formUnion(allTabIDs)

        // Already confirmed (from Cmd+Q → applicationShouldTerminate)
        if appDelegate.isTerminationConfirmed {
            isClosingForShutdown = true
            return true
        }

        // Last-window close via X button: run confirmations
        if !appDelegate.confirmQuitIfNeeded() {
            closingTabIDs.subtract(allTabIDs)
            return false
        }

        // R8-A (r8-fix-spec.md; r7-verdicts.md R7-V1): re-checks
        // closingWouldTerminate instead of trusting this method's own
        // entry-time result above, a global event tap can toggle the
        // quick terminal mid-modal (confirmQuitIfNeeded just ran one),
        // making this close no longer terminating by the time control
        // returns here. A no-op when it no longer would (see
        // markTerminationConfirmedIfWouldTerminate's own doc comment);
        // the window still closes either way (isClosingForShutdown/
        // return true below are unaffected), only whether a LATER
        // Cmd+Q silently skips its own confirm-quit prompt changes.
        markTerminationConfirmedAndSetClosingForShutdown()
        return true
    }

    func windowDidChangeBackingProperties(_ notification: Notification) {
        guard let window = self.window, let tab = activeTab else { return }
        let scale = window.backingScaleFactor
        for id in tab.registry.allIDs {
            tab.registry.controller(for: id)?.setContentScale(scale)
        }
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        guard let window = self.window else { return }
        let nowVisible = window.occlusionState.contains(.visible)
        let shouldRecreate = nowVisible && wasOccluded
        wasOccluded = !nowVisible
        guard shouldRecreate else { return }
        DispatchQueue.main.async { [weak self] in
            self?.recreateHostingView()
            self?.restoreFocus()
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

        // Destroy all surfaces in all tabs. R6-D (r6-fix-spec.md, sweep
        // finding in r5-verdicts.md): when the app is NOT actually
        // terminating (a red-button close of one of several open
        // windows), each persistent surface must go through the same
        // close policy closeTab already uses (kill semantics, an
        // explicit window close), unregistering SessionSurfaceMap/
        // tab.sessionRefs instead of silently orphaning them. When the
        // app IS terminating, preserve today's behavior exactly: destroy
        // without kill/detach, so tracking state survives into the
        // snapshot for the next launch. `isAppActuallyTerminating`, not
        // the per-window `isClosingForShutdown`, is the discriminator
        // (see each flag's own doc comment for why). R8-F
        // (tearDownSurfaces) shares this loop's body with closeTab/
        // closeActiveGroup/closeAllTabsInGroup; R8-C passes
        // `appIsTerminating` straight through to it (rather than gating
        // the call outside and letting the policy re-derive its own
        // notion of "terminating" from `isClosingForShutdown` inside),
        // so this outer gate and the inner kill decision always read
        // the exact same value.
        let appIsTerminating = isAppActuallyTerminating
        for group in windowSession.groups {
            for tab in group.tabs {
                tearDownSurfaces(in: tab, isTerminating: appIsTerminating)
            }
        }

        browserControllers.removeAll()

        for (_, task) in diffTasks { task.cancel() }
        diffTasks.removeAll()
        diffStates.removeAll()
        reviewStores.removeAll()
        for (_, task) in expandTasks { task.cancel() }
        expandTasks.removeAll()
        for (_, task) in childExitedTasks { task.cancel() }
        childExitedTasks.removeAll()
        for (_, task) in reconnectEstablishGraceTasks { task.cancel() }
        reconnectEstablishGraceTasks.removeAll()
        refreshTask?.cancel()
        loadMoreTask?.cancel()
        screenPollTask?.cancel()

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

            // Install the calyx-agent-hook script and wire each agent CLI's
            // own hook/plugin configuration to it so panes report lifecycle
            // state to the Agents sidebar. Same collect-independently shape
            // as IPCConfigManager.enableIPC above: an agent-hooks failure
            // degrades the sidebar rather than the whole "Enable AI Agent
            // IPC" flow, since the MCP server is already running.
            let hooksResult = AgentHooksCoordinator.install()

            // Persist any hook-install failure as a standing sidebar
            // banner (AgentStatusView) rather than only the one-shot
            // alert below — a symlink/permissions failure here otherwise
            // degrades the Agents sidebar silently for the rest of the
            // session. `[]` when every tool installed cleanly, clearing
            // any banner left over from a prior enable attempt.
            AgentRegistry.shared.setHooksIssues(Self.hooksIssueMessages(hooksResult))

            showIPCAlert(
                title: "IPC Enabled",
                message: "MCP server running on port \(port).\n\(configStatusMessage(result))\n" +
                    "\(agentHooksStatusMessage(hooksResult, mode: .install))\nRestart agent instances to connect."
            )
        } catch {
            showIPCAlert(title: "IPC Error", message: error.localizedDescription)
        }
    }

    private func disableIPC() {
        CalyxMCPServer.shared.stop()
        let result = IPCConfigManager.disableIPC()
        let hooksResult = AgentHooksCoordinator.remove()

        showIPCAlert(
            title: "IPC Disabled",
            message: "MCP server stopped.\n\(configStatusMessage(result))\n" +
                "\(agentHooksStatusMessage(hooksResult, mode: .remove))"
        )
    }

    /// Whether an `AgentHooksResult` reflects `AgentHooksCoordinator.install()`
    /// or `.remove()` — determines the verb `configStatusLabel` reports for
    /// `.success`, since "configured" reads wrong after a removal.
    private enum AgentHooksMode {
        case install
        case remove
    }

    /// Formats one tool's `ConfigStatus` as a single status line: `name: verb`
    /// on success, `name: reason (skipped)` on skip, `name: error - ...` on
    /// failure. Shared by `configStatusMessage` (always "configured", since
    /// `IPCConfigManager` has no separate disable-wording need) and
    /// `agentHooksStatusMessage` (whose verb depends on `AgentHooksMode`).
    private func configStatusLabel(_ status: ConfigStatus, name: String, verb: String) -> String {
        switch status {
        case .success:
            return "\(name): \(verb)"
        case .skipped(let reason):
            return "\(name): \(reason) (skipped)"
        case .failed(let error):
            return "\(name): error - \(error.localizedDescription)"
        }
    }

    private func configStatusMessage(_ result: IPCConfigResult) -> String {
        [
            configStatusLabel(result.claudeCode, name: "Claude Code", verb: "configured"),
            configStatusLabel(result.codex, name: "Codex", verb: "configured"),
            configStatusLabel(result.openCode, name: "OpenCode", verb: "configured"),
            configStatusLabel(result.hermes, name: "Hermes", verb: "configured"),
        ].joined(separator: "\n")
    }

    private func agentHooksStatusMessage(_ result: AgentHooksResult, mode: AgentHooksMode) -> String {
        let verb = mode == .install ? "configured" : "removed"
        return [
            configStatusLabel(result.claudeCode, name: "Claude Code hooks", verb: verb),
            configStatusLabel(result.codex, name: "Codex hooks", verb: verb),
            configStatusLabel(result.openCode, name: "OpenCode plugin", verb: verb),
        ].joined(separator: "\n")
    }

    /// One `"<name>: <localizedDescription>"` line per `.failed` tool in
    /// `result`, for `AgentRegistry.hooksIssues`'s persistent sidebar
    /// banner. `[]` when every tool installed successfully (or was
    /// skipped) — `AgentStatusView` only renders the banner when this is
    /// non-empty.
    private static func hooksIssueMessages(_ result: AgentHooksResult) -> [String] {
        [
            ("Claude Code hooks", result.claudeCode),
            ("Codex hooks", result.codex),
            ("OpenCode plugin", result.openCode),
        ].compactMap { name, status in
            guard case .failed(let error) = status else { return nil }
            return "\(name): \(error.localizedDescription)"
        }
    }

    // MARK: - AI Agent Tab Detection

    /// Returns true if a terminal tab title indicates it is running one of the
    /// supported AI agents (Claude Code, Codex, OpenCode, Hermes). Centralizes
    /// the title-substring check used by both compose and review send paths.
    /// Keep the agent list in sync with `IPCConfigResult` axes.
    private static func isAIAgentTitle(_ title: String) -> Bool {
        title.localizedCaseInsensitiveContains("claude") ||
        title.localizedCaseInsensitiveContains(AgentEntry.codexKind) ||
        title.localizedCaseInsensitiveContains(AgentEntry.openCodeKind) ||
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
