//
//  MCPServerSettingsModel.swift
//  Calyx
//
//  State behind Settings > MCP Servers. The server list and the config
//  error come from `MCPServerRegistry`; each row's connection state, tool
//  counts and server instructions from that server's
//  `MCPUpstreamConnecting`; its excluded tools from the catalog; its
//  sign-in state and its Retry, Sign In and Sign Out from
//  `MCPServerSettingsActions`. The composition root supplies all of them
//  through `configure(_:)`; until then the pane is empty.
//
//  A row is re-read on every event of its connection. Connections are
//  looked up again when the registry's server list changes and when
//  `refreshConnections()` is called.
//

import Foundation
import Observation

@MainActor @Observable
final class MCPServerSettingsModel {

    struct Dependencies {
        let registry: MCPServerRegistry
        let connections: any MCPConnectionLookup
        let catalog: any MCPCatalogProviding
        let secretStore: any MCPSecretStore
        let actions: any MCPServerSettingsActions
    }

    /// What one connection reported at its last event.
    struct LiveStatus: Equatable {
        let connectionState: MCPConnectionState
        let toolCount: Int
        let uiToolCount: Int
        let authState: MCPServerAuthState
        let exclusions: [MCPCatalogExclusion]
        /// The server's `instructions` once `ready`.
        let instructions: String?
    }

    private(set) var registry: MCPServerRegistry?
    private(set) var ipcEnabled: Bool
    private(set) var liveStatus: [MCPServerID: LiveStatus] = [:]
    /// The last failed action or status read of each row.
    private(set) var rowErrors: [MCPServerID: String] = [:]
    /// The sign-in this pane started for each server, until it ends.
    private(set) var signIns: [MCPServerID: SignIn] = [:]

    struct SignIn {
        let token: UUID
        let task: Task<Void, Never>
    }

    @ObservationIgnored private var dependencies: Dependencies?
    @ObservationIgnored private var trackers: [MCPServerID: Task<Void, Never>] = [:]

    init() {
        self.ipcEnabled = IPCSettings.enabled
    }

    func configure(_ dependencies: Dependencies) {
        self.dependencies = dependencies
        self.registry = dependencies.registry
        observeRegistry(dependencies.registry)
        refreshConnections()
    }

    /// Re-reads `IPCSettings.enabled`.
    func refreshIPCEnabled() {
        ipcEnabled = IPCSettings.enabled
    }

    // MARK: - Rows

    /// The resolver's input for `config`. A server whose connection has
    /// not reported yet is `connecting` when enabled and `disabled`
    /// otherwise, with no tools.
    func rowState(for config: MCPServerConfig) -> MCPServerRowStatusResolver.RowState {
        guard let live = liveStatus[config.id] else {
            return MCPServerRowStatusResolver.resolve(
                connectionState: config.isEnabled ? .connecting : .disabled,
                toolCount: 0, uiToolCount: 0, authState: .notRequired, ipcEnabled: ipcEnabled
            )
        }
        return MCPServerRowStatusResolver.resolve(
            connectionState: live.connectionState,
            toolCount: live.toolCount,
            uiToolCount: live.uiToolCount,
            authState: live.authState,
            ipcEnabled: ipcEnabled
        )
    }

    func isSigningIn(_ serverID: MCPServerID) -> Bool {
        signIns[serverID] != nil
    }

    // MARK: - Connections

    /// Looks up every configured server's connection again and follows
    /// its events. The composition root calls this after the supervisor
    /// has built or replaced connections. Does nothing before
    /// `configure(_:)`: there is nothing to look up yet.
    func refreshConnections() {
        guard let dependencies else { return }
        for task in trackers.values {
            task.cancel()
        }
        trackers.removeAll()
        let configuredIDs = Set(dependencies.registry.servers.map(\.id))
        liveStatus = liveStatus.filter { configuredIDs.contains($0.key) }
        rowErrors = rowErrors.filter { configuredIDs.contains($0.key) }
        for serverID in configuredIDs {
            trackers[serverID] = Task { [weak self] in
                await self?.follow(serverID, dependencies: dependencies)
            }
        }
    }

