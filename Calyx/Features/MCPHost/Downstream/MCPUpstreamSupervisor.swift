//
//  MCPUpstreamSupervisor.swift
//  Calyx
//
//  Owns every upstream MCP server connection: builds one per configured
//  server from its registry entry, starts the enabled ones, follows the
//  registry (add, remove, enable, disable, transport or auth change),
//  runs OAuth sign-in and sign-out, and tells the view host to tear down a
//  removed or disabled server's views.
//
//  `MCPUpstreamConnection.events` has a single consumer, this supervisor.
//  It records the negotiated era of each transport configuration (in
//  memory only, keyed by `MCPServerTransportConfig.fingerprint`), forwards
//  every state change to the view host, and republishes every event
//  through `MCPSupervisedConnection`, whose `events` hands each reader its
//  own stream.
//
//  `.calyxMCPConnectionsDidChange` is posted after every reconciliation
//  and after `disconnectAll()`, the points where connections are built,
//  replaced or retired.
//

import Foundation
import Observation

extension Notification.Name {
    /// Posted on the main actor by `MCPUpstreamSupervisor` after it built,
    /// replaced or retired connections.
    static let calyxMCPConnectionsDidChange = Notification.Name("com.calyx.mcpHost.connectionsDidChange")
}

enum MCPUpstreamSupervisorError: Error, Equatable {
    case unknownServer(MCPServerID)
    case notHTTPServer(MCPServerID)
    case invalidURL(String)
    /// A configured env var or header has no value in the secret store.
    case missingSecret(name: String)
}

@MainActor
final class MCPUpstreamSupervisor: MCPConnectionLookup {

    /// Per request of the upstream client, the handshake included;
    /// `tools/call` has none.
    static let requestTimeout: TimeInterval = 60
    static let maxMRTRRounds = 8
    static let maxCrashesBeforeFailed = 5
    static let backoffCapSeconds: TimeInterval = 60

    private struct Entry {
        var config: MCPServerConfig
        let connection: MCPUpstreamConnection
        let supervised: MCPSupervisedConnection
        let pump: Task<Void, Never>
    }

    private let registry: MCPServerRegistry
    private let secretStore: any MCPSecretStore
    private let authFlow: MCPOAuthFlow
    private let clientInfo: MCPImplementation
    private let credentials: MCPSecretStoreOAuthCredentials
    private let httpSession: MCPHTTPSession

    private var entries: [MCPServerID: Entry] = [:]
    private var viewHosting: (any MCPAppViewHosting)?
    private var elicitationPresenting: (any MCPElicitationPresenting)?
    private var isObservingRegistry = false
    /// The last queued change of `entries`. `connectAll()`,
    /// `disconnectAll()` and each registry change run after it, one at a
    /// time, so no two of them interleave at an `await`.
    private var entriesTail: Task<Void, Never>?
    /// Whether `connectAll()` has run: until then, registry changes build
    /// connections but start none.
    private var mayConnect = false

    /// The negotiated era per transport fingerprint. Updated when a
    /// connection enters `.ready`; never persisted.
    private var eraCache: [String: MCPProtocolEra] = [:]

    /// `httpSession` carries every request of the HTTP transports.
    init(
        registry: MCPServerRegistry,
        secretStore: any MCPSecretStore,
        authFlow: MCPOAuthFlow,
        clientInfo: MCPImplementation,
        httpSession: MCPHTTPSession = MCPHTTPSession()
    ) {
        self.registry = registry
        self.httpSession = httpSession
        self.secretStore = secretStore
        self.authFlow = authFlow
        self.clientInfo = clientInfo
        self.credentials = MCPSecretStoreOAuthCredentials(secretStore: secretStore)
    }

    /// Receives every connection state change, and
    /// `teardownViews(forServer:reason:)` when a server is removed or
    /// disabled or its connection is retired.
    func setViewHosting(_ viewHosting: any MCPAppViewHosting) {
        self.viewHosting = viewHosting
    }

