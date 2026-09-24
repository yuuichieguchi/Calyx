//
//  MCPHostComposition.swift
//  Calyx
//
//  The composition root of the MCP Apps host. `AppDelegate` builds one at
//  launch. Construction wires every piece once: the registry and secret
//  store, OAuth, the upstream supervisor (with its elicitation presenter
//  and view host set before any connection exists), the live catalog and
//  app tool registry, the WebKit runtime and view store, the coordinator,
//  and the `/calyx-mcp` router.
//
//  Settings > MCP Servers is configured at launch whatever the AI Agent
//  IPC state, so a config error is visible with IPC off. Only its model
//  is configured; the Settings window is created when first opened.
//  `/calyx-mcp` gets the router as soon as an enable is running, before
//  that enable starts the listener, so no request the listener accepts is
//  answered 503; the router's session key is the server's own token
//  (`CalyxMCPServer.sessionBearerToken`), set before the listener binds.
//  Connections follow the IPC server: when it starts, every enabled
//  server connects; when it stops, `/calyx-mcp` answers 503 again and
//  every connection is closed. These transitions, and the launch-time
//  sweep of stale content rule lists, run one after another in the order
//  they were requested.
//

import AppKit
import GhosttyKit
import os

private let logger = Logger(subsystem: "com.calyx.terminal", category: "MCPApp")

@MainActor
final class MCPHostComposition {

    /// `<Application Support>/Calyx/mcp-secrets`, used by the file secret
    /// store of a scoped test launch.
    static let secretDirectoryName = "mcp-secrets"

    let registry: MCPServerRegistry
    let supervisor: MCPUpstreamSupervisor
    let store: MCPAppHostStore
    let runtime: MCPAppWebViewRuntime
    let router: MCPCalyxMCPRouter

    private let appDelegate: AppDelegate
    private let secretStore: any MCPSecretStore
    private let catalog: MCPLiveCatalogProvider
    private let settingsActions: MCPSupervisorSettingsActions
    private var isIPCRunning = false
    /// The last requested lifecycle step; each step waits for the one
    /// before it.
    private var lifecycleTail: Task<Void, Never>?

    init(appDelegate: AppDelegate) {
        self.appDelegate = appDelegate
        let directory = AppSupportDirectory.path
        let secretStore = MCPSecretStoreFactory.make(
            directory: (directory as NSString).appendingPathComponent(Self.secretDirectoryName)
        )
        let registry = MCPServerRegistry(directory: directory, secretStore: secretStore)
        let httpSession = MCPHTTPSession()
        let authFlow = MCPOAuthFlow(
            session: httpSession,
            discovery: MCPOAuthMetadataDiscovery(session: httpSession),
            registration: MCPOAuthClientRegistration(
                session: httpSession,
                store: MCPSecretStoreOAuthClientRegistrationStore(secretStore: secretStore)
            ),
            browser: SystemMCPOAuthBrowserOpening(),
            redirectConfig: MCPOAuthRedirectConfig(host: .loopback, port: .random),
            credentials: MCPSecretStoreOAuthCredentials(secretStore: secretStore)
        )
        let supervisor = MCPUpstreamSupervisor(
            registry: registry,
            secretStore: secretStore,
            authFlow: authFlow,
            clientInfo: MCPImplementation(
                name: MCPCalyxMCPWire.serverName,
                version: MCPAppHostCapabilities.hostInfo.version,
                title: nil,
                description: nil,
                websiteUrl: nil
            ),
            httpSession: httpSession
        )
        let windowForSurface: @MainActor (UUID) -> NSWindow? = { appDelegate.window(showingSurface: $0) }
        let elicitationPanel = MCPElicitationPanel(windowForSurface: windowForSurface)
        supervisor.setElicitationPresenting(elicitationPanel)

        let appToolRegistry = MCPLiveAppToolRegistry()
        let catalog = MCPLiveCatalogProvider(registry: registry, connections: supervisor, appToolRegistry: appToolRegistry)
        let runtime = MCPAppWebViewRuntime(environment: AppMCPAppRuntimeEnvironment(appDelegate: appDelegate))
        let store = MCPAppHostStore(paneResolver: appDelegate, runtime: runtime, appToolRegistry: appToolRegistry)
        runtime.store = store
        supervisor.setViewHosting(store)

        let signInPrompt = MCPSignInPrompt(
            signIn: { try await supervisor.signIn(serverID: $0) },
            windowForSurface: windowForSurface
        )
        let coordinator = MCPHostCoordinator(
            connections: supervisor,
            catalog: catalog,
            viewHosting: store,
            elicitationPresenting: elicitationPanel,
            authorizationPrompting: signInPrompt,
            cwdResolver: { surfaceID in
                SurfacePropertyStore.shared.cwd(for: surfaceID).map { URL(fileURLWithPath: $0) }
            }
        )
        let bearerToken = CalyxMCPServer.shared.sessionBearerToken
        self.router = MCPCalyxMCPRouter(
            coordinator: coordinator,
            registry: registry,
            catalog: catalog,
            connections: supervisor,
            appToolRegistry: appToolRegistry,
            sessionBearerToken: { bearerToken.value }
        )
        self.registry = registry
        self.secretStore = secretStore
        self.supervisor = supervisor
        self.catalog = catalog
        self.runtime = runtime
        self.store = store
        self.settingsActions = MCPSupervisorSettingsActions(supervisor: supervisor)
    }