    private func observeRegistry(_ registry: MCPServerRegistry) {
        withObservationTracking {
            _ = registry.servers
        } onChange: {
            Task { @MainActor [weak self] in
                guard let self, self.registry === registry else { return }
                self.observeRegistry(registry)
                self.refreshConnections()
            }
        }
    }

    /// Reads the connection once, then again on each of its events, until
    /// the stream ends or the task is cancelled.
    private func follow(_ serverID: MCPServerID, dependencies: Dependencies) async {
        guard let connection = await dependencies.connections.connection(forServerID: serverID) else {
            liveStatus[serverID] = nil
            return
        }
        let events = await connection.events
        await read(serverID, connection: connection, dependencies: dependencies)
        for await _ in events {
            guard !Task.isCancelled else { return }
            await read(serverID, connection: connection, dependencies: dependencies)
        }
        guard !Task.isCancelled else { return }
        liveStatus[serverID] = nil
    }

    private func read(_ serverID: MCPServerID, connection: any MCPUpstreamConnecting, dependencies: Dependencies) async {
        let state = await connection.state()
        let tools = await connection.tools()
        let catalog = await dependencies.catalog.currentCatalog(clientDeclaredUI: true, surfaceID: nil)
        let authState: MCPServerAuthState
        do {
            authState = try await dependencies.actions.authState(for: serverID)
        } catch {
            guard !Task.isCancelled else { return }
            rowErrors[serverID] = "Could not read the sign-in state: \(Self.describe(error))"
            return
        }
        guard !Task.isCancelled else { return }
        let instructions: String?
        if case .ready(let info, _) = state {
            instructions = info.instructions
        } else {
            instructions = nil
        }
        liveStatus[serverID] = LiveStatus(
            connectionState: state,
            toolCount: tools.count,
            uiToolCount: tools.filter { $0.ui != nil }.count,
            authState: authState,
            exclusions: catalog.exclusions.filter { $0.serverID == serverID },
            instructions: instructions
        )
    }

    // MARK: - Row actions

    func setEnabled(_ isEnabled: Bool, for config: MCPServerConfig) {
        var updated = config
        updated.isEnabled = isEnabled
        runRowAction(config.id) { try await $0.registry.update(updated) }
    }

    func retry(_ serverID: MCPServerID) {
        runRowAction(serverID) { try await $0.actions.retry(serverID: serverID) }
    }

    func signOut(_ serverID: MCPServerID) {
        runRowAction(serverID) { try await $0.actions.signOut(serverID: serverID) }
    }

    func remove(_ serverID: MCPServerID) {
        signIns[serverID]?.task.cancel()
        runRowAction(serverID) { try await $0.registry.remove(id: serverID) }
    }

    func signIn(_ serverID: MCPServerID) {
        signIns[serverID]?.task.cancel()
        rowErrors[serverID] = nil
        let token = UUID()
        let task = Task { [weak self] in
            do {
                guard let self else { return }
                try await self.requireDependencies().actions.signIn(serverID: serverID)
            } catch {
                // A cancelled task was cancelled from this pane (Cancel
                // Sign-In, Remove, or a newer Sign In), so it is not shown.
                if !Task.isCancelled {
                    self?.rowErrors[serverID] = Self.describe(error)
                }
            }
            if self?.signIns[serverID]?.token == token {
                self?.signIns[serverID] = nil
            }
        }
        signIns[serverID] = SignIn(token: token, task: task)
    }

    /// Cancels the sign-in this pane started for `serverID`.
    func cancelSignIn(_ serverID: MCPServerID) {
        signIns[serverID]?.task.cancel()
    }

    private func runRowAction(_ serverID: MCPServerID, _ action: @escaping @MainActor (Dependencies) async throws -> Void) {
        rowErrors[serverID] = nil
        Task { [weak self] in
            do {
                guard let self else { return }
                try await action(self.requireDependencies())
            } catch {
                self?.rowErrors[serverID] = Self.describe(error)
            }
        }
    }

