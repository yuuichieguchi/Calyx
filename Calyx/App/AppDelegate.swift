import AppKit
import GhosttyKit
import OSLog

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.calyx.terminal",
    category: "AppDelegate"
)

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, HerdrSessionPresenceObserver {
    private(set) var appSession = AppSession()
    private(set) var browserTabBroker = BrowserTabBroker()
    private var windowControllers: [CalyxWindowController] = []
    private var pendingURLs: [URL] = []
    private var quickTerminalController: QuickTerminalController?
    /// The MCP Apps host (`MCPHostComposition.swift`). Built in
    /// `applicationDidFinishLaunching`, so nil in the unit-test host.
    private(set) var mcpHostComposition: MCPHostComposition?

    /// Tracks the window the user is working in app-wide -- see
    /// `CurrentWindowTracker.swift`'s own file header for the full
    /// resolution contract.
    let currentWindowTracker = CurrentWindowTracker()

    /// The window the user is working in right now, resolved in three
    /// tiers: (1) a real key `CalyxWindowController`, if one exists; (2)
    /// else the front-most `CalyxWindowController` among `NSApp.
    /// orderedWindows` that could actually take key right now -- that
    /// array is front-to-back but includes never-shown, miniaturized, and
    /// off-Space windows, so tier 2 filters to `window.isVisible &&
    /// window.isOnActiveSpace` before taking the first member of
    /// `windowControllers` found (a window on another Space cannot take
    /// key without a Space switch, so it is not what the user is looking
    /// at), giving the most-recently-used Calyx window on the current
    /// Space even while none is key (e.g. Calyx is inactive, or some
    /// other app's window is key); (3) else `currentWindowTracker.
    /// lastKeyWindowController` while it's still a member of
    /// `windowControllers`, else `windowControllers.first` -- the fallback
    /// for when every Calyx window is minimized, off-Space, or not yet
    /// shown (tier 2 finds nothing), nil with zero open windows. Tiers 1
    /// and 2 are resolved here, against live `NSWindow` state; the actual
    /// three-tier decision is delegated to `CurrentWindowResolver.resolve(
    /// key:frontMostVisible:lastKey:ordered:)`, the pure form of this same
    /// rule. Every consumer that needs a "which window" answer with no
    /// more specific signal -- a target-pane-less approval request, a
    /// new-tab/attach flow with no explicit source window -- resolves
    /// through this.
    var currentWindowController: CalyxWindowController? {
        let key = windowControllers.first(where: { $0.window?.isKeyWindow == true })
        let frontMostVisible = NSApp.orderedWindows.lazy.filter({ $0.isVisible && $0.isOnActiveSpace }).compactMap({ window in
            self.windowControllers.first { $0.window === window }
        }).first
        return CurrentWindowResolver.resolve(
            key: key,
            frontMostVisible: frontMostVisible,
            lastKey: currentWindowTracker.lastKeyWindowController,
            ordered: windowControllers
        )
    }

    /// The window controller whose `windowSession.groups` registry
    /// reports ownership of `id` (`tabAndGroup(owningSurface:)`), or nil
    /// if no open window does.
    func windowController(owningSurface id: UUID) -> CalyxWindowController? {
        windowControllers.first { $0.windowSession.groups.tabAndGroup(owningSurface: id) != nil }
    }

    /// The split container that shows `surfaceID`'s leaf: its window's
    /// container, or the Quick Terminal's.
    func splitContainer(owningSurface surfaceID: UUID) -> SplitContainerView? {
        if let controller = windowController(owningSurface: surfaceID) {
            return controller.splitContainer
        }
        return quickTerminalController?.splitContainer(owningSurface: surfaceID)
    }

    /// The window that shows `surfaceID`: its main window, or the Quick
    /// Terminal's.
    func window(showingSurface surfaceID: UUID) -> NSWindow? {
        if let controller = windowController(owningSurface: surfaceID) {
            return controller.window
        }
        return quickTerminalController?.window(owningSurface: surfaceID)
    }

    /// Restores terminal focus after an approval decision resolves (or a
    /// question's free-text field loses relevance): a surface-targeted
    /// request reaches the window owning that surface, a window-agnostic
    /// (nil `targetSurfaceID`) request reaches `currentWindowController`.
    /// `reclaimKey` is computed here, at call time, from whether the
    /// app-wide approval panel actually holds key status right now --
    /// reading `_approvalPanelController` directly (never the creating
    /// `approvalPanelController` getter), so a request resolving before
    /// any panel was ever shown reads as "the panel does not hold key"
    /// rather than creating one just to ask it.
    ///
    /// When the owning window cannot actually take key (minimized,
    /// off-Space, or otherwise not showable), Calyx does nothing further:
    /// the panel orders out and AppKit's own key-window restoration
    /// decides, so Calyx never moves an unrelated window's first
    /// responder into its terminal.
    func restoreTerminalFocusAfterApproval(targetSurfaceID: UUID?) {
        let reclaimKey = _approvalPanelController?.panel?.isKeyWindow == true
        let owner = targetSurfaceID.flatMap(windowController(owningSurface:)) ?? currentWindowController
        guard let owner else { return }
        owner.restoreTerminalFocusAfterApproval(reclaimKey: reclaimKey)
    }

    /// The single, app-wide Cockpit approval queue -- one instance for
    /// the whole app, not one per window (see ApprovalBannerModel.swift's
    /// own header).
    ///
    /// `lazy`: `restoreTerminalFocus` captures `self` (to call
    /// `restoreTerminalFocusAfterApproval(targetSurfaceID:)`), which a
    /// plain stored property initializer cannot do (`self` does not
    /// exist yet at that point).
    lazy var approvalBannerModel = ApprovalBannerModel(
        store: .shared,
        restoreTerminalFocus: { [weak self] targetSurfaceID in
            self?.restoreTerminalFocusAfterApproval(targetSurfaceID: targetSurfaceID)
        }
    )

    /// Backing storage for `approvalPanelController` below, so
    /// `applicationWillTerminate` can tear it down without creating one
    /// that was never needed -- `nil` reads cleanly as "never rendered".
    private var _approvalPanelController: ApprovalPanelController?

    /// The single, app-wide floating approval panel: one page-style
    /// panel for the whole app, not one per window (see
    /// `ApprovalPanelController.swift`'s own header). Lazily created on
    /// first access, same self-capturing rationale as
    /// `approvalBannerModel` above; implemented as a manual lazy
    /// (`_approvalPanelController`) rather than `lazy var` so
    /// `applicationWillTerminate` can tear it down only if it was
    /// actually created.
    var approvalPanelController: ApprovalPanelController {
        if let existing = _approvalPanelController { return existing }
        let controller = ApprovalPanelController(
            model: approvalBannerModel,
            hostWindow: { [weak self] in self?.currentWindowController?.window },
            handOffKey: { [weak self] targetSurfaceID in
                self?.restoreTerminalFocusAfterApproval(targetSurfaceID: targetSurfaceID)
            },
            hostWindowController: { [weak self] in self?.currentWindowController },
            targetTabTitle: { [weak self] id in self?.windowController(owningSurface: id)?.tabDisplayTitle(owningSurface: id) }
        )
        _approvalPanelController = controller
        return controller
    }

    /// Re-renders the single app-wide approval panel: called whenever a
    /// window is added/removed, the current window changes, or the
    /// current window's own geometry changes. Only `.calyxApprovalInboxChanged`
    /// (`handleApprovalInboxChangedForPanel`) creates the panel controller;
    /// every other caller renders the existing one if any, since none of
    /// these events can themselves put a new request in the inbox. Reads
    /// `_approvalPanelController` directly rather than the creating
    /// `approvalPanelController` getter, so this never creates a panel
    /// controller just to render an inbox that is still empty.
    ///
    /// Kept after every `windowControllers.append`/`removeWindowController`/
    /// `cleanupFailedWindow` even though it cannot create the controller:
    /// a window created while Calyx is inactive never becomes key, so
    /// `windowDidBecomeKey` (and this app's `windowControllerDidBecomeKey`
    /// re-render) cannot be relied on to pick up the new/removed window as
    /// the panel's host.
    ///
    /// A no-op while `isApplicationTerminating`: nothing should show or
    /// move a floating panel once the app is already tearing down.
    func refreshApprovalPanel() {
        guard !isApplicationTerminating else { return }
        _approvalPanelController?.render()
    }

    /// `CalyxWindowController.windowDidBecomeKey` calls this instead of
    /// refreshing its own (now nonexistent) per-window banner.
    /// Re-renders the app-wide panel only when the current window
    /// actually changes (`CurrentWindowTracker.didBecomeKey(_:)`'s own
    /// return value) -- a window becoming key that was already the
    /// current window changes nothing this panel cares about.
    func windowControllerDidBecomeKey(_ controller: CalyxWindowController) {
        guard currentWindowTracker.didBecomeKey(controller) else { return }
        refreshApprovalPanel()
    }

    /// `CalyxWindowController.windowDidChangeScreen`/full-screen enter/
    /// exit call this instead of re-anchoring their own (now
    /// nonexistent) per-window panel. Re-renders (re-measures and
    /// re-anchors) the app-wide panel only when `controller` is the
    /// CURRENT window -- a geometry change on some other window never
    /// affects where the panel sits.
    func windowControllerGeometryChanged(_ controller: CalyxWindowController) {
        guard controller === currentWindowController else { return }
        refreshApprovalPanel()
    }

    /// Herdr-to-`AgentRegistry` state translator -- see
    /// `HerdrAgentMirror.swift`'s own header. Hoisted to its own stored
    /// property (rather than inlined into `herdrIntegrationCoordinator`'s
    /// own init below) so `HerdrPaneRegistry.shared.setBridgeObserver`
    /// (`applicationDidFinishLaunching`) can wire the IDENTICAL instance
    /// `herdrIntegrationCoordinator` forwards every snapshot/event to as
    /// its `HerdrPaneBridgeObserver` -- two independently-constructed
    /// mirrors would each only ever see half of what herdr reports.
    private let herdrAgentMirror = HerdrAgentMirror(registry: .shared)

    /// Herdr integration lifecycle owner -- see
    /// `HerdrIntegrationCoordinator.swift`'s own header. `lazy`: a
    /// stored property initializer cannot reference another stored
    /// property, and this one's own `mirror:` argument needs
    /// `herdrAgentMirror` above. Safe to defer construction to first
    /// access (unlike `herdrTabCoordinator` below -- see that
    /// property's own doc comment for why a `lazy var` THERE would be
    /// unsafe) because `HerdrIntegrationCoordinator.init` does no I/O of
    /// its own and starts no timer
    /// (`HerdrIntegrationCoordinatorTests.test_neverObservingAPresenceChange_doesNoWork_noBackgroundTimer`
    /// pins that), so this property being read for the first time is
    /// behaviorally inert until `herdrSessionPresence` below reports a
    /// herdr session it can connect to.
    private lazy var herdrIntegrationCoordinator = HerdrIntegrationCoordinator(
        discovery: HerdrSessionDiscovery(),
        transportFactory: LiveHerdrTransportFactory(),
        mirror: herdrAgentMirror
    )

    /// Owns "is a herdr session there right now?" -- see
    /// `HerdrSessionPresence.swift`'s own header -- and drives
    /// `herdrIntegrationCoordinator` above through every transition it
    /// observes. Held here because the answer outlives any window,
    /// sidebar, or tab: watching stops only when the app does.
    /// Constructing it opens nothing and starts nothing; `start()`
    /// (`startHerdrIntegration()` below, reached only past
    /// `applicationDidFinishLaunching`'s unit-test-host gate) is what
    /// begins watching.
    private let herdrSessionPresence = HerdrSessionPresence()

    /// The most recent presence-forwarding task -- see
    /// `herdrSessionPresenceDidChange(_:)`. Only the last one is
    /// retained; each awaits its predecessor, which is what keeps
    /// transitions in order.
    private var herdrPresenceForwardingTask: Task<Void, Never>?

    /// Shared across `herdrTabCoordinator`'s own lazy
    /// construction AND `createSurfaceWithPwd`'s restore-time
    /// `HerdrRestoreCommandPolicy` consultation, so both benefit from
    /// `HerdrBinaryResolver`'s own per-instance memoization of a FOUND
    /// path (that type's own doc comment) instead of each re-scanning
    /// PATH independently.
    private let herdrBinaryResolver = HerdrBinaryResolver()
    /// `createSurfaceWithPwd`'s restore-time socket-liveness
    /// probe (`HerdrRestoreCommandPolicy.decide`'s own `isSocketAlive:`
    /// input).
    private let herdrSessionDiscovery = HerdrSessionDiscovery()

    /// Native-tab coordinator -- see `HerdrTabCoordinator.swift`'s
    /// own header. `nil` when herdr itself isn't resolvable, OR before
    /// `startHerdrIntegration()`'s own async resolution below has
    /// completed -- every call site here guards on that `nil`. Everywhere
    /// else in this integration that means zero behavior change while
    /// herdr stays unresolved (`openHerdrAttachTab`'s own doc comment),
    /// except `adoptRestoredHerdrTabIfNeeded(_:)`: a tab restored before
    /// this resolves queues its adoption into `pendingHerdrTabAdoptions`
    /// instead of dropping it, flushed the moment this property is
    /// actually assigned (`flushPendingHerdrTabAdoptions()`, called
    /// immediately after, in `startHerdrIntegration()`). A herdr
    /// installed, or put on `PATH`, AFTER launch IS picked up: every
    /// presence transition that still finds this nil resolves again
    /// (`prepareHerdrTabCoordinatorIfNeeded()`), and presence reporting
    /// a live session is the strongest evidence there is that herdr
    /// exists. Assigned at most once all the same -- the first
    /// resolution that succeeds wins, and this instance owns
    /// per-workspace state no later one may replace.
    ///
    /// Populated asynchronously, off `@MainActor`, by
    /// `startHerdrIntegration()` below: a `lazy var` here would run
    /// `herdrBinaryResolver.resolve()`'s real, uncached `PATH` walk
    /// synchronously on first access, forced unconditionally on every
    /// launch by that same method -- see that method's own doc comment
    /// for the resolve-then-construct sequence.
    ///
    /// Read-only outside this file (`private(set)`):
    /// `SessionBrowserWindowController.createHerdrWorkspace(_:)`/
    /// `.attachHerdrWorkspace(_:)` and `CalyxWindowController`'s
    /// `herdr.attachTUI` palette command (indirectly, via
    /// `openHerdrAttachTab`, which does not need this property at all)
    /// all only ever READ it.
    private(set) var herdrTabCoordinator: HerdrTabCoordinator?

    private typealias PendingHerdrTabAdoption = (
        workspaceID: String, socketPath: String, tabID: UUID, paneRefs: [UUID: HerdrPaneRef]
    )

    /// Restored-tab adoptions queued by `adoptRestoredHerdrTabIfNeeded(_:)`
    /// while `herdrTabCoordinator` above was still nil -- `restoreSession()`
    /// runs synchronously during launch, before
    /// `startHerdrIntegration()`'s own async herdr-binary
    /// resolution can possibly have assigned that property yet, so a
    /// restored herdr tab must not simply be dropped here. Appended to
    /// ONLY from that one call site; flushed in order, and cleared, by
    /// `flushPendingHerdrTabAdoptions()` the instant a coordinator is
    /// actually constructed. Every entry is plain value data (no surface,
    /// no `Tab`, no live object), so herdr never resolving at all this
    /// launch leaves this holding a few small value tuples, with no other
    /// effect, for the rest of the process's life.
    private var pendingHerdrTabAdoptions: [PendingHerdrTabAdoption] = []

    #if DEBUG
    /// See `resolveHerdrBinPathOffMainThread()`. DO NOT use from
    /// production code.
    var _herdrBinPathOverrideForTesting: String?

    /// Test seam: sets `herdrTabCoordinator` directly and flushes
    /// `pendingHerdrTabAdoptions`, mirroring
    /// `startHerdrIntegration()`'s own assign-then-flush sequence
    /// exactly. `startHerdrIntegration()` itself is unreachable
    /// from a test (`applicationDidFinishLaunching`'s own
    /// `LaunchEnvironmentPolicy.isUnitTestHost()` gate), and
    /// `herdrTabCoordinator`'s setter is private besides, so
    /// this is the only way to drive the flush deterministically, without
    /// a real herdr binary. DO NOT use from production code.
    func _setHerdrTabCoordinatorForTesting(_ coordinator: HerdrTabCoordinator?) {
        herdrTabCoordinator = coordinator
        flushPendingHerdrTabAdoptions()
    }
    #endif

    /// Builds the real `HerdrTabCoordinator` once `herdrBinPath` is
    /// already resolved -- extracted out of `herdrTabCoordinator`'s own
    /// former `lazy var` initializer so `startHerdrIntegration()`
    /// can call it only AFTER resolving off `@MainActor` (see that
    /// method's own doc comment).
    private func makeHerdrTabCoordinator(herdrBinPath: String) -> HerdrTabCoordinator {
        let attacher = HerdrNativeTabAttacherLive(
            tabsProvider: { [weak self] in
                guard let self else { return [] }
                return self.nonClosingWindowGroups.flatMap { $0.group.tabs }
            },
            attachHook: { [weak self] tab in self?.attachHerdrNativeTab(tab) ?? false },
            focusHook: { [weak self] tabID in self?.focusHerdrNativeTab(tabID) },
            ratioMutationHook: { [weak self] leafA, leafB, direction, ratio in
                self?.applyHerdrNativeRatioMutation(leafA: leafA, leafB: leafB, direction: direction, ratio: ratio)
            },
            closeLeafHook: { [weak self] surfaceID in self?.closeHerdrNativeLeaf(surfaceID) },
            sessionKillHook: { surfaceID in
                // Never actually invoked by the attacher -- see
                // `HerdrNativeTabAttacherLive`'s own header (a herdr pane
                // carries no calyx-session identity, so there is never a
                // session to kill here). Wired to the real
                // "kill this surface's tracked session" primitive anyway,
                // purely so that never-kill invariant is provable rather
                // than papered over with a no-op closure.
                guard let sessionID = SessionSurfaceMap.shared.sessionID(for: surfaceID) else { return }
                SessionKillTracker.track { await SessionDaemonClient.shared.kill(id: sessionID) }
            }
        )

        return HerdrTabCoordinator(
            transportFactory: LiveHerdrTransportFactory(),
            herdrBinPath: herdrBinPath,
            registry: HerdrPaneRegistry.shared,
            surfaceFactory: HerdrAppDelegateSurfaceFactory(appDelegate: self),
            attacher: attacher
        )
    }

    /// The `SurfaceRegistry` every surface `herdrCreateSurface(
    /// command:)` creates for ONE in-flight `HerdrTabCoordinator
    /// .openWorkspace` call lands in -- see that method's own doc
    /// comment for why sharing exactly one instance across a whole open
    /// is both necessary and safe. `nil` between opens.
    private var herdrPendingSurfaceRegistry: SurfaceRegistry?

    /// Captured explicitly by `applicationShouldTerminate` (the only
    /// termination route now that closing a window never terminates the
    /// app any more — see `applicationShouldTerminateAfterLastWindowClosed`),
    /// BEFORE `markAllControllersClosingForShutdown` or any window
    /// teardown can empty windowControllers/appSession. applicationWillTerminate
    /// (via saveForTermination()) consults this instead of re-deriving
    /// buildSnapshot() from the possibly-already-emptied live state, so a
    /// Cmd+Q quit always saves a real snapshot even if it races a window
    /// close that already emptied windowControllers via
    /// `removeWindowController` (see that method's own doc comment for
    /// the matching synchronous save on that route).
    private(set) var pendingTerminationSnapshot: SessionSnapshot?

    #if DEBUG
    /// Test seam: force pendingTerminationSnapshot directly instead of
    /// only via applicationShouldTerminate's own capture, so
    /// saveForTermination()'s own "prefers the captured snapshot over a
    /// live rebuild" contract is testable in isolation from the capture
    /// mechanism itself. DO NOT use from production code.
    func _setPendingTerminationSnapshotForTesting(_ snapshot: SessionSnapshot?) {
        pendingTerminationSnapshot = snapshot
    }
    #endif

    /// App-wide "the app is actually terminating" discriminator, distinct
    /// from any single `CalyxWindowController.isClosingForShutdown`. That
    /// per-window flag means only "this window is tearing down"
    /// (`closeLastWindow` sets it even for a non-terminating close), so it
    /// cannot alone tell a deferred-event drain or `windowWillClose`'s
    /// destroy loop whether the whole app is quitting. This flag must be
    /// consulted (in addition to, not instead of, the per-window flag) by:
    /// the deferred-reconnect-event drain (must NOT replay into teardown
    /// while the app is mid-quit), and `windowWillClose`'s destroy loop
    /// (must preserve `sessionRefs` into the snapshot only while this is
    /// true; otherwise it must run the normal kill/detach close policy).
    /// Set `true` in `applicationShouldTerminate` on every
    /// `.terminateNow` return (alongside `markAllControllersClosingForShutdown`)
    /// and again in `applicationWillTerminate` as a belt-and-suspenders
    /// safety net. Never reset back to `false`: once the app is genuinely
    /// terminating, it stays that way for the remainder of the process's
    /// life. The one canonical "is the app actually terminating" query:
    /// `CalyxWindowController.isAppActuallyTerminating`,
    /// consulted directly by `detachSessionIfPersistent` and passed
    /// explicitly as `killSessionIfPersistent`'s `isTerminating` parameter
    /// by its callers, reads this flag alone.
    private(set) var isApplicationTerminating = false

    #if DEBUG
    /// Test seam: mirrors
    /// `_setConfirmingQuitForTesting`'s convention for `isApplicationTerminating`.
    /// DO NOT use from production code.
    func _setApplicationTerminatingForTesting(_ value: Bool) {
        isApplicationTerminating = value
    }
    #endif

    var allWindowControllers: [CalyxWindowController] {
        windowControllers
    }

    #if DEBUG
    /// Test seam: appends
    /// `controller` directly to `windowControllers`, bypassing
    /// `createNewWindow`/`makeRestoringWindowController`'s real window/
    /// surface construction. Lets tests exercise `focusWindowForExistingSession`
    /// (via `attachWindow`) against a genuine, already-registered
    /// controller, instead of only the "no owning controller at all"
    /// (stale-mapping) case `AppDelegateAttachWindowTests`'s existing
    /// fixture covers. DO NOT use from production code.
    func _testInsertWindowController(_ controller: CalyxWindowController) {
        windowControllers.append(controller)
    }
    #endif

    #if DEBUG
    /// Test seam: `quickTerminalController` is `private`, and its only
    /// production writer is `toggleQuickTerminal()`, which also opens a
    /// REAL window -- unsafe to call from a unit test (see this file's own
    /// close-path test suites' shared warning about the `NSApp.terminate`
    /// cascade a real window close can trigger in the XCTest host). Lets
    /// `closeAllWindows()`'s "a quick terminal being open changes nothing"
    /// invariant be exercised without ever calling
    /// `toggleQuickTerminal()` for real -- a plain `QuickTerminalController()`
    /// is safe to construct directly, since its `init` only registers
    /// notification observers (config-change and close-surface) and
    /// neither creates a window nor a ghostty surface (both deferred to
    /// `animateIn()`/`ensureSurface()`, never called here). DO NOT use
    /// from production code.
    func _setQuickTerminalControllerForTesting(_ controller: QuickTerminalController?) {
        quickTerminalController = controller
    }
    #endif

    #if DEBUG
    /// Test seam: overrides the resources root
    /// `applyGhosttyResourcesDirEnvironmentIfNeeded()` resolves against,
    /// instead of `Bundle.main.resourceURL`. DO NOT use from production
    /// code.
    var _ghosttyResourcesRootForTesting: URL?
    #endif

    /// Sets `GHOSTTY_RESOURCES_DIR` in this process's environment to
    /// Calyx's own bundled ghostty resources directory, if the bundle
    /// actually contains shell-integration scripts (via
    /// `GhosttyResourcesDirResolver`), overwriting any inherited value
    /// (via `GhosttyResourcesDirEnvironment.apply(_:)`). Must run before
    /// `GhosttyAppController.shared` is ever touched, since ghostty reads
    /// this variable from its own process environment at engine init.
    func applyGhosttyResourcesDirEnvironmentIfNeeded() {
        #if DEBUG
        let root = _ghosttyResourcesRootForTesting ?? Bundle.main.resourceURL ?? Bundle.main.bundleURL
        #else
        let root = Bundle.main.resourceURL ?? Bundle.main.bundleURL
        #endif
        let resolvedPath = GhosttyResourcesDirResolver(resourcesRoot: root).resolve()
        GhosttyResourcesDirEnvironment.apply(resolvedPath)
    }

    #if DEBUG
    /// Test seam: overrides the root `ShellIntegrationInstaller.install`
    /// writes into, instead of
    /// `ShellIntegrationInstaller.defaultInstallDirectory`. DO NOT use
    /// from production code.
    var _shellIntegrationRootForTesting: URL?
    #endif

    /// If command tracking is enabled (`CommandTrackingSettings
    /// .trackingEnabled`), installs Calyx's own zsh/fish command-log
    /// shell integration scripts and points this process's environment
    /// at them (`CalyxShellIntegrationEnvironment.apply(rootDirectory:)`)
    /// -- every surface's child shell inherits this process's own
    /// environment fresh at launch, so a toggle change takes effect from
    /// the next NEW terminal without an app restart, matching
    /// `applyGhosttyResourcesDirEnvironmentIfNeeded()`'s own env-based
    /// injection point. Run right after that method so both env
    /// mutations land before `GhosttyAppController.shared` is ever
    /// touched.
    func applyCalyxShellIntegrationIfEnabled() {
        guard CommandTrackingSettings.trackingEnabled else { return }
        #if DEBUG
        let root = _shellIntegrationRootForTesting ?? ShellIntegrationInstaller.defaultInstallDirectory
        #else
        let root = ShellIntegrationInstaller.defaultInstallDirectory
        #endif
        ShellIntegrationActivation.activateIfPossible(root: root)
    }

    // MARK: - Agent Hooks

    /// Re-syncs Calyx's own hook config entries with the current
    /// contract, per tool, for whichever CLIs already have them
    /// installed from a previous launch. `AgentHooksCoordinator
    /// .resyncInstalled()` is idempotent -- `ClaudeHooksConfigManager`'s
    /// `removingOwnCommandEntries` and `CodexHooksConfigManager`'s
    /// managed-block replacement both strip stale Calyx-owned entries
    /// before writing fresh ones -- so re-running it here on every
    /// launch doubles as the migration path for a user who enabled IPC
    /// under an older Calyx version and has not manually re-run "Enable
    /// AI Agent IPC" since. Without this, a pre-migration install's
    /// synchronous approval entry keeps firing under its old hook event,
    /// which `CalyxMCPServer.routeApprovalRequest`'s own `hookEventName`
    /// guard now treats as inert (see that method's own doc comment) --
    /// silently leaving the approval banner non-functional until the
    /// user happens to notice and re-enables IPC by hand. Resyncing is
    /// scoped per tool (`resyncInstalled()`'s own doc comment) rather
    /// than an all-or-nothing gate on whether ANY tool has Calyx hooks,
    /// so enabling IPC for one CLI can never spread to a second CLI the
    /// user installed afterward but never opted in for.
    ///
    /// Skipped for a `--uitesting` launch that has no
    /// `CalyxPathRoot.testRoot` (i.e. did not receive
    /// `--calyx-path-root=`), per
    /// `LaunchEnvironmentPolicy.mayPerformAgentIPCActivation()`:
    /// `CalyxUITestCase` runs the app-under-test with `--uitesting` and
    /// no XCTest loaded, so `LaunchEnvironmentPolicy.isUnitTestHost()`'s
    /// gate at the top of `applicationDidFinishLaunching` never catches
    /// it -- every Calyx-owned and agent-owned config path now resolves
    /// through `CalyxPathRoot.testRoot` (see that type's own doc
    /// comment), so a launch that DOES pass `--calyx-path-root=` writes
    /// only inside its own scoped root and this guard does not apply to
    /// it; a launch that does not pass it would still read-modify-write
    /// the developer's own real `~/.claude/settings.json` /
    /// `~/.codex/config.toml` / OpenCode plugin file, so the guard still
    /// applies there. The same predicate also gates both Settings > Agents
    /// IPC handlers, so a `--uitesting` launch missing
    /// `--calyx-path-root=` can never activate from either entry point.
    ///
    /// The actual per-tool checks, config parsing, and any resulting
    /// writes all run off `@MainActor` (`resyncAgentHooksOffMainThread()`
    /// below), mirroring `startHerdrIntegration()`'s identical
    /// off-main hop for the same reason: this would otherwise be
    /// synchronous I/O running before the first window ever draws.
    ///
    /// Any resulting failure is surfaced the same way
    /// `IPCActivationCoordinator.enable()` already does for a manual
    /// install: a persistent `AgentRegistry.hooksIssues` sidebar banner
    /// via `AgentHooksResult.issueMessages`, never a modal alert -- this
    /// runs unattended at launch, with no window guaranteed to exist yet
    /// to present one against. Never touches `configIssues`: this path
    /// only ever re-syncs hooks, so a config-write failure a manual
    /// enable already surfaced stays visible across it.
    ///
    /// Two-branch launch-time decision: on a real launch with
    /// IPCSettings.enabled, activates AI Agent IPC (starts the server,
    /// writes agent CLI configs, installs hooks via install() -- the
    /// setting being on already records explicit consent, so
    /// resyncInstalled()'s existing-entry inference is not needed here);
    /// otherwise falls back to the resync-only migration path below,
    /// which existing users who have not opted into the setting yet
    /// (every user right after upgrading) still need.
    private func resyncAgentHooksIfInstalled() {
        guard LaunchEnvironmentPolicy.mayPerformAgentIPCActivation() else { return }

        if IPCSettings.enabled {
            // IPCActivationCoordinator.enable() already serializes itself
            // through IPCActivationChain.shared, which also records the
            // outcome and posts .calyxIPCStateDidChange itself before its
            // in-flight flag drops -- wrapping this call in a second
            // chain.run() would deadlock (the inner run() would await the
            // very outer Task it is nested inside), and re-recording or
            // re-posting here would be redundant with what the chain
            // already does.
            Task {
                _ = await IPCActivationCoordinator().enable()
            }
        } else {
            Task {
                let hooksResult = await resyncAgentHooksOffMainThread()
                AgentRegistry.shared.setHooksIssues(hooksResult.issueMessages)
            }
        }
    }

    /// Runs `AgentHooksCoordinator.resyncInstalled()` off `@MainActor`,
    /// on `DispatchQueue.global()` -- mirrors
    /// `resolveHerdrBinPathOffMainThread()`'s identical hop for the same
    /// reason: a plain `Task { }` created from this (`@MainActor`)
    /// method inherits `@MainActor` isolation, so calling
    /// `resyncInstalled()` directly from `resyncAgentHooksIfInstalled()`'s
    /// own `Task { }` would still run its config-file reads and writes
    /// on the main thread -- only deferring WHEN, never WHERE.
    /// `AgentHooksCoordinator` and `AgentHooksResult` are both
    /// `Sendable`, so both cross the hop safely.
    private func resyncAgentHooksOffMainThread() async -> AgentHooksResult {
        await withCheckedContinuation { (continuation: CheckedContinuation<AgentHooksResult, Never>) in
            DispatchQueue.global().async {
                continuation.resume(returning: AgentHooksCoordinator.resyncInstalled())
            }
        }
    }

    // MARK: - Bell

    /// `.ghosttyRingBell` (`GHOSTTY_ACTION_RING_BELL`) receiver for a
    /// surface-targeted bell (`GhosttyAction.swift`'s `handleRingBell` —
    /// `RING_BELL` is always surface-targeted, see that method's own doc
    /// comment). `features` mirrors the user's `bell-features` config
    /// (`BellFeatures.swift`); `effects` is the injectable seam for the
    /// actual side effects (`BellEffectHandlers.swift`), defaulted so
    /// callers that don't care about observing individual effects (i.e.
    /// every real call site) don't need to pass one explicitly.
    /// `handleRingBellNotification` below is the real production caller,
    /// with `cachedBellFeatures` and a `BellEffectHandlers` wired to real
    /// system effects; `title`/`border` are left as `BellEffectHandlers`'
    /// no-op defaults (see that call site's own doc comment) even though
    /// the dispatch below still fires them when set, so a later pass can
    /// wire real presentation in without touching this dispatch logic.
    func processRingBell(features: BellFeatures, effects: BellEffectHandlers = BellEffectHandlers()) {
        if features.contains(.system) { effects.performSystemBell() }
        if features.contains(.audio) { effects.performAudioBell() }
        if features.contains(.attention) { effects.requestAttention() }
        if features.contains(.title) { effects.flashTitle() }
        if features.contains(.border) { effects.flashBorder() }
    }

    /// Cached decode of the user's live `bell-features` config, refreshed
    /// on `.ghosttyConfigChange` (`handleBellFeaturesConfigChange`/
    /// `refreshBellFeaturesCache` below) rather than re-read via FFI on
    /// every `.ghosttyRingBell` -- mirrors `GhosttyThemeProvider
    /// .refreshFromConfig()`'s identical cache-on-config-change shape
    /// (`GhosttyThemeProvider.swift`). Defaults to `BellFeatures
    /// .ghosttyDefault` until the first refresh primes it
    /// (`applicationDidFinishLaunching`, once `GhosttyAppController.shared`
    /// is ready).
    private var cachedBellFeatures: BellFeatures = .ghosttyDefault

    /// `.ghosttyRingBell` notification handler -- the real production call
    /// site for `processRingBell` above. Bell effects are app-wide (system
    /// beep, custom audio, dock bounce), not scoped to any one window, so
    /// this lives here rather than in `CalyxWindowController
    /// .registerNotificationObservers`. `flashTitle`/`flashBorder` are
    /// left as `BellEffectHandlers`' no-op defaults: prepending a bell
    /// emoji to the alerted surface's title and flashing a border around
    /// it are both out of scope here -- `processRingBell` above
    /// still correctly dispatches to them when `features` sets those
    /// bits, only their actual presentation is unimplemented.
    @objc private func handleRingBellNotification(_ notification: Notification) {
        let effects = BellEffectHandlers(
            performSystemBell: { NSSound.beep() },
            performAudioBell: { [weak self] in self?.playBellAudio() },
            requestAttention: { NotificationManager.shared.bounceDockIcon() }
        )
        processRingBell(features: cachedBellFeatures, effects: effects)
    }

    /// Refreshes `cachedBellFeatures` from the user's live `bell-features`
    /// config. `bell-features` is ghostty's packed-bool-struct config
    /// value (`Config.zig`'s `pub const BellFeatures = packed struct {
    /// ... }`; see `BellFeatures.swift`'s own doc comment for the exact
    /// bit layout), which `c_get.zig` marshals as a raw `c_uint` bit
    /// pattern across the C boundary for any packed struct backed by <= a
    /// C `int` -- Swift `CUnsignedInt` (4 bytes), NOT `GhosttyConfigManager
    /// .getUInt`'s `UInt` (8 bytes, sized for a plain integer config
    /// value, not a packed-struct's C ABI representation).
    @objc private func handleBellFeaturesConfigChange(_ notification: Notification) {
        refreshBellFeaturesCache()
    }

    private func refreshBellFeaturesCache() {
        var raw: CUnsignedInt = 0
        guard GhosttyAppController.shared.configManager.get("bell-features", value: &raw) else {
            cachedBellFeatures = .ghosttyDefault
            return
        }
        cachedBellFeatures = BellFeatures(rawValue: UInt32(raw))
    }

    /// Bell sounds currently playing. `NSSound` does not keep itself
    /// alive for the duration of playback -- Apple provides
    /// `NSSoundDelegate.sound(_:didFinishPlaying:)` precisely because the
    /// CALLER is expected to own the object's lifetime across an async
    /// playback, so a purely local `NSSound` (as `playBellAudio()` used
    /// to have) can be deallocated, silently cutting playback short, the
    /// moment `playBellAudio()` returns. An array, not a single scalar
    /// property: `bell-features` places no rate limit of its own beyond
    /// libghostty's 100ms bell throttle, so two bells can legitimately
    /// overlap, and a scalar would drop (and thus prematurely release)
    /// an earlier sound's only strong reference the moment a later bell
    /// starts. Each entry removes itself once its own playback finishes.
    private var activeBellSounds: [NSSound] = []

    /// `.audio` bell effect: plays `bell-audio-path` at `bell-audio-volume`.
    /// Read fresh via FFI rather than cached like `cachedBellFeatures`
    /// above -- `.audio` is off in `BellFeatures.ghosttyDefault`, and even
    /// when enabled fires far less often than a plain bell (gated behind
    /// libghostty's own 100ms bell rate limit), so a dedicated FFI round
    /// trip here is not a hot path worth caching.
    private func playBellAudio() {
        guard let path = GhosttyAppController.shared.configManager.getPath("bell-audio-path") else { return }
        guard let sound = NSSound(contentsOfFile: path, byReference: true) else {
            logger.warning("bell-audio-path did not resolve to a playable sound: \(path, privacy: .public)")
            return
        }
        let volume = GhosttyAppController.shared.configManager.getDouble("bell-audio-volume", default: 0.5)
        sound.volume = Float(volume)
        activeBellSounds.append(sound)
        sound.play()
        // `sound.duration` is NSSound's own documented playback length --
        // used instead of NSSoundDelegate so cleanup doesn't depend on a
        // delegate callback actually firing (e.g. if playback is ever cut
        // short some other way). DispatchQueue.main.asyncAfter's closure
        // is not statically MainActor-isolated even though it always runs
        // on the main thread, so `MainActor.assumeIsolated` here mirrors
        // this codebase's own established pattern for that exact gap
        // (CalyxWindowController.restoreWindow's FullScreenRestoreBox).
        DispatchQueue.main.asyncAfter(deadline: .now() + sound.duration) { [weak self] in
            MainActor.assumeIsolated {
                self?.activeBellSounds.removeAll { $0 === sound }
            }
        }
    }

    // MARK: - Herdr Integration

    /// Assembles the herdr integration, once, at launch: resolves the
    /// herdr binary, builds `herdrTabCoordinator` from it, wires that
    /// coordinator up as `herdrIntegrationCoordinator`'s structure-event
    /// observer, and only THEN lets `herdrSessionPresence` start
    /// reporting -- a connection must never exist before there is
    /// somewhere to send its structure events.
    ///
    /// Nothing here decides WHEN a connection happens: presence owns
    /// that (`HerdrSessionPresence`'s own header), so this runs exactly
    /// once per launch rather than being poked by app activation or by
    /// a view appearing.
    ///
    /// Called only from `applicationDidFinishLaunching`, which returns
    /// early for `LaunchEnvironmentPolicy.isUnitTestHost()` -- that is
    /// what keeps a unit-test host from watching, or connecting to, the
    /// developer's own real herdr (see that method's own doc comment for
    /// the incident this guards against).
    private func startHerdrIntegration() {
        Task {
            await prepareHerdrTabCoordinatorIfNeeded()
            herdrSessionPresence.setObserver(self)
            herdrSessionPresence.start()
        }
    }

    /// Resolves herdr and builds `herdrTabCoordinator` from it, unless
    /// one already exists. Runs at launch AND again on a presence
    /// transition that still finds this nil (see
    /// `herdrSessionPresenceDidChange(_:)`): herdr installed, or put on
    /// `PATH`, after Calyx launched would otherwise leave this nil for
    /// the whole process, and a nil structure-event observer means a
    /// `pane.closed` never closes its bridge surface and a native herdr
    /// tab can never be opened -- while the mirror happily shows rows
    /// for that same session.
    ///
    /// Re-resolved per transition rather than once: herdr existing is a
    /// fact presence owns, so the moment it reports a live session is
    /// the only honest moment to ask again -- a flag saying "already
    /// tried" would be Calyx deciding herdr is absent on evidence older
    /// than presence's own.
    ///
    /// `herdrBinaryResolver.resolve()` is a real, uncached `PATH` walk
    /// and runs off `@MainActor` (`resolveHerdrBinPathOffMainThread()`):
    /// a plain `Task { }` created from an `@MainActor` method inherits
    /// that isolation, so calling it directly would only defer WHEN, not
    /// WHERE.
    private func prepareHerdrTabCoordinatorIfNeeded() async {
        guard herdrTabCoordinator == nil else { return }
        guard let herdrBinPath = await resolveHerdrBinPathOffMainThread() else { return }
        // Re-checked (not just re-assigned) after the await: the launch
        // call and a presence-driven call can both reach the resolve.
        // This check and the assignment below are synchronous on
        // `@MainActor` with no `await` between them, so two callers can
        // never both construct one.
        guard herdrTabCoordinator == nil else { return }
        herdrTabCoordinator = makeHerdrTabCoordinator(herdrBinPath: herdrBinPath)
        // Adopts any restore-time queued entry now that a coordinator
        // finally exists -- see flushPendingHerdrTabAdoptions()'s own
        // doc comment.
        flushPendingHerdrTabAdoptions()
        herdrIntegrationCoordinator.setStructureEventObserver(herdrTabCoordinator)
    }

    /// Forwards every presence transition to
    /// `herdrIntegrationCoordinator`, which owns what a connection does
    /// about it -- but only after `prepareHerdrTabCoordinatorIfNeeded()`
    /// has had its chance, so a connection never exists before there is
    /// somewhere to send its structure events.
    ///
    /// That preparation is asynchronous while this callback is not, so
    /// forwarding is chained onto the previous transition's own task
    /// rather than spawned freely: presence transitions are only
    /// meaningful in the order they happened, and the coordinator reads
    /// them as such.
    func herdrSessionPresenceDidChange(_ change: HerdrSessionPresenceChange) {
        let previous = herdrPresenceForwardingTask
        herdrPresenceForwardingTask = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            await self.prepareHerdrTabCoordinatorIfNeeded()
            self.herdrIntegrationCoordinator.herdrSessionPresenceDidChange(change)
        }
    }

    /// Runs `herdrBinaryResolver.resolve()` off `@MainActor`, on
    /// `DispatchQueue.global()` -- see `startHerdrIntegration()`'s
    /// own doc comment for why a plain `Task { }` alone is not enough.
    /// `HerdrBinaryResolver` is `Sendable` (its own doc comment), so
    /// capturing it into the background closure is sound without any
    /// actor hop of its own -- mirrors `detectLiveCandidate()`'s
    /// identical `resolver`/`discovery` capture in
    /// `HerdrIntegrationCoordinator.swift`.
    private func resolveHerdrBinPathOffMainThread() async -> String? {
        #if DEBUG
        // Test seam: stands in for the real `PATH` walk, so a test can
        // drive `prepareHerdrTabCoordinatorIfNeeded()` without its
        // outcome depending on whether the machine running the suite
        // happens to have herdr installed. DO NOT use from production
        // code.
        if let overridden = _herdrBinPathOverrideForTesting { return overridden }
        #endif
        let resolver = herdrBinaryResolver
        return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            DispatchQueue.global().async {
                continuation.resume(returning: resolver.resolve())
            }
        }
    }

    /// Adopts every entry `adoptRestoredHerdrTabIfNeeded(_:)` queued into
    /// `pendingHerdrTabAdoptions` while `herdrTabCoordinator` was still
    /// nil, in the order they were queued, then empties the queue.
    /// Called immediately after `herdrTabCoordinator` is assigned, above
    /// in `startHerdrIntegration()` and in
    /// `_setHerdrTabCoordinatorForTesting` -- a coordinator that never
    /// gets constructed this launch simply leaves the queue as-is, with
    /// no other effect (no timer, no request, nothing beyond the value
    /// data `pendingHerdrTabAdoptions` already held). `adoptRestoredTab`
    /// itself is idempotent (its own doc comment), so a workspace already
    /// opened for real by the time this runs is unaffected by a queued
    /// entry for the same (workspaceID, socketPath).
    private func flushPendingHerdrTabAdoptions() {
        guard let coordinator = herdrTabCoordinator else { return }
        let queued = pendingHerdrTabAdoptions
        pendingHerdrTabAdoptions.removeAll()
        for entry in queued {
            coordinator.adoptRestoredTab(
                workspaceID: entry.workspaceID, socketPath: entry.socketPath, tabID: entry.tabID, paneRefs: entry.paneRefs
            )
        }
    }

    // MARK: - Herdr Native Tab Wiring

    /// `herdrTabCoordinator`'s own `HerdrNativeSurfaceFactory.createSurface(
    /// command:)`: creates ONE ghostty surface for a herdr-bridged pane,
    /// running `command` (`HerdrAttachBridgeCommand.build(...)`'s own
    /// output) as its child process -- mirrors `openHerdrAttachTab`'s own
    /// creation recipe (command variant), except the surface is created
    /// into `herdrPendingSurfaceRegistry` rather than a Tab's own
    /// registry: `HerdrTabCoordinator.openWorkspace`'s own Phase 2 creates
    /// every one of ONE workspace open's surfaces BEFORE any Tab exists
    /// to own a registry at all (`HerdrNativeTabAttacherLive.attachTab`'s
    /// pinned interface takes no registry of its own), so this method and
    /// `attachHerdrNativeTab(_:)` below share exactly one `SurfaceRegistry`
    /// instance across a whole open -- lazily created on this method's
    /// first call for that open, consumed (and reset to `nil`) by
    /// `attachHerdrNativeTab(_:)` once Phase 2 fully completes -- so the
    /// Tab eventually presented has every one of its own leaves' surfaces
    /// already registered in the SAME `SurfaceRegistry` instance
    /// `SplitContainerView` reads from
    /// (`CalyxWindowController.rebuildSplitContainer`'s own
    /// `SplitContainerView(registry: tab.registry)`; `Tab.registry` is a
    /// `let`, so it cannot be swapped in after construction, only chosen
    /// at construction time -- see `attachHerdrNativeTab(_:)` below).
    ///
    /// Safe as a single mutable property with no locking of its own:
    /// `HerdrTabCoordinator.openWorkspace`'s own Phase-2-through-attachTab
    /// stretch runs as ONE uninterrupted synchronous `@MainActor` sequence
    /// with no `await` in between (`HerdrTabCoordinator.swift`'s own
    /// header, "TWO-PHASE SURFACE CREATION"), so no second, concurrent
    /// open can ever interleave its own Phase 2 calls into this one's.
    private func herdrCreateSurface(command: String) -> UUID? {
        guard let app = GhosttyAppController.shared.app,
              let window = currentWindowController?.window
        else {
            return nil
        }

        let registry = herdrPendingSurfaceRegistry ?? SurfaceRegistry()
        herdrPendingSurfaceRegistry = registry

        var config = GhosttyFFI.surfaceConfigNew()
        config.scale_factor = Double(window.backingScaleFactor)
        return registry.createSurface(app: app, config: config, pwd: nil, command: command)
    }

    /// `herdrTabCoordinator`'s own `HerdrNativeSurfaceFactory
    /// .destroySurface(_:)`: destroys a surface `herdrCreateSurface(
    /// command:)` created, via "the registry's existing removal path"
    /// (`SurfaceRegistry.destroySurface(_:)`) on the SAME
    /// `herdrPendingSurfaceRegistry` it was created in.
    ///
    /// Deliberately does NOT clear `herdrPendingSurfaceRegistry` to `nil`
    /// here: a rollback destroys every surface from ONE failed open in a
    /// tight loop (`HerdrTabCoordinator.openWorkspace`'s own rollback
    /// paths), and each of those calls still needs to find the SAME
    /// registry the others do. Once every surface from a failed open is
    /// destroyed this way, the registry holds zero entries -- functionally
    /// indistinguishable from a fresh one -- so leaving the (now-empty)
    /// reference in place for `herdrCreateSurface(command:)`'s own next
    /// call to reuse is harmless.
    private func herdrDestroySurface(_ id: UUID) {
        herdrPendingSurfaceRegistry?.destroySurface(id)
    }

    /// `herdrTabCoordinator`'s own attacher's `attachHook`: replaces the
    /// "shell" `Tab` `HerdrNativeTabAttacherLive.attachTab` built (a
    /// fresh, empty default `SurfaceRegistry` -- that type's own pinned
    /// interface carries no registry parameter of its own) with a
    /// corrected one sharing `herdrPendingSurfaceRegistry` -- the SAME
    /// registry `herdrCreateSurface(command:)` actually created this
    /// tab's own surfaces in. Copies over `title`/`splitTree`/
    /// `herdrPaneRefs`; `sessionRefs` stays empty (`Tab.init`'s own
    /// default) and `SessionSurfaceMap` is never touched, mirroring
    /// `openHerdrAttachTab`'s own tail exactly.
    ///
    /// `false` when no target window is available (every Calyx window
    /// closed), OR that target's own `windowSession.activeGroup` is `nil`
    /// (`attachRestoredTab` itself silently no-ops on that same condition,
    /// and its `Void` return gives this method no way to observe that, so
    /// this guard checks the condition directly rather than trusting
    /// `attachRestoredTab`'s return) -- no new-window fallback, mirroring
    /// `openHerdrAttachTab`'s own identical "no dialog, no fallback window"
    /// choice for the same edge case.
    /// `herdrPendingSurfaceRegistry` is deliberately left untouched on
    /// this path: `HerdrTabCoordinator.openWorkspace`'s own "ATTACHTAB
    /// FAILURE" rollback destroys every already-created surface right
    /// after this returns `false`, via `herdrDestroySurface(_:)`, which
    /// still needs to find them through this SAME property.
    private func attachHerdrNativeTab(_ tab: Tab) -> Bool {
        guard let target = currentWindowController,
              let registry = herdrPendingSurfaceRegistry,
              target.windowSession.activeGroup != nil
        else {
            return false
        }

        let realTab = Tab(title: tab.title, splitTree: tab.splitTree, registry: registry)
        realTab.herdrPaneRefs = tab.herdrPaneRefs
        herdrPendingSurfaceRegistry = nil

        target.attachRestoredTab(realTab)
        return true
    }

    /// `herdrTabCoordinator`'s own attacher's `focusHook`: finds the
    /// window controller owning the tab `tabID` names and switches to it,
    /// mirroring `focusWindowForExistingSession`'s own "find the owning
    /// controller, then act" shape one level up (tab id, not surface id).
    private func focusHerdrNativeTab(_ tabID: UUID) {
        guard let wc = windowControllers.first(where: { wc in
            wc.windowSession.groups.tabAndGroup(tabID: tabID) != nil
        }) else {
            return
        }
        wc.switchToTab(id: tabID)
        wc.showWindow(nil)
    }

    /// `herdrTabCoordinator`'s own attacher's `ratioMutationHook`: finds
    /// the window controller whose some tab owns `leafA` as a registry
    /// entry and routes to `CalyxWindowController.applyHerdrRatioMutation(
    /// leafA:leafB:direction:ratio:)`.
    private func applyHerdrNativeRatioMutation(leafA: UUID, leafB: UUID, direction: SplitDirection, ratio: Double) {
        guard let wc = windowController(owningSurface: leafA) else {
            return
        }
        wc.applyHerdrRatioMutation(leafA: leafA, leafB: leafB, direction: direction, ratio: ratio)
    }

    /// `herdrTabCoordinator`'s own attacher's `closeLeafHook`: finds the
    /// window controller owning `surfaceID` and routes to
    /// `CalyxWindowController.closeHerdrTrackedSurface(_:)` -- the
    /// existing pane-close path for that surface.
    private func closeHerdrNativeLeaf(_ surfaceID: UUID) {
        guard let wc = windowController(owningSurface: surfaceID) else {
            return
        }
        wc.closeHerdrTrackedSurface(surfaceID)
    }

    /// Thin `HerdrNativeSurfaceFactory` conformer delegating to
    /// `herdrCreateSurface(command:)`/`herdrDestroySurface(_:)` above --
    /// exists only so `HerdrTabCoordinator` (which stores its own
    /// `surfaceFactory` as `any HerdrNativeSurfaceFactory`, a hard
    /// reference) does not retain `AppDelegate` itself, which would
    /// cycle back through `herdrTabCoordinator`'s own stored
    /// `surfaceFactory`/`attacher` -- `appDelegate` is captured `weak`
    /// for exactly that reason (harmless in practice either way, since
    /// `AppDelegate` lives for the process's whole lifetime, but avoiding
    /// the cycle costs nothing). Mirrors `FullScreenRestoreBox`'s own
    /// "small reference-typed helper nested inside `AppDelegate`" shape.
    @MainActor
    private final class HerdrAppDelegateSurfaceFactory: HerdrNativeSurfaceFactory {
        private weak var appDelegate: AppDelegate?

        init(appDelegate: AppDelegate) {
            self.appDelegate = appDelegate
        }

        func createSurface(command: String) -> UUID? {
            appDelegate?.herdrCreateSurface(command: command)
        }

        func destroySurface(_ id: UUID) {
            appDelegate?.herdrDestroySurface(id)
        }
    }

    // MARK: - NSApplicationDelegate

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The CalyxTests scheme runs this app itself as its unit-test
        // HOST, so this method runs for real, unguarded, against the
        // developer's own ~/.calyx before a single test method executes.
        // That already caused a live incident on 2026-03-20 (commit
        // 8a0a76bcc, "Skip global event tap in unit test host
        // environment"): the global event tap was installed for real
        // from the test host. Left ungated, the rest of this method is
        // worse -- it increments the real crash-loop recovery counter
        // and, on terminate, overwrites the real sessions.json (see
        // applicationWillTerminate's own matching gate below); with
        // persistentSessionsEnabled == true in the developer's real
        // UserDefaults, restoreSession()/createNewWindow() would also
        // spawn real persistent calyx-session daemons; it starts
        // BrowserServer's real loopback listener; and setupMainMenu()
        // transitively initializes UpdateController.shared, pulling in
        // Sparkle. CalyxUITests launches the app-under-test as a
        // separate process with "--uitesting" and no XCTest loaded, so
        // it always evaluates false here and keeps running the full
        // launch unchanged.
        if LaunchEnvironmentPolicy.isUnitTestHost() { return }

        // Wire the real Ghostty-FFI-backed output reader now that we're
        // definitely not in the unit-test host (a GhosttyCommandOutputReader
        // read touches live ghostty FFI, unsafe there).
        CommandLogStore.shared.reader = GhosttyCommandOutputReader()

        // Must run before GhosttyAppController.shared's first access below:
        // ghostty forwards shell-integration scripts to surface children
        // only when GHOSTTY_RESOURCES_DIR is already set in this process's
        // own environment at engine init.
        applyGhosttyResourcesDirEnvironmentIfNeeded()
        applyCalyxShellIntegrationIfEnabled()

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
        refreshBellFeaturesCache()
        installKeyMonitor()
        installGlobalEventTap()
        SurfacePropertyStore.shared.startObserving()
        HerdrHostedSurfaces.shared.startObserving()
        // Started unconditionally here (not deferred to herdrTabCoordinator's
        // own lazy construction, HerdrTabCoordinator.init's own idempotent
        // startObserving() call): a restore-time bridge-command surface
        // (AppDelegate.createSurfaceWithPwd) can register into
        // HerdrPaneRegistry.shared before herdrTabCoordinator is ever
        // accessed at all (e.g. herdr resolves, but the coordinator's own
        // first access happens later, or never, this launch), and its
        // .calyxSurfaceDestroyed self-pruning (HerdrPaneRegistry.swift's
        // own header) must be armed before that can happen.
        HerdrPaneRegistry.shared.startObserving()
        // Wired here, before restoreSession() below, so no
        // HerdrPaneRegistry.shared.register call (including
        // AppDelegate.createSurfaceWithPwd's own restore-time call) ever
        // runs before herdrAgentMirror is listening: any row it later
        // creates or already owns for that pane gets its focusSurfaceID
        // pushed the moment a bridge changes, on top of the upsert-time
        // resolution HerdrAgentMirror.swift's own header already
        // documents (which is what actually self-heals a row created
        // before this launch's herdr connection is even established).
        HerdrPaneRegistry.shared.setBridgeObserver(herdrAgentMirror)
        startHerdrIntegration()
        // Before `resyncAgentHooksIfInstalled()`, so the IPC start it may
        // trigger reaches the MCP host.
        startMCPHost()
        resyncAgentHooksIfInstalled()

        browserTabBroker.appDelegate = self
        let browserHandler = BrowserToolHandler(broker: browserTabBroker)
        BrowserServer.shared.toolHandler = browserHandler
        BrowserServer.shared.start()
        NSApp.servicesProvider = self

        // No `--uitesting` bypass here: `restoreSession()` returns false
        // whenever there is no snapshot to restore (see its guard against
        // a nil or empty-`windows` snapshot), and every UI test launches
        // with a fresh, never-before-used `CALYX_UITEST_SESSION_DIR`
        // (`CalyxUITestCase.setUp`), so this always falls through to
        // `createNewWindow()` exactly as before for every existing test.
        // Only a test that relaunches with the SAME session dir (the
        // persistence E2E suite) can find a snapshot and take the
        // restore path, which is required for the restored pane to
        // reattach to its pre-restart session instead of a fresh one
        // being created.
        if !restoreSession() {
            if pendingURLs.isEmpty {
                createNewWindow()
                // Demo-recording scenario only (CalyxUITests
                // /DemoRecordingScenario.swift): every UI test launches
                // with a fresh session dir (see comment above), so
                // launch always takes THIS branch, not restoreSession()'s
                // -- no equivalent hook is needed there.
                applyDemoWindowFrameIfNeeded()
            }
        }
        // issue #37 recurrence guard: issue #37 ("Calyx closes after
        // opening") was a snapshot restoring a window with no tabs, that
        // window closing immediately, and `removeWindowController` reading
        // the resulting empty `windowControllers` as "last window closed"
        // and terminating the app outright -- fixed by
        // `SessionSnapshot.removingEmptyWindows()` below `restoreSession()`,
        // still in place, still load-bearing. Closing the last window no
        // longer terminates the app at all (see
        // `applicationShouldTerminateAfterLastWindowClosed`), so the same
        // gap can no longer manifest as a silent quit -- but with
        // nothing above having produced a window (an edge case
        // `removingEmptyWindows()` doesn't fully rule out) and no URL
        // still pending one (`application(_:open:)` runs below and
        // creates its own window(s)), it would instead surface as a
        // launch that shows nothing at all, just as unrecoverable to the
        // user. This is the safety net for that: nothing above created a
        // window and none is still coming, so create one now.
        if windowControllers.isEmpty && pendingURLs.isEmpty {
            createNewWindow()
        }
        // A snapshot preserved by a PREVIOUS run's
        // restoreSession() (via preserveSnapshotForRecovery()) still sits
        // on disk at launch even though THIS run never called that method
        // itself -- without this, `session.recoverPreviousSession` would
        // stay unavailable until the next skipped/failed restore, instead
        // of offering the still-pending recovery from before. Mirrors
        // reassertHistoryPersistenceIfNeeded()'s own async-Task-after-launch shape.
        Task { await initializeHasPreservedSessionSnapshotFlag() }
        Task { await reassertHistoryPersistenceIfNeeded() }
        // Process any URLs that arrived before launch completed
        if !pendingURLs.isEmpty {
            let urls = pendingURLs
            pendingURLs = []
            application(NSApp, open: urls)
        }
    }

    /// Ghostty parity: closing the last window
    /// never terminates Calyx any more, matching Ghostty's own
    /// last-window-doesn't-quit behavior. The app instead keeps running
    /// with zero windows open until the user explicitly quits (Cmd+Q /
    /// the Quit menu item) or reopens one (`applicationShouldHandleReopen`,
    /// the Dock icon).
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Dock-icon click / re-open (double-clicking Calyx.app, or clicking
    /// its Dock icon, while it's already running) with no window already
    /// coming to the front on its own. Mirrors Ghostty's own
    /// `applicationShouldHandleReopen` (ghostty/macos/Sources/App/macOS/AppDelegate.swift).
    /// Now that closing every window no longer
    /// terminates the app (see `applicationShouldTerminateAfterLastWindowClosed`),
    /// this is how a user gets a window back after closing them all
    /// without quitting.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // A visible window already exists -- defer to AppKit's own
        // default behavior (bring it to front).
        guard !flag else { return true }

        // A window exists but isn't visible yet (e.g. still initializing,
        // flag can lag a genuinely-open window) -- nothing to do.
        guard windowControllers.isEmpty else { return true }

        createNewWindow()
        return false
    }

    /// The Cmd+Q / "Quit Calyx" path: the only remaining termination
    /// route now that closing a window never terminates the app (see
    /// `applicationShouldTerminateAfterLastWindowClosed`), so unlike
    /// before, there is no second, already-confirmed route to
    /// short-circuit here.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if ProcessInfo.processInfo.arguments.contains("--uitesting") {
            markAllControllersClosingForShutdown()
            isApplicationTerminating = true
            return .terminateNow
        }

        if !confirmQuitIfNeeded() {
            return .terminateCancel
        }

        // Captured explicitly, BEFORE markAllControllersClosingForShutdown
        // or any window teardown can empty windowControllers/appSession
        // (see pendingTerminationSnapshot's own doc comment).
        pendingTerminationSnapshot = buildSnapshot()
        // Flag all controllers so windowDidExitFullScreen preserves tracking state
        // during app teardown (the red-button / Cmd+W path sets its own flag).
        markAllControllersClosingForShutdown()
        // App-wide termination signal, alongside
        // markAllControllersClosingForShutdown, consulted by
        // the deferred-reconnect-event drain and windowWillClose's
        // destroy loop (see isApplicationTerminating's own doc comment).
        isApplicationTerminating = true
        return .terminateNow
    }

    private func markAllControllersClosingForShutdown() {
        for wc in windowControllers {
            wc.isClosingForShutdown = true
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Mirrors applicationDidFinishLaunching's own gate (see that
        // method's doc comment for the full incident narrative): a
        // unit-test host's applicationDidFinishLaunching already
        // returned early and never populated windowControllers or
        // appSession, but this notification still fires for real at
        // host process teardown regardless. Without this gate,
        // saveAtTermination/resetRecoveryCounter below would still run
        // against SessionPersistenceActor.shared and write to the
        // developer's real ~/.calyx even though nothing in this launch
        // was ever gated by a window/session-emptiness check alone.
        if LaunchEnvironmentPolicy.isUnitTestHost() { return }

        // Belt-and-suspenders alongside
        // applicationShouldTerminate's own set, in case this notification
        // ever fires without that method having run first (see
        // isApplicationTerminating's own doc comment).
        isApplicationTerminating = true

        // Only if the app-wide approval panel was ever actually created --
        // reading `_approvalPanelController` directly, never the
        // `approvalPanelController` computed property, so this never
        // creates one that was never needed just to tear it down again.
        _approvalPanelController?.tearDown()

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

        // Closing the last window already persists synchronously in
        // `removeWindowController` (see that method's own doc comment).
        // This guard's ONLY remaining job is skipping pointless work when
        // there is neither a captured confirm-time pendingTerminationSnapshot
        // nor any live window left to build one from -- saveForTermination()'s
        // own saveAtTermination(_:) call already refuses to let an empty
        // snapshot clobber a non-empty on-disk one, so this is not a
        // correctness gate: a non-nil pendingTerminationSnapshot (captured
        // by applicationShouldTerminate's own Cmd+Q path, see that
        // property's own doc comment) must still be saved even when
        // windowControllers/appSession are already empty by the time this
        // runs (e.g. every window was already closed, each already saved
        // via removeWindowController, before the user then pressed Cmd+Q).
        let hasLiveWindows = !windowControllers.isEmpty && !appSession.windows.isEmpty
        guard pendingTerminationSnapshot != nil || hasLiveWindows else {
            return
        }

        saveForTermination()
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
        // `.ghosttyRingBell`'s effects (system beep, custom audio, dock
        // bounce) are app-wide, not scoped to any one window, so its
        // observer lives here rather than in `CalyxWindowController
        // .registerNotificationObservers` (see `processRingBell`'s own
        // doc comment). `.ghosttyConfigChange`
        // keeps `cachedBellFeatures` in sync with the user's live config.
        center.addObserver(self, selector: #selector(handleRingBellNotification(_:)), name: .ghosttyRingBell, object: nil)
        center.addObserver(
            self, selector: #selector(handleBellFeaturesConfigChange(_:)), name: .ghosttyConfigChange, object: nil
        )
        // Both of these name a surface and mutate the app-wide
        // `AgentRegistry` singleton, so neither is window-scoped and
        // neither may depend on a `CalyxWindowController` existing to
        // relay it -- see each handler's own doc comment below.
        center.addObserver(
            self, selector: #selector(handleGhosttyCommandFinishedNotification(_:)),
            name: .ghosttyCommandFinished, object: nil
        )
        center.addObserver(
            self, selector: #selector(handleSurfaceDestroyedForAgentMonitor(_:)),
            name: .calyxSurfaceDestroyed, object: nil
        )
        // Drives the single app-wide floating approval panel -- see
        // `refreshApprovalPanel()`'s own doc comment. Observed here
        // (not by any `CalyxWindowController`) since the panel is now
        // owned by AppDelegate itself, not one per window.
        center.addObserver(
            self, selector: #selector(handleApprovalInboxChangedForPanel(_:)),
            name: .calyxApprovalInboxChanged, object: nil
        )
    }

    @objc private func handleNewTab(_ notification: Notification) {
        // Find the window controller that owns the source surface
        guard let surfaceView = notification.object as? SurfaceView,
              let window = surfaceView.window,
              let wc = windowControllers.first(where: { $0.window === window }) else {
            // No source: only a KEY CalyxWindowController receives the
            // tab. A surface outside windowControllers (the Quick
            // Terminal) therefore produces no tab at all rather than one
            // landing in a background main window -- this does not
            // resolve through currentWindowController, whose fallback
            // (last-key, else first open window) would do exactly that.
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

    /// ghostty's own OSC 133 C/D pane-exit signal
    /// (`GHOSTTY_ACTION_COMMAND_FINISHED`, forwarded as
    /// `.ghosttyCommandFinished`) -- feeds `AgentRegistry
    /// .handleGhosttyCommandFinished`'s shell-integration-coverage
    /// fallback. `userInfo["exit_code"]` is an `Int32?`
    /// (`GhosttyActionRouter.commandFinishedExitCode`'s converted
    /// payload), and a missing or non-`Int32` value there is itself a
    /// legitimate "no exit code reported" reading, not a malformed
    /// notification to bail out on -- so it is read directly rather than
    /// through a `guard let ... else { return }`.
    ///
    /// Observed at app scope, not per window: the notification names a
    /// surface and mutates an app-wide singleton, and the pane it names
    /// need not belong to any main window at all. A QuickTerminal pane is
    /// a real surface with a real Agents row (`QuickTerminalContentView`
    /// holds the same `SplitContainerView` main windows use), and with
    /// every main window closed -- an ordinary state on macOS, where
    /// closing the last window does not terminate the app -- no
    /// `CalyxWindowController` exists to relay anything. The signal fires
    /// once per command with no replay, so a drop is permanent: the row
    /// would keep whatever state it had. Filtering on window membership
    /// would fail for a second reason too, since a pane in a background
    /// tab has already been removed from the view hierarchy
    /// (`SplitContainerView.updateRegistry` does `subviews.forEach {
    /// $0.removeFromSuperview() }`), leaving its `view.window` nil.
    @objc private func handleGhosttyCommandFinishedNotification(_ notification: Notification) {
        guard let surfaceView = notification.object as? SurfaceView else { return }
        guard let surfaceID = surfaceView.surfaceController?.id else { return }
        let exitCode = notification.userInfo?["exit_code"] as? Int32

        AgentRegistry.shared.handleGhosttyCommandFinished(surfaceID: surfaceID, exitCode: exitCode)
    }

    /// Relays `.calyxSurfaceDestroyed` (posted by `SurfaceRegistry
    /// .destroySurface`) into `AgentRegistry`, retiring the destroyed
    /// pane's row and its per-surface bookkeeping. App-scoped for the
    /// same reason `handleGhosttyCommandFinishedNotification` above is: a
    /// pane is torn down exactly once, and it can be torn down while no
    /// main window exists at all.
    @objc private func handleSurfaceDestroyedForAgentMonitor(_ notification: Notification) {
        guard let surfaceID = notification.userInfo?["surfaceID"] as? UUID else { return }
        AgentRegistry.shared.handleSurfaceDestroyed(surfaceID: surfaceID)
    }

    /// `ApprovalInboxStore` posts `.calyxApprovalInboxChanged` on every
    /// submit/decide -- the sole trigger for re-rendering the app-wide
    /// approval panel outside of a window/designated-host change.
    @objc private func handleApprovalInboxChangedForPanel(_ notification: Notification) {
        guard !isApplicationTerminating else { return }
        approvalPanelController.render()
    }

    // MARK: - MCP Apps host

    /// Builds the MCP Apps host, configures Settings > MCP Servers, and
    /// follows the IPC server, the supervisor's connections, the views and
    /// the ghostty config.
    private func startMCPHost() {
        let composition = MCPHostComposition(appDelegate: self)
        mcpHostComposition = composition
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(handleIPCStateDidChangeForMCPHost(_:)), name: .calyxIPCStateDidChange, object: nil)
        center.addObserver(self, selector: #selector(handleMCPConnectionsDidChange(_:)), name: .calyxMCPConnectionsDidChange, object: nil)
        center.addObserver(self, selector: #selector(handleMCPAppViewsChanged(_:)), name: .calyxMCPAppViewsChanged, object: nil)
        center.addObserver(self, selector: #selector(handleGhosttyConfigChangeForMCPHost(_:)), name: .ghosttyConfigChange, object: nil)
        composition.start()
        composition.ipcStateDidChange()
    }

    @objc private func handleIPCStateDidChangeForMCPHost(_ notification: Notification) {
        mcpHostComposition?.ipcStateDidChange()
    }

    @objc private func handleMCPConnectionsDidChange(_ notification: Notification) {
        mcpHostComposition?.connectionsDidChange()
    }

    @objc private func handleMCPAppViewsChanged(_ notification: Notification) {
        mcpHostComposition?.appViewsDidChange()
    }

    /// App-level config changes only (`object == nil`): theme presets and
    /// glass opacity reload the app config, and the theme inputs read the
    /// app config.
    @objc private func handleGhosttyConfigChangeForMCPHost(_ notification: Notification) {
        guard notification.object == nil else { return }
        mcpHostComposition?.hostEnvironmentDidChange()
    }

    #if DEBUG
    /// Test seam: `registerNotificationObservers` is `private`, and its
    /// only production caller is `applicationDidFinishLaunching`, which
    /// returns before reaching it in the unit-test host
    /// (`LaunchEnvironmentPolicy.isUnitTestHost`). Lets a test register
    /// this delegate's observers for real -- the same call production
    /// makes, so the two cannot drift -- instead of asserting against a
    /// narrower registration path nothing else runs. Callers must pair it
    /// with `NotificationCenter.default.removeObserver(self)` so the
    /// registration does not outlive the test. DO NOT use from production
    /// code.
    func _testRegisterNotificationObservers() {
        registerNotificationObservers()
    }
    #endif

    // MARK: - Window Management

    @objc func createNewWindow() {
        openNewWindow(initialHost: nil)
    }

    /// `initialHost` (remote sessions): forwarded to
    /// `CalyxWindowController.init(initialHost:)` for the new window's
    /// sole initial tab. `nil` (`createNewWindow()` above, every
    /// existing caller) is unchanged, a local window exactly as before
    /// this parameter existed. Reached by `spawnRemoteSessionTab(host:)`
    /// when no key window controller exists yet to add a tab to. Named
    /// distinctly from `createNewWindow()` (rather than an overload of
    /// it) since `#selector(createNewWindow)` above resolves by base
    /// name alone and would become ambiguous with a same-named overload.
    private func openNewWindow(initialHost: String?) {
        let initialTab = Tab()
        let windowSession = WindowSession(initialTab: initialTab)
        appSession.addWindow(windowSession)

        let wc = CalyxWindowController(windowSession: windowSession, initialHost: initialHost)
        windowControllers.append(wc)
        refreshApprovalPanel()
        wc.showWindow(nil)
    }

    /// `--demo-window-frame=<W>x<H>` (DemoWindowFrameArgument.parse):
    /// forces the just-created main window to a fixed, screen-recording-
    /// friendly size and position, so the scripted demo scenario
    /// (CalyxUITests/DemoRecordingScenario.swift) always frames
    /// identically regardless of this machine's actual screen size or
    /// `CalyxWindowController`'s own 800x600-then-`center()` default.
    /// Gated on `--uitesting` (mirrors every other `--uitesting`-only
    /// behavior in this file) even though a production launch never
    /// receives `--demo-window-frame` in the first place -- an explicit
    /// gate here keeps the intent readable at the call site, per this
    /// argument's own spec (only ever consulted alongside `--uitesting`).
    private func applyDemoWindowFrameIfNeeded() {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("--uitesting"),
              let size = DemoWindowFrameArgument.parse(arguments),
              let window = windowControllers.last?.window else {
            return
        }
        // Same NSScreen.main?.visibleFrame fallback shape as
        // restoreWindow(_:)'s own screen-clamping above, for consistency.
        let screenFrame = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let origin = CGPoint(x: screenFrame.midX - size.width / 2, y: screenFrame.midY - size.height / 2)
        window.setFrame(CGRect(origin: origin, size: size), display: true)
    }

    #if DEBUG
    /// Test seam: called with the chosen target controller immediately
    /// before `spawnRemoteSessionTab` calls `targetWC.createNewTab(host:)`.
    /// Needed because `createNewTab` itself would silently no-op if
    /// driven for real here: it guards on `GhosttyAppController.shared.app`,
    /// which is `nil` in this test host (see
    /// `CalyxWindowControllerCreateManagedSurfaceRemoteHostTests`'s own
    /// dummy-app workaround for the identical constraint) -- so there is
    /// no observable effect to assert on without this hook. `nil` (the
    /// default) leaves production behavior unchanged: `createNewTab`
    /// still runs for real when this hook is nil. DO NOT use from
    /// production code.
    var _spawnRemoteSessionTabAddTabHookForTesting: ((CalyxWindowController) -> Void)?

    /// Test seam: called
    /// immediately before `spawnRemoteSessionTab` calls
    /// `openNewWindow(initialHost:)`, mirroring
    /// `_attachWindowCreationHookForTesting`'s exact "intercept right
    /// before the actually-unsafe call" pattern -- `openNewWindow`
    /// constructs a real `CalyxWindowController` and calls
    /// `showWindow(nil)` for real, confirmed unsafe to drive in this test
    /// host (see `AppDelegateAttachWindowTests`'s header for the
    /// identical hang). `nil` (the default) leaves production behavior
    /// unchanged. DO NOT use from production code.
    var _spawnRemoteSessionTabNewWindowHookForTesting: (() -> Void)?
    #endif

    /// `SessionBrowserModel.onRemoteSessionRequested`'s target (Session
    /// Browser's remote-host picker, `SessionBrowserWindowController
    /// .attachRemote(_:)`): spawns a new tab against `host` in the
    /// current window's controller if one exists -- unlike `handleNewTab`'s
    /// own key-window-only lookup for a local ghostty-originated new tab,
    /// this resolves through `currentWindowController` -- otherwise opens
    /// a fresh window whose sole initial tab spawns against `host`,
    /// reaching a window controller the same way `attachWindow` always
    /// does for a session with no live surface anywhere yet.
    ///
    /// Every real caller of this method fires from inside the Session
    /// Browser's own button action, at which point the Session Browser's
    /// own window (not any `CalyxWindowController`'s window) is key -- so
    /// an isKeyWindow-only lookup never matches a real main window in
    /// practice, unlike `handleNewTab`, whose source surface is always a
    /// `CalyxWindowController`'s own window when one owns it at all.
    /// Resolving through `currentWindowController` instead
    /// (`AppDelegateAttachSessionAsTabTests` covers the identical case
    /// for the local session-browser Attach flow) means a main window
    /// that exists but isn't key still receives the new tab instead of a
    /// redundant new window opening. See
    /// `AppDelegateSpawnRemoteSessionTabWindowLookupTests` for coverage;
    /// the two hooks above make this lookup observable without driving a
    /// real window/surface in the test process.
    func spawnRemoteSessionTab(host: String?) {
        if let targetWC = currentWindowController {
            #if DEBUG
            _spawnRemoteSessionTabAddTabHookForTesting?(targetWC)
            if _spawnRemoteSessionTabAddTabHookForTesting != nil { return }
            #endif
            targetWC.createNewTab(host: host)
            return
        }
        #if DEBUG
        if let hook = _spawnRemoteSessionTabNewWindowHookForTesting {
            hook()
            return
        }
        #endif
        openNewWindow(initialHost: host)
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
        refreshApprovalPanel()
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
    /// Test seam: when non-nil, consulted
    /// right where `attachWindow` is about to construct a real window
    /// and ghostty surface, invoked instead of that real work, which
    /// never runs. Driving `attachWindow` end-to-end with a live
    /// surface is unsafe from this test host (confirmed empirically:
    /// it hangs the XCTest process indefinitely, no other test in
    /// this suite creates a real ghostty surface or calls
    /// `showWindow`). This seam lets `AppDelegateAttachWindowTests`
    /// observe WHETHER `attachWindow` reaches its window-creation step
    /// at all, exactly what the double-attach guard above must prevent
    /// for an already-attached sessionID, without ever performing that
    /// real, unsafe-to-test work. Does not affect production behavior:
    /// `nil` (the default) leaves this line as a no-op; every guard
    /// ABOVE this point still runs for real, unmodified. DO NOT use
    /// from production code.
    var _attachWindowCreationHookForTesting: (() -> Void)?

    /// Test seam: called with the
    /// constructed placeholder `tab`, immediately before
    /// `_attachWindowCreationHookForTesting`'s own check -- that hook
    /// fires and returns BEFORE the placeholder tab is even constructed,
    /// so no existing seam can observe the `SessionRef` it would have
    /// produced. A second, independent, purely additive observer instead
    /// of changing that hook's signature, mirroring `AppDelegate
    /// ._createSurfaceWithPwdCommandObserverForTesting`'s/
    /// `CalyxWindowController._performReconnectCommandObserverForTesting`'s
    /// identical reasoning. `nil` (the default) leaves production
    /// behavior unchanged; every existing test using
    /// `_attachWindowCreationHookForTesting` alone is unaffected. DO NOT
    /// use from production code.
    var _attachWindowPlaceholderTabObserverForTesting: ((Tab) -> Void)?
    #endif

    func attachWindow(sessionID: String, cwd: String?, host: String? = nil) {
        guard let app = GhosttyAppController.shared.app else { return }

        // A sessionID already registered
        // in SessionSurfaceMap already has a live surface somewhere in
        // this process. This covers the session browser's double-click/
        // stale-row race (rows only refresh on poll, and this method has
        // no debounce of its own). Focus that existing surface's window
        // instead of creating a second one. Checked BEFORE the
        // test-creation hook below, so AppDelegateAttachWindowTests can
        // observe the guard firing without ever reaching real window/
        // surface creation.
        //
        // `focusWindowForExistingSession`
        // returns `false` for a STALE mapping (registered, but no
        // controller anywhere actually contains the surfaceID, e.g. left
        // behind by a non-terminating window close), having already
        // unregistered it, in which case this falls through to a fresh
        // attach below instead of silently doing nothing.
        if SessionSurfaceMap.shared.surfaceID(for: sessionID) != nil {
            if focusWindowForExistingSession(sessionID: sessionID) {
                return
            }
        }

        let placeholderLeafID = UUID()
        let tab = Tab(
            // NSHomeDirectory() ignores a HOME env override; use the canonical resolver.
            title: SessionTabTitle.fromCwd(cwd, home: SessionRootResolver().resolve()),
            pwd: cwd,
            splitTree: SplitTree(leafID: placeholderLeafID),
            sessionRefs: [placeholderLeafID: SessionRef(sessionID: sessionID, host: host)]
        )

        // Tab's own init has no side effects (no
        // FFI, no SessionSurfaceMap/global registration), so constructing
        // it ahead of the creation hook below is behaviorally inert for
        // every existing caller -- the hook still fires (and still
        // returns early) at exactly the same decision point relative to
        // every OTHER guard, just after this (side-effect-free) tab value
        // now exists to observe.
        #if DEBUG
        _attachWindowPlaceholderTabObserverForTesting?(tab)
        if let hook = _attachWindowCreationHookForTesting {
            hook()
            return
        }
        #endif

        let windowSession = WindowSession(initialTab: tab)
        let (window, wc) = makeRestoringWindowController(
            contentRect: NSRect(origin: .zero, size: CalyxWindowController.defaultContentSize),
            windowSession: windowSession
        )

        // Starts the
        // fetch without waiting on it, window/surface creation proceeds
        // immediately (see fetchSessionsForAgentResume's doc comment).
        fetchSessionsForAgentResume()
        let restored = restoreTabSurfaces(tab: tab, app: app, window: window)
        guard restored || fallbackCreateSurface(tab: tab, app: app, window: window) else {
            cleanupFailedWindow(window, windowSession, wc, message: "Failed to attach window for session \(sessionID)")
            return
        }

        wc.activateRestoredSession()
        wc.showWindow(nil)
    }

    #if DEBUG
    /// Test seam: when non-nil, called
    /// instead of the real `wc.showWindow(nil)` inside
    /// `focusWindowForExistingSession`, mirroring
    /// `_attachWindowCreationHookForTesting`'s "hook right before the
    /// actually-unsafe-to-test call" pattern (see that seam's doc
    /// comment): no other test in this suite calls `showWindow` for real,
    /// and this avoids the same unverified risk for the "found an
    /// existing controller" branch. `nil` (the default) leaves production
    /// behavior unchanged. DO NOT use from production code.
    var _focusWindowForExistingSessionShowHookForTesting: ((CalyxWindowController) -> Void)?
    #endif

    /// Every tab group of every window controller that is not mid-teardown
    /// (`isClosingForShutdown`), each paired with its owning controller. A
    /// closing window's tabs and surfaces are about to be torn down or
    /// preserved into a snapshot, so they are never a valid target for
    /// focus or tab adoption.
    private var nonClosingWindowGroups: [(controller: CalyxWindowController, group: TabGroup)] {
        windowControllers
            .filter { !$0.isClosingForShutdown }
            .flatMap { controller in controller.windowSession.groups.map { (controller: controller, group: $0) } }
    }

    /// Brings the window already hosting `sessionID`'s live surface
    /// to the front, instead of `attachWindow` creating a second one for
    /// the same session. Returns `true` once a live controller was found
    /// and focused, `false` when the mapping was stale (see below); the
    /// caller (`attachWindow`) falls through to a fresh attach on `false`.
    ///
    /// When NO controller contains
    /// the mapped surfaceID at all (a stale mapping left behind by, e.g.,
    /// a non-terminating window close that unregistered every OTHER
    /// tracked surface but somehow left this one stale, or a window
    /// that's mid-teardown, skipped below), unregisters the stale entry
    /// and returns `false` instead of silently doing nothing.
    ///
    /// Also activates the tab/group
    /// containing `surfaceID` (`CalyxWindowController.activateTabContaining`,
    /// reusing that controller's existing tab-switch logic instead of
    /// reimplementing containment) before showing the
    /// window, so a session living in a background tab is actually
    /// visible, not just the window with whatever tab happened to
    /// already be active. Searches only `nonClosingWindowGroups`, whose
    /// own doc comment explains why a mid-teardown controller is never a
    /// valid focus target.
    private func focusWindowForExistingSession(sessionID: String) -> Bool {
        guard let surfaceID = SessionSurfaceMap.shared.surfaceID(for: sessionID) else { return false }
        guard let wc = nonClosingWindowGroups.first(where: { $0.group.tab(owningSurface: surfaceID) != nil })?.controller else {
            SessionSurfaceMap.shared.unregister(sessionID: sessionID)
            return false
        }

        wc.activateTabContaining(surfaceID: surfaceID)

        #if DEBUG
        if let hook = _focusWindowForExistingSessionShowHookForTesting {
            hook(wc)
            return true
        }
        #endif
        wc.showWindow(nil)
        return true
    }

    #if DEBUG
    /// Test seam: when
    /// non-nil, called with the `SessionAttachRoutingPolicy.Decision`
    /// `attachSessionAsTab` just computed, immediately before acting on
    /// it. Mirrors `_attachWindowPlaceholderTabObserverForTesting`'s
    /// "new, narrow, DEBUG-gated, nil-by-default" shape: `nil` (the
    /// default) leaves production behavior unchanged. DO NOT use from
    /// production code.
    var _attachSessionAsTabRoutingObserverForTesting: ((SessionAttachRoutingPolicy.Decision) -> Void)?
    #endif

    /// Session Browser's "Attach" action (`SessionBrowserWindowController
    /// .attach(_:)`'s single entry point, replacing a direct
    /// `attachWindow` call): keeps the local-attach flow consistent with
    /// the sibling remote-session flow (`spawnRemoteSessionTab(host:)`),
    /// per `SessionAttachRoutingPolicy`'s own doc comment. Computes both
    /// of that policy's inputs from real `AppDelegate` state --
    /// `isAttachedHere` from `SessionSurfaceMap` (identical to
    /// `attachWindow`'s own double-attach guard), `hasAvailableWindow`
    /// from the same `currentWindowController` resolution
    /// `spawnRemoteSessionTab` also uses (see that method's own doc
    /// comment for why an `isKeyWindow`-only lookup never matches a real
    /// main window from either call site: both fire from inside the
    /// Session Browser's own button action, at which point the Session
    /// Browser's plain `NSWindow`, not any `CalyxWindowController`'s
    /// window, is key) -- and dispatches to the matching action.
    ///
    func attachSessionAsTab(sessionID: String, cwd: String?, host: String? = nil) {
        let isAttachedHere = SessionSurfaceMap.shared.surfaceID(for: sessionID) != nil
        // Same `currentWindowController` resolution as
        // `spawnRemoteSessionTab`'s own fix, and for the identical
        // reason: whichever controller this resolves to is also the one
        // `.attachAsTab` below adds the new tab to, so
        // `hasAvailableWindow` and the eventual target come from the
        // same lookup.
        let targetWindowController = currentWindowController
        let decision = SessionAttachRoutingPolicy.decide(
            isAttachedHere: isAttachedHere, hasAvailableWindow: targetWindowController != nil
        )
        #if DEBUG
        _attachSessionAsTabRoutingObserverForTesting?(decision)
        #endif
        switch decision {
        case .focusExistingSurface:
            if focusWindowForExistingSession(sessionID: sessionID) { return }
            // Stale mapping: focusWindowForExistingSession already
            // unregistered it above. Re-decide now that
            // isAttachedHere is no longer true, exactly one recursion.
            attachSessionAsTab(sessionID: sessionID, cwd: cwd, host: host)
        case .attachAsTab:
            if let target = targetWindowController {
                attachSessionAsNewTab(sessionID: sessionID, cwd: cwd, host: host, in: target)
            }
        case .attachAsNewWindow:
            attachWindow(sessionID: sessionID, cwd: cwd, host: host)
        }
    }

    #if DEBUG
    /// Test seam: mirrors
    /// `_attachWindowPlaceholderTabObserverForTesting` exactly -- same
    /// "new, narrow, DEBUG-gated, nil-by-default, purely additive"
    /// shape, just for `attachSessionAsNewTab`'s placeholder `Tab`
    /// instead of `attachWindow`'s. `attachSessionAsNewTab` is private
    /// and has no other seam that observes the placeholder tab it
    /// constructs before wiring it into `target`, so without this,
    /// nothing in this file's `.attachAsTab` path could pin the tab's
    /// initial `title`/`pwd`. `nil` (the default) leaves production
    /// behavior unchanged; every existing test reaching this method
    /// (e.g. `AppDelegateAttachSessionAsTabTests`'s `.attachAsTab` row)
    /// is unaffected. DO NOT use from production code.
    var _attachSessionAsNewTabPlaceholderTabObserverForTesting: ((Tab) -> Void)?

    /// Test seam: mirrors `_attachWindowCreationHookForTesting` exactly,
    /// for `attachSessionAsNewTab`'s `.attachAsTab` branch. When non-nil,
    /// called immediately after the placeholder observer above and BEFORE
    /// this method reaches `GhosttyAppController.shared.app` /
    /// `restoreTabSurfaces` / `fallbackCreateSurface` / `attachRestoredTab`
    /// -- the same real, ghostty-FFI-driven surface + PTY creation
    /// `attachWindow` guards behind its own creation hook. Without this,
    /// every test driving the `.attachAsTab` route (an unregistered
    /// sessionID with a window available) spawns a real ghostty surface
    /// and a real login-shell PTY in the unit-test host, which leak across
    /// the process-wide `SurfaceRegistry`/`SessionSurfaceMap`/
    /// `GhosttyAppController.shared` singletons and crash the XCTest host
    /// during a later surface teardown (confirmed unsafe, identical to the
    /// hang/crash `_attachWindowCreationHookForTesting`'s own doc comment
    /// describes). `nil` (the default) leaves production behavior
    /// unchanged. DO NOT use from production code.
    var _attachSessionAsNewTabCreationHookForTesting: (() -> Void)?

    /// Test seam: mirrors
    /// `_attachSessionAsNewTabPlaceholderTabObserverForTesting` exactly
    /// -- fires once, immediately after `openHerdrAttachTab` builds its
    /// placeholder `Tab` (deliberately empty `sessionRefs`: herdr
    /// session identity must never enter `Tab.sessionRefs`/
    /// `SessionSurfaceMap`), so a test
    /// can inspect that shape without reaching real surface creation.
    /// `nil` (the default) leaves production behavior unchanged. DO NOT
    /// use from production code.
    var _openHerdrAttachTabPlaceholderTabObserverForTesting: ((Tab) -> Void)?

    /// Test seam: substitutes ONLY the real ghostty-FFI
    /// `SurfaceRegistry.createSurface(app:config:pwd:command:)` step
    /// `openHerdrAttachTab` would otherwise reach -- unsafe in the
    /// unit-test host, identical to
    /// `_attachSessionAsNewTabCreationHookForTesting`'s own reasoning.
    /// Unlike that `() -> Void` hook, this one also stands in for the
    /// call's result: `openHerdrAttachTab` has no existing session to
    /// reattach (unlike `attachSessionAsNewTab`, which derives its
    /// command internally via `restoreTabSurfaces`/`SessionRef`), so the
    /// `command` this closure receives IS the exact string that would
    /// otherwise reach `createSurface`, and its return value stands in
    /// for the surface UUID that call would have produced.
    ///
    /// When this
    /// hook is set, `openHerdrAttachTab` must still perform
    /// `HerdrHostedSurfaces.shared.register(_:)` with the returned UUID,
    /// then return -- exactly like
    /// `_attachSessionAsNewTabCreationHookForTesting` bails out before
    /// `attachRestoredTab` -- so `AppDelegateOpenHerdrAttachTabTests` can
    /// observe the registration without ever reaching a real window
    /// attach. `nil` (the default) leaves production behavior unchanged.
    /// DO NOT use from production code.
    var _openHerdrAttachTabSurfaceCreationHookForTesting: ((String) -> UUID)?
    #endif

    /// Herdr attach: opens `command` (an already-synthesized,
    /// escaped `<herdrBin>`/`<herdrBin> --session <name>` invocation --
    /// see `HerdrAttachCommandSynthesizer`) as a new tab, `title`-labeled.
    /// Mirrors `attachSessionAsNewTab` (below) with every session-identity
    /// concern stripped: no `SessionRef`, no `SessionSurfaceMap`
    /// registration -- herdr's own identity must never enter either:
    /// `SessionReconnectCoordinator
    /// .childExited`'s surfaceMap-registration guard is what keeps herdr
    /// panes structurally unreachable from calyx-session's own
    /// reconnect/kill/restore paths.
    ///
    /// Builds the placeholder `Tab` (empty `sessionRefs`, fires the
    /// observer above), resolves a target window through the same
    /// `currentWindowController` resolution `attachSessionAsTab` does,
    /// then creates the real surface and attaches the tab to that
    /// window.
    ///
    /// No target window available (e.g. every Calyx window closed while
    /// the Session Browser itself, a separate `NSWindow`, stayed open)
    /// silently does nothing -- no new-window fallback: unlike
    /// `attachSessionAsTab`'s `SessionAttachRoutingPolicy`, herdr has no
    /// daemon-backed session to justify spawning a brand-new window for,
    /// and the no-dialog philosophy (herdr absence/death never
    /// surfaces an error) extends naturally to this edge case too.
    ///
    /// When `_openHerdrAttachTabSurfaceCreationHookForTesting`
    /// is set, its returned UUID is registered with `HerdrHostedSurfaces`
    /// and this method returns immediately after -- mirrors
    /// `attachSessionAsNewTab`'s own `_attachSessionAsNewTabCreationHookForTesting`
    /// bailing out before `attachRestoredTab`, so a test never drives a
    /// real ghostty surface/window-layout pass (confirmed unsafe/hang-prone
    /// in this test host, see that hook's own doc comment).
    func openHerdrAttachTab(command: String, title: String) {
        let placeholderLeafID = UUID()
        let tab = Tab(title: title, splitTree: SplitTree(leafID: placeholderLeafID))

        #if DEBUG
        _openHerdrAttachTabPlaceholderTabObserverForTesting?(tab)
        #endif

        guard let target = currentWindowController,
              let app = GhosttyAppController.shared.app,
              let window = target.window
        else { return }

        #if DEBUG
        if let hook = _openHerdrAttachTabSurfaceCreationHookForTesting {
            HerdrHostedSurfaces.shared.register(hook(command))
            return
        }
        #endif

        var config = GhosttyFFI.surfaceConfigNew()
        config.scale_factor = Double(window.backingScaleFactor)

        guard let surfaceID = tab.registry.createSurface(app: app, config: config, pwd: tab.pwd, command: command) else {
            logger.error("Failed to create herdr attach surface")
            return
        }

        tab.splitTree = SplitTree(leafID: surfaceID)
        HerdrHostedSurfaces.shared.register(surfaceID)
        target.attachRestoredTab(tab)
    }

    /// `.attachAsTab`'s real work: reuses `restoreTabSurfaces`/
    /// `fallbackCreateSurface` -- the same machinery `attachWindow` uses
    /// to reattach `sessionID` to a placeholder leaf -- but wires the
    /// result into `target`'s EXISTING window as a new tab
    /// (`CalyxWindowController.attachRestoredTab(_:)`) instead of
    /// constructing a brand-new window. Deliberately does not route
    /// through `createNewTab`/`SessionSpawnPlanner`: both of those spawn
    /// a brand-new session (`createManagedSurface`), not a reattach to
    /// an already-running one. A total surface-creation failure leaves
    /// `target` untouched (the tab is only wired in on success), so no
    /// window/group cleanup is needed the way `attachWindow`'s own
    /// failure path needs `cleanupFailedWindow`.
    private func attachSessionAsNewTab(sessionID: String, cwd: String?, host: String?, in target: CalyxWindowController) {
        guard let app = GhosttyAppController.shared.app, let window = target.window else { return }

        let placeholderLeafID = UUID()
        let tab = Tab(
            // NSHomeDirectory() ignores a HOME env override; use the canonical resolver.
            title: SessionTabTitle.fromCwd(cwd, home: SessionRootResolver().resolve()),
            pwd: cwd,
            splitTree: SplitTree(leafID: placeholderLeafID),
            sessionRefs: [placeholderLeafID: SessionRef(sessionID: sessionID, host: host)]
        )

        #if DEBUG
        _attachSessionAsNewTabPlaceholderTabObserverForTesting?(tab)
        if let hook = _attachSessionAsNewTabCreationHookForTesting {
            hook()
            return
        }
        #endif

        fetchSessionsForAgentResume()
        let restored = restoreTabSurfaces(tab: tab, app: app, window: window)
        guard restored || fallbackCreateSurface(tab: tab, app: app, window: window) else {
            logger.error("Failed to attach tab for session \(sessionID, privacy: .public)")
            return
        }

        target.attachRestoredTab(tab)
    }

    /// The window-construction +
    /// registration boilerplate shared identically by `attachWindow` and
    /// `restoreWindow`. Does NOT cover the tab-restoration control flow
    /// around it (single guard vs. loop+accumulator) or the fullscreen
    /// branch, which genuinely differ and must stay separate. Registers
    /// `windowSession` with `appSession`
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
        refreshApprovalPanel()
        return (window, wc)
    }

    /// The failure-cleanup triple shared identically
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
        refreshApprovalPanel()
        logger.error("\(message, privacy: .public)")
    }

    /// Closing the LAST window no longer terminates the app (Ghostty
    /// parity — see `applicationShouldTerminateAfterLastWindowClosed`),
    /// so this is now purely per-window bookkeeping: unregister
    /// `controller` and, unless the app is already mid-quit
    /// (`isApplicationTerminating` — `applicationShouldTerminate` already
    /// captured its own `pendingTerminationSnapshot` and will save it in
    /// `applicationWillTerminate`; nothing here should race that),
    /// persist the now-smaller session.
    ///
    /// Saves SYNCHRONOUSLY (`saveImmediately()`), not `requestSave()`'s
    /// debounced write, the moment this empties `windowControllers`: a
    /// Cmd+Q immediately following this close would otherwise race
    /// `requestSave()`'s debounce, and `SessionPersistenceActor
    /// .saveAtTermination`'s own "never let an empty snapshot clobber a
    /// non-empty on-disk one" guard would then let the STALE, still-
    /// non-empty on-disk snapshot survive untouched — restoring this
    /// already-killed session's windows on the next launch. A window
    /// that survives this close (`windowControllers` still non-empty)
    /// has no such race: `requestSave()` exactly as before.
    func removeWindowController(_ controller: CalyxWindowController) {
        appSession.removeWindow(id: controller.windowSession.id)
        windowControllers.removeAll { $0 === controller }
        guard !isApplicationTerminating else { return }
        // The removed controller may have been the current window --
        // re-render so the panel picks up whatever window-agnostic
        // request it was showing, now against the new current window.
        refreshApprovalPanel()
        if windowControllers.isEmpty {
            saveImmediately()
        } else {
            requestSave()
        }
    }

    // MARK: - GHOSTTY_ACTION_CLOSE_ALL_WINDOWS / GHOSTTY_ACTION_GOTO_WINDOW
    //
    // App-scoped libghostty keybind wiring. Router-side dispatch is
    // `GhosttyActionRouter.handleCloseAllWindows`/`.handleGotoWindow`
    // (`GhosttyBridge/GhosttyAction.swift`), which translate the C target/
    // enum payloads and call straight into these methods, mirroring
    // `handleQuit`/`handleOpenConfig`/`handleToggleQuickTerminal`'s
    // established "app-target action -> AppDelegate/singleton directly,
    // no notification round-trip" shape. `closeAllWindows`'s close
    // contract is covered by `AppDelegateCloseAllWindowsTests`;
    // `adjacentWindowIndex`'s pure index arithmetic is covered by
    // `AppDelegateAdjacentWindowIndexTests`. `focusAdjacentWindow` itself
    // has no direct unit test — see its own doc comment below.

    /// `GHOSTTY_ACTION_CLOSE_ALL_WINDOWS`. Closes every managed window.
    ///
    /// Closing windows -- one at a time or
    /// all at once -- never terminates the app any more
    /// (`applicationShouldTerminateAfterLastWindowClosed` always returns
    /// `false`), and every OTHER close path in this codebase closes/kills
    /// silently, without confirming anything first:
    /// `CalyxWindowController.closeLastWindow()`, `processCloseWindow()`,
    /// `closeTab`/`closeActiveGroup`/`closeAllTabsInGroup`/
    /// `closeFocusedSessionSurface` (see each's own doc comment in
    /// `CalyxWindowController.swift`). `closeTab` and, since they route
    /// through `closeGroups`, `closeActiveGroup`/`closeAllTabsInGroup`
    /// each run the unsent-review-comments prompt per diff tab; none of
    /// them consults the quit gate.
    /// `confirmQuitIfNeeded()` below documents itself as having exactly
    /// one legitimate caller, `applicationShouldTerminate` (Cmd+Q) --
    /// adding a second call site here would contradict that.
    ///
    /// So: closing every window in one action is no different in kind
    /// from closing them one at a time. Each closed window's own
    /// `windowWillClose` sees `isAppActuallyTerminating == false` and
    /// kills (never detaches) its own persistent sessions exactly like an
    /// ordinary individual close would -- this is what keeps this method
    /// honoring the "close=kill / quit=detach" contract
    /// (`SessionCloseKillPolicy.swift`) even with a Quick Terminal open,
    /// which needs no special-casing here any more either: nothing about
    /// this loop can terminate the app, so there is no
    /// "would-this-actually-quit" branch left to get wrong.
    /// `removeWindowController` synchronously saves the (eventually
    /// empty) snapshot once the last managed window is removed, exactly
    /// like any other close that happens to empty `windowControllers`
    /// (see that method's own doc comment) -- no separate save call is
    /// needed here.
    ///
    /// This also matches upstream ghostty's own product decision that
    /// `close_all_windows` is not `quit`: Ghostty defaults
    /// `quit-after-last-window-closed` to `false`.
    ///
    /// Uses `window.close()`, never `performClose(_:)`: mirrors
    /// `CalyxWindowController.closeLastWindow()`'s own choice. There is
    /// no `windowShouldClose` override left anywhere in this codebase for
    /// `performClose` to usefully round-trip through any more.
    ///
    /// `targets` snapshots `windowControllers` before either loop below:
    /// closing a window synchronously cascades `windowWillClose` ->
    /// `removeWindowController`, which mutates the live array in place,
    /// so iterating the live property directly would skip entries as it
    /// shrinks out from under the loop.
    ///
    /// `isClosingForShutdown` is set for every target in its own loop,
    /// BEFORE any window closes (not interleaved one-at-a-time with the
    /// close loop below): mirrors `closeLastWindow()`'s own "set before
    /// `window?.close()`" ordering -- needed so `windowDidExitFullScreen`'s
    /// stale-snapshot guard sees it in time (see that flag's own doc
    /// comment) -- applied to the whole batch up front so a fullscreen
    /// window later in `targets` is already protected even while an
    /// earlier window in the same batch is still mid-close.
    func closeAllWindows() {
        let targets = windowControllers
        guard !targets.isEmpty else { return }
        for wc in targets { wc.isClosingForShutdown = true }
        for wc in targets { wc.window?.close() }
    }

    /// GitHub issue #45 follow-on: a distinct `Selector` (`closeAllWindows:`,
    /// NOT the no-argument `closeAllWindows()` above, which is
    /// `GHOSTTY_ACTION_CLOSE_ALL_WINDOWS`'s existing keybind receiver,
    /// see that method's own doc comment) for the File menu's "Close All
    /// Windows" item (`setupMainMenu()`). Just forwards to the existing
    /// no-argument `closeAllWindows()` above — same call, distinct
    /// selector purely so the menu item's `action` has an `Any?` sender
    /// parameter to satisfy `NSMenuItem`'s target-action signature.
    @objc func closeAllWindows(_ sender: Any?) {
        closeAllWindows()
    }

    /// Pure index arithmetic for `GHOSTTY_ACTION_GOTO_WINDOW`
    /// (`GHOSTTY_GOTO_WINDOW_PREVIOUS`/`GHOSTTY_GOTO_WINDOW_NEXT` map to
    /// `step: -1`/`step: +1` respectively). Deliberately free of any
    /// `NSWindow`/`NSApp` access so it is unit-testable in isolation (see
    /// `AppDelegateAdjacentWindowIndexTests`).
    ///
    /// `currentIndex == nil` always resolves to `0`, regardless of
    /// `step`'s sign: with no reference point to step "from", there is
    /// nothing for a direction to modify, so this is its own standalone
    /// rule — NOT `currentIndex ?? 0` substituted into the modular-step
    /// formula below (that substitution would instead land on
    /// `count - 1` for a backward step).
    ///
    /// Swift's `%` returns a NEGATIVE result for a negative dividend, so
    /// `((currentIndex + step) % count + count) % count` double-
    /// normalizes the result back into `0..<count`.
    nonisolated static func adjacentWindowIndex(currentIndex: Int?, step: Int, count: Int) -> Int? {
        guard count > 1, step != 0 else { return nil }
        guard let currentIndex else { return 0 }
        let next = ((currentIndex + step) % count + count) % count
        return next == currentIndex ? nil : next
    }

    /// Focuses the previous/next managed window (`step: -1`/`+1`), for
    /// `GHOSTTY_ACTION_GOTO_WINDOW`, resolved via `adjacentWindowIndex`
    /// above.
    ///
    /// Candidates come from `windowControllers`, NOT `NSApp.windows`:
    /// the latter also includes the Settings/Session Browser/Quick
    /// Terminal panels, which have no place in this cycle order and no
    /// stable ordering relative to the managed windows. A candidate must
    /// have a live window that is `isVisible && !isMiniaturized`.
    ///
    /// The "current" position prefers `isKeyWindow`, falling back to
    /// `isMainWindow` (e.g. invoked while some non-managed panel holds
    /// key status but a managed window is still main), and `nil` —
    /// resolved to index 0 by `adjacentWindowIndex` — if neither is
    /// found.
    ///
    /// Not directly unit-tested: exercising the isVisible/isKeyWindow/
    /// isMiniaturized filtering above needs real, visible `NSWindow`
    /// instances, which is unsafe to drive from this test host (see
    /// `AppDelegateAdjacentWindowIndexTests`'s own header comment for
    /// why coverage is concentrated in `adjacentWindowIndex` instead).
    /// `makeKeyAndOrderFront` below triggers `windowDidBecomeKey` ->
    /// `restoreFocus()` on the target controller, so no explicit surface
    /// focus call is needed here.
    @discardableResult
    func focusAdjacentWindow(step: Int) -> Bool {
        let candidates = windowControllers.filter { controller in
            guard let window = controller.window else { return false }
            return window.isVisible && !window.isMiniaturized
        }
        let currentIndex = candidates.firstIndex { $0.window?.isKeyWindow == true }
            ?? candidates.firstIndex { $0.window?.isMainWindow == true }
        guard let target = Self.adjacentWindowIndex(currentIndex: currentIndex, step: step, count: candidates.count) else {
            return false
        }
        candidates[target].window?.makeKeyAndOrderFront(nil)
        return true
    }

    /// Set for the duration of `confirmQuitIfNeeded`'s `alert.runModal()`
    /// call (see that method's own doc comment). While `true`, other
    /// MainActor entry points that could mutate window/tab state out
    /// from under an in-flight confirm-quit prompt, currently
    /// `CalyxWindowController.handleShowChildExitedNotification` and
    /// `handleSessionReconnectDecision`, defer their work instead of
    /// acting immediately (see each's doc comment). The `didSet` below
    /// posts `.calyxConfirmingQuitDidEnd` on the `true` -> `false`
    /// transition so every live `CalyxWindowController` can replay
    /// whatever it deferred. This fires for both
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
    /// Test seam: lets tests simulate the
    /// `isConfirmingQuit` gate flipping on/off without driving a real,
    /// blocking `NSAlert.runModal()` through `confirmQuitIfNeeded`,
    /// mirrors `SurfaceRegistry._testInsert`'s naming/gating convention.
    /// Production code only ever toggles `isConfirmingQuit` itself, from
    /// within `confirmQuitIfNeeded`'s own bracket. DO NOT use from
    /// production code.
    func _setConfirmingQuitForTesting(_ value: Bool) {
        isConfirmingQuit = value
    }
    #endif

    /// Returns true if the app should proceed with quit, false if user
    /// cancelled. Called only from `applicationShouldTerminate` (the
    /// Cmd+Q / "Quit Calyx" path): closing a
    /// window, tab, or pane never terminates the app any more (see
    /// `applicationShouldTerminateAfterLastWindowClosed`), so this is the
    /// only remaining route to this prompt, and its wording is always
    /// the kill-semantics one: a real process is about to be killed by
    /// quitting.
    func confirmQuitIfNeeded() -> Bool {
        // Check for running processes
        guard let app = GhosttyAppController.shared.app,
              ghostty_app_needs_confirm_quit(app) else {
            return true
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Quit Calyx?"
        alert.informativeText = "A process is still running. Do you want to quit?"
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

    /// Not `private` any more: mirrors
    /// `closeAllTabsInGroup(id:)`'s/`processChildExited`'s/
    /// `handleSessionReconnectDecision`'s own identical "un-privated for
    /// direct test access" precedent. Builds and assigns a fresh
    /// `NSApp.mainMenu` -- pure menu/item construction, no ghostty
    /// surface, no window, no async work -- so, unlike `attachWindow`/
    /// `showWindow`, driving it directly from a test is safe (confirmed:
    /// see `AppDelegateSessionBrowserMenuItemTests`).
    func setupMainMenu() {
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

        // GitHub issue #45: four distinct close scopes, each with its own
        // shortcut and stable selector — see `NSWindow+CalyxClose.swift`'s
        // header comment for the full root-cause writeup of why a single
        // nil-target `closeTab:` item used to sit on Cmd+W here. Every
        // item below deliberately keeps `target == nil` (unlike
        // `selectTabByNumber`'s items further down, which need `self`):
        // a nil target is what lets `-[NSApplication targetForAction:]`
        // walk the KEY window's own responder chain first, which is the
        // entire point of `calyxPerformClose(_:)` existing as a
        // same-selector-on-every-window method.
        fileMenu.addItem(withTitle: "Close", action: #selector(NSWindow.calyxPerformClose(_:)), keyEquivalent: "w")

        let closeTabItem = NSMenuItem(
            title: "Close Tab",
            action: #selector(CalyxWindowController.closeTab(_:)),
            keyEquivalent: "w")
        closeTabItem.keyEquivalentModifierMask = [.command, .option]
        fileMenu.addItem(closeTabItem)

        let closeWindowItem = NSMenuItem(
            title: "Close Window",
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w")
        closeWindowItem.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(closeWindowItem)

        let closeAllWindowsItem = NSMenuItem(
            title: "Close All Windows",
            action: #selector(AppDelegate.closeAllWindows(_:)),
            keyEquivalent: "w")
        closeAllWindowsItem.keyEquivalentModifierMask = [.command, .shift, .option]
        fileMenu.addItem(closeAllWindowsItem)

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

        let missionMapItem = NSMenuItem(
            title: "Mission Map",
            action: #selector(CalyxWindowController.toggleMissionMap),
            keyEquivalent: "m"
        )
        missionMapItem.keyEquivalentModifierMask = [.command, .shift]
        viewMenu.addItem(missionMapItem)

        viewMenu.addItem(.separator())

        viewMenu.addItem(
            withTitle: "Quick Terminal",
            action: #selector(handleToggleQuickTerminal),
            keyEquivalent: ""
        )

        let sessionBrowserItem = NSMenuItem(
            title: "Session Browser",
            action: #selector(openSessionBrowser(_:)),
            keyEquivalent: "b"
        )
        sessionBrowserItem.keyEquivalentModifierMask = [.command, .shift]
        viewMenu.addItem(sessionBrowserItem)

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

        // Help menu — deliberately LAST, and assigned to `NSApp.helpMenu`
        // so AppKit treats it as THE help menu (the same thing Ghostty's
        // MainMenu.xib does with `systemMenu="help"`): that is what makes
        // macOS insert its own "Search" field at the top of the menu.
        let helpMenuItem = NSMenuItem()
        mainMenu.addItem(helpMenuItem)
        let helpMenu = NSMenu(title: "Help")
        helpMenuItem.submenu = helpMenu
        // Cmd+? — the system-standard help shortcut, matching Ghostty's
        // own "Ghostty Help" item.
        //
        // `target = self`, unlike almost every other item in this menu
        // bar: a Help menu item is the one place where leaving the
        // target nil is actively dangerous, because AppKit's own
        // `NSApplication.showHelp(_:)` sits in the responder chain ahead
        // of the delegate (see `openCalyxHelp(_:)`'s doc comment). The
        // explicit target pins resolution to this class regardless of
        // what any future selector rename does.
        let helpItem = NSMenuItem(title: "Calyx Help", action: #selector(openCalyxHelp(_:)), keyEquivalent: "?")
        helpItem.target = self
        helpMenu.addItem(helpItem)

        NSApp.mainMenu = mainMenu
        // `helpMenu` must be reachable from `NSApp.mainMenu` before it is
        // assigned here -- otherwise AppKit can't resolve it as a menu
        // inside the menu bar, and the assignment is silently ignored
        // (no Search field gets inserted).
        NSApp.helpMenu = helpMenu
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
        ).removingEmptyWindows()
    }

    /// Extracted from applicationWillTerminate's save step so it is
    /// directly unit-testable: applicationWillTerminate itself is gated
    /// behind LaunchEnvironmentPolicy.isUnitTestHost() and always
    /// early-returns in the CalyxTests process (see that gate's own doc
    /// comment), so no test can drive it directly. Saves
    /// pendingTerminationSnapshot when present, falling back to
    /// buildSnapshot() otherwise (the existing behavior for e.g. a Cmd+Q
    /// with no window-close race). Routes through saveAtTermination(_:),
    /// which itself refuses to let an empty snapshot clobber a non-empty
    /// on-disk one, and resets the crash-loop counter exactly as
    /// applicationWillTerminate's own Task body already did.
    /// See SyncBridgeBox's own doc comment for why this uses
    /// `Task.detached` instead of the plain `Task { }` every other
    /// busy-wait in this file uses: this method must also behave
    /// correctly when driven directly from an async XCTest method
    /// (AppDelegatePendingTerminationSnapshotTests), not only from
    /// applicationWillTerminate's genuinely synchronous call stack.
    func saveForTermination() {
        let snapshot = pendingTerminationSnapshot ?? buildSnapshot()
        #if DEBUG
        let actor = _sessionPersistenceActorForTesting ?? SessionPersistenceActor.shared
        #else
        let actor = SessionPersistenceActor.shared
        #endif
        let box = SyncBridgeBox<Bool>(false)
        Task.detached {
            await actor.saveAtTermination(snapshot)
            await actor.resetRecoveryCounter()
            box.value = true
        }
        let deadline = Date().addingTimeInterval(1.0)
        while !box.value, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        }
    }

    #if DEBUG
    /// Test seam: overrides the SessionPersistenceActor instance
    /// scheduleRecoveryCounterResetAfterStableLaunch(delay:) resets,
    /// instead of SessionPersistenceActor.shared. DO NOT use from
    /// production code.
    var _sessionPersistenceActorForTesting: SessionPersistenceActor?
    #endif

    /// Schedules a delayed reset of the crash-loop recovery counter,
    /// confirming this launch survived `delay` before declaring it
    /// stable. Called exactly once per restoreSession() invocation,
    /// unconditionally -- independent of whether anything was restored
    /// -- so every launch that stays up long enough eventually resets
    /// the counter. A launch that crashes before `delay` elapses never
    /// runs this Task's body, so the counter is left incremented for
    /// the crash-loop detector exactly as today.
    func scheduleRecoveryCounterResetAfterStableLaunch(delay: Duration = .seconds(5)) {
        #if DEBUG
        let actor = _sessionPersistenceActorForTesting ?? SessionPersistenceActor.shared
        #else
        let actor = SessionPersistenceActor.shared
        #endif
        Task {
            try? await Task.sleep(for: delay)
            await actor.resetRecoveryCounter()
        }
    }

    /// True once Bug 3a's preserveSnapshotForRecovery() has moved a
    /// skipped/failed session's snapshot aside. Gates
    /// session.recoverPreviousSession's isAvailable. Cleared back to
    /// false once recoverPreservedSession() either restores at least
    /// one window from the preserved snapshot (via
    /// finalizeRecoverPreservedSession(restoredAny:)), or finds the
    /// preserved snapshot undecodable and quarantines it (see
    /// SessionPersistenceActor.quarantineCorruptPreservedSnapshot()). A
    /// recovery attempt that restores nothing from an otherwise
    /// decodable snapshot leaves this flag untouched, so the user's
    /// last-resort backup is never silently destroyed.
    private(set) var hasPreservedSessionSnapshot = false

    #if DEBUG
    /// Test seam: mirrors _setApplicationTerminatingForTesting's
    /// convention for a private(set) Bool. DO NOT use from production code.
    func _setHasPreservedSessionSnapshotForTesting(_ value: Bool) {
        hasPreservedSessionSnapshot = value
    }
    #endif

    /// Reentrancy guard for `recoverPreservedSession()`: two back-to-back
    /// invocations (e.g. a double-click on "Recover Previous Session")
    /// would otherwise each independently load the same preserved
    /// snapshot and each run their own `restoreWindow(_:)` loop over its
    /// windows, restoring every window TWICE. Mirrors
    /// `SessionBrowserModel.refresh()`'s existing `isRefreshing` guard.
    private(set) var isRecovering = false

    #if DEBUG
    /// Test seam: mirrors `_setHasPreservedSessionSnapshotForTesting`'s
    /// convention for a private(set) Bool. DO NOT use from production code.
    func _setIsRecoveringForTesting(_ value: Bool) {
        isRecovering = value
    }
    #endif

    /// Bug 3c gap-close: initializes hasPreservedSessionSnapshot from
    /// whatever preserveSnapshotForRecovery() left on disk in a PREVIOUS
    /// run, so a relaunch (where THIS run's own restoreSession() never
    /// calls preserveSnapshotForRecovery() itself) still offers the
    /// still-pending recovery command. Mirrors
    /// reassertHistoryPersistenceIfNeeded()'s async-Task-after-launch shape.
    ///
    /// Not `private` any more (recovery-bar empty-snapshot fix, mirrors
    /// `finalizeRecoverPreservedSession(restoredAny:)`'s own identical
    /// extraction-for-testability precedent):
    /// AppDelegateEmptyPreservedSnapshotTests drives this directly via
    /// `@testable import Calyx`.
    ///
    /// A decodable-but-EMPTY preserved snapshot (`windows.isEmpty`) has
    /// nothing to recover, so it is treated as ABSENT here: the useless
    /// file is retired (clearPreservedSnapshot()) and the flag stays
    /// false, instead of trusting hasPreservedSnapshot()'s bare file-
    /// existence check -- an empty file left on disk would otherwise
    /// re-trigger this same dead state on every future launch. Broadcasts
    /// the resolved value to every tracked window controller's
    /// RecoveryBarModel either way, fixing the launch-time race where a
    /// window was already constructed (with the flag still at its
    /// initial `false`) before this Task resolves (see
    /// RecoveryBarModelTests.swift's own header).
    func initializeHasPreservedSessionSnapshotFlag() async {
        #if DEBUG
        let actor = _sessionPersistenceActorForTesting ?? SessionPersistenceActor.shared
        #else
        let actor = SessionPersistenceActor.shared
        #endif
        guard let snapshot = await actor.loadPreservedSnapshot()?.removingEmptyWindows(),
              !snapshot.windows.isEmpty else {
            await actor.clearPreservedSnapshot()
            hasPreservedSessionSnapshot = false
            broadcastHasPreservedSessionSnapshotToRecoveryBars()
            return
        }
        hasPreservedSessionSnapshot = true
        broadcastHasPreservedSessionSnapshotToRecoveryBars()
    }

    /// Pushes the current `hasPreservedSessionSnapshot` into every
    /// currently-tracked window controller's `RecoveryBarModel`
    /// (RecoveryBarModel.swift), so an already-constructed window's bar
    /// updates in lockstep with this flag instead of only ever
    /// reflecting whatever value was current at that window's own
    /// construction time. Called from every site that changes this
    /// flag: `initializeHasPreservedSessionSnapshotFlag()`,
    /// `recoverPreservedSession()`'s empty/corrupt-snapshot guards, and
    /// `finalizeRecoverPreservedSession(restoredAny:)`.
    private func broadcastHasPreservedSessionSnapshotToRecoveryBars() {
        for wc in windowControllers {
            wc.recoveryBarModel.updateHasPreservedSessionSnapshot(hasPreservedSessionSnapshot)
            wc.refreshRecoveryBar()
        }
    }

    /// Tells the user restoreSession() skipped or failed to restore
    /// their previous windows/tabs, and that the previous session was
    /// preserved (see SessionPersistenceActor.preserveSnapshotForRecovery(),
    /// Bug 3a) and can be recovered via the command palette's
    /// "Recover Previous Session" action (session.recoverPreviousSession,
    /// Bug 3c). Called once from restoreSession()'s crash-loop-skip and
    /// restoredAny-false branches (see
    /// SessionPersistenceActorRecoveryPreservationTests's wire-point
    /// note for the full branch list), alongside preserveSnapshotForRecovery().
    func notifyPreviousSessionNotRestored() {
        NotificationManager.shared.sendNotification(
            title: "Previous session not restored",
            body: "Calyx didn't restore your previous windows and tabs, but they're safely preserved. " +
                  "Recover them from the command palette (\"Recover Previous Session\").",
            tabID: UUID()
        )
    }

    /// session.recoverPreviousSession's handler: loads the preserved
    /// snapshot (via the same actor _sessionPersistenceActorForTesting
    /// seam scheduleRecoveryCounterResetAfterStableLaunch already uses).
    /// When the preserved snapshot is undecodable (corrupt JSON, unknown
    /// future schema version) or nothing was preserved at all, quarantines
    /// it (a safe no-op in the latter sub-case -- see
    /// SessionPersistenceActor.quarantineCorruptPreservedSnapshot()) and
    /// resets hasPreservedSessionSnapshot, so a dead command never stays
    /// stuck available. Otherwise rebuilds each window through the
    /// existing restoreWindow(_:) machinery (same one restoreSession()
    /// itself uses), tracking whether any window actually restored, and
    /// hands that result to finalizeRecoverPreservedSession(restoredAny:),
    /// which only clears the preserved file and resets the flag once at
    /// least one window restored -- a total-failure attempt leaves the
    /// backup in place so the user can retry or investigate.
    func recoverPreservedSession() {
        guard !isRecovering else { return }
        isRecovering = true
        #if DEBUG
        let actor = _sessionPersistenceActorForTesting ?? SessionPersistenceActor.shared
        #else
        let actor = SessionPersistenceActor.shared
        #endif
        Task {
            defer { isRecovering = false }
            guard let rawSnapshot = await actor.loadPreservedSnapshot() else {
                // Nothing preserved, OR preserved but undecodable
                // (corrupt/unknown schema) -- quarantine is a no-op in
                // the former sub-case, so calling it unconditionally is
                // safe and unsticks the latter.
                await actor.quarantineCorruptPreservedSnapshot()
                hasPreservedSessionSnapshot = false
                broadcastHasPreservedSessionSnapshotToRecoveryBars()
                return
            }
            let snapshot = rawSnapshot.removingEmptyWindows()
            // Empty-snapshot fix: a decodable-but-empty preserved
            // snapshot has nothing to recover -- clear the useless file
            // and reset the flag (mirroring
            // finalizeRecoverPreservedSession(restoredAny: true)'s own
            // two-step "clear + reset" shape) instead of a silent no-op
            // that leaves a permanently dead command enabled.
            guard !snapshot.windows.isEmpty else {
                await actor.clearPreservedSnapshot()
                hasPreservedSessionSnapshot = false
                broadcastHasPreservedSessionSnapshotToRecoveryBars()
                return
            }
            var restoredAny = false
            let herdrTerminalIDCache = HerdrRestoreTerminalIDCache()
            for windowSnap in snapshot.windows {
                if restoreWindow(windowSnap, herdrTerminalIDCache: herdrTerminalIDCache) {
                    restoredAny = true
                }
            }
            await finalizeRecoverPreservedSession(restoredAny: restoredAny)
        }
    }

    /// Extracted from recoverPreservedSession() so the "was anything
    /// actually recovered" bookkeeping is unit-testable without reaching
    /// restoreWindow(_:)'s real GhosttyAppController/window-creation path
    /// (see AppDelegateRecoverPreservedSessionFinalizeTests's own
    /// reachability note). Mirrors
    /// scheduleRecoveryCounterResetAfterStableLaunch(delay:)'s
    /// actor-seam resolution. Clears the preserved snapshot and resets
    /// hasPreservedSessionSnapshot ONLY when restoredAny is true;
    /// otherwise leaves both untouched, so a recovery attempt that
    /// restored NOTHING never destroys the user's last-resort backup.
    func finalizeRecoverPreservedSession(restoredAny: Bool) async {
        guard restoredAny else { return }
        #if DEBUG
        let actor = _sessionPersistenceActorForTesting ?? SessionPersistenceActor.shared
        #else
        let actor = SessionPersistenceActor.shared
        #endif
        await actor.clearPreservedSnapshot()
        hasPreservedSessionSnapshot = false
        broadcastHasPreservedSessionSnapshotToRecoveryBars()
    }

    /// Single-slot, lock-protected box used ONLY to bridge a
    /// `Task.detached` result back into a synchronous busy-wait loop.
    ///
    /// WHY THIS EXISTS (confirmed empirically, not theoretical): a plain
    /// (non-detached) `Task { ... }` created inside a `@MainActor`
    /// method inherits MainActor isolation, so it is queued onto
    /// MainActor's SAME serial turn the enclosing synchronous method is
    /// still occupying. When that method is invoked from a genuinely
    /// synchronous, non-Task call stack (e.g. `applicationDidFinishLaunching`,
    /// every production call site here), no other MainActor turn is in
    /// the way, so the queued task runs as soon as the run loop is
    /// pumped -- this is why the busy-wait convention used throughout
    /// this file already works for production. But when the SAME method
    /// is invoked from a caller that is ITSELF already an async Task
    /// running on MainActor (an `async` XCTest method, exactly what
    /// AppDelegateSessionRestoreDiskTimeoutTests/
    /// AppDelegatePendingTerminationSnapshotTests need for their own
    /// setup), the child task cannot start until the CURRENT MainActor
    /// turn (this very function) returns -- confirmed by raising the
    /// busy-wait deadline to 10s in a throwaway experiment and observing
    /// it still never completes; only `Task.detached`, which runs
    /// independently of MainActor's turn, avoids this. `Task.detached`'s
    /// closure must be `@Sendable`, so its result cannot cross back via
    /// a captured `var` the way the inherited-isolation `Task { }`
    /// pattern does elsewhere in this file; `@unchecked Sendable` here is
    /// justified because EVERY read and write of `value` is serialized
    /// through `lock`, so there is no actual unsynchronized shared
    /// mutable state despite crossing an isolation domain.
    private final class SyncBridgeBox<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var storedValue: Value
        init(_ value: Value) { storedValue = value }
        var value: Value {
            get { lock.lock(); defer { lock.unlock() }; return storedValue }
            set { lock.lock(); defer { lock.unlock() }; storedValue = newValue }
        }
    }

    enum SessionRestoreDiskOutcome: Equatable {
        case snapshot(SessionSnapshot)
        case empty
        case timedOut
    }

    /// Extracted from restoreSession()'s crash-loop-check + disk-read
    /// preamble so the timeout branch is genuinely unit-drivable and
    /// distinguishable from "the actor completed and said no" (see
    /// AppDelegateSessionRestoreDiskTimeoutTests's own header for the
    /// full root-cause narrative). `deadline: 0` deterministically
    /// forces `.timedOut` without needing an artificially slow actor.
    /// See SyncBridgeBox's own doc comment for why the disk read runs
    /// in a `Task.detached` instead of a plain `Task { }`.
    func attemptSessionRestoreFromDisk(deadline: TimeInterval = 2.0) -> SessionRestoreDiskOutcome {
        #if DEBUG
        let actor = _sessionPersistenceActorForTesting ?? SessionPersistenceActor.shared
        #else
        let actor = SessionPersistenceActor.shared
        #endif
        let box = SyncBridgeBox<(snapshot: SessionSnapshot?, done: Bool)>((nil, false))
        let task = Task.detached {
            let recoveryCount = await actor.incrementRecoveryCounter()
            var snapshot: SessionSnapshot?
            if recoveryCount <= SessionPersistenceActor.maxRecoveryAttempts {
                snapshot = await actor.restore()
            }
            box.value = (snapshot, true)
        }
        let deadlineDate = Date().addingTimeInterval(deadline)
        while !box.value.done, Date() < deadlineDate {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        }
        guard box.value.done else {
            task.cancel()
            return .timedOut
        }
        guard let snapshot = box.value.snapshot else { return .empty }
        return .snapshot(snapshot)
    }

    enum SessionPreserveDiskOutcome: Equatable {
        case preserved
        case notPreserved
        case timedOut
    }

    /// Extracted from preserveDiscardedSessionIfAny()'s body for the
    /// identical reason as attemptSessionRestoreFromDisk(deadline:)
    /// above; see SyncBridgeBox's own doc comment for why this also
    /// needs `Task.detached`.
    func attemptPreserveDiscardedSessionOnDisk(deadline: TimeInterval = 2.0) -> SessionPreserveDiskOutcome {
        #if DEBUG
        let actor = _sessionPersistenceActorForTesting ?? SessionPersistenceActor.shared
        #else
        let actor = SessionPersistenceActor.shared
        #endif
        let box = SyncBridgeBox<(didPreserve: Bool, done: Bool)>((false, false))
        let task = Task.detached {
            let didPreserve = await actor.preserveSnapshotForRecovery()
            box.value = (didPreserve, true)
        }
        let deadlineDate = Date().addingTimeInterval(deadline)
        while !box.value.done, Date() < deadlineDate {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        }
        guard box.value.done else {
            task.cancel()
            return .timedOut
        }
        return box.value.didPreserve ? .preserved : .notPreserved
    }

    /// Bug 3a/3b wiring shared by restoreSession()'s empty-outcome,
    /// timed-out, and restoredAny-false branches: moves whatever is
    /// currently on disk aside into the recovery file (a harmless no-op
    /// when nothing is there -- e.g. the "nothing was ever saved"
    /// sub-case), and, only when a file was actually moved, marks it
    /// recoverable and tells the user. Deliberately does NOT
    /// notify/flag on a no-op preserve: an on-disk file can be absent
    /// even after a successful restore() (e.g. restore() fell back to
    /// backupPath while savePath itself never existed), and a
    /// notification claiming a session is recoverable when
    /// session.recoverPreviousSession would find nothing would be
    /// actively misleading. On `.timedOut`, we do not know for certain
    /// whether a recovery file exists, so this never claims one does.
    private func preserveDiscardedSessionIfAny() {
        switch attemptPreserveDiscardedSessionOnDisk() {
        case .preserved:
            hasPreservedSessionSnapshot = true
            notifyPreviousSessionNotRestored()
        case .notPreserved:
            break
        case .timedOut:
            logger.warning("Timed out attempting to preserve a discarded session snapshot")
        }
    }

    /// Extracted from restoreSession()'s empty-snapshot guard for the
    /// same reason attemptSessionRestoreFromDisk(deadline:)/
    /// attemptPreserveDiscardedSessionOnDisk(deadline:)/
    /// scheduleRecoveryCounterResetAfterStableLaunch(delay:) were each
    /// already extracted (see AppDelegateRecoveryCounterResetTests' own
    /// header): restoreSession() itself stays private and, past this
    /// guard, still reaches GhosttyAppController.shared/real window
    /// creation, so it remains unsafe to drive directly from a unit
    /// test; this extracted method is the safe PREFIX that never
    /// reaches that code.
    ///
    /// C4 REVERSAL: a decodable, genuinely empty restored snapshot is
    /// now unconditionally "nothing to restore" -- never preserved,
    /// never notified about, regardless of what the daemon's session
    /// ledger reports. This guard used to query that ledger and treat
    /// an empty snapshot alongside a still-RUNNING persistent session
    /// as evidence of a lost snapshot, but that premise stopped holding
    /// once closing the last window stopped terminating the app: with
    /// applicationShouldTerminateAfterLastWindowClosed now
    /// returning `false`, removeWindowController(_:) deliberately calls
    /// saveImmediately() the instant windowControllers reaches zero,
    /// synchronously writing a genuinely empty snapshot to disk ON
    /// PURPOSE. A persistent session can also legitimately stay RUNNING
    /// in the daemon's ledger with no window attached to it at all --
    /// e.g. session.detach deliberately leaves one running for later
    /// reattachment -- so a running ledger entry is no longer evidence
    /// that anything was lost. A GENUINE loss of the snapshot itself
    /// (decode failure, no file at all, or the crash-loop counter
    /// exceeding maxRecoveryAttempts) never reaches this method at all:
    /// it still falls into attemptSessionRestoreFromDisk()'s separate
    /// .empty/.timedOut branches above this guard in restoreSession(),
    /// whose own preserveDiscardedSessionIfAny() handling is unchanged
    /// by this reversal.
    ///
    /// Not private: called directly on a bare AppDelegate() by
    /// AppDelegateEmptySnapshotNotAnomalyTests, exactly like
    /// notifyPreviousSessionNotRestored()'s own precedent.
    func handleEmptyRestoredSnapshot() -> Bool {
        logger.info("No session to restore")
        return false
    }

    private func restoreSession() -> Bool {
        let outcome = attemptSessionRestoreFromDisk()

        // Bug 1: every restoreSession() invocation schedules the delayed
        // stability-confirmation reset, unconditionally -- independent of
        // what is found or done below -- so a healthy "nothing to
        // restore" launch does not leave the crash-loop counter
        // incremented forever (see this method's own doc comment).
        scheduleRecoveryCounterResetAfterStableLaunch()

        let snapshot: SessionSnapshot
        switch outcome {
        case .timedOut:
            // C3: never silently fall through to createNewWindow() as if
            // disk were confirmed empty -- we genuinely don't know
            // whether there was something to restore.
            logger.warning("Timed out reading session snapshot from disk")
            preserveDiscardedSessionIfAny()
            return false
        case .empty:
            // restore() failed to decode, nothing was ever saved, or the
            // crash-loop counter exceeded maxRecoveryAttempts --
            // preserveDiscardedSessionIfAny() harmlessly no-ops in the
            // "nothing was ever saved" sub-case.
            logger.info("No session to restore")
            preserveDiscardedSessionIfAny()
            return false
        case .snapshot(let restored):
            snapshot = restored.removingEmptyWindows()
        }

        guard !snapshot.windows.isEmpty else {
            return handleEmptyRestoredSnapshot()
        }

        // One listAll() subprocess
        // for the whole restore pass, instead of one per surface (see
        // fetchSessionsForAgentResume's doc comment). Not
        // waited on here, window/tab restoration proceeds immediately.
        fetchSessionsForAgentResume()
        var restoredAny = false

        let herdrTerminalIDCache = HerdrRestoreTerminalIDCache()
        for windowSnap in snapshot.windows {
            if restoreWindow(windowSnap, herdrTerminalIDCache: herdrTerminalIDCache) {
                restoredAny = true
            }
        }

        if !restoredAny {
            logger.warning("Failed to restore any windows")
            preserveDiscardedSessionIfAny()
            return false
        }

        return true
    }

    private func restoreWindow(_ windowSnap: WindowSnapshot, herdrTerminalIDCache: HerdrRestoreTerminalIDCache) -> Bool {
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
                if restoreTabSurfaces(tab: tab, app: app, window: window, herdrTerminalIDCache: herdrTerminalIDCache) {
                    anyTabRestored = true
                } else {
                    // Fallback: create a single new surface for this tab
                    if fallbackCreateSurface(tab: tab, app: app, window: window, herdrTerminalIDCache: herdrTerminalIDCache) {
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

    /// Not `private`:
    /// `AppDelegateRestoreTabSurfacesOwnershipTests`/
    /// `AppDelegateOfferAgentResumePipelineBoundTests` call this directly
    /// (with `_createSurfaceWithPwdHookForTesting` set, see that seam's
    /// own doc comment on `createSurfaceWithPwd`) to drive its
    /// partial-failure cleanup and per-surface agent-resume dispatch
    /// deterministically, without a real, live ghostty surface, mirroring
    /// `fetchSessionsForAgentResume`'s identical precedent.
    func restoreTabSurfaces(
        tab: Tab, app: ghostty_app_t, window: NSWindow,
        herdrTerminalIDCache: HerdrRestoreTerminalIDCache = HerdrRestoreTerminalIDCache()
    ) -> Bool {
        let oldLeafIDs = tab.splitTree.allLeafIDs()
        guard !oldLeafIDs.isEmpty else { return false }

        // Reject any persisted SessionRef whose sessionID isn't shaped
        // like a genuine ULID before it ever reaches calyx-session
        // attach, a corrupted/malicious sessions.json value must not
        // run arbitrary daemon-side lookups. The rejected leaf simply
        // restores as an ordinary passthrough shell below
        // (createSurfaceWithPwd only synthesizes an attach command when
        // tab.sessionRefs still has an entry for that leaf).
        for (leafID, sessionRef) in tab.sessionRefs where !SessionRef.isValidULID(sessionRef.sessionID) {
            tab.sessionRefs.removeValue(forKey: leafID)
        }

        var mapping: [UUID: UUID] = [:]
        // Collected here, fanned out
        // through a single shared Task below instead of
        // `createSurfaceWithPwd` spawning its own per-surface Task (see
        // its own doc comment).
        var agentResumeCandidates: [(tab: Tab, surfaceID: UUID, sessionID: String)] = []

        for oldID in oldLeafIDs {
            guard let created = createSurfaceWithPwd(
                tab: tab, app: app, window: window, oldLeafID: oldID, herdrTerminalIDCache: herdrTerminalIDCache
            ) else {
                continue
            }
            let newID = created.surfaceID
            mapping[oldID] = newID
            if let sessionRef = tab.sessionRefs[oldID] {
                // Re-checked
                // immediately before registering, defense in depth
                // against a future async gap between this check and the
                // register call (this whole loop stays fully synchronous
                // today, with no `await` in between, so no other
                // MainActor call can interleave here, see
                // fetchSessionsForAgentResume's doc comment); abort
                // registering over an entry that appeared meanwhile
                // rather than clobber it.
                if SessionSurfaceMap.shared.surfaceID(for: sessionRef.sessionID) == nil {
                    SessionSurfaceMap.shared.register(sessionID: sessionRef.sessionID, surfaceID: newID)
                }
            }
            if let agentResumeSessionID = created.agentResumeSessionID {
                agentResumeCandidates.append((tab, newID, agentResumeSessionID))
            }
        }

        // One shared Task awaits the shared fetch
        // once and calls `offerAgentResume` for every reattached leaf
        // from this single restore pass, an O(1) Task count regardless
        // of how many persistent-session leaves this tab has.
        if !agentResumeCandidates.isEmpty {
            let candidates = agentResumeCandidates
            let fetchTask = agentResumeSessionsTask
            Task { [weak self] in
                let sessions = await fetchTask?.value ?? [:]
                for candidate in candidates {
                    self?.offerAgentResume(
                        tab: candidate.tab, surfaceID: candidate.surfaceID,
                        sessionID: candidate.sessionID, sessions: sessions
                    )
                    #if DEBUG
                    self?._createSurfaceWithPwdOfferAgentResumeCompletedHookForTesting?()
                    #endif
                }
            }
        }

        // All leaves must be restored for split integrity
        if mapping.count == oldLeafIDs.count {
            tab.splitTree = tab.splitTree.remapLeafIDs(mapping)
            tab.sessionRefs = tab.sessionRefs.remappingKeys(mapping)
            // herdrPaneRefs is a parallel side-channel to
            // sessionRefs (Tab.swift's own header) that needs the
            // identical old-leaf-ID -> new-surface-ID re-key -- without
            // this, a restored bridge leaf's ref would still point at the
            // OLD (pre-restore) leaf UUID, so focusExistingTab could never
            // match this tab again, and the next snapshot would persist an
            // orphaned key.
            tab.herdrPaneRefs = tab.herdrPaneRefs.remappingKeys(mapping)
            // Mission Map card offsets are keyed by the same leaf UUIDs,
            // so they follow the leaves to their new surface IDs too.
            tab.missionMapCardOffsets = tab.missionMapCardOffsets.remappingKeys(mapping)
            adoptRestoredHerdrTabIfNeeded(tab)
            return true
        }

        // Partial failure: destroy any surfaces we created (undoing
        // their SessionSurfaceMap registration too) and return false.
        // Unregisters only
        // when the mapping still actually points at THIS (failed)
        // restore's own surface. A duplicate sessionID across two tabs
        // (a corrupted/hand-edited sessions.json, explicitly in this
        // function's own threat model, see the doc comment above)
        // registers the FIRST tab's surface and skips the SECOND (the
        // `== nil` guard above); without this check, the second tab's
        // partial-failure cleanup would unregister the sessionID
        // unconditionally, ripping the FIRST tab's still-live,
        // already-succeeded mapping out from under it.
        for (oldID, newID) in mapping {
            if let sessionRef = tab.sessionRefs[oldID],
               SessionSurfaceMap.shared.surfaceID(for: sessionRef.sessionID) == newID {
                SessionSurfaceMap.shared.unregister(sessionID: sessionRef.sessionID)
            }
            tab.registry.destroySurface(newID)
        }
        return false
    }

    /// Registers `tab`'s bridged herdr leaves, if any survived restore,
    /// with `herdrTabCoordinator`'s own per-workspace bookkeeping (see
    /// `HerdrTabCoordinator.adoptRestoredTab`'s own doc comment for what
    /// it stores and why), so a workspace killed or a pane closed after a
    /// RESTORE closes this tab exactly like one opened via
    /// `HerdrTabCoordinator.openWorkspace` in this session. Called only
    /// from `restoreTabSurfaces`'s own full-success branch, after
    /// `tab.herdrPaneRefs` has already been re-keyed to the new surface
    /// ids -- an entry survives there ONLY through
    /// `HerdrRestoreCommandPolicy.decide`'s `.bridgeCommand` outcome
    /// (`.plainShellAndPrune` removes it, `.plainShell` never adds one),
    /// so an empty `tab.herdrPaneRefs` here means every ref degraded to a
    /// plain shell, or the tab never had one -- no call, no herdr work,
    /// either way.
    ///
    /// The workspace id is derived from any one surviving ref's own
    /// paneID (`HerdrPaneID(parsing:)`, HerdrEvent.swift): every leaf in
    /// one tab bridges the SAME herdr workspace
    /// (`HerdrTabCoordinator.openWorkspace` only ever builds one tab's
    /// panes from one workspace's own layout.export), so any single
    /// entry's own workspace id speaks for the whole tab. `isValidPaneID`
    /// already gated this paneID before it could survive into
    /// `tab.herdrPaneRefs` (`HerdrRestoreCommandPolicy.decide`'s own
    /// guard), so `HerdrPaneID(parsing:)`'s more lenient parse is safe
    /// here -- extraction, not validation.
    ///
    /// When `herdrTabCoordinator` already exists, this adopts directly.
    /// Otherwise (still nil at restore time -- `startHerdrIntegration()`'s
    /// own async herdr-binary resolution has not necessarily landed yet
    /// by the time `restoreSession()` runs), the entry is queued into
    /// `pendingHerdrTabAdoptions` instead of being dropped, and adopted
    /// once `flushPendingHerdrTabAdoptions()` runs -- see that
    /// property's and that method's own doc comments.
    private func adoptRestoredHerdrTabIfNeeded(_ tab: Tab) {
        guard let anyRef = tab.herdrPaneRefs.values.first,
              let workspaceID = HerdrPaneID(parsing: anyRef.paneID)?.workspaceID
        else {
            return
        }
        if let coordinator = herdrTabCoordinator {
            coordinator.adoptRestoredTab(
                workspaceID: workspaceID, socketPath: anyRef.socketPath, tabID: tab.id, paneRefs: tab.herdrPaneRefs
            )
        } else {
            pendingHerdrTabAdoptions.append(
                (workspaceID: workspaceID, socketPath: anyRef.socketPath, tabID: tab.id, paneRefs: tab.herdrPaneRefs)
            )
        }
        #if DEBUG
        _restoreTabSurfacesHerdrAdoptionObserverForTesting?(workspaceID, anyRef.socketPath, tab.id, tab.herdrPaneRefs)
        #endif
    }

    private func fallbackCreateSurface(
        tab: Tab, app: ghostty_app_t, window: NSWindow,
        herdrTerminalIDCache: HerdrRestoreTerminalIDCache = HerdrRestoreTerminalIDCache()
    ) -> Bool {
        guard let created = createSurfaceWithPwd(
            tab: tab, app: app, window: window, herdrTerminalIDCache: herdrTerminalIDCache
        ) else {
            return false
        }
        let newID = created.surfaceID
        tab.splitTree = SplitTree(leafID: newID)
        // The whole original tree failed to restore, so none of the
        // old leaf UUIDs survive into this brand-new single-leaf tree.
        // Drop every now-orphaned SessionRef rather than let it linger
        // (and get written back out by the next snapshot) pointing at a
        // leaf that no longer exists.
        tab.pruneSessionRefs()
        // Identical orphaned-ref reasoning for herdrPaneRefs
        // (Tab.swift's own header, "parallel side-channel to sessionRefs").
        tab.pruneHerdrPaneRefs(keeping: Set(tab.splitTree.allLeafIDs()))
        // Same for Mission Map card offsets: no old leaf survives.
        tab.pruneMissionMapCardOffsets()
        return true
    }

    /// Creates one surface for `tab` during restore. When `oldLeafID`
    /// names a leaf that had a `SessionRef` in the snapshot
    /// (`tab.sessionRefs`, carried over by `Tab.init(snapshot:)`
    /// regardless of the current `SessionSettings
    /// .persistentSessionsEnabled` toggle, a session that already
    /// exists in the daemon must not be orphaned just because the user
    /// has since turned the feature off), creates the surface with an
    /// attach command instead of a plain shell so `restoreTabSurfaces`
    /// can reconnect it, returning the sessionID it reattached
    /// alongside the new surfaceID so the caller can offer agent resume
    /// for it (see `agentResumeSessionID`'s own doc comment).
    /// `fallbackCreateSurface`'s single-surface, whole-tree-failed path
    /// calls this with the default `oldLeafID: nil`, so it always falls
    /// back to a plain passthrough surface (`agentResumeSessionID` is
    /// always `nil` for that call, matching this method's pre-feature
    /// behavior exactly for that rare failure case).
    ///
    /// The surface is created immediately, synchronously; a caller that
    /// gets a non-nil `agentResumeSessionID` back awaits
    /// `agentResumeSessionsTask`'s result itself before calling
    /// `offerAgentResume` (see `restoreTabSurfaces`'s fan-out dispatch),
    /// so this method never waits on the daemon.
    private func createSurfaceWithPwd(
        tab: Tab, app: ghostty_app_t, window: NSWindow, oldLeafID: UUID? = nil,
        herdrTerminalIDCache: HerdrRestoreTerminalIDCache
    ) -> (surfaceID: UUID, agentResumeSessionID: String?)? {
        var config = GhosttyFFI.surfaceConfigNew()
        config.scale_factor = Double(window.backingScaleFactor)

        // Consulted before the existing plain/sessionRef path
        // below -- mirrors this same method's own invalid-ULID SessionRef
        // precedent (restoreTabSurfaces, "Reject any persisted SessionRef
        // whose sessionID isn't shaped like a genuine ULID..."). A leaf
        // with no HerdrPaneRef at all decides .plainShell WITHOUT ever
        // resolving the herdr binary or probing socket liveness: both are
        // real, uncached filesystem/socket I/O
        // (HerdrBinaryResolver.swift's own doc comment on why a miss is
        // never cached), and most restored leaves carry no HerdrPaneRef
        // at all, so evaluating them unconditionally here scales that
        // work with every restored leaf on every launch, herdr installed
        // or not.
        if let oldLeafID {
            let herdrPaneRef = tab.herdrPaneRefs[oldLeafID]
            let outcome: HerdrRestoreCommandOutcome
            if let herdrPaneRef {
                // The bridge command needs the pane's TERMINAL id, not
                // persisted on HerdrPaneRef (terminal ids are not stable
                // across a herdr server restart). Resolved from a live
                // `session.snapshot` via `herdrTerminalIDCache`, which
                // only runs for a leaf that actually has a ref, so a
                // launch with no herdr refs performs zero herdr work.
                let terminalIDs = herdrTerminalIDCache.terminalIDs(forSocketPath: herdrPaneRef.socketPath)
                outcome = HerdrRestoreCommandPolicy.decide(
                    herdrPaneRef: herdrPaneRef,
                    herdrBinPath: herdrBinaryResolver.resolve(),
                    isSocketAlive: herdrSessionDiscovery.isAlive(socketPath: herdrPaneRef.socketPath),
                    terminalID: terminalIDs[
                        HerdrRestoreTerminalIDResolver.key(
                            socketPath: herdrPaneRef.socketPath, paneID: herdrPaneRef.paneID
                        )
                    ]
                )
            } else {
                outcome = .plainShell
            }
            switch outcome {
            case .bridgeCommand(let command):
                #if DEBUG
                _createSurfaceWithPwdCommandObserverForTesting?(oldLeafID, command)
                #endif
                guard let surfaceID = createRegistrySurface(tab: tab, app: app, config: config, pwd: tab.pwd, command: command, oldLeafID: oldLeafID) else {
                    return nil
                }
                if let herdrPaneRef {
                    HerdrPaneRegistry.shared.register(surfaceID: surfaceID, ref: herdrPaneRef)
                }
                // A herdr-bridged leaf carries no calyx-session identity
                // (see HerdrHostedSurfaces.swift's header) -- nothing to
                // offer agent resume for.
                return (surfaceID, nil)
            case .plainShellAndPrune:
                // A ref that can never be reattached (herdr unresolvable,
                // its socket dead, or the ref itself invalid) -- drop JUST
                // this leaf's ref (mirrors the invalid-ULID SessionRef
                // prune's own per-leaf removal) and fall through to the
                // ordinary passthrough-shell path below, exactly like a
                // rejected SessionRef does.
                tab.pruneHerdrPaneRefs(keeping: Set(tab.herdrPaneRefs.keys).subtracting([oldLeafID]))
            case .plainShell:
                break // No HerdrPaneRef for this leaf at all -- falls through to the plain/sessionRef path below, unaffected by herdr bridging.
            }
        }

        if let oldLeafID, let sessionRef = tab.sessionRefs[oldLeafID] {
            let command: String?
            if let host = sessionRef.host {
                command = SessionCommandSynthesizer.remoteAttachCommand(
                    host: host, sessionID: sessionRef.sessionID, cwd: tab.pwd ?? NSHomeDirectory()
                )
            } else {
                command = SessionCommandSynthesizer.reattachCommand(
                    sessionID: sessionRef.sessionID, cwd: tab.pwd ?? NSHomeDirectory()
                )
            }
            #if DEBUG
            _createSurfaceWithPwdCommandObserverForTesting?(oldLeafID, command)
            #endif
            if let command {
                guard let surfaceID = createRegistrySurface(tab: tab, app: app, config: config, pwd: tab.pwd, command: command, oldLeafID: oldLeafID) else {
                    return nil
                }
                return (surfaceID, sessionRef.sessionID)
            }
        } else {
            #if DEBUG
            _createSurfaceWithPwdCommandObserverForTesting?(oldLeafID, nil)
            #endif
        }
        guard let surfaceID = createRegistrySurface(tab: tab, app: app, config: config, pwd: tab.pwd, command: nil, oldLeafID: oldLeafID) else {
            return nil
        }
        return (surfaceID, nil)
    }

    #if DEBUG
    /// Test seam: when non-nil,
    /// called INSTEAD of the real `tab.registry.createSurface(...)` FFI
    /// call inside `createRegistrySurface`, keyed by `oldLeafID` (`nil`
    /// for the no-old-leaf/fallback path). Returns the UUID to report as
    /// the newly created surface (simulating success), or `nil` to
    /// simulate surface-creation failure for that one leaf, letting
    /// `restoreTabSurfaces`'s partial-failure bookkeeping (and
    /// its shared agent-resume fan-out `Task`) be driven deterministically
    /// without a real, live ghostty surface (confirmed unsafe from this
    /// test host, see `_attachWindowCreationHookForTesting`'s doc comment
    /// for the confirmed hang). Placed as the narrowest possible wrapper
    /// around only the actually-unsafe call: everything around it (the
    /// attach-command detection, the `offerAgentResume` dispatch) stays
    /// real, unmodified production code. `nil` (the default) leaves
    /// production behavior unchanged. DO NOT use from production code.
    var _createSurfaceWithPwdHookForTesting: ((UUID?) -> UUID?)?

    /// Test seam: when non-nil, called
    /// once `restoreTabSurfaces`'s shared agent-resume fan-out `Task`
    /// has awaited `agentResumeSessionsTask`'s result
    /// and called `offerAgentResume` for ONE reattached leaf, i.e. once
    /// that leaf's pipeline reaches a terminal state, regardless of
    /// whether `offerAgentResume` actually found a resumable session to
    /// act on. Fires once per candidate leaf in the fan-out, not once
    /// per restore pass. The fan-out `Task` is otherwise fire-and-forget,
    /// with nothing else to await from a test. `nil` (the default) leaves production
    /// behavior unchanged. DO NOT use from production code.
    var _createSurfaceWithPwdOfferAgentResumeCompletedHookForTesting: (() -> Void)?

    /// Test seam: when non-nil,
    /// called with `(oldLeafID, command)` from inside
    /// `createSurfaceWithPwd`, immediately before `createRegistrySurface`
    /// is invoked, in both of that method's branches -- the
    /// `sessionRef`-carrying branch (with its local `reattachCommand` or
    /// remote `remoteAttachCommand` result, either of which may itself be
    /// `nil`) and the plain-passthrough branch (`command` always `nil`).
    /// Added as a second, independent observer alongside
    /// `_createSurfaceWithPwdHookForTesting` rather than changing that
    /// hook's signature, since every existing caller of it only needs the
    /// resulting surfaceID, never the command string. `nil` (the default)
    /// leaves production behavior unchanged. DO NOT use from production
    /// code.
    var _createSurfaceWithPwdCommandObserverForTesting: ((UUID?, String?) -> Void)?

    /// Test seam: when non-nil, called with `(workspaceID, socketPath,
    /// tabID, paneRefs)` from `adoptRestoredHerdrTabIfNeeded` whenever a
    /// restored tab has at least one surviving (bridged) `herdrPaneRefs`
    /// entry -- fires with the EXACT arguments that reach
    /// `HerdrTabCoordinator.adoptRestoredTab(...)`, whether delivered
    /// directly (`herdrTabCoordinator` already set, e.g. via
    /// `_setHerdrTabCoordinatorForTesting`) or queued into
    /// `pendingHerdrTabAdoptions` for a later `flushPendingHerdrTabAdoptions()`
    /// to deliver (`herdrTabCoordinator` still nil -- always the case in
    /// the unit-test host unless a test sets one, since
    /// `applicationDidFinishLaunching`'s own unit-test-host gate
    /// stops `startHerdrIntegration()` from ever running there), so a
    /// test can observe the adoption's computed shape either way. `nil`
    /// (the default) leaves production behavior unchanged: the real
    /// adoption, direct or queued, still always happens regardless of
    /// this hook. DO NOT use from production code.
    var _restoreTabSurfacesHerdrAdoptionObserverForTesting: ((String, String, UUID, [UUID: HerdrPaneRef]) -> Void)?
    #endif

    /// Thin wrapper around the one actually-unsafe-to-test call
    /// `createSurfaceWithPwd` makes (`tab.registry.createSurface`, a
    /// real ghostty FFI surface), so `_createSurfaceWithPwdHookForTesting`
    /// (see its own doc comment) can intercept exactly that call and
    /// nothing else.
    private func createRegistrySurface(
        tab: Tab, app: ghostty_app_t, config: ghostty_surface_config_s, pwd: String?, command: String?, oldLeafID: UUID?
    ) -> UUID? {
        #if DEBUG
        if let hook = _createSurfaceWithPwdHookForTesting {
            return hook(oldLeafID)
        }
        #endif
        return tab.registry.createSurface(app: app, config: config, pwd: pwd, command: command)
    }

    #if DEBUG
    /// Test seam: when non-nil, used
    /// instead of `SessionDaemonClient.shared` inside
    /// `fetchSessionsForAgentResume`. Mirrors the
    /// `SessionDaemonClientProtocol` fake pattern already established by
    /// `SessionBrowserModelTests`/`SessionReconnectCoordinatorTests`
    /// rather than inventing a new one, since `SessionDaemonClient.shared`
    /// itself is a non-swappable `let` (unlike `NotificationManager
    /// .shared`). Lets a test control exactly when/whether the daemon
    /// round-trip completes, without spawning a real `calyx-session`
    /// process, to prove `fetchSessionsForAgentResume` does or does not
    /// block the calling thread on it. `nil` (the default) leaves
    /// production behavior unchanged. DO NOT use from production code.
    var _sessionDaemonClientForTesting: SessionDaemonClientProtocol?
    #endif

    /// The async
    /// fetch task `fetchSessionsForAgentResume()` starts, shared by
    /// every surface created during the SAME restore/attach pass so
    /// `restoreTabSurfaces`'s fan-out `Task` can await its
    /// result, right before calling `offerAgentResume`, instead of
    /// blocking on it. `restoreSession`/`attachWindow` each make exactly
    /// one call per pass (matching the "one `listAll()` per
    /// pass" intent); `restoreWindow`/`restoreTabSurfaces` read this
    /// property synchronously afterward, within that same call stack.
    ///
    /// `fetchSessionsForAgentResume()` reuses an already
    /// in-flight task instead of starting a second daemon subprocess
    /// for the same purpose (a `listAll()` round-trip reflects the
    /// whole daemon-wide ledger regardless of which pass triggered it,
    /// so an overlapping pass reusing a still-in-flight fetch from a
    /// previous one is exactly as correct as waiting for a fresh one).
    /// Not `private`: exposed read-only
    /// so `AppDelegateFetchSessionsForAgentResumeTests` can observe that
    /// a task was actually started, now that
    /// `fetchSessionsForAgentResume()` itself no longer returns a
    /// meaningful synchronous result.
    ///
    /// Reset back to `nil` once the task it
    /// holds actually COMPLETES (see `agentResumeFetchGeneration`'s doc
    /// comment), not only when agent resume is disabled. Without this,
    /// the `== nil` reuse guard in `fetchSessionsForAgentResume()`
    /// would never reset after a successful fetch, so every call after the
    /// very first one would silently reuse the launch-time snapshot forever;
    /// a first fetch that timed out would permanently pin an empty `[:]`
    /// result.
    private(set) var agentResumeSessionsTask: Task<[String: SessionInfo], Never>?

    /// Monotonic counter identifying which
    /// `fetchSessionsForAgentResume()` call started the currently
    /// in-flight `agentResumeSessionsTask`, mirroring
    /// `BrowserTabController.snapshotGeneration`'s established pattern.
    /// The task's own completion compares this against its own captured
    /// generation before resetting `agentResumeSessionsTask` to `nil`,
    /// so a disable-then-re-enable cycle that starts a NEWER fetch
    /// while an older, already-cancelled one is still unwinding can
    /// never have that older fetch's completion clobber the newer
    /// task's reference.
    private var agentResumeFetchGeneration = 0

    /// The deadline `SessionDaemonClientProtocol
    /// .listAllBounded()` races the real daemon round-trip against, so
    /// `agentResumeSessionsTask` always reaches a terminal state even
    /// if the daemon never responds at all.
    /// `AppDelegateOfferAgentResumePipelineBoundTests`'s 15s `XCTWaiter`
    /// bound comfortably exceeds this: shared with
    /// `SessionBrowserModel.refresh()` via `listAllBounded()`'s
    /// `daemonQueryBoundTimeoutSeconds`. `sessionStateBounded(id:)`'s
    /// reconnect-decision path uses its own,
    /// longer `sessionStateBoundTimeoutSeconds` instead of reusing this
    /// one: the low- and high-consequence callers deliberately use
    /// two separate bounds, not a single shared constant.

    /// Starts (but does not wait
    /// for) the daemon's session list fetch, keyed by session ID, gated
    /// on `SessionSettings.agentResumeEnabled` (off, the default, spawns
    /// no subprocess at all, the same gate `offerAgentResume` itself
    /// used to check before spawning its own `Task`). `offerAgentResume`
    /// used to call `SessionDaemonClient.shared.listAll()` itself, once
    /// per restored surface: N concurrent `calyx-session ls --all --json`
    /// subprocesses at launch for N restored persistent-session
    /// surfaces, each decoding the full ledger just to pick out one ID.
    /// Shared by `restoreSession` (one call for the whole restore pass)
    /// and `attachWindow` (one call for the single session being
    /// attached).
    ///
    /// This used
    /// to `RunLoop.current.run` spin the calling (main) thread in 10ms
    /// steps for up to 2.0s, synchronously, on both call sites above,
    /// the opposite of this method's stated purpose. Now it only starts
    /// `agentResumeSessionsTask` and returns immediately; window/tab
    /// restoration proceeds without ever waiting on the daemon, and
    /// `restoreTabSurfaces`'s fan-out `Task` awaits
    /// `agentResumeSessionsTask` itself, only where the result is
    /// actually needed.
    ///
    /// Returns `Void`, not a dictionary. The old
    /// return value was always `[:]` (no daemon response is ever
    /// available synchronously), never a meaningful result to report;
    /// `agentResumeSessionsTask` itself (see its own doc comment) is
    /// what callers actually need. Not `private`:
    /// `AppDelegateFetchSessionsForAgentResumeTests` calls this directly
    /// to measure that it no longer blocks, matching this file's
    /// `offerAgentResume`/`attachWindow` direct-drive precedent.
    func fetchSessionsForAgentResume() {
        guard SessionSettings.agentResumeEnabled else {
            // Cancel a still-in-flight
            // fetch instead of merely dropping the reference.
            // `Task.cancel()` only sets a cooperative flag; `SessionDaemonClientProtocol
            // .bounded(...)` (the race `listAllSessionsBounded` below
            // ultimately awaits) honors that flag with a
            // `withTaskCancellationHandler` that cancels both its
            // internal race arms and resumes promptly -- reaching, in
            // turn, `SystemCommandRunner.run()`'s own cancellation
            // handler, which SIGTERMs the underlying `calyx-session`
            // subprocess -- so a disable mid-flight genuinely ends
            // the daemon round-trip promptly instead of merely dropping
            // an unobserved reference to it while it rides out
            // the full bound regardless of this cancel() call.
            agentResumeSessionsTask?.cancel()
            agentResumeSessionsTask = nil
            return
        }
        // Reuse whatever fetch is already in flight
        // rather than starting a second daemon subprocess for the
        // identical purpose.
        guard agentResumeSessionsTask == nil else { return }
        #if DEBUG
        let client = _sessionDaemonClientForTesting ?? SessionDaemonClient.shared
        #else
        let client = SessionDaemonClient.shared
        #endif
        agentResumeFetchGeneration += 1
        let generation = agentResumeFetchGeneration
        agentResumeSessionsTask = Task {
            let result = await AppDelegate.listAllSessionsBounded(client: client)
            // Reset back to nil once
            // THIS fetch completes, so the next
            // fetchSessionsForAgentResume() call starts a fresh daemon
            // round-trip instead of reusing an already-resolved (or
            // timed-out) snapshot forever. Guarded by generation (see
            // agentResumeFetchGeneration's own doc comment) so a newer
            // fetch started after a disable/re-enable cycle is never
            // clobbered by this one's completion.
            if self.agentResumeFetchGeneration == generation {
                self.agentResumeSessionsTask = nil
            }
            return result
        }
    }

    /// The attach-spawned calyx-session daemon always starts
    /// with history OFF (`DaemonConfig::history_enabled`'s bind-time
    /// default; see `ControlMsg::SetHistoryEnabled`'s own doc comment --
    /// a live, in-memory override, never persisted daemon-side),
    /// regardless of any `history on` a previous process lifetime sent
    /// it. A user with `historyPersistenceEnabled` on therefore needs it
    /// re-pushed once per launch, against whatever daemon this launch
    /// attaches to or spawns. Gated on `persistentSessionsEnabled` (no
    /// persistent daemon is ever spawned otherwise, so there is nothing
    /// to reassert to) AND `historyPersistenceEnabled`. Called once from
    /// `applicationDidFinishLaunching`, right after the
    /// `restoreSession()`/`createNewWindow()` branch resolves -- NOT
    /// piggybacked onto `fetchSessionsForAgentResume()`, which gates on
    /// the unrelated `agentResumeEnabled` setting and would silently
    /// skip reassertion for a user who has `persistentSessionsEnabled`
    /// and `historyPersistenceEnabled` on but `agentResumeEnabled` off.
    ///
    /// CAVEAT: the daemon that ends up serving this launch's
    /// persistent-session panes is spawned on demand, per pane, by the
    /// FIRST `calyx-session attach --create` ghostty actually execs
    /// (`commands/attach.rs`'s `connect_or_spawn`) -- a process this
    /// call has no synchronous handle on and does not wait for. Unlike
    /// `attach`, the `history` CLI subcommand does not auto-spawn a
    /// daemon, so a reassertion that runs before any pane has actually
    /// attached could race a not-yet-running daemon and silently no-op.
    /// Left as documented best-effort rather than adding a bounded
    /// retry: this whole feature is opt-in/experimental, the corner
    /// self-heals on the next settings toggle (which also pushes
    /// immediately, via `HistoryPersistenceToggleCoordinator`) or the
    /// next launch, and a retry would add timers for a corner most
    /// launches never hit (the daemon is typically already running from
    /// a previous session by the time this races it).
    func reassertHistoryPersistenceIfNeeded() async {
        guard SessionSettings.persistentSessionsEnabled, SessionSettings.historyPersistenceEnabled else { return }
        #if DEBUG
        let client = _sessionDaemonClientForTesting ?? SessionDaemonClient.shared
        #else
        let client = SessionDaemonClient.shared
        #endif
        await client.setHistoryEnabled(true)
    }

    /// Delegates to
    /// `SessionDaemonClientProtocol.listAllBounded()` (lifted from this
    /// method's own former implementation so `SessionBrowserModel.refresh()`
    /// shares the same bounded race and the same timeout constant instead of
    /// awaiting `listAll()` unbounded), then keys the result by session
    /// ID for `offerAgentResume`'s lookup.
    @MainActor
    private static func listAllSessionsBounded(client: SessionDaemonClientProtocol) async -> [String: SessionInfo] {
        let sessions = await client.listAllBounded()
        // A disable mid-flight
        // (`fetchSessionsForAgentResume`'s guard above) cancels this
        // call's enclosing Task; skip the otherwise-pointless keying
        // work once cancelled instead of building a dictionary nobody
        // will read.
        guard !Task.isCancelled else { return [:] }
        return Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
    }

    /// Once a reattached persistent-session surface exists, checks
    /// the daemon's per-session meta (`AgentSessionMetaBridge`'s
    /// recording, resolved from the caller-supplied `sessions`, i.e.
    /// `fetchSessionsForAgentResume`'s result, rather than this
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
    /// connection is even established, which is unverified -- this
    /// method waits for a live, reattached surface first, at the cost
    /// of one caveat verified against ghostty's core (`Surface
    /// .textCallback`): pasted text goes through the same completion
    /// path a real clipboard paste does, and most shells' bracketed
    /// paste handling does not treat a pasted trailing newline as
    /// Return -- so this reliably reproduces "propose" mode
    /// (`agentResumeAutoExecute == false`, no trailing newline, user
    /// presses Return themselves) but "auto-execute" mode's trailing
    /// newline may not actually submit the command; needs live
    /// verification.
    ///
    /// Not `private`: `AppDelegateOfferAgentResumeTests`
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
    /// Test seam: when non-nil, called instead of
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
    /// - `missionMap`:     Cmd+Shift+M — toggle Mission Map.
    /// - `unreadTab`:      Cmd+Shift+U — jump to most recent unread tab.
    /// - `nextTab`:        Cmd+Shift+] — select next tab (Issue #27).
    /// - `previousTab`:    Cmd+Shift+[ — select previous tab (Issue #27).
    /// - `selectTab(Int)`: Cmd+1..Cmd+9 — select tab at 0-based index.
    /// - `debugSelect`:    Ctrl+Shift+D — UI-testing-only debug hook.
    enum KeyMonitorAction: Equatable, Sendable {
        case commandPalette
        case missionMap
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

        // Cmd+Shift+M — Mission Map. Plain Cmd+M (Minimize) is left to
        // the Window menu.
        if mods == [.command, .shift], lowered == "m" {
            return .missionMap
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
            case .commandPalette, .missionMap, .unreadTab, .nextTab, .previousTab, .selectTab:
                // All window-targeted actions require a key window. If none,
                // fall through so the event can still reach the responder
                // chain / menu.
                guard let wc = keyWC else { return event }
                switch action {
                case .commandPalette:        wc.toggleCommandPalette()
                case .missionMap:            wc.toggleMissionMap()
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

    /// Calyx's own About window (`AboutWindowController`) -- it replaced
    /// `NSApp.orderFrontStandardAboutPanel`, which had nowhere to put
    /// the Build/Commit rows or the Docs/GitHub buttons. Only the
    /// implementation changed; the name stayed `showAboutPanel` so the
    /// menu item's selector, and every reference to it, still resolves.
    @objc private func showAboutPanel() {
        AboutWindowController.shared.show()
    }

    /// Help menu's "Calyx Help" item -- opens the hosted documentation
    /// in the user's browser, the same thing About's own "Docs" button
    /// does (both point at `AboutView.docsURL`).
    ///
    /// MUST NOT be named `showHelp(_:)`: `NSApplication` itself
    /// implements that selector (it opens the app's Help Book, or puts
    /// up a "Help isn't available for Calyx." alert when there is none),
    /// and `-[NSApplication targetForAction:]` reaches NSApp BEFORE its
    /// delegate -- so a nil-target `showHelp:` menu item never reaches
    /// this class at all. Field-verified: the alert is exactly what the
    /// first cut of this menu item produced. Ghostty avoids the same
    /// collision only because its MainMenu.xib wires the item's target
    /// to its AppDelegate explicitly; the item below does both (unique
    /// selector AND explicit target).
    @objc private func openCalyxHelp(_ sender: Any?) {
        guard let url = AboutView.docsURL else { return }
        NSWorkspace.shared.open(url)
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

    @objc func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleSecureInput(_:)) {
            menuItem.state = SecureInput.shared.global ? .on : .off
            return true
        }
        return true
    }

    @objc private func handleToggleQuickTerminal() {
        toggleQuickTerminal()
    }

    /// View menu's "Session Browser" item (Cmd+Shift+B): the same call
    /// every other entry point into the session browser already makes
    /// (`SessionBrowserWindowController.attachRemote(_:)`'s sibling
    /// palette command `session.attach`, the Settings panel button).
    @objc private func openSessionBrowser(_ sender: Any?) {
        SessionBrowserWindowController.shared.showBrowser()
    }
}

// MARK: - Notification Names

extension Notification.Name {
    /// Posted when `AppDelegate.isConfirmingQuit` transitions from
    /// `true` to `false` (see that property's `didSet`): the
    /// confirm-quit gate has cleared, whether via a real
    /// `NSAlert.runModal()` return or the `_setConfirmingQuitForTesting`
    /// test seam. `CalyxWindowController` observes this to replay events
    /// it deferred while the gate was up; see
    /// `drainDeferredReconnectEvents()`.
    static let calyxConfirmingQuitDidEnd = Notification.Name("com.calyx.session.confirmingQuitDidEnd")
}

// MARK: - MCPPaneResolving

extension AppDelegate: MCPPaneResolving {
    /// The window and tab that hold `surfaceID`, or the Quick Terminal.
    func paneHost(owningSurface surfaceID: UUID) -> MCPPaneHost? {
        for controller in windowControllers {
            if let owner = controller.windowSession.groups.tabAndGroup(owningSurface: surfaceID) {
                return .window(windowID: controller.windowSession.id, tabID: owner.tab.id)
            }
        }
        if quickTerminalController?.ownsSurface(surfaceID) == true {
            return .quickTerminal
        }
        return nil
    }
}
