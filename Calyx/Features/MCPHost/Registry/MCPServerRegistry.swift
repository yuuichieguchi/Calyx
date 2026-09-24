//
//  MCPServerRegistry.swift
//  Calyx
//
//  The configured upstream MCP servers, persisted as
//  `<directory>/mcp-servers.json` (mode 0600, written through
//  `ConfigFileUtils.withExclusiveConfig` on `DispatchQueue.global()`,
//  one change at a time):
//
//      {"schemaVersion": 1, "servers": [<MCPServerConfig>, ...]}
//
//  A file that cannot be decoded, or carries a newer schema version, is
//  moved aside byte-for-byte to `<path>.corrupt-<suffix>` and reported
//  through `loadError`; the registry then starts empty.
//

import Foundation

enum MCPServerRegistryLoadError: Sendable, Equatable {
    case corrupt(movedToPath: String)
    /// The file exists but could not be read, or could not be moved aside.
    /// It is left in place and the registry refuses to write over it.
    case unavailable(path: String, reason: String)
}

enum MCPServerRegistryError: Error, Sendable, Equatable {
    case duplicateAlias(String)
    case aliasChanged(from: String, to: String)
    case unsupportedVersion(Int)
    case unknownServer(MCPServerID)
    /// Writing is refused because `loadError` is `.unavailable`.
    case fileUnavailable(path: String)
}

enum MCPImportConflictPolicy: Sendable, Equatable {
    case replace, rename, skip
}

struct MCPImportOutcome: Sendable, Equatable {
    let added: [MCPServerID]
    let replaced: [MCPServerID]
    let renamed: [MCPImportRename]
    /// Aliases that clashed and were skipped.
    let skipped: [String]
}

struct MCPImportRename: Sendable, Equatable {
    let from: String
    let to: String
}

@MainActor @Observable
final class MCPServerRegistry {

    static let fileName = "mcp-servers.json"
    nonisolated static let currentSchemaVersion = 1

    private(set) var servers: [MCPServerConfig]
    private(set) var loadError: MCPServerRegistryLoadError?

    private let directory: String
    private let filePath: String
    private let secretStore: any MCPSecretStore
    /// The last queued change; see `serialized(_:)`.
    @ObservationIgnored private var changeTail: Task<Void, Never>?

    /// Production callers pass `AppSupportDirectory.path`.
    init(directory: String, secretStore: any MCPSecretStore) {
        self.directory = directory
        self.filePath = (directory as NSString).appendingPathComponent(Self.fileName)
        self.secretStore = secretStore
        let loaded = Self.load(filePath: filePath)
        self.servers = loaded.servers
        self.loadError = loaded.error
    }

    /// Throws `.duplicateAlias` when another server already has the alias.
    func add(_ config: MCPServerConfig) async throws {
        try await serialized { registry in
            guard !registry.servers.contains(where: { $0.alias == config.alias }) else {
                throw MCPServerRegistryError.duplicateAlias(config.alias.rawValue)
            }
            try await registry.commit(registry.servers + [config])
        }
    }

    /// Replaces the server with the same id. Throws `.aliasChanged` when
    /// the alias differs from the stored one.
    func update(_ config: MCPServerConfig) async throws {
        try await serialized { registry in
            guard let index = registry.servers.firstIndex(where: { $0.id == config.id }) else {
                throw MCPServerRegistryError.unknownServer(config.id)
            }
            let stored = registry.servers[index]
            guard stored.alias == config.alias else {
                throw MCPServerRegistryError.aliasChanged(from: stored.alias.rawValue, to: config.alias.rawValue)
            }
            var updated = registry.servers
            updated[index] = config
            try await registry.commit(updated)
        }
    }

    /// Deletes every secret of the server, then the server itself. Other
    /// servers' secrets are untouched.
    func remove(id: MCPServerID) async throws {
        try await serialized { registry in
            guard registry.servers.contains(where: { $0.id == id }) else {
                throw MCPServerRegistryError.unknownServer(id)
            }
            try await registry.secretStore.deleteAll(forServer: id)
            try await registry.commit(registry.servers.filter { $0.id != id })
        }
    }

