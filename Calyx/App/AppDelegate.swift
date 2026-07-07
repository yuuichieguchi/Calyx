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

    /// Captured the moment termination is confirmed (isTerminationConfirmed's
    /// didSet, false -> true transition only), BEFORE any window teardown or
    /// removeWindowController(_:) call can empty windowControllers/appSession.
    /// applicationWillTerminate (via saveForTermination()) consults this
    /// instead of re-deriving buildSnapshot() from the possibly-already-
    /// emptied live state, so the confirm-quit-by-closing-the-last-window
    /// route always saves a real snapshot. Covers BOTH termination routes:
    /// windowShouldClose's confirm branch and applicationShouldTerminate's
    /// own Cmd+Q branch both set isTerminationConfirmed = true.
    private(set) var pendingTerminationSnapshot: SessionSnapshot?

    #if DEBUG
    /// Test seam: force pendingTerminationSnapshot directly instead of
    /// only via isTerminationConfirmed's didSet, so saveForTermination()'s
    /// own "prefers the captured snapshot over a live rebuild" contract is
    /// testable in isolation from the capture mechanism itself. DO NOT use
    /// from production code.
    func _setPendingTerminationSnapshotForTesting(_ snapshot: SessionSnapshot?) {
        pendingTerminationSnapshot = snapshot
    }
    #endif

    /// Set when the user has already confirmed quit (prevents double-prompting
    /// between windowShouldClose and applicationShouldTerminate). The
    /// false -> true transition also captures pendingTerminationSnapshot
    /// (see that property's own doc comment for why); resetting back to
    /// false (applicationShouldTerminate's own "already confirmed" branch)
    /// deliberately leaves any already-captured snapshot untouched.
    var isTerminationConfirmed = false {
        didSet {
            guard isTerminationConfirmed, !oldValue else { return }
            pendingTerminationSnapshot = buildSnapshot()
        }
    }

    /// P4 round-6 fix (R6-A/R6-D, r6-fix-spec.md): app-wide "the app is
    /// actually terminating" discriminator, distinct from any single
    /// `CalyxWindowController.isClosingForShutdown`. That per-window flag
    /// means only "this window is tearing down" (round-5 review finding
    /// I2: `closeLastWindow`/F7 sets it even for a non-terminating close),
    /// so it cannot alone tell a deferred-event drain or `windowWillClose`'s
    /// destroy loop whether the whole app is quitting. This flag must be
    /// consulted (in addition to, not instead of, the per-window flag) by:
    /// the deferred-reconnect-event drain (must NOT replay into teardown
    /// while the app is mid-quit, see r5-verdicts.md V5), and
    /// `windowWillClose`'s destroy loop (must preserve `sessionRefs`
    /// into the snapshot only while this is true; otherwise it must run
    /// the normal kill/detach close policy, see r5-verdicts.md's sweep
    /// finding). Set `true` in `applicationShouldTerminate` on every
    /// `.terminateNow` return (alongside `markAllControllersClosingForShutdown`)
    /// and again in `applicationWillTerminate` as a belt-and-suspenders
    /// safety net. Never reset back to `false`: once the app is genuinely
    /// terminating, it stays that way for the remainder of the process's
    /// life.
    private(set) var isApplicationTerminating = false

    /// R8-C (r8-fix-spec.md; consolidates r7-verdicts.md's I1/A2/C2
    /// dormant discriminator-mismatch finding): the ONE canonical "is
    /// the app actually terminating" query, folding in both
    /// `isApplicationTerminating` (set once `applicationShouldTerminate`
    /// itself has decided to terminate) and `isTerminationConfirmed`
    /// (set earlier, by `windowShouldClose`'s last-window success path,
    /// for the whole window between that decision and
    /// `applicationShouldTerminate` actually running, see that flag's
    /// own doc comment for why `isClosingForShutdown` alone cannot
    /// stand in for this: round-5 review (I2) found it set even for a
    /// non-terminating close). Every reader that used to consult one or
    /// the other ad hoc (`CalyxWindowController.isAppActuallyTerminating`,
    /// `killSessionIfPersistent`/`detachSessionIfPersistent`'s
    /// `isTerminating` parameter) must read THIS query instead, so the
    /// outer "should this teardown preserve or tear down" gate and any
    /// inner policy it drives always agree.
    var isTerminating: Bool {
        isApplicationTerminating || isTerminationConfirmed
    }

    #if DEBUG
    /// Test seam (P4 round-6 fix RED phase): mirrors
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
    /// Test seam (P4 round-6 fix RED phase, R6-D/R6-E): appends
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
        let root = _ghosttyResourcesRootForTesting ?? Bundle.main.resourceURL ?? Bundle.main.bundleURL
        let resolvedPath = GhosttyResourcesDirResolver(resourcesRoot: root).resolve()
        GhosttyResourcesDirEnvironment.apply(resolvedPath)
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

        // Must run before GhosttyAppController.shared's first access below:
        // ghostty forwards shell-integration scripts to surface children
        // only when GHOSTTY_RESOURCES_DIR is already set in this process's
        // own environment at engine init.
        applyGhosttyResourcesDirEnvironmentIfNeeded()

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
            }
        }
        // Bug 3c gap-close: a snapshot preserved by a PREVIOUS run's
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
            isApplicationTerminating = true
            return .terminateNow
        }

        // Already confirmed (from windowShouldClose on last-window close path)
        if isTerminationConfirmed {
            isTerminationConfirmed = false
            markAllControllersClosingForShutdown()
            isApplicationTerminating = true
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
        // R6-A/R6-D (r6-fix-spec.md): app-wide termination signal,
        // alongside markAllControllersClosingForShutdown, consulted by
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

        // R6-A/R6-D (r6-fix-spec.md): belt-and-suspenders alongside
        // applicationShouldTerminate's own set, in case this notification
        // ever fires without that method having run first (see
        // isApplicationTerminating's own doc comment).
        isApplicationTerminating = true

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

        // Last-window close path already persists synchronously in
        // windowWillClose. This guard's ONLY remaining job is skipping
        // pointless work when there is neither a captured confirm-time
        // pendingTerminationSnapshot nor any live window left to build one
        // from -- saveForTermination()'s own saveAtTermination(_:) call
        // already refuses to let an empty snapshot clobber a non-empty
        // on-disk one, so this is not a correctness gate: a non-nil
        // pendingTerminationSnapshot (the confirm-quit-by-closing-the-
        // last-window route, see that property's own doc comment) must
        // still be saved even though windowControllers/appSession are
        // already emptied by the time this runs.
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
        openNewWindow(initialHost: nil)
    }

    /// `initialHost` (P5, remote sessions): forwarded to
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
        wc.showWindow(nil)
    }

    #if DEBUG
    /// Test seam (spawnRemoteSessionTab latent-bug RED phase, confirmed
    /// in scope): called with the chosen target controller immediately
    /// before `spawnRemoteSessionTab` calls `keyWC.createNewTab(host:)`.
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

    /// Test seam (spawnRemoteSessionTab latent-bug RED phase): called
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
    /// .attachRemote(_:)`): spawns a new tab against `host` in the key
    /// window's controller if one exists -- mirrors `handleNewTab`'s own
    /// key-window lookup for a local ghostty-originated new tab --
    /// otherwise opens a fresh window whose sole initial tab spawns
    /// against `host`, reaching a window controller the same way
    /// `attachWindow` always does for a session with no live surface
    /// anywhere yet.
    ///
    /// LATENT BUG (confirmed, in scope for this cycle's Green phase, same
    /// round as the session-browser attach-as-tab fix): every real caller
    /// of this method fires from inside the Session Browser's own button
    /// action, at which point the Session Browser's own window (not any
    /// `CalyxWindowController`'s window) is key -- so
    /// `windowControllers.first(where: { $0.window?.isKeyWindow == true })`
    /// never matches in practice, and this method always falls through to
    /// `openNewWindow`, even when a main window is already open. See
    /// `AppDelegateAttachSessionAsTabTests`'s scope-1 fix for the
    /// identical defect and chosen resolution
    /// (`windowControllers.first(where: { $0.window?.isKeyWindow == true }) ?? windowControllers.first`,
    /// team-confirmed); this method's own fix is Green-phase work, not
    /// yet applied here -- the two new hooks above exist solely to make
    /// today's (buggy) behavior observable without hanging the test
    /// process, see `AppDelegateSpawnRemoteSessionTabWindowLookupTests`.
    func spawnRemoteSessionTab(host: String?) {
        // FIX (see this method's own doc comment): the real caller fires
        // from inside the Session Browser's own button action, at which
        // point the Session Browser's plain NSWindow, not any
        // CalyxWindowController's window, is key -- so an isKeyWindow-
        // only lookup never matched in practice. Prefer the actually-key
        // window if one exists, but fall back to the first available
        // controller instead of dead-ending on the Session Browser panel
        // holding key status.
        if let targetWC = windowControllers.first(where: { $0.window?.isKeyWindow == true }) ?? windowControllers.first {
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
    /// and ghostty surface, invoked instead of that real work, which
    /// never runs. Driving `attachWindow` end-to-end with a live
    /// surface is unsafe from this test host (confirmed empirically:
    /// it hangs the XCTest process indefinitely, no other test in
    /// this suite creates a real ghostty surface or calls
    /// `showWindow`). This seam lets `AppDelegateAttachWindowTests`
    /// observe WHETHER `attachWindow` reaches its window-creation step
    /// at all, exactly what F6's double-attach guard must prevent for
    /// an already-attached sessionID, without ever performing that
    /// real, unsafe-to-test work. Does not affect production behavior:
    /// `nil` (the default) leaves this line as a no-op; every guard
    /// ABOVE this point (including the fix this seam was added for)
    /// still runs for real, unmodified. DO NOT use from production
    /// code.
    var _attachWindowCreationHookForTesting: (() -> Void)?

    /// Test seam (P5, remote sessions, contract 3c): called with the
    /// constructed placeholder `tab`, immediately before
    /// `_attachWindowCreationHookForTesting`'s own check -- today's hook
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

        // F6 (S1, HIGH, r4-fix-spec.md): a sessionID already registered
        // in SessionSurfaceMap already has a live surface somewhere in
        // this process. This covers the session browser's double-click/
        // stale-row race (rows only refresh on poll, and this method has
        // no debounce of its own). Focus that existing surface's window
        // instead of creating a second one. Checked BEFORE the
        // test-creation hook below, so AppDelegateAttachWindowTests can
        // observe the guard firing without ever reaching real window/
        // surface creation.
        //
        // R6-D (r6-fix-spec.md, sweep finding): `focusWindowForExistingSession`
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
            // NSHomeDirectory() ignores a HOME env override (P4 root-resolver lesson); use the canonical resolver.
            title: SessionTabTitle.fromCwd(cwd, home: SessionRootResolver().resolve()),
            pwd: cwd,
            splitTree: SplitTree(leafID: placeholderLeafID),
            sessionRefs: [placeholderLeafID: SessionRef(sessionID: sessionID, host: host)]
        )

        // P5 (remote sessions): Tab's own init has no side effects (no
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
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            windowSession: windowSession
        )

        // R6-C (r6-fix-spec.md, r5-verdicts.md R5-blocking): starts the
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
    /// Test seam (P4 round-6 fix RED phase, R6-E): when non-nil, called
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

    /// F6: brings the window already hosting `sessionID`'s live surface
    /// to the front, instead of `attachWindow` creating a second one for
    /// the same session. Returns `true` once a live controller was found
    /// and focused, `false` when the mapping was stale (see below); the
    /// caller (`attachWindow`) falls through to a fresh attach on `false`.
    ///
    /// R6-D (r6-fix-spec.md, sweep finding): when NO controller contains
    /// the mapped surfaceID at all (a stale mapping left behind by, e.g.,
    /// a non-terminating window close that unregistered every OTHER
    /// tracked surface but somehow left this one stale, or a window
    /// that's mid-teardown, skipped below), unregisters the stale entry
    /// and returns `false` instead of silently doing nothing.
    ///
    /// R6-E (r6-fix-spec.md, A2): also activates the tab/group
    /// containing `surfaceID` (`CalyxWindowController.activateTabContaining`,
    /// reusing that controller's existing tab-switch logic instead of
    /// reimplementing containment, reuse finding F3f) before showing the
    /// window, so a session living in a background tab is actually
    /// visible, not just the window with whatever tab happened to
    /// already be active. Skips any controller mid-teardown
    /// (`isClosingForShutdown`), since that window's surfaces are about
    /// to be torn down or preserved into a snapshot, not a valid focus
    /// target.
    private func focusWindowForExistingSession(sessionID: String) -> Bool {
        guard let surfaceID = SessionSurfaceMap.shared.surfaceID(for: sessionID) else { return false }
        guard let wc = windowControllers.first(where: { controller in
            !controller.isClosingForShutdown && controller.windowSession.groups.contains { group in
                group.tabs.contains { $0.registry.contains(surfaceID) }
            }
        }) else {
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
    /// Test seam (session browser Attach-consistency RED phase): when
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
    /// `attachWindow`'s own F6 guard), `hasAvailableWindow` from the same
    /// "prefer the key window, else the first available one" lookup
    /// `spawnRemoteSessionTab` now also uses (see that method's own doc
    /// comment for why an `isKeyWindow`-only lookup never matches a real
    /// main window from either call site: both fire from inside the
    /// Session Browser's own button action, at which point the Session
    /// Browser's plain `NSWindow`, not any `CalyxWindowController`'s
    /// window, is key) -- and dispatches to the matching action.
    ///
    func attachSessionAsTab(sessionID: String, cwd: String?, host: String? = nil) {
        let isAttachedHere = SessionSurfaceMap.shared.surfaceID(for: sessionID) != nil
        // Same "prefer key, else first" fallback as `spawnRemoteSessionTab`'s
        // own fix, and for the identical reason: whichever controller this
        // resolves to is also the one `.attachAsTab` below adds the new tab
        // to, so `hasAvailableWindow` and the eventual target come from the
        // same lookup.
        let targetWindowController = windowControllers.first(where: { $0.window?.isKeyWindow == true })
            ?? windowControllers.first
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
            // unregistered it above (R6-D precedent). Re-decide now that
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
    /// Test seam (attached-tab placeholder title RED phase): mirrors
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
    #endif

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
            // NSHomeDirectory() ignores a HOME env override (P4 root-resolver lesson); use the canonical resolver.
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

    /// Not `private` any more (session-browser menu-item RED phase):
    /// mirrors `closeAllTabsInGroup(id:)`'s/`processChildExited`'s/
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
        let actor = _sessionPersistenceActorForTesting ?? SessionPersistenceActor.shared
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
        let actor = _sessionPersistenceActorForTesting ?? SessionPersistenceActor.shared
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

    /// Bug 3c gap-close: initializes hasPreservedSessionSnapshot from
    /// whatever preserveSnapshotForRecovery() left on disk in a PREVIOUS
    /// run, so a relaunch (where THIS run's own restoreSession() never
    /// calls preserveSnapshotForRecovery() itself) still offers the
    /// still-pending recovery command. Mirrors
    /// reassertHistoryPersistenceIfNeeded()'s async-Task-after-launch shape.
    private func initializeHasPreservedSessionSnapshotFlag() async {
        let actor = _sessionPersistenceActorForTesting ?? SessionPersistenceActor.shared
        hasPreservedSessionSnapshot = await actor.hasPreservedSnapshot()
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
        let actor = _sessionPersistenceActorForTesting ?? SessionPersistenceActor.shared
        Task {
            guard let snapshot = await actor.loadPreservedSnapshot() else {
                // Nothing preserved, OR preserved but undecodable
                // (corrupt/unknown schema) -- quarantine is a no-op in
                // the former sub-case, so calling it unconditionally is
                // safe and unsticks the latter.
                await actor.quarantineCorruptPreservedSnapshot()
                hasPreservedSessionSnapshot = false
                return
            }
            guard !snapshot.windows.isEmpty else { return }
            var restoredAny = false
            for windowSnap in snapshot.windows {
                if restoreWindow(windowSnap) {
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
        let actor = _sessionPersistenceActorForTesting ?? SessionPersistenceActor.shared
        await actor.clearPreservedSnapshot()
        hasPreservedSessionSnapshot = false
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
        let actor = _sessionPersistenceActorForTesting ?? SessionPersistenceActor.shared
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
        let actor = _sessionPersistenceActorForTesting ?? SessionPersistenceActor.shared
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

    /// Synchronously bridges the async hasRunningPersistentSessions()
    /// into restoreSession()'s own synchronous body. Unlike
    /// attemptSessionRestoreFromDisk(deadline:)/
    /// attemptPreserveDiscardedSessionOnDisk(deadline:) above, this uses
    /// a plain (non-detached) `Task { }`, not SyncBridgeBox/Task.detached:
    /// hasRunningPersistentSessions() is itself MainActor-isolated (this
    /// class's default), so a detached task calling back into it would
    /// need to re-acquire MainActor's turn -- exactly the deadlock
    /// SyncBridgeBox's own doc comment describes -- reintroducing the
    /// same bug this bridge exists to avoid. This is safe as the plain,
    /// inherited-isolation form ONLY because restoreSession() (this
    /// method's sole caller) is itself reached exclusively from
    /// applicationDidFinishLaunching, a genuinely synchronous call stack
    /// with no enclosing MainActor Task already occupying a turn -- if
    /// this is ever driven from an async test caller the way
    /// attemptSessionRestoreFromDisk's sibling tests are, it needs the
    /// same SyncBridgeBox treatment first. The generous default deadline
    /// comfortably exceeds SessionDaemonClient.daemonQueryBoundTimeoutSeconds's
    /// own default bound, so a merely-slow (not unreachable) daemon
    /// still gets a real chance to answer; if it doesn't, this
    /// conservatively reports `false` -- the same "no evidence of an
    /// anomaly" default hasRunningPersistentSessions() itself already
    /// reports for a probe failure.
    private func hasRunningPersistentSessionsBridged(deadline: TimeInterval = 6.0) -> Bool {
        var result = false
        var done = false
        Task {
            result = await hasRunningPersistentSessions()
            done = true
        }
        let deadlineDate = Date().addingTimeInterval(deadline)
        while !done, Date() < deadlineDate {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        }
        return result
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
            snapshot = restored
        }

        guard !snapshot.windows.isEmpty else {
            // C4: with close=kill semantics, a genuinely empty on-disk
            // snapshot from a deliberate "closed every window" quit
            // should never coexist with the daemon still reporting a
            // running persistent session -- when it does, this is much
            // more likely a bug/race (see hasRunningPersistentSessions's
            // own doc comment) than a deliberate quit, so route through
            // preserve+notify instead of silently accepting it.
            if hasRunningPersistentSessionsBridged() {
                logger.warning("Empty session snapshot restored alongside a running persistent session; treating as an anomaly")
                preserveDiscardedSessionIfAny()
                notifyPreviousSessionNotRestored()
                return false
            }
            // The user deliberately closed every window before their
            // last quit -- not a loss to recover from, so this branch
            // does not preserve or notify.
            logger.info("No session to restore")
            return false
        }

        // F10 (V11, WARNING, r4-fix-spec.md): one listAll() subprocess
        // for the whole restore pass, instead of one per surface (see
        // fetchSessionsForAgentResume's doc comment). R6-C: no longer
        // waited on here, window/tab restoration proceeds immediately.
        fetchSessionsForAgentResume()
        var restoredAny = false

        for windowSnap in snapshot.windows {
            if restoreWindow(windowSnap) {
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

    private func restoreWindow(_ windowSnap: WindowSnapshot) -> Bool {
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

    /// Not `private` (P4 round-8 fix RED phase, T-B):
    /// `AppDelegateRestoreTabSurfacesOwnershipTests`/
    /// `AppDelegateOfferAgentResumePipelineBoundTests` call this directly
    /// (with `_createSurfaceWithPwdHookForTesting` set, see that seam's
    /// own doc comment on `createSurfaceWithPwd`) to drive its
    /// partial-failure cleanup and per-surface agent-resume dispatch
    /// deterministically, without a real, live ghostty surface, mirroring
    /// `fetchSessionsForAgentResume`'s identical round-6 RED phase
    /// precedent.
    func restoreTabSurfaces(tab: Tab, app: ghostty_app_t, window: NSWindow) -> Bool {
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
        // R8-D item 3 (H2, r8-fix-spec.md): collected here, fanned out
        // through a single shared Task below instead of
        // `createSurfaceWithPwd` spawning its own per-surface Task (see
        // its own doc comment).
        var agentResumeCandidates: [(tab: Tab, surfaceID: UUID, sessionID: String)] = []

        for oldID in oldLeafIDs {
            guard let created = createSurfaceWithPwd(tab: tab, app: app, window: window, oldLeafID: oldID) else {
                continue
            }
            let newID = created.surfaceID
            mapping[oldID] = newID
            if let sessionRef = tab.sessionRefs[oldID] {
                // R6-C (V4 constraint, r6-fix-spec.md): re-checked
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

        // R8-D item 3 (H2): one shared Task awaits the shared fetch
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
            return true
        }

        // Partial failure: destroy any surfaces we created (undoing
        // their SessionSurfaceMap registration too) and return false.
        // R8-B (r8-fix-spec.md; r7-verdicts.md R7-V3): unregisters only
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

    private func fallbackCreateSurface(tab: Tab, app: ghostty_app_t, window: NSWindow) -> Bool {
        guard let created = createSurfaceWithPwd(tab: tab, app: app, window: window) else {
            return false
        }
        let newID = created.surfaceID
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
    /// R6-C (r6-fix-spec.md): no longer takes a `sessions` parameter.
    /// The surface is created immediately, synchronously; a caller that
    /// gets a non-nil `agentResumeSessionID` back awaits
    /// `agentResumeSessionsTask`'s result itself before calling
    /// `offerAgentResume` (see `restoreTabSurfaces`'s R8-D/H2 fan-out),
    /// so this method never waits on the daemon.
    private func createSurfaceWithPwd(
        tab: Tab, app: ghostty_app_t, window: NSWindow, oldLeafID: UUID? = nil
    ) -> (surfaceID: UUID, agentResumeSessionID: String?)? {
        var config = GhosttyFFI.surfaceConfigNew()
        config.scale_factor = Double(window.backingScaleFactor)

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
    /// Test seam (P4 round-8 fix RED phase, T-B/T-D): when non-nil,
    /// called INSTEAD of the real `tab.registry.createSurface(...)` FFI
    /// call inside `createRegistrySurface`, keyed by `oldLeafID` (`nil`
    /// for the no-old-leaf/fallback path). Returns the UUID to report as
    /// the newly created surface (simulating success), or `nil` to
    /// simulate surface-creation failure for that one leaf, letting
    /// `restoreTabSurfaces`'s partial-failure bookkeeping (and, R8-D/H2,
    /// its shared agent-resume fan-out `Task`) be driven deterministically
    /// without a real, live ghostty surface (confirmed unsafe from this
    /// test host, see `_attachWindowCreationHookForTesting`'s doc comment
    /// for the confirmed hang). Placed as the narrowest possible wrapper
    /// around only the actually-unsafe call: everything around it (the
    /// attach-command detection, the `offerAgentResume` dispatch) stays
    /// real, unmodified production code. `nil` (the default) leaves
    /// production behavior unchanged. DO NOT use from production code.
    var _createSurfaceWithPwdHookForTesting: ((UUID?) -> UUID?)?

    /// Test seam (P4 round-8 fix RED phase, T-D): when non-nil, called
    /// once `restoreTabSurfaces`'s shared agent-resume fan-out `Task`
    /// (R8-D/H2, r8-fix-spec.md; formerly a per-surface `Task` spawned
    /// directly inside `createSurfaceWithPwd`, before that fan-out
    /// consolidated it) has awaited `agentResumeSessionsTask`'s result
    /// and called `offerAgentResume` for ONE reattached leaf, i.e. once
    /// that leaf's pipeline reaches a terminal state, regardless of
    /// whether `offerAgentResume` actually found a resumable session to
    /// act on. Fires once per candidate leaf in the fan-out, not once
    /// per restore pass. No such observable existed before this seam:
    /// the fan-out `Task` is otherwise fire-and-forget, with nothing to
    /// await from a test. `nil` (the default) leaves production
    /// behavior unchanged. DO NOT use from production code.
    var _createSurfaceWithPwdOfferAgentResumeCompletedHookForTesting: (() -> Void)?

    /// Test seam (P5, remote sessions, contract R2): when non-nil,
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
    /// Test seam (P4 round-6 fix RED phase, R6-C): when non-nil, used
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

    /// R6-C (r6-fix-spec.md, r5-verdicts.md R5-blocking): the async
    /// fetch task `fetchSessionsForAgentResume()` starts, shared by
    /// every surface created during the SAME restore/attach pass so
    /// `restoreTabSurfaces`'s fan-out `Task` (R8-D/H2) can await its
    /// result, right before calling `offerAgentResume`, instead of
    /// blocking on it. `restoreSession`/`attachWindow` each make exactly
    /// one call per pass (matching F10's original "one `listAll()` per
    /// pass" intent); `restoreWindow`/`restoreTabSurfaces` read this
    /// property synchronously afterward, within that same call stack.
    ///
    /// R8-D item 2 (H1, r8-fix-spec.md): no longer unconditionally
    /// overwritten. `fetchSessionsForAgentResume()` reuses an already
    /// in-flight task instead of starting a second daemon subprocess
    /// for the same purpose (a `listAll()` round-trip reflects the
    /// whole daemon-wide ledger regardless of which pass triggered it,
    /// so an overlapping pass reusing a still-in-flight fetch from a
    /// previous one is exactly as correct as waiting for a fresh one).
    /// Not `private` (P4 round-8 fix RED phase, G5): exposed read-only
    /// so `AppDelegateFetchSessionsForAgentResumeTests` can observe that
    /// a task was actually started, now that
    /// `fetchSessionsForAgentResume()` itself no longer returns a
    /// meaningful synchronous result.
    ///
    /// R10-B (r10-fix-spec.md): reset back to `nil` once the task it
    /// holds actually COMPLETES (see `agentResumeFetchGeneration`'s doc
    /// comment), not only when agent resume is disabled. Before this
    /// fix, the `== nil` reuse guard in `fetchSessionsForAgentResume()`
    /// never reset after a successful fetch, so every call after the
    /// very first one silently reused the launch-time snapshot forever;
    /// a first fetch that timed out permanently pinned an empty `[:]`
    /// result.
    private(set) var agentResumeSessionsTask: Task<[String: SessionInfo], Never>?

    /// R10-B (r10-fix-spec.md): monotonic counter identifying which
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

    /// R8-D item 1 (r8-fix-spec.md; r7-verdicts.md's "Unbounded await
    /// (D1)" finding): the deadline `SessionDaemonClientProtocol
    /// .listAllBounded()` races the real daemon round-trip against, so
    /// `agentResumeSessionsTask` always reaches a terminal state even
    /// if the daemon never responds at all.
    /// `AppDelegateOfferAgentResumePipelineBoundTests`'s 15s `XCTWaiter`
    /// bound comfortably exceeds this (R10-C item 2/5, r10-fix-spec.md:
    /// shared with `SessionBrowserModel.refresh()` via `listAllBounded()`'s
    /// `daemonQueryBoundTimeoutSeconds`. R14-B (r14-fix-spec.md) later gave
    /// `sessionStateBounded(id:)`'s reconnect-decision path its own,
    /// longer `sessionStateBoundTimeoutSeconds` instead of reusing this
    /// one, so the low- and high-consequence callers now deliberately use
    /// two separate bounds, not the single shared constant this comment
    /// used to describe).

    /// F10 (V11, WARNING, r4-fix-spec.md): starts (but does not wait
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
    /// R6-C (r6-fix-spec.md, r5-verdicts.md R5-blocking) fix: this used
    /// to `RunLoop.current.run` spin the calling (main) thread in 10ms
    /// steps for up to 2.0s, synchronously, on both call sites above,
    /// the opposite of this method's stated purpose. Now it only starts
    /// `agentResumeSessionsTask` and returns immediately; window/tab
    /// restoration proceeds without ever waiting on the daemon, and
    /// `restoreTabSurfaces`'s fan-out `Task` (R8-D/H2) awaits
    /// `agentResumeSessionsTask` itself, only where the result is
    /// actually needed.
    ///
    /// G5 (r8-fix-spec.md): returns `Void`, not a dictionary. The old
    /// return value was always `[:]` (no daemon response is ever
    /// available synchronously), never a meaningful result to report;
    /// `agentResumeSessionsTask` itself (see its own doc comment) is
    /// what callers actually need. Not `private` (round-6 RED phase):
    /// `AppDelegateFetchSessionsForAgentResumeTests` calls this directly
    /// to measure that it no longer blocks, matching this file's
    /// `offerAgentResume`/`attachWindow` direct-drive precedent.
    func fetchSessionsForAgentResume() {
        guard SessionSettings.agentResumeEnabled else {
            // R10-B item 2 (r10-fix-spec.md): cancel a still-in-flight
            // fetch instead of merely dropping the reference.
            // `Task.cancel()` only sets a cooperative flag, but R14-A
            // (r14-fix-spec.md) made `SessionDaemonClientProtocol
            // .bounded(...)` (the race `listAllSessionsBounded` below
            // ultimately awaits) honor that flag with a
            // `withTaskCancellationHandler` that cancels both its
            // internal race arms and resumes promptly -- reaching, in
            // turn, `SystemCommandRunner.run()`'s own R12-A cancellation
            // handler, which SIGTERMs the underlying `calyx-session`
            // subprocess -- so a disable mid-flight now genuinely ends
            // the daemon round-trip promptly instead of merely dropping
            // an unobserved reference to it (or, pre-R14-A, riding out
            // the full bound regardless of this cancel() call).
            agentResumeSessionsTask?.cancel()
            agentResumeSessionsTask = nil
            return
        }
        // R8-D item 2 (H1): reuse whatever fetch is already in flight
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
            // R10-B item 1 (r10-fix-spec.md): reset back to nil once
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

    /// P6 (R-B4): the attach-spawned calyx-session daemon always starts
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

    /// R8-D item 1 (r8-fix-spec.md; r7-verdicts.md's "Unbounded await
    /// (D1)" finding): delegates to
    /// `SessionDaemonClientProtocol.listAllBounded()` (R10-C item 2,
    /// r10-fix-spec.md, lifted from this method's own former
    /// implementation so `SessionBrowserModel.refresh()` shares the
    /// same bounded race and the same timeout constant instead of
    /// awaiting `listAll()` unbounded), then keys the result by session
    /// ID for `offerAgentResume`'s lookup.
    @MainActor
    private static func listAllSessionsBounded(client: SessionDaemonClientProtocol) async -> [String: SessionInfo] {
        let sessions = await client.listAllBounded()
        // R12-A item 4 (r12-fix-spec.md): a disable mid-flight
        // (`fetchSessionsForAgentResume`'s guard above) cancels this
        // call's enclosing Task; skip the otherwise-pointless keying
        // work once cancelled instead of building a dictionary nobody
        // will read.
        guard !Task.isCancelled else { return [:] }
        return Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
    }

    /// True when the daemon's ledger currently reports at least one
    /// RUNNING persistent session. Reuses listAllSessionsBounded(client:)
    /// exactly as fetchSessionsForAgentResume() already does -- bounded,
    /// best-effort; a probe failure (daemon unreachable/timeout) surfaces
    /// as an empty ledger, which this method treats as "no evidence of
    /// any anomaly" (current, unchanged behavior for that case).
    /// Consulted by restoreSession()'s empty-snapshot branch: with
    /// close=kill semantics, a genuinely empty snapshot from a deliberate
    /// "closed every window" quit should never coexist with a still-
    /// running persistent session.
    func hasRunningPersistentSessions() async -> Bool {
        #if DEBUG
        let client = _sessionDaemonClientForTesting ?? SessionDaemonClient.shared
        #else
        let client = SessionDaemonClient.shared
        #endif
        let sessions = await AppDelegate.listAllSessionsBounded(client: client)
        return sessions.values.contains { session in
            if case .running = session.state { return true }
            return false
        }
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
    /// it deferred while the gate was up (F4, r4-fix-spec.md); see
    /// `drainDeferredReconnectEvents()`.
    static let calyxConfirmingQuitDidEnd = Notification.Name("com.calyx.session.confirmingQuitDidEnd")
}