    /// Where the connections present elicitation requests. Must be set
    /// before the first connection is built.
    func setElicitationPresenting(_ presenting: any MCPElicitationPresenting) {
        self.elicitationPresenting = presenting
    }

    // MARK: - Lifecycle

    /// Connects to every enabled server, including one whose connection
    /// was built while connecting was not allowed. Does nothing when
    /// `LaunchEnvironmentPolicy.mayPerformAgentIPCActivation()` is false.
    func connectAll() async {
        guard LaunchEnvironmentPolicy.mayPerformAgentIPCActivation() else { return }
        await enqueue { supervisor in
            supervisor.mayConnect = true
            await supervisor.reconcile()
            for entry in supervisor.entries.values where entry.config.isEnabled {
                // `start()` acts only on a connection that is still `.disabled`.
                await entry.connection.start()
            }
        }
    }

    /// Closes and retires every connection, tearing down their views, and
    /// builds none until the next `connectAll()`. Used when AI Agent IPC
    /// is turned off.
    func disconnectAll() async {
        await enqueue { supervisor in
            supervisor.mayConnect = false
            let retiring = supervisor.entries
            supervisor.entries.removeAll()
            for entry in retiring.values {
                await supervisor.retire(entry, reason: "Calyx AI Agent IPC was turned off.")
            }
            NotificationCenter.default.post(name: .calyxMCPConnectionsDidChange, object: nil)
        }
    }

    /// Runs `step` after every step queued before it, and returns when it
    /// has finished.
    private func enqueue(_ step: @escaping @MainActor (MCPUpstreamSupervisor) async -> Void) async {
        let previous = entriesTail
        let task = Task { @MainActor [weak self] in
            await previous?.value
            guard let self else { return }
            await step(self)
        }
        entriesTail = task
        await task.value
    }

    /// Follows every later change of `registry.servers`. Idempotent.
    func startObservingRegistry() {
        guard !isObservingRegistry else { return }
        isObservingRegistry = true
        observeRegistry()
    }

