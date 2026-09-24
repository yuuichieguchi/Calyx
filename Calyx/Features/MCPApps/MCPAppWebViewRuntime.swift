//
//  MCPAppWebViewRuntime.swift
//  Calyx
//
//  The WebKit side of MCP Apps. Mounts each view's web view (host page,
//  sandboxed iframe, bridge in its own content world), keeps one card per
//  store view in the pane's dock or a standalone panel, and answers the
//  view's requests (see MCPAppWebViewRuntime+Requests.swift). Consent
//  prompts (`ui/open-link`, `ui/message`) show in the app-wide approval
//  panel through `MCPAppRuntimeEnvironment.consentPresenter`, one
//  pending request per view at most.
//

import AppKit
import WebKit
import os

private let logger = Logger(subsystem: "com.calyx.terminal", category: "MCPAppWebViewRuntime")

/// What the runtime needs from the app around it.
@MainActor
protocol MCPAppRuntimeEnvironment: AnyObject {
    /// The split container that shows `surfaceID`'s leaf, whichever tab is active.
    func splitContainer(owningSurface surfaceID: UUID) -> SplitContainerView?
    /// The herdr pane a surface mirrors, when it is a herdr pane.
    func herdrPaneRef(forSurface surfaceID: UUID) -> HerdrPaneRef?
    /// `agentRegistry.entries[surfaceID] != nil`: the Return rule of `pane_run`.
    func isAgentPane(_ surfaceID: UUID) -> Bool
    /// Delivery into ordinary Calyx panes.
    var cockpitInputDelivery: any MCPAppInputDelivering { get }
    /// Calyx's theme and the ghostty colors and font, for the style variables.
    func themeInputs() -> MCPAppThemeInputs
    /// Opens a `ui/open-link` URL the user allowed. True when it opened.
    func openLink(_ url: URL) -> Bool
    /// Shows the consent prompts of `ui/open-link` and `ui/message` (the
    /// approval panel) and returns the user's decision.
    var consentPresenter: any MCPAppConsentPresenting { get }
}

@MainActor
final class MCPAppWebViewRuntime: MCPAppViewRuntime {

    /// `ui/resource-teardown` gets this long to answer.
    nonisolated static let teardownReplyWait: Duration = .seconds(2)

    /// How long a consent prompt waits for the user before it resolves as
    /// Cancel / Don't Send: one hour, the longest `ApprovalInboxStore`
    /// allows.
    nonisolated static let defaultConsentTimeoutMs = 3_600_000

    /// One mounted web view and the objects that guard it.
    final class Mounted {
        let webView: WKWebView
        let bridge: MCPAppBridge
        let navigationGuard: MCPAppNavigationGuard
        let mediaDelegate: MCPAppMediaPermissionDelegate
        let document: MCPAppViewDocument

        init(webView: WKWebView, bridge: MCPAppBridge, navigationGuard: MCPAppNavigationGuard,
             mediaDelegate: MCPAppMediaPermissionDelegate, document: MCPAppViewDocument) {
            self.webView = webView
            self.bridge = bridge
            self.navigationGuard = navigationGuard
            self.mediaDelegate = mediaDelegate
            self.document = document
        }
    }

    /// Everything the runtime keeps for one store view.
    final class ViewState {
        let pane: MCPAppViewPane
        var mounted: Mounted?
        var surfaceID: UUID?
        var displayMode = "inline"
        /// `appCapabilities.availableDisplayModes` from `ui/initialize`; nil when not declared.
        var appDisplayModes: [String]?
        /// `appCapabilities.tools` was declared: the view offers its own tools.
        var appDeclaresTools = false
        var lastHostContext: [String: AnyCodable] = [:]
        var pipWindow: MCPAppPiPWindow?
        var panel: MCPAppStandalonePanel?
        /// Grows by one each time a document of the view starts unloading
        /// (`requestTeardown`, `unmount`). A prompt answered after it grew
        /// belongs to a document that is gone.
        var documentGeneration = 0
        /// The view's consent request waiting in the approval panel, if
        /// any. A new prompt for the view, an unloading document, and the
        /// view's removal each expire it.
        var pendingConsentRequestID: UUID?

        init(pane: MCPAppViewPane) {
            self.pane = pane
        }
    }

    /// A pane's dock and the container it was attached to. The dock is
    /// detached through that container: a destroyed surface is no longer
    /// found through `environment`.
    private struct DockAttachment {
        let dock: MCPAppDockView
        weak var container: SplitContainerView?
    }