    /// Configures Settings, gives `app_context` its provider, and sweeps
    /// the content rule lists a previous run left behind before any view
    /// can mount.
    func start() {
        SettingsWindowController.configureMCPServers(MCPServerSettingsModel.Dependencies(
            registry: registry,
            connections: supervisor,
            catalog: catalog,
            secretStore: secretStore,
            actions: settingsActions
        ))
        CalyxMCPServer.shared.calyxMCPModelContextProvider = store
        enqueue {
            do {
                try await MCPAppWebViewFactory.sweepStaleContentRuleLists()
            } catch {
                logger.error("Removing stale MCP App content rule lists failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    // MARK: - Notifications (forwarded by AppDelegate)

    /// `.calyxIPCStateDidChange`: `/calyx-mcp` has the router while the
    /// IPC server runs or an enable is running, so it is in place before
    /// the enable's work starts the listener (the chain announces a
    /// running enable before that work runs). Connections follow the
    /// server itself: every enabled server connects once it has started
    /// and is disconnected once it has stopped.
    func ipcStateDidChange() {
        SettingsWindowController.mcpServerSettingsModel.refreshIPCEnabled()
        let server = CalyxMCPServer.shared
        let installsRouter = Self.installsCalyxMCPRouter(
            isServerRunning: server.isRunning,
            runningOperation: IPCActivationChain.shared.runningOperation
        )
        server.setCalyxMCPRouter(installsRouter ? router : nil)
        guard server.isRunning != isIPCRunning else { return }
        isIPCRunning = server.isRunning
        let supervisor = self.supervisor
        if isIPCRunning {
            enqueue {
                await supervisor.connectAll()
                supervisor.startObservingRegistry()
            }
        } else {
            enqueue { await supervisor.disconnectAll() }
        }
    }

    /// Whether `/calyx-mcp` has the router: while the server runs, and
    /// while an enable is running, since that enable's work starts the
    /// listener. Otherwise `/calyx-mcp` answers 503.
    static func installsCalyxMCPRouter(
        isServerRunning: Bool,
        runningOperation: IPCActivationChain.Operation?
    ) -> Bool {
        isServerRunning || runningOperation == .enabling
    }

    /// `.calyxMCPConnectionsDidChange`: Settings looks the connections up
    /// again.
    func connectionsDidChange() {
        SettingsWindowController.mcpServerSettingsModel.refreshConnections()
    }

    /// `.calyxMCPAppViewsChanged`: recomputes which tabs show the activity
    /// dot.
    func appViewsDidChange() {
        var activeTabIDs: Set<UUID> = []
        for controller in appDelegate.allWindowControllers {
            let windowID = controller.windowSession.id
            for group in controller.windowSession.groups {
                for tab in group.tabs where store.hasBackgroundActivity(in: .window(windowID: windowID, tabID: tab.id)) {
                    activeTabIDs.insert(tab.id)
                }
            }
        }
        MCPAppActivityIndicatorModel.shared.update(activeTabIDs: activeTabIDs)
    }

    /// The ghostty config or Calyx's theme changed.
    func hostEnvironmentDidChange() {
        runtime.hostEnvironmentDidChange()
    }

    private func enqueue(_ step: @escaping @MainActor () async -> Void) {
        let previous = lifecycleTail
        lifecycleTail = Task {
            await previous?.value
            await step()
        }
    }
}

// MARK: - Settings actions

/// Settings > MCP Servers actions, forwarded to the supervisor.
@MainActor
final class MCPSupervisorSettingsActions: MCPServerSettingsActions {
    private let supervisor: MCPUpstreamSupervisor

    init(supervisor: MCPUpstreamSupervisor) {
        self.supervisor = supervisor
    }

    func retry(serverID: MCPServerID) async throws {
        try await supervisor.retry(serverID: serverID)
    }

    func signIn(serverID: MCPServerID) async throws {
        try await supervisor.signIn(serverID: serverID)
    }

    func signOut(serverID: MCPServerID) async throws {
        try await supervisor.signOut(serverID: serverID)
    }

    func authState(for serverID: MCPServerID) async throws -> MCPServerAuthState {
        try await supervisor.authState(for: serverID)
    }
}

// MARK: - Runtime environment

/// What the WebKit runtime needs from the app: pane lookups through
/// `AppDelegate`, herdr and agent state, Cockpit input delivery, and the
/// theme inputs.
@MainActor
final class AppMCPAppRuntimeEnvironment: MCPAppRuntimeEnvironment {
    private let appDelegate: AppDelegate
    let cockpitInputDelivery: any MCPAppInputDelivering

    init(appDelegate: AppDelegate) {
        self.appDelegate = appDelegate
        self.cockpitInputDelivery = MCPAppCockpitInputDelivery(
            access: LiveCockpitAppAccess(),
            isAgentPane: { AgentRegistry.shared.entries[$0] != nil }
        )
    }

    func splitContainer(owningSurface surfaceID: UUID) -> SplitContainerView? {
        appDelegate.splitContainer(owningSurface: surfaceID)
    }

    func herdrPaneRef(forSurface surfaceID: UUID) -> HerdrPaneRef? {
        HerdrPaneRegistry.shared.paneRef(forSurfaceID: surfaceID)
    }

    func isAgentPane(_ surfaceID: UUID) -> Bool {
        AgentRegistry.shared.entries[surfaceID] != nil
    }

    func themeInputs() -> MCPAppThemeInputs {
        MCPAppThemeInputsReader.read(config: GhosttyAppController.shared.configManager, defaults: .standard)
    }
}

// MARK: - Theme inputs

/// Builds `MCPAppThemeInputs` from the ghostty config and Calyx's theme.
///
/// ghostty has one background and foreground pair. It fills the dark
/// side when its background is dark and the light side otherwise; the
/// other side is the system text background and text color of that
/// appearance. The accent is Calyx's glass chrome tint. The font is
/// ghostty's `font-family` and `font-size`. A value that is missing or
/// cannot be read falls back to `defaultInputs`.
@MainActor
enum MCPAppThemeInputsReader {

    /// The system text background and text colors of the light (aqua) and
    /// dark (darkAqua) appearances, the system blue accent, the system
    /// monospaced font (`ui-monospace`) and the system font size.
    static let defaultInputs = MCPAppThemeInputs(
        lightBackground: MCPAppHexColor(rgb: 0xFFFFFF),
        lightForeground: MCPAppHexColor(rgb: 0x000000),
        darkBackground: MCPAppHexColor(rgb: 0x1E1E1E),
        darkForeground: MCPAppHexColor(rgb: 0xFFFFFF),
        accent: MCPAppHexColor(rgb: 0x007AFF),
        fontFamily: "ui-monospace",
        fontSize: NSFont.systemFontSize
    )

    static func read(config: GhosttyConfigManager, defaults: UserDefaults) -> MCPAppThemeInputs {
        var lightPair = (
            background: systemColor(.textBackgroundColor, appearance: .aqua) ?? defaultInputs.lightBackground,
            foreground: systemColor(.textColor, appearance: .aqua) ?? defaultInputs.lightForeground
        )
        var darkPair = (
            background: systemColor(.textBackgroundColor, appearance: .darkAqua) ?? defaultInputs.darkBackground,
            foreground: systemColor(.textColor, appearance: .darkAqua) ?? defaultInputs.darkForeground
        )
        if let background = config.getColor("background"), let foreground = config.getColor("foreground") {
            let pair = (background: hexColor(background), foreground: hexColor(foreground))
            if ColorLuminance.prefersDarkText(for: nsColor(background)) {
                lightPair = pair
            } else {
                darkPair = pair
            }
        }
        return MCPAppThemeInputs(
            lightBackground: lightPair.background,
            lightForeground: lightPair.foreground,
            darkBackground: darkPair.background,
            darkForeground: darkPair.foreground,
            accent: accent(config: config, defaults: defaults) ?? defaultInputs.accent,
            fontFamily: fontFamily(config: config) ?? defaultInputs.fontFamily,
            fontSize: fontSize(config: config) ?? defaultInputs.fontSize
        )
    }

    /// Calyx's glass chrome tint, as the tab bar and sidebar derive it.
    private static func accent(config: GhosttyConfigManager, defaults: UserDefaults) -> MCPAppHexColor? {
        let themeColor = ThemeColorPreset.resolve(
            preset: defaults.string(forKey: "themeColorPreset") ?? ThemeColorPreset.original.rawValue,
            customHex: defaults.string(forKey: "themeColorCustomHex") ?? ThemeColorPreset.defaultCustomHex,
            ghosttyBackground: config.getColor("background").map(nsColor)
        )
        let glassOpacity = defaults.object(forKey: "terminalGlassOpacity") as? Double ?? 0.7
        return MCPAppHexColor(HexColor.toHex(GlassTheme.chromeTint(for: themeColor, glassOpacity: glassOpacity)))
    }

    /// ghostty's C API has no getter for `font-family` (a repeatable
    /// string), so this reads nil.
    private static func fontFamily(config: GhosttyConfigManager) -> String? {
        guard let family = config.getString("font-family"), !family.isEmpty else { return nil }
        return family
    }

    /// `font-size` is an f32 in ghostty's config.
    private static func fontSize(config: GhosttyConfigManager) -> Double? {
        var size: Float = 0
        guard config.get("font-size", value: &size), size > 0 else { return nil }
        return Double(size)
    }

    private static func hexColor(_ color: ghostty_config_color_s) -> MCPAppHexColor {
        MCPAppHexColor(rgb: UInt32(color.r) << 16 | UInt32(color.g) << 8 | UInt32(color.b))
    }

    private static func nsColor(_ color: ghostty_config_color_s) -> NSColor {
        NSColor(red: CGFloat(color.r) / 255, green: CGFloat(color.g) / 255, blue: CGFloat(color.b) / 255, alpha: 1)
    }

    /// `color` resolved in the named appearance; nil when AppKit has no
    /// such appearance.
    private static func systemColor(_ color: NSColor, appearance name: NSAppearance.Name) -> MCPAppHexColor? {
        guard let appearance = NSAppearance(named: name) else { return nil }
        var hex = ""
        appearance.performAsCurrentDrawingAppearance {
            hex = HexColor.toHex(color)
        }
        return MCPAppHexColor(hex)
    }
}