    private func observeRegistry() {
        withObservationTracking {
            _ = registry.servers
        } onChange: {
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.observeRegistry()
                await self.enqueue { await $0.reconcile() }
            }
        }
    }

    func connection(forServerID serverID: MCPServerID) -> (any MCPUpstreamConnecting)? {
        entries[serverID]?.supervised
    }

    // MARK: - Sign-in

    /// Runs the OAuth flow for an HTTP server in `.needsAuthorization`,
    /// moving its connection through `.authorizing`.
    func signIn(serverID: MCPServerID) async throws {
        guard let entry = entries[serverID] else { throw MCPUpstreamSupervisorError.unknownServer(serverID) }
        guard case .http(let url, _, _) = entry.config.transport else { throw MCPUpstreamSupervisorError.notHTTPServer(serverID) }
        guard let mcpServerURL = URL(string: url) else { throw MCPUpstreamSupervisorError.invalidURL(url) }
        let auth = entry.config.auth
        await entry.connection.beginAuthorization()
        do {
            let clientAuthentication = try await clientAuthentication(for: serverID, method: auth?.clientAuthenticationMethod)
            _ = try await authFlow.authorize(
                serverID: serverID,
                mcpServerURL: mcpServerURL,
                resourceMetadataHintURL: nil,
                preRegisteredClientID: auth?.preRegisteredClientID,
                clientAuthentication: clientAuthentication,
                scopeOverride: auth?.scopeOverride,
                redirect: auth?.redirect
            )
        } catch {
            await entry.connection.endAuthorization(succeeded: false)
            throw error
        }
        await entry.connection.endAuthorization(succeeded: true)
    }

    /// Deletes the server's stored OAuth tokens and keeps its client
    /// registration, which the next sign-in reuses. A running connection
    /// reconnects without tokens, so the server's 401 moves it to
    /// `.needsAuthorization`.
    func signOut(serverID: MCPServerID) async throws {
        let config = try configuredServer(serverID)
        try await credentials.setTokens(nil, for: serverID)
        guard let entry = entries[serverID], config.isEnabled, mayConnect else { return }
        await entry.connection.disable()
        await entry.connection.enable()
    }

    /// From `.failed`, connects again.
    func retry(serverID: MCPServerID) async throws {
        guard let entry = entries[serverID] else { throw MCPUpstreamSupervisorError.unknownServer(serverID) }
        await entry.connection.retryFromFailed()
    }

    /// A stdio server needs no sign-in. An HTTP server is signed in while
    /// OAuth tokens are stored for it; no stored value names the account.
    func authState(for serverID: MCPServerID) async throws -> MCPServerAuthState {
        switch try configuredServer(serverID).transport {
        case .stdio:
            return .notRequired
        case .http:
            return try await credentials.tokens(for: serverID) == nil ? .signedOut : .signedIn(account: nil)
        }
    }

    private func configuredServer(_ serverID: MCPServerID) throws -> MCPServerConfig {
        guard let config = registry.servers.first(where: { $0.id == serverID }) else {
            throw MCPUpstreamSupervisorError.unknownServer(serverID)
        }
        return config
    }

    private func clientAuthentication(for serverID: MCPServerID, method: MCPOAuthClientAuthenticationMethod?) async throws -> MCPOAuthClientAuthentication {
        switch method {
        case nil, .none?:
            return .none
        case .clientSecretPost?:
            return .clientSecretPost(secret: try await requiredSecret(.clientSecret(serverID: serverID), name: "client secret"))
        case .clientSecretBasic?:
            return .clientSecretBasic(secret: try await requiredSecret(.clientSecret(serverID: serverID), name: "client secret"))
        }
    }

    private func requiredSecret(_ key: MCPSecretKey, name: String) async throws -> String {
        guard let value = try await secretStore.get(key) else {
            throw MCPUpstreamSupervisorError.missingSecret(name: name)
        }
        return value
    }

    // MARK: - Registry reconciliation

    /// Brings `entries` in line with `registry.servers`. Runs only through
    /// `enqueue`. An entry leaves `entries` (removed or replaced) before it
    /// is retired, and the config of a kept entry is written in place, so no
    /// copy of an entry is written back after an `await`.
    private func reconcile() async {
        let configs = registry.servers
        let configuredIDs = Set(configs.map(\.id))

        for serverID in Array(entries.keys) where !configuredIDs.contains(serverID) {
            guard let entry = entries.removeValue(forKey: serverID) else { continue }
            await retire(entry, reason: "The MCP server was removed.")
        }

        for config in configs {
            guard let entry = entries[config.id] else {
                await add(config)
                continue
            }
            if entry.config.transport != config.transport || entry.config.auth != config.auth {
                // The replacement is listed before the old connection stops,
                // so a reader whose events end finds the new connection.
                let replacement = makeEntry(for: config)
                entries[config.id] = replacement
                await retire(entry, reason: "The MCP server's configuration changed.")
                if config.isEnabled, mayConnect {
                    await replacement.connection.start()
                }
                continue
            }
            let wasEnabled = entry.config.isEnabled
            entries[config.id]?.config = config
            if wasEnabled != config.isEnabled {
                if config.isEnabled {
                    if mayConnect {
                        await entry.connection.enable()
                    }
                } else {
                    await entry.connection.disable()
                    await viewHosting?.teardownViews(forServer: config.id, reason: "The MCP server was disabled.")
                }
            }
        }
        NotificationCenter.default.post(name: .calyxMCPConnectionsDidChange, object: nil)
    }

    private func add(_ config: MCPServerConfig) async {
        let entry = makeEntry(for: config)
        entries[config.id] = entry
        if config.isEnabled, mayConnect {
            await entry.connection.start()
        }
    }

    /// Builds the connection for `config` and the task that forwards its
    /// events. Starts nothing.
    private func makeEntry(for config: MCPServerConfig) -> Entry {
        let connection = makeConnection(for: config)
        let supervised = MCPSupervisedConnection(connection: connection)
        let fingerprint = config.transport.fingerprint
        let serverID = config.id
        let pump = Task { [weak self] in
            for await event in await connection.events {
                if case .stateChanged(let state) = event {
                    if case .ready(let info, _) = state {
                        self?.recordEra(info.negotiatedEra, fingerprint: fingerprint)
                    }
                    self?.viewHosting?.serverConnectionChanged(serverID: serverID, state: state)
                }
                await supervised.publish(event)
            }
            await supervised.finish()
        }
        return Entry(config: config, connection: connection, supervised: supervised, pump: pump)
    }

    private func retire(_ entry: Entry, reason: String) async {
        await entry.connection.stop()
        await viewHosting?.teardownViews(forServer: entry.config.id, reason: reason)
    }

    private func recordEra(_ version: MCPProtocolVersion, fingerprint: String) {
        eraCache[fingerprint] = version.isModern ? .modern : .legacy(version)
    }

    // MARK: - Connections

    /// Builds the connection for `config`. stdio runs the command through
    /// `StdioLSPTransport` framed by `StdioMCPTransport` and handshakes
    /// `initialize` first; HTTP uses `StreamableHTTPMCPTransport`
    /// (`server/discover` first) or, for `.legacySSE`, `LegacySSEMCPTransport`
    /// (`initialize` first). An HTTP transport sends the configured headers
    /// with their values from the secret store. `knownEra` is the cached era
    /// of the same transport configuration.
    func makeConnection(for config: MCPServerConfig) -> MCPUpstreamConnection {
        guard let elicitationPresenting else {
            preconditionFailure("setElicitationPresenting(_:) must be called before a connection is built")
        }
        let serverID = config.id
        let transport = config.transport
        let knownEra = eraCache[transport.fingerprint]
        let secretStore = self.secretStore
        let credentials = self.credentials
        let authFlow = self.authFlow
        let session = httpSession
        let redirect = config.auth?.redirect

        let handshakeOrder: MCPHandshakeOrder
        switch transport {
        case .stdio:
            handshakeOrder = .initializeFirst
        case .http(_, _, let hint):
            handshakeOrder = hint == .legacySSE ? .initializeFirst : .discoverFirst
        }

        let transportFactory: @Sendable (MCPTransportVariant) async throws -> any MCPMessageTransport = { variant in
            switch transport {
            case .stdio(let command, let args, let envNames, let cwd):
                var environment = ProcessInfo.processInfo.environment
                for name in envNames {
                    guard let value = try await secretStore.get(.env(serverID: serverID, name: name)) else {
                        throw MCPUpstreamSupervisorError.missingSecret(name: name)
                    }
                    environment[name] = value
                }
                let byteTransport = StdioLSPTransport(
                    executable: command,
                    arguments: args,
                    environment: environment,
                    workingDirectory: cwd.map { URL(fileURLWithPath: $0) }
                )
                try await byteTransport.spawn()
                return StdioMCPTransport(byteTransport: byteTransport)

            case .http(let url, let headerNames, let hint):
                guard let endpoint = URL(string: url) else {
                    throw MCPUpstreamSupervisorError.invalidURL(url)
                }
                var staticHeaders: [String: String] = [:]
                for name in headerNames {
                    guard let value = try await secretStore.get(.header(serverID: serverID, name: name)) else {
                        throw MCPUpstreamSupervisorError.missingSecret(name: name)
                    }
                    staticHeaders[name] = value
                }
                // Without stored tokens the transport sends no Authorization
                // header, and a 401 reaches the connection as
                // `.needsAuthorization`.
                let hooks: MCPOAuthTransportHooks? = try await credentials.tokens(for: serverID) == nil
                    ? nil
                    : await authFlow.makeTransportHooks(serverID: serverID, mcpServerURL: endpoint, redirect: redirect)
                if variant == .legacySSE || hint == .legacySSE {
                    let legacy = LegacySSEMCPTransport(
                        sseEndpoint: endpoint,
                        session: session,
                        staticHeaders: staticHeaders,
                        headerProvider: hooks?.headerProvider,
                        on401: hooks?.on401,
                        on403InsufficientScope: hooks?.on403InsufficientScope
                    )
                    try await legacy.openStream()
                    return legacy
                }
                let protocolVersion: MCPProtocolVersion
                if case .legacy(let version)? = knownEra {
                    protocolVersion = version
                } else {
                    protocolVersion = .v2026_07_28
                }
                return StreamableHTTPMCPTransport(
                    endpoint: endpoint,
                    session: session,
                    protocolVersion: protocolVersion,
                    staticHeaders: staticHeaders,
                    headerProvider: hooks?.headerProvider,
                    on401: hooks?.on401,
                    on403InsufficientScope: hooks?.on403InsufficientScope
                )
            }
        }

        return MCPUpstreamConnection(
            serverID: serverID,
            transportFactory: transportFactory,
            handshakeOrder: handshakeOrder,
            knownEra: knownEra,
            configuration: MCPUpstreamConnection.Configuration(
                client: MCPUpstreamClient.Configuration(
                    clientInfo: clientInfo,
                    requestTimeout: Self.requestTimeout,
                    serverDisplayName: config.displayName,
                    maxMRTRRounds: Self.maxMRTRRounds
                ),
                maxCrashesBeforeFailed: Self.maxCrashesBeforeFailed,
                backoffCapSeconds: Self.backoffCapSeconds
            ),
            elicitationPresenter: elicitationPresenting
        )
    }
}