    weak var store: MCPAppHostStore? {
        didSet { syncWithStore() }
    }
    let environment: any MCPAppRuntimeEnvironment
    let consentGate = MCPAppMessageConsentGate()
    let openLinkPolicy = MCPAppOpenLinkPolicy()
    /// How long a consent prompt waits for the user; tests shorten it.
    var consentTimeoutMs = defaultConsentTimeoutMs
    private(set) var views: [UUID: ViewState] = [:]
    /// Web views of views the store dropped, kept until `unmount`.
    private var retiringMounts: [UUID: Mounted] = [:]
    private var docks: [UUID: DockAttachment] = [:]
    private var observers: [NSObjectProtocol] = []

    init(environment: any MCPAppRuntimeEnvironment) {
        self.environment = environment
        let center = NotificationCenter.default
        // `queue: .main` delivers on the main thread, so the main actor is
        // already current (the codebase's ConfigFileWatcher idiom).
        observers.append(center.addObserver(forName: .calyxMCPAppViewsChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncWithStore() }
        })
        for name in [NSLocale.currentLocaleDidChangeNotification, .NSSystemTimeZoneDidChange] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.hostEnvironmentDidChange() }
            })
        }
    }

    // MARK: - MCPAppViewRuntime

    /// Throws `MCPAppWebViewFactoryError.viewRemoved`, after removing the
    /// compiled rule list, when the store dropped the view while the
    /// configuration was being built.
    func mount(viewID: UUID, document: MCPAppViewDocument) async throws {
        let configuration = try await MCPAppWebViewFactory.makeViewConfiguration(document: document, additionalSchemeHandlers: [:])
        guard store?.snapshot(viewID: viewID) != nil else {
            await removeContentRuleList(identifier: document.contentRuleListIdentifier)
            throw MCPAppWebViewFactoryError.viewRemoved
        }
        guard let hostPageURL = MCPAppSchemeHandler.hostPageURL(hostOrigin: document.hostOrigin),
              let viewURL = MCPAppSchemeHandler.viewDocumentURL(viewOrigin: document.viewOrigin) else {
            throw MCPAppWebViewFactoryError.invalidOrigin
        }
        let webView = WKWebView(frame: .zero, configuration: configuration)
        let bridge = MCPAppBridge()
        bridge.webView = webView
        bridge.delegate = self
        MCPAppWebViewFactory.installBridge(into: webView, world: bridge.world, handler: bridge)
        let navigationGuard = MCPAppNavigationGuard(allowedInitialURLs: [hostPageURL, viewURL])
        navigationGuard.onDidFinishLoad = { [weak self] in self?.store?.viewDidLoadDocument(viewID: viewID) }
        navigationGuard.onProcessTerminated = { [weak self, weak bridge] in
            // A dead process answers nothing: pending requests fail now.
            bridge?.close()
            self?.store?.viewProcessDidTerminate(viewID: viewID)
        }
        let mediaDelegate = MCPAppMediaPermissionDelegate()
        webView.navigationDelegate = navigationGuard
        webView.uiDelegate = mediaDelegate

        let mounted = Mounted(webView: webView, bridge: bridge, navigationGuard: navigationGuard,
                              mediaDelegate: mediaDelegate, document: document)
        let state = viewState(for: viewID)
        state.mounted = mounted
        state.pane.setWebView(webView)
        syncWithStore()
        webView.load(URLRequest(url: hostPageURL))
    }

    func send(_ message: JSONRPCMessage, to viewID: UUID) async throws -> JSONRPCMessage? {
        guard let bridge = mounted(viewID)?.bridge else { throw MCPAppBridgeError.viewUnavailable }
        return try await bridge.send(message)
    }

    /// The view's web view, whether its card is shown or already dropped.
    private func mounted(_ viewID: UUID) -> Mounted? {
        views[viewID]?.mounted ?? retiringMounts[viewID]
    }

    /// Sends `ui/resource-teardown` to a view that initialized (the host
    /// sends nothing before `initialized`) and waits up to 2 seconds.
    func requestTeardown(viewID: UUID) async {
        denyPendingPrompts(viewID: viewID)
        guard let bridge = mounted(viewID)?.bridge, bridge.hasReceivedInitialized else { return }
        let request = JSONRPCMessage.request(id: .string("teardown"), method: "ui/resource-teardown", params: [:])
        let wait = Self.teardownReplyWait
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let once = MCPAppResumeOnce(continuation)
            Task { @MainActor in
                do {
                    _ = try await bridge.send(request)
                } catch {
                    logger.info("ui/resource-teardown got no reply: \(error, privacy: .public)")
                }
                once.resume()
            }
            Task { @MainActor in
                try await Task.sleep(for: wait)
                once.resume()
            }
        }
    }

    func unmount(viewID: UUID) {
        denyPendingPrompts(viewID: viewID)
        let mounted: Mounted
        if let state = views[viewID], let shown = state.mounted {
            state.mounted = nil
            // A remounted view initializes again and gets a full host context.
            state.lastHostContext = [:]
            state.pane.setWebView(nil)
            mounted = shown
        } else if let retiring = retiringMounts.removeValue(forKey: viewID) {
            mounted = retiring
        } else {
            return
        }
        mounted.bridge.close()
        mounted.webView.stopLoading()
        MCPAppWebViewFactory.removeBridgeAndContent(from: mounted.webView, world: mounted.bridge.world)
        mounted.webView.navigationDelegate = nil
        mounted.webView.uiDelegate = nil
        let identifier = mounted.document.contentRuleListIdentifier
        Task { @MainActor [weak self] in
            await self?.removeContentRuleList(identifier: identifier)
        }
    }

    private func removeContentRuleList(identifier: String) async {
        do {
            try await MCPAppWebViewFactory.removeContentRuleList(identifier: identifier)
        } catch {
            logger.error("Could not remove content rule list \(identifier, privacy: .public): \(error, privacy: .public)")
        }
    }

    // MARK: - Startup

    /// Removes rule lists a previous run left behind. Call once at launch,
    /// before any view mounts.
    func sweepStaleContentRuleLists() async throws {
        try await MCPAppWebViewFactory.sweepStaleContentRuleLists()
    }

    // MARK: - Placement

    /// Brings panes, docks and panels in line with the store.
    func syncWithStore() {
        guard let store else { return }
        let snapshots = store.allSnapshots()
        let liveIDs = Set(snapshots.map(\.viewID))

        for viewID in Array(views.keys) where !liveIDs.contains(viewID) {
            discard(viewID: viewID)
        }
        for snapshot in snapshots {
            let state = viewState(for: snapshot.viewID)
            state.pane.update(snapshot: snapshot, droppedCSPEntries: store.droppedCSPEntries(forView: snapshot.viewID))
            place(state, snapshot: snapshot)
        }
    }

    /// The dock of `surfaceID`, attached to its leaf.
    private func dock(for surfaceID: UUID) -> MCPAppDockView? {
        if let attachment = docks[surfaceID] { return attachment.dock }
        guard let container = environment.splitContainer(owningSurface: surfaceID) else { return nil }
        let dock = MCPAppDockView(surfaceID: surfaceID)
        docks[surfaceID] = DockAttachment(dock: dock, container: container)
        container.attachDock(dock, toLeaf: surfaceID)
        return dock
    }

    /// Puts the card in its pane's dock or its standalone panel. The view's
    /// `displayMode` is the only record of fullscreen: a card entering a
    /// dock (first placement, return from PiP, a remapped surface) sets
    /// the container's fullscreen from it.
    private func place(_ state: ViewState, snapshot: MCPAppViewSnapshot) {
        let viewID = snapshot.viewID
        if state.surfaceID != snapshot.surfaceID, let old = state.surfaceID {
            removeFromDock(viewID: viewID, surfaceID: old)
        }
        state.surfaceID = snapshot.surfaceID

        if let surfaceID = snapshot.surfaceID {
            guard state.pipWindow == nil, let dock = dock(for: surfaceID) else { return }
            let isEntering = !dock.panes.contains { $0 === state.pane }
            dock.add(state.pane)
            dock.setTitle(snapshot.title, forViewID: viewID)
            if isEntering, state.displayMode == "fullscreen" {
                docks[surfaceID]?.container?.setFullscreen(true, forLeaf: surfaceID)
            }
        } else if state.panel == nil {
            let panel = MCPAppStandalonePanel(viewID: viewID, pane: state.pane)
            panel.title = snapshot.title
            panel.onUserClose = { [weak self] in self?.userClosed(viewID: viewID) }
            state.panel = panel
            panel.makeKeyAndOrderFront(nil)
        } else {
            state.panel?.title = snapshot.title
        }
    }

    private func viewState(for viewID: UUID) -> ViewState {
        if let state = views[viewID] { return state }
        let prefersBorder = store?.resolvedResource(forView: viewID)?.meta?.prefersBorder
        let pane = MCPAppViewPane(viewID: viewID, prefersBorder: prefersBorder)
        pane.onClose = { [weak self] in self?.userClosed(viewID: viewID) }
        pane.onEnvironmentChange = { [weak self] in self?.hostEnvironmentDidChange() }
        pane.onReload = { [weak self] in
            guard let store = self?.store else { return }
            Task { @MainActor in await store.reload(viewID: viewID) }
        }
        let state = ViewState(pane: pane)
        views[viewID] = state
        return state
    }

    private func userClosed(viewID: UUID) {
        guard let store else { return }
        Task { @MainActor in await store.close(viewID: viewID) }
    }

    /// Drops the card of a view the store no longer has. A web view still
    /// mounted is kept for `requestTeardown` and `unmount`. The only place
    /// that forgets the view's "Always" grants for `ui/open-link` and
    /// `ui/message`: every removal from the store reaches it through
    /// `syncWithStore`, and a Reload does not.
    private func discard(viewID: UUID) {
        guard let state = views.removeValue(forKey: viewID) else { return }
        if let mounted = state.mounted {
            retiringMounts[viewID] = mounted
        }
        expirePendingConsent(state)
        openLinkPolicy.viewWasRemoved(viewID: viewID)
        consentGate.viewWasRemoved(viewID: viewID)
        if let surfaceID = state.surfaceID {
            if state.displayMode == "fullscreen" {
                docks[surfaceID]?.container?.setFullscreen(false, forLeaf: surfaceID)
            }
            removeFromDock(viewID: viewID, surfaceID: surfaceID)
        }
        state.pipWindow?.dismiss()
        state.panel?.dismiss()
        state.pane.removeFromSuperview()
    }

    private func removeFromDock(viewID: UUID, surfaceID: UUID) {
        guard let attachment = docks[surfaceID] else { return }
        attachment.dock.remove(viewID: viewID)
        if attachment.dock.panes.isEmpty {
            docks.removeValue(forKey: surfaceID)
            attachment.container?.detachDock(fromLeaf: surfaceID)
        }
    }

    /// Denies the prompts of a document that is unloading: a pending
    /// `ui/message` fails with "Message sending denied" and a pending
    /// `ui/open-link` opens nothing. The view's "Always" grants stay;
    /// `discard` forgets them. `documentGeneration` grows before the
    /// request expires, so the handler, whenever it resumes, already sees
    /// its document as gone.
    private func denyPendingPrompts(viewID: UUID) {
        guard let state = views[viewID] else { return }
        state.documentGeneration += 1
        consentGate.cancelPendingPrompt(viewID: viewID)
        expirePendingConsent(state)
    }

    /// Withdraws the view's consent request from the approval panel; its
    /// handler resolves as Cancel / Don't Send.
    private func expirePendingConsent(_ state: ViewState) {
        guard let requestID = state.pendingConsentRequestID else { return }
        state.pendingConsentRequestID = nil
        environment.consentPresenter.expire(requestID: requestID)
    }

    /// Shows a consent prompt for the view in the approval panel and
    /// waits for the user. A prompt the view already has pending is
    /// expired first: a new prompt replaces it. The request targets the
    /// view's pane (nil for a pane-less view) and is titled with the
    /// server's display name. A view the store no longer has is closing:
    /// nothing is asked and the prompt resolves `.expired` (Cancel /
    /// Don't Send), the same answer its removal would give a pending one.
    func requestConsent(viewID: UUID, state: ViewState, kind: MCPAppConsentKind) async -> ApprovalDecision {
        expirePendingConsent(state)
        guard let invocation = store?.invocation(forView: viewID) else { return .expired }
        let request = ApprovalRequest(
            id: UUID(),
            source: .mcpApp(viewID: viewID, title: invocation.serverDisplayName, kind: kind),
            targetSurfaceID: state.surfaceID,
            payload: kind.displayText,
            createdAt: Date()
        )
        state.pendingConsentRequestID = request.id
        let decision = await environment.consentPresenter.requestConsent(request, timeoutMs: consentTimeoutMs)
        // A later prompt of the view may have replaced this one meanwhile.
        if state.pendingConsentRequestID == request.id {
            state.pendingConsentRequestID = nil
        }
        return decision
    }

    /// True when `state` is still the view's card and no document of the
    /// view started unloading since `generation` was read: a prompt's
    /// answer still belongs to the document that asked.
    func isCurrentDocument(viewID: UUID, state: ViewState, generation: Int) -> Bool {
        views[viewID] === state && state.documentGeneration == generation
    }

    // MARK: - Display modes and host context

    /// pip only for a view with a pane; narrowed to what the app declared.
    func availableDisplayModes(for viewID: UUID) -> [String] {
        guard let state = views[viewID] else { return ["inline"] }
        let hostModes = state.surfaceID == nil ? ["inline", "fullscreen"] : ["inline", "fullscreen", "pip"]
        guard let appModes = state.appDisplayModes else { return hostModes }
        return hostModes.filter { appModes.contains($0) }
    }

    func applyDisplayMode(_ mode: String, viewID: UUID) {
        guard let state = views[viewID], state.displayMode != mode else { return }
        let previous = state.displayMode
        state.displayMode = mode

        if let surfaceID = state.surfaceID {
            let container = environment.splitContainer(owningSurface: surfaceID)
            if previous == "fullscreen" { container?.setFullscreen(false, forLeaf: surfaceID) }
            if previous == "pip" {
                state.pipWindow?.dismiss()
                state.pipWindow = nil
                if let snapshot = store?.snapshot(viewID: viewID) { place(state, snapshot: snapshot) }
            }
            switch mode {
            case "fullscreen":
                container?.setFullscreen(true, forLeaf: surfaceID)
            case "pip":
                if let window = container?.window {
                    removeFromDock(viewID: viewID, surfaceID: surfaceID)
                    let dimensions = MCPAppDockLayout.containerDimensions(
                        mode: "pip", dockSize: .zero, windowSize: window.frame.size, tabTerminalRect: .zero, contentTopInset: 0
                    )
                    // "pip" always reports a width and a height.
                    let pip = MCPAppPiPWindow(size: NSSize(width: dimensions.width!, height: dimensions.height!))
                    // Closing the window is `ui/request-display-mode` inline.
                    pip.onUserClose = { [weak self] in self?.applyDisplayMode("inline", viewID: viewID) }
                    state.pipWindow = pip
                    pip.present(state.pane, over: window)
                }
            default:
                break
            }
        } else {
            state.panel?.setFillsScreen(mode == "fullscreen")
        }
        hostEnvironmentDidChange()
    }

    /// The host context inputs for one view, from where its card is shown.
    func hostEnvironment(for viewID: UUID) -> MCPAppHostContextBuilder.Environment? {
        guard let state = views[viewID], let invocation = store?.invocation(forView: viewID) else { return nil }
        let pane = state.pane
        let window = pane.window
        let container = state.surfaceID.flatMap { environment.splitContainer(owningSurface: $0) }
        // A docked card's size is the dock's card area. A card in a panel, or
        // in a dock not laid out yet (zero or negative card area), reports
        // the pane's own size. The reported height is the card's content
        // area: the card below the header.
        let cardSize = state.surfaceID.flatMap { docks[$0]?.dock.cardSize }
            .flatMap { $0.width > 0 && $0.height > 0 ? $0 : nil }
        let dimensions = MCPAppDockLayout.containerDimensions(
            mode: state.displayMode,
            dockSize: cardSize ?? pane.bounds.size,
            windowSize: window?.frame.size ?? pane.bounds.size,
            tabTerminalRect: container?.bounds ?? pane.bounds,
            contentTopInset: pane.contentTopInset
        )
        let appearance = pane.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
        return MCPAppHostContextBuilder.Environment(
            toolRequestID: invocation.upstreamRequestID,
            tool: invocation.tool,
            isDarkTheme: appearance == .darkAqua,
            displayMode: state.displayMode,
            availableDisplayModes: availableDisplayModes(for: viewID),
            containerDimensions: dimensions,
            locale: Locale.current.identifier(.bcp47),
            timeZone: TimeZone.current.identifier,
            appVersion: MCPAppHostCapabilities.hostInfo.version,
            theme: environment.themeInputs()
        )
    }

    /// Recomputes the host context of every view that has answered
    /// `ui/initialize` and hands the changed keys to the store.
    func hostEnvironmentDidChange() {
        guard let store else { return }
        for (viewID, state) in views where state.mounted != nil && !state.lastHostContext.isEmpty {
            guard let environment = hostEnvironment(for: viewID) else { continue }
            let next = MCPAppHostContextBuilder.buildHostContext(environment)
            let changes = MCPAppHostContextBuilder.diff(previous: state.lastHostContext, next: next)
            state.lastHostContext = next
            store.hostContextDidChange(viewID: viewID, changes: changes)
        }
    }
}

/// Resumes a continuation the first time only: the teardown reply and the
/// 2-second wait race to finish `requestTeardown`.
@MainActor
private final class MCPAppResumeOnce {
    private var continuation: CheckedContinuation<Void, Never>?

    init(_ continuation: CheckedContinuation<Void, Never>) {
        self.continuation = continuation
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}