    // MARK: - Add, edit, import

    /// Writes the draft's secrets, then registers the server.
    func add(_ draft: MCPServerCreateDraft) async throws {
        let dependencies = try requireDependencies()
        guard let alias = MCPServerAlias(rawValue: draft.alias) else {
            throw MCPServerSettingsError.invalidAlias(draft.alias)
        }
        guard !dependencies.registry.servers.contains(where: { $0.alias == alias }) else {
            throw MCPServerRegistryError.duplicateAlias(alias.rawValue)
        }
        let config = MCPServerConfig(
            id: MCPServerID(),
            alias: alias,
            displayName: draft.displayName,
            isEnabled: true,
            transport: draft.transport.transportConfig,
            auth: MCPServerDraftConversion.authConfig(transport: draft.transport, authDraft: draft.authDraft, existing: nil)
        )
        // The supervisor reads the secrets as soon as the server is
        // registered, so they are written first.
        try await writeSecrets(of: draft.transport, authDraft: draft.authDraft, serverID: config.id, secretStore: dependencies.secretStore)
        do {
            try await dependencies.registry.add(config)
        } catch {
            try await dependencies.secretStore.deleteAll(forServer: config.id)
            throw error
        }
    }

    /// The edit sheet's starting draft, with the stored env, header and
    /// client secret values.
    func makeEditDraft(for config: MCPServerConfig) async throws -> MCPServerEditDraft {
        let secretStore = try requireDependencies().secretStore
        let transport: MCPServerTransportConfigDraft
        switch config.transport {
        case .stdio(let command, let args, let envNames, let cwd):
            transport = .stdio(
                command: command, args: args,
                env: try await storedValues(envNames, secretStore: secretStore) { .env(serverID: config.id, name: $0) },
                cwd: cwd
            )
        case .http(let url, let headerNames, let hint):
            transport = .http(
                url: url,
                headers: try await storedValues(headerNames, secretStore: secretStore) { .header(serverID: config.id, name: $0) },
                hint: hint,
                useFixedPort: config.auth?.redirect.port == .calyxFixed
            )
        }
        let authDraft: MCPServerAuthConfigDraftValue?
        if let auth = config.auth, auth.preRegisteredClientID != nil || auth.clientAuthenticationMethod != nil {
            authDraft = MCPServerAuthConfigDraftValue(
                preRegisteredClientID: auth.preRegisteredClientID,
                clientAuthentication: try await clientAuthentication(
                    method: auth.clientAuthenticationMethod, serverID: config.id, secretStore: secretStore
                )
            )
        } else {
            authDraft = nil
        }
        return MCPServerEditDraft(displayName: config.displayName, transport: transport, authDraft: authDraft)
    }

    /// Writes the draft's secrets, replaces the server's config, then
    /// deletes the secrets the new config no longer names.
    func update(_ config: MCPServerConfig, with draft: MCPServerEditDraft) async throws {
        let dependencies = try requireDependencies()
        let updated = MCPServerConfig(
            id: config.id,
            alias: config.alias,
            displayName: draft.displayName,
            isEnabled: config.isEnabled,
            transport: draft.transport.transportConfig,
            auth: MCPServerDraftConversion.authConfig(transport: draft.transport, authDraft: draft.authDraft, existing: config.auth)
        )
        try await writeSecrets(of: draft.transport, authDraft: draft.authDraft, serverID: config.id, secretStore: dependencies.secretStore)
        try await dependencies.registry.update(updated)
        let kept = Set(MCPServerDraftConversion.secretKeys(of: updated.transport, serverID: config.id))
        for key in MCPServerDraftConversion.secretKeys(of: config.transport, serverID: config.id) where !kept.contains(key) {
            try await dependencies.secretStore.delete(key)
        }
        if MCPServerDraftConversion.clientSecret(of: draft.authDraft) == nil {
            try await dependencies.secretStore.delete(.clientSecret(serverID: config.id))
        }
    }