/// `MCPUpstreamConnecting` over a supervised `MCPUpstreamConnection`.
/// Every read of `events` returns a new stream that receives the events
/// published after it was created.
actor MCPSupervisedConnection: MCPUpstreamConnecting {

    nonisolated let serverID: MCPServerID
    private let connection: MCPUpstreamConnection
    private var subscribers: [UUID: AsyncStream<MCPServerEvent>.Continuation] = [:]
    private var isFinished = false

    init(connection: MCPUpstreamConnection) {
        self.serverID = connection.serverID
        self.connection = connection
    }

    func publish(_ event: MCPServerEvent) {
        for subscriber in subscribers.values {
            subscriber.yield(event)
        }
    }

    func finish() {
        isFinished = true
        for subscriber in subscribers.values {
            subscriber.finish()
        }
        subscribers.removeAll()
    }

    private func unsubscribe(_ id: UUID) {
        subscribers[id] = nil
    }

    var events: AsyncStream<MCPServerEvent> {
        get async {
            let (stream, continuation) = AsyncStream<MCPServerEvent>.makeStream()
            guard !isFinished else {
                continuation.finish()
                return stream
            }
            let id = UUID()
            subscribers[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.unsubscribe(id) }
            }
            return stream
        }
    }

    func tools() async -> [MCPToolDefinition] {
        await connection.tools()
    }

    func state() async -> MCPConnectionState {
        await connection.state()
    }

    func callTool(name: String, arguments: [String: AnyCodable], context: MCPToolCallContext) async -> MCPUpstreamClient.ToolCallOutcome {
        await connection.callTool(name: name, arguments: arguments, context: context)
    }

    func readResource(uri: String) async throws -> [String: AnyCodable] {
        try await connection.readResource(uri: uri)
    }

    func listResources(cursor: String?) async throws -> (items: [[String: AnyCodable]], nextCursor: String?) {
        try await connection.listResources(cursor: cursor)
    }

    func listResourceTemplates(cursor: String?) async throws -> (items: [[String: AnyCodable]], nextCursor: String?) {
        try await connection.listResourceTemplates(cursor: cursor)
    }

    func listPrompts(cursor: String?) async throws -> (items: [[String: AnyCodable]], nextCursor: String?) {
        try await connection.listPrompts(cursor: cursor)
    }
}