    /// Registers imported servers. An imported server's alias is derived
    /// from its name, or is the id fallback when it has none. An alias that
    /// clashes with a registered server (including one registered earlier
    /// in the same call) follows `conflictPolicy`: `.replace` swaps in the
    /// imported transport and keeps the existing id, alias, display name,
    /// enabled state, and auth; `.rename` adds it under a numeric suffix;
    /// `.skip` leaves it out. Every registered server's `envValues` and
    /// `headerValues` are written under its id first, as `add` callers do,
    /// because the supervisor starts a server as soon as its config is
    /// saved. All configs are then written in one file write. Last, for
    /// each replaced server, the env and header secrets named by its
    /// previous transport and not written again by this import are
    /// deleted.
    func importServers(_ imported: [MCPImportedServer], conflictPolicy: MCPImportConflictPolicy) async throws -> MCPImportOutcome {
        try await serialized { registry in
            try await registry.performImport(imported, conflictPolicy: conflictPolicy)
        }
    }

    private func performImport(_ imported: [MCPImportedServer], conflictPolicy: MCPImportConflictPolicy) async throws -> MCPImportOutcome {
        var updated = servers
        var staleSecrets: [MCPSecretKey] = []
        var secretWrites: [(key: MCPSecretKey, value: String)] = []
        var added: [MCPServerID] = []
        var replaced: [MCPServerID] = []
        var renamed: [MCPImportRename] = []
        var skipped: [String] = []

        for server in imported {
            let id = MCPServerID()
            let candidate = server.name.flatMap(MCPServerAliasDeriver.derive(fromDisplayName:))
                ?? MCPServerAliasDeriver.fallback(forServerID: id)
            let takenAliases = Set(updated.map(\.alias.rawValue))

            guard takenAliases.contains(candidate) else {
                updated.append(Self.newConfig(id: id, alias: candidate, from: server))
                added.append(id)
                secretWrites += Self.secretValues(of: server, serverID: id)
                continue
            }
            switch conflictPolicy {
            case .replace:
                guard let index = updated.firstIndex(where: { $0.alias.rawValue == candidate }) else {
                    preconditionFailure("an alias in takenAliases belongs to a server in updated")
                }
                let existing = updated[index]
                updated[index] = MCPServerConfig(
                    id: existing.id, alias: existing.alias, displayName: existing.displayName,
                    isEnabled: existing.isEnabled, transport: server.transport, auth: existing.auth
                )
                replaced.append(existing.id)
                staleSecrets += Self.envAndHeaderKeys(of: existing.transport, serverID: existing.id)
                secretWrites += Self.secretValues(of: server, serverID: existing.id)
            case .rename:
                // One result per candidate.
                let alias = MCPServersJSONImporter.resolveAliasClashes(candidates: [candidate], existingAliases: takenAliases)[0]
                updated.append(Self.newConfig(id: id, alias: alias, from: server))
                added.append(id)
                renamed.append(MCPImportRename(from: candidate, to: alias))
                secretWrites += Self.secretValues(of: server, serverID: id)
            case .skip:
                skipped.append(candidate)
            }
        }

        for write in secretWrites {
            try await secretStore.set(write.value, forKey: write.key)
        }
        try await commit(updated)
        let writtenKeys = Set(secretWrites.map(\.key))
        for key in staleSecrets where !writtenKeys.contains(key) {
            try await secretStore.delete(key)
        }
        return MCPImportOutcome(added: added, replaced: replaced, renamed: renamed, skipped: skipped)
    }

