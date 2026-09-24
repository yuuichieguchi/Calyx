//
//  MCPServerRegistryTests.swift
//  CalyxTests
//
//  `MCPServerRegistry` persists `mcp-servers.json` under an injected
//  directory (production default `AppSupportDirectory.path`), 0600,
//  written through `ConfigFileUtils.withExclusiveConfig`, and deletes a
//  server's secrets (all four `MCPSecretKey` kinds) when the server
//  itself is deleted. Contract v2 SS7.6.
//

import XCTest
@testable import Calyx

@MainActor
final class MCPServerRegistryTests: XCTestCase {

    private var tempDir: String!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        try! FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: tempDir)
        tempDir = nil
        super.tearDown()
    }

    private func makeConfig(alias: String = "myserver", id: MCPServerID = MCPServerID(rawValue: UUID())) -> MCPServerConfig {
        MCPServerConfig(
            id: id,
            alias: MCPServerAlias(rawValue: alias)!,
            displayName: "My Server",
            isEnabled: true,
            transport: .stdio(command: "/usr/bin/tool", args: [], envNames: ["MYVAR"], cwd: nil),
            auth: nil
        )
    }

    private func assertThrowsAsync(_ body: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            try await body()
            XCTFail("expected an error", file: file, line: line)
        } catch {}
    }

    // MARK: - Persists to <directory>/mcp-servers.json

    func test_add_persistsToMcpServersJSON_underGivenDirectory() async throws {
        let registry = MCPServerRegistry(directory: tempDir, secretStore: InMemoryMCPSecretStore())
        try await registry.add(makeConfig())

        let filePath = (tempDir as NSString).appendingPathComponent("mcp-servers.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: filePath))
    }

    func test_add_writesSchemaVersionOne() async throws {
        let registry = MCPServerRegistry(directory: tempDir, secretStore: InMemoryMCPSecretStore())
        try await registry.add(makeConfig())

        let filePath = (tempDir as NSString).appendingPathComponent("mcp-servers.json")
        let data = try Data(contentsOf: URL(fileURLWithPath: filePath))
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(object?["schemaVersion"] as? Int, 1)
    }

    // MARK: - Written through ConfigFileUtils.withExclusiveConfig (a lock file exists for the resolved path)

    func test_add_writesThroughExclusiveConfigLock_lockFileExistsForResolvedPath() async throws {
        let registry = MCPServerRegistry(directory: tempDir, secretStore: InMemoryMCPSecretStore())
        try await registry.add(makeConfig())

        let filePath = (tempDir as NSString).appendingPathComponent("mcp-servers.json")
        let resolvedPath = try ConfigFileUtils.resolveConfigPath(filePath)
        let lockPath = try ConfigFileUtils.lockFilePath(forResolvedPath: resolvedPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: lockPath), "withExclusiveConfig must have created the shared lock file for this resolved path")
    }

    // MARK: - File mode 0600

    func test_add_fileMode_is0600() async throws {
        let registry = MCPServerRegistry(directory: tempDir, secretStore: InMemoryMCPSecretStore())
        try await registry.add(makeConfig())

        let filePath = (tempDir as NSString).appendingPathComponent("mcp-servers.json")
        let attributes = try FileManager.default.attributesOfItem(atPath: filePath)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.uint16Value
        XCTAssertEqual(permissions, 0o600)
    }

    // MARK: - In-memory servers reflect what was added

    func test_add_appendsToServers_reloadedRegistryReadsItBack() async throws {
        let config = makeConfig()
        let first = MCPServerRegistry(directory: tempDir, secretStore: InMemoryMCPSecretStore())
        try await first.add(config)
        XCTAssertEqual(first.servers, [config])

        let second = MCPServerRegistry(directory: tempDir, secretStore: InMemoryMCPSecretStore())
        XCTAssertEqual(second.servers, [config])
    }

    // MARK: - add rejects a duplicate alias

    func test_add_duplicateAlias_throws_serversUnchanged() async throws {
        let registry = MCPServerRegistry(directory: tempDir, secretStore: InMemoryMCPSecretStore())
        try await registry.add(makeConfig(alias: "myserver"))

        await assertThrowsAsync { try await registry.add(makeConfig(alias: "myserver")) }
        XCTAssertEqual(registry.servers.count, 1)
    }

    // MARK: - update rejects an alias change (alias is immutable after creation)

    func test_update_aliasChanged_throws_storedAliasUnchanged() async throws {
        let registry = MCPServerRegistry(directory: tempDir, secretStore: InMemoryMCPSecretStore())
        let original = makeConfig(alias: "myserver")
        try await registry.add(original)

        var renamed = original
        renamed.displayName = "Renamed"
        let withDifferentAlias = MCPServerConfig(
            id: original.id, alias: MCPServerAlias(rawValue: "otheralias")!, displayName: "Renamed",
            isEnabled: original.isEnabled, transport: original.transport, auth: original.auth
        )
        await assertThrowsAsync { try await registry.update(withDifferentAlias) }
        XCTAssertEqual(registry.servers.first?.alias.rawValue, "myserver")
    }

    func test_update_sameAlias_differentDisplayName_succeeds() async throws {
        let registry = MCPServerRegistry(directory: tempDir, secretStore: InMemoryMCPSecretStore())
        let original = makeConfig(alias: "myserver")
        try await registry.add(original)

        var updated = original
        updated.displayName = "New Display Name"
        try await registry.update(updated)

        XCTAssertEqual(registry.servers.first?.displayName, "New Display Name")
        XCTAssertEqual(registry.servers.first?.alias.rawValue, "myserver")
    }

    // MARK: - Corrupt file handling

    func test_init_corruptFile_movedAsideAndSurfacedAsError_serversEmpty() throws {
        let filePath = (tempDir as NSString).appendingPathComponent("mcp-servers.json")
        FileManager.default.createFile(atPath: filePath, contents: Data("{ this is not valid json".utf8))

        let registry = MCPServerRegistry(directory: tempDir, secretStore: InMemoryMCPSecretStore())

        XCTAssertTrue(registry.servers.isEmpty)
        XCTAssertNotNil(registry.loadError)
        guard case .corrupt(let movedToPath) = registry.loadError else {
            return XCTFail("expected .corrupt")
        }
        XCTAssertTrue(movedToPath.hasPrefix(filePath + ".corrupt-"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: movedToPath), "the corrupt bytes must be preserved, not discarded")
        let preserved = try Data(contentsOf: URL(fileURLWithPath: movedToPath))
        XCTAssertEqual(preserved, Data("{ this is not valid json".utf8))
    }

    func test_init_corruptFile_originalPathNoLongerExists() throws {
        let filePath = (tempDir as NSString).appendingPathComponent("mcp-servers.json")
        FileManager.default.createFile(atPath: filePath, contents: Data("not json at all".utf8))

        _ = MCPServerRegistry(directory: tempDir, secretStore: InMemoryMCPSecretStore())

        XCTAssertFalse(FileManager.default.fileExists(atPath: filePath), "the corrupt file must have been moved aside, not rewritten in place")
    }

    // MARK: - Deleting a server deletes every secret kind (env, header, oauthTokens, clientSecret)

    func test_remove_deletesAllFourSecretKindsForTheServer_leavesOtherServerIntact() async throws {
        let secretStore = InMemoryMCPSecretStore()
        let configA = makeConfig(alias: "servera")
        let configB = makeConfig(alias: "serverb")

        try await secretStore.set("a-env", forKey: .env(serverID: configA.id, name: "MYVAR"))
        try await secretStore.set("a-header", forKey: .header(serverID: configA.id, name: "X-Region"))
        try await secretStore.set("a-tokens", forKey: .oauthTokens(serverID: configA.id))
        try await secretStore.set("a-secret", forKey: .clientSecret(serverID: configA.id))
        try await secretStore.set("b-env", forKey: .env(serverID: configB.id, name: "MYVAR"))

        let registry = MCPServerRegistry(directory: tempDir, secretStore: secretStore)
        try await registry.add(configA)
        try await registry.add(configB)
        try await registry.remove(id: configA.id)

        let remainingEnv = try await secretStore.get(.env(serverID: configA.id, name: "MYVAR"))
        let remainingHeader = try await secretStore.get(.header(serverID: configA.id, name: "X-Region"))
        let remainingTokens = try await secretStore.get(.oauthTokens(serverID: configA.id))
        let remainingSecret = try await secretStore.get(.clientSecret(serverID: configA.id))
        XCTAssertNil(remainingEnv)
        XCTAssertNil(remainingHeader)
        XCTAssertNil(remainingTokens)
        XCTAssertNil(remainingSecret)

        let bEnv = try await secretStore.get(.env(serverID: configB.id, name: "MYVAR"))
        XCTAssertEqual(bEnv, "b-env", "another server's secrets must not be touched")

        XCTAssertEqual(registry.servers.map(\.id), [configB.id])
    }

    // MARK: - importServers (SS7.6): conflict policy replace / rename / skip

    private func makeImported(
        name: String,
        command: String = "/usr/bin/tool",
        envValues: [String: String] = [:],
        headerValues: [String: String] = [:]
    ) -> MCPImportedServer {
        MCPImportedServer(
            name: name,
            transport: .stdio(command: command, args: [], envNames: Array(envValues.keys), cwd: nil),
            envValues: envValues,
            headerValues: headerValues,
            unresolvedVariables: [],
            ignoredKeys: []
        )
    }

    func test_importServers_replacePolicy_overwritesConfigKeepingID() async throws {
        let registry = MCPServerRegistry(directory: tempDir, secretStore: InMemoryMCPSecretStore())
        let original = makeConfig(alias: "myserver")
        try await registry.add(original)

        let outcome = try await registry.importServers([makeImported(name: "myserver", command: "/usr/bin/replacement")], conflictPolicy: .replace)

        XCTAssertEqual(outcome.replaced, [original.id])
        XCTAssertTrue(outcome.added.isEmpty)
        XCTAssertTrue(outcome.renamed.isEmpty)
        XCTAssertTrue(outcome.skipped.isEmpty)
        XCTAssertEqual(registry.servers.count, 1)
        XCTAssertEqual(registry.servers.first?.id, original.id, "replace must keep the existing server's id")
        guard case .stdio(let command, _, _, _) = registry.servers.first?.transport else {
            return XCTFail("expected stdio transport")
        }
        XCTAssertEqual(command, "/usr/bin/replacement")
    }

    func test_importServers_renamePolicy_appliesNumericSuffix_reportsRename() async throws {
        let registry = MCPServerRegistry(directory: tempDir, secretStore: InMemoryMCPSecretStore())
        let original = makeConfig(alias: "myserver")
        try await registry.add(original)

        let outcome = try await registry.importServers([makeImported(name: "myserver")], conflictPolicy: .rename)

        XCTAssertEqual(outcome.renamed, [MCPImportRename(from: "myserver", to: "myserver2")])
        XCTAssertTrue(outcome.replaced.isEmpty)
        XCTAssertTrue(outcome.skipped.isEmpty)
        XCTAssertEqual(outcome.added.count, 1)
        XCTAssertEqual(registry.servers.count, 2)
        XCTAssertEqual(Set(registry.servers.map { $0.alias.rawValue }), ["myserver", "myserver2"])
        XCTAssertEqual(registry.servers.first { $0.alias.rawValue == "myserver" }?.id, original.id, "the pre-existing server must be untouched by a rename import")
    }

    func test_importServers_skipPolicy_leavesExistingConfig_reportsAlias() async throws {
        let registry = MCPServerRegistry(directory: tempDir, secretStore: InMemoryMCPSecretStore())
        let original = makeConfig(alias: "myserver")
        try await registry.add(original)

        let outcome = try await registry.importServers([makeImported(name: "myserver", command: "/usr/bin/should-not-apply")], conflictPolicy: .skip)

        XCTAssertEqual(outcome.skipped, ["myserver"])
        XCTAssertTrue(outcome.added.isEmpty)
        XCTAssertTrue(outcome.replaced.isEmpty)
        XCTAssertTrue(outcome.renamed.isEmpty)
        XCTAssertEqual(registry.servers, [original], "a skipped import must leave the existing config byte-for-byte unchanged")
    }

    func test_importServers_noCollision_envAndHeaderValuesRoutedToSecretStore_underTheNewServerID() async throws {
        let secretStore = InMemoryMCPSecretStore()
        let registry = MCPServerRegistry(directory: tempDir, secretStore: secretStore)

        let outcome = try await registry.importServers(
            [makeImported(name: "newsrv", envValues: ["MYVAR": "xyz"], headerValues: ["X-Region": "abc"])],
            conflictPolicy: .replace
        )

        XCTAssertEqual(outcome.added.count, 1)
        let newID = try XCTUnwrap(outcome.added.first)
        XCTAssertEqual(registry.servers.first { $0.id == newID }?.alias.rawValue, "newsrv")

        let env = try await secretStore.get(.env(serverID: newID, name: "MYVAR"))
        let header = try await secretStore.get(.header(serverID: newID, name: "X-Region"))
        XCTAssertEqual(env, "xyz")
        XCTAssertEqual(header, "abc")
    }

    func test_importServers_writesSecretsBeforeSavingTheConfigs() async throws {
        let configPath = (tempDir as NSString).appendingPathComponent(MCPServerRegistry.fileName)
        let secretStore = OrderRecordingSecretStore(configPath: configPath)
        let registry = MCPServerRegistry(directory: tempDir, secretStore: secretStore)

        _ = try await registry.importServers(
            [makeImported(name: "myserver", envValues: ["MYVAR": "imported-value"])],
            conflictPolicy: .rename
        )

        let configSavedAtWrite = await secretStore.configExistedAtSet
        XCTAssertEqual(configSavedAtWrite, [false], "the secret is written before mcp-servers.json is saved")
        XCTAssertEqual(registry.servers.count, 1)
    }

    func test_importServers_replaceReusingAnEnvName_keepsTheNewValue() async throws {
        let secretStore = InMemoryMCPSecretStore()
        let registry = MCPServerRegistry(directory: tempDir, secretStore: secretStore)
        let original = makeConfig(alias: "myserver")
        try await registry.add(original)
        try await secretStore.set("old-value", forKey: .env(serverID: original.id, name: "MYVAR"))

        _ = try await registry.importServers([makeImported(name: "myserver", envValues: ["MYVAR": "new-value"])], conflictPolicy: .replace)

        let stored = try await secretStore.get(.env(serverID: original.id, name: "MYVAR"))
        XCTAssertEqual(stored, "new-value", "a stale key the import writes again is not deleted after the write")
    }

    func test_importServers_replacePolicy_removesStaleEnvSecretOfTheReplacedServer() async throws {
        let secretStore = InMemoryMCPSecretStore()
        let registry = MCPServerRegistry(directory: tempDir, secretStore: secretStore)
        let original = makeConfig(alias: "myserver")
        try await registry.add(original)
        try await secretStore.set("stale", forKey: .env(serverID: original.id, name: "MYVAR"))

        _ = try await registry.importServers([makeImported(name: "myserver", envValues: ["OTHERVAR": "fresh"])], conflictPolicy: .replace)

        let stale = try await secretStore.get(.env(serverID: original.id, name: "MYVAR"))
        let fresh = try await secretStore.get(.env(serverID: original.id, name: "OTHERVAR"))
        XCTAssertNil(stale, "replace must delete the replaced server's previous env secrets")
        XCTAssertEqual(fresh, "fresh")
    }

    // MARK: - migrate (SS7.6): schemaVersion 0 (missing) upgraded, 1 passes through, >1 throws unsupportedVersion

    func test_migrate_missingSchemaVersion_upgradedToCurrent() throws {
        let document: [String: AnyCodable] = ["servers": AnyCodable([AnyCodable]())]
        let migrated = try MCPServerRegistry.migrate(document)
        XCTAssertEqual(migrated["schemaVersion"], AnyCodable(MCPServerRegistry.currentSchemaVersion))
    }

    func test_migrate_currentSchemaVersion_passesThroughUnchanged() throws {
        let document: [String: AnyCodable] = ["schemaVersion": AnyCodable(1), "servers": AnyCodable([AnyCodable]())]
        let migrated = try MCPServerRegistry.migrate(document)
        XCTAssertEqual(migrated, document)
    }

    func test_migrate_newerSchemaVersion_throwsUnsupportedVersion() {
        let document: [String: AnyCodable] = ["schemaVersion": AnyCodable(2), "servers": AnyCodable([AnyCodable]())]
        XCTAssertThrowsError(try MCPServerRegistry.migrate(document)) { error in
            guard case MCPServerRegistryError.unsupportedVersion(let version) = error else {
                return XCTFail("expected .unsupportedVersion, got \(error)")
            }
            XCTAssertEqual(version, 2)
        }
    }

    // MARK: - A file with an unsupported schemaVersion is treated exactly like a corrupt file

    func test_init_unsupportedSchemaVersion_movedAsideAndSurfacedAsError() throws {
        let filePath = (tempDir as NSString).appendingPathComponent("mcp-servers.json")
        FileManager.default.createFile(atPath: filePath, contents: Data(#"{"schemaVersion":2,"servers":[]}"#.utf8))

        let registry = MCPServerRegistry(directory: tempDir, secretStore: InMemoryMCPSecretStore())

        XCTAssertTrue(registry.servers.isEmpty)
        guard case .corrupt(let movedToPath) = registry.loadError else {
            return XCTFail("expected .corrupt for an unsupported schemaVersion")
        }
        XCTAssertTrue(movedToPath.hasPrefix(filePath + ".corrupt-"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: filePath), "the unsupported-version file must have been moved aside, not rewritten in place")
    }
}

/// Records, at each `set`, whether the registry's file had been saved.
private actor OrderRecordingSecretStore: MCPSecretStore {
    private let configPath: String
    private(set) var configExistedAtSet: [Bool] = []
    private var storage: [MCPSecretKey: String] = [:]

    init(configPath: String) {
        self.configPath = configPath
    }

    func get(_ key: MCPSecretKey) async throws -> String? { storage[key] }

    func set(_ value: String, forKey key: MCPSecretKey) async throws {
        configExistedAtSet.append(FileManager.default.fileExists(atPath: configPath))
        storage[key] = value
    }

    func delete(_ key: MCPSecretKey) async throws { storage[key] = nil }

    func deleteAll(forServer serverID: MCPServerID) async throws {}
}