    func importServers(_ imported: [MCPImportedServer], conflictPolicy: MCPImportConflictPolicy) async throws -> MCPImportOutcome {
        try await requireDependencies().registry.importServers(imported, conflictPolicy: conflictPolicy)
    }

    private func requireDependencies() throws -> Dependencies {
        guard let dependencies else { throw MCPServerSettingsError.notConfigured }
        return dependencies
    }

    private func writeSecrets(
        of transport: MCPServerTransportConfigDraft,
        authDraft: MCPServerAuthConfigDraftValue?,
        serverID: MCPServerID,
        secretStore: any MCPSecretStore
    ) async throws {
        for secret in transport.secretValues(serverID: serverID) {
            try await secretStore.set(secret.value, forKey: secret.key)
        }
        if let clientSecret = MCPServerDraftConversion.clientSecret(of: authDraft) {
            try await secretStore.set(clientSecret, forKey: .clientSecret(serverID: serverID))
        }
    }

    /// A configured name without a stored value is `MCPServerSettingsError.missingSecret`.
    private func storedValues(
        _ names: [String],
        secretStore: any MCPSecretStore,
        key: (String) -> MCPSecretKey
    ) async throws -> [String: String] {
        var values: [String: String] = [:]
        for name in names {
            guard let value = try await secretStore.get(key(name)) else {
                throw MCPServerSettingsError.missingSecret(name: name)
            }
            values[name] = value
        }
        return values
    }

    private func clientAuthentication(
        method: MCPOAuthClientAuthenticationMethod?,
        serverID: MCPServerID,
        secretStore: any MCPSecretStore
    ) async throws -> MCPOAuthClientAuthentication? {
        switch method {
        case nil, .none?:
            return nil
        case .clientSecretPost?, .clientSecretBasic?:
            guard let secret = try await secretStore.get(.clientSecret(serverID: serverID)) else {
                throw MCPServerSettingsError.missingSecret(name: "client secret")
            }
            return method == .clientSecretPost ? .clientSecretPost(secret: secret) : .clientSecretBasic(secret: secret)
        }
    }

    // MARK: - Text

    /// The config error banner's text.
    static func configErrorText(_ error: MCPServerRegistryLoadError) -> String {
        switch error {
        case .corrupt(let movedToPath):
            return "mcp-servers.json could not be read and was moved to \(movedToPath). Calyx started with no MCP servers."
        case .unavailable(let path, let reason):
            return "\(path) could not be read: \(reason). Changes to MCP servers cannot be saved until the file is readable."
        }
    }

    static func describe(_ error: any Error) -> String {
        switch error {
        case let error as MCPServerSettingsError:
            switch error {
            case .notConfigured:
                return "MCP servers are not available yet."
            case .invalidAlias(let alias):
                return "\"\(alias)\" is not a valid alias. Use a lowercase letter followed by up to 9 lowercase letters or digits."
            case .missingSecret(let name):
                return "No stored value for \(name)."
            }
        case let error as MCPServerRegistryError:
            switch error {
            case .duplicateAlias(let alias):
                return "Another server already uses the alias \"\(alias)\"."
            case .aliasChanged(let from, let to):
                return "The alias cannot change from \"\(from)\" to \"\(to)\"."
            case .unsupportedVersion(let version):
                return "mcp-servers.json has unsupported schema version \(version)."
            case .unknownServer:
                return "The server is no longer configured."
            case .fileUnavailable(let path):
                return "\(path) is unavailable, so changes cannot be saved."
            }
        case let error as MCPServersJSONImportError:
            switch error {
            case .parseError(let line, let column, let message):
                return "Line \(line), column \(column): \(message)"
            case .invalidServer(let name, let message):
                return name.map { "\($0): \(message)" } ?? message
            }
        default:
            return String(describing: error)
        }
    }
}

enum MCPServerSettingsError: Error, Sendable, Equatable {
    /// `configure(_:)` has not run.
    case notConfigured
    case invalidAlias(String)
    /// A configured env var, header or client secret has no stored value.
    case missingSecret(name: String)
}