    /// Brings a decoded document to `currentSchemaVersion`. A missing
    /// `schemaVersion` is version 0 and gains `schemaVersion: 1`. A version
    /// other than 0 or 1 throws `.unsupportedVersion`; a non-integer
    /// version throws `DecodingError`.
    nonisolated static func migrate(_ document: [String: AnyCodable]) throws -> [String: AnyCodable] {
        let version: Int
        if let raw = document[DocumentKey.schemaVersion] {
            guard let value = raw.intValue else {
                throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "schemaVersion is not an integer"))
            }
            version = value
        } else {
            version = 0
        }
        switch version {
        case currentSchemaVersion:
            return document
        case 0:
            var migrated = document
            migrated[DocumentKey.schemaVersion] = AnyCodable(currentSchemaVersion)
            return migrated
        default:
            throw MCPServerRegistryError.unsupportedVersion(version)
        }
    }

    // MARK: - Persistence

    private nonisolated enum DocumentKey {
        static let schemaVersion = "schemaVersion"
    }

    private struct Document: Codable {
        let schemaVersion: Int
        let servers: [MCPServerConfig]
    }

    /// Why a readable file is treated as corrupt although it decodes.
    private enum DocumentInvariantError: Error {
        case duplicateID
        case duplicateAlias
    }

    /// Runs `body` after every change queued before it, so each change
    /// reads `servers` as the previous one left it.
    private func serialized<T: Sendable>(_ body: @escaping @MainActor (MCPServerRegistry) async throws -> T) async throws -> T {
        let previous = changeTail
        let change = Task { @MainActor in
            await previous?.value
            return try await body(self)
        }
        // The next change waits for this one whether it succeeds or throws;
        // its error reaches the caller through `change.value`.
        changeTail = Task { _ = await change.result }
        return try await change.value
    }

    /// Writes `newServers` off the main actor, then publishes them.
    /// `servers` is unchanged when the write throws.
    private func commit(_ newServers: [MCPServerConfig]) async throws {
        if case .unavailable = loadError {
            throw MCPServerRegistryError.fileUnavailable(path: filePath)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(Document(schemaVersion: Self.currentSchemaVersion, servers: newServers))
        try await Self.write(data, directory: directory, filePath: filePath)
        servers = newServers
    }

    /// The file write and its lock wait (up to 10 seconds) run on
    /// `DispatchQueue.global()`.
    private nonisolated static func write(_ data: Data, directory: String, filePath: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global().async {
                do {
                    let fileManager = FileManager.default
                    if !fileManager.fileExists(atPath: directory) {
                        try fileManager.createDirectory(atPath: directory, withIntermediateDirectories: true)
                    }
                    // 0600: Calyx owns this file outright.
                    try ConfigFileUtils.withExclusiveConfig(path: filePath, mode: 0o600, restoreModeOnNoWrite: true) { _ in data }
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func load(filePath: String) -> (servers: [MCPServerConfig], error: MCPServerRegistryLoadError?) {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: filePath) else {
            return ([], nil)
        }
        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: filePath))
        } catch {
            return ([], .unavailable(path: filePath, reason: String(describing: error)))
        }
        do {
            return (try decodeServers(from: data), nil)
        } catch {
            let movedToPath = filePath + ".corrupt-" + corruptSuffix()
            do {
                try fileManager.moveItem(atPath: filePath, toPath: movedToPath)
            } catch {
                return ([], .unavailable(path: filePath, reason: String(describing: error)))
            }
            return ([], .corrupt(movedToPath: movedToPath))
        }
    }

    private static func decodeServers(from data: Data) throws -> [MCPServerConfig] {
        let raw = try JSONDecoder().decode([String: AnyCodable].self, from: data)
        let migrated = try migrate(raw)
        let document = try JSONDecoder().decode(Document.self, from: JSONEncoder().encode(migrated))
        guard Set(document.servers.map(\.id)).count == document.servers.count else {
            throw DocumentInvariantError.duplicateID
        }
        guard Set(document.servers.map(\.alias)).count == document.servers.count else {
            throw DocumentInvariantError.duplicateAlias
        }
        return document.servers
    }

    /// `<unix seconds>-<8 hex digits>`.
    private static func corruptSuffix() -> String {
        let seconds = Int(Date().timeIntervalSince1970)
        return "\(seconds)-\(UUID().uuidString.prefix(8).lowercased())"
    }

    private static func secretValues(of server: MCPImportedServer, serverID: MCPServerID) -> [(key: MCPSecretKey, value: String)] {
        let env = server.envValues.sorted { $0.key < $1.key }.map { (key: MCPSecretKey.env(serverID: serverID, name: $0.key), value: $0.value) }
        let headers = server.headerValues.sorted { $0.key < $1.key }.map { (key: MCPSecretKey.header(serverID: serverID, name: $0.key), value: $0.value) }
        return env + headers
    }

    private static func envAndHeaderKeys(of transport: MCPServerTransportConfig, serverID: MCPServerID) -> [MCPSecretKey] {
        switch transport {
        case .stdio(_, _, let envNames, _):
            return envNames.map { .env(serverID: serverID, name: $0) }
        case .http(_, let headerNames, _):
            return headerNames.map { .header(serverID: serverID, name: $0) }
        }
    }

    private static func newConfig(id: MCPServerID, alias: String, from server: MCPImportedServer) -> MCPServerConfig {
        guard let validAlias = MCPServerAlias(rawValue: alias) else {
            preconditionFailure("derived, fallback, and suffixed aliases satisfy the alias syntax")
        }
        return MCPServerConfig(
            id: id, alias: validAlias, displayName: server.name ?? alias,
            isEnabled: true, transport: server.transport, auth: nil
        )
    }
}
