//
//  MCPSecretStoreTests.swift
//  CalyxTests
//
//  `MCPSecretStore` implementations keyed by the typed `MCPSecretKey`
//  (contract v2 SS7.10-SS7.15): `KeychainMCPSecretStore` (service
//  "com.calyx.terminal.mcp" -- never exercised against the real
//  keychain in this suite, only constructed and type-checked),
//  `FileMCPSecretStore` (one 0600 file per key under a temp directory,
//  filename is a hash and never contains the key text or the value
//  text), `InMemoryMCPSecretStore`, and `MCPSecretStoreFactory.make(
//  directory:testRoot:)`, whose explicit `testRoot` parameter (SS7.15)
//  makes both branches testable by construction rather than only the
//  branch the real `CalyxPathRoot.testRoot` happens to select under
//  the unit-test host.
//

import XCTest
@testable import Calyx

final class MCPSecretStoreTests: XCTestCase {

    private var tempDir: String!
    private let serverA = MCPServerID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-0000000000aa")!)
    private let serverB = MCPServerID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-0000000000bb")!)

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

    // MARK: - Keychain store: identity only, never touches the real keychain

    func test_keychainStore_usesTheDedicatedMCPService() {
        XCTAssertEqual(KeychainMCPSecretStore.service, "com.calyx.terminal.mcp")
    }

    // MARK: - Shared behavior, exercised against both FileMCPSecretStore and InMemoryMCPSecretStore

    private func assertSetThenGetRoundTrips(_ store: any MCPSecretStore, file: StaticString = #filePath, line: UInt = #line) async throws {
        let key = MCPSecretKey.env(serverID: serverA, name: "MYVAR")
        try await store.set("xyz", forKey: key)
        let value = try await store.get(key)
        XCTAssertEqual(value, "xyz", file: file, line: line)
    }

    private func assertGetMissingKeyReturnsNil(_ store: any MCPSecretStore, file: StaticString = #filePath, line: UInt = #line) async throws {
        let value = try await store.get(.env(serverID: serverA, name: "ABSENT"))
        XCTAssertNil(value, file: file, line: line)
    }

    private func assertDeleteRemovesTheValue(_ store: any MCPSecretStore, file: StaticString = #filePath, line: UInt = #line) async throws {
        let key = MCPSecretKey.header(serverID: serverA, name: "X-Region")
        try await store.set("xyz", forKey: key)
        try await store.delete(key)
        let value = try await store.get(key)
        XCTAssertNil(value, file: file, line: line)
    }

    private func assertDistinctKeysAreIsolated(_ store: any MCPSecretStore, file: StaticString = #filePath, line: UInt = #line) async throws {
        let keyA = MCPSecretKey.oauthTokens(serverID: serverA)
        let keyB = MCPSecretKey.clientSecret(serverID: serverA)
        try await store.set("value-a", forKey: keyA)
        try await store.set("value-b", forKey: keyB)
        try await store.delete(keyA)

        let a = try await store.get(keyA)
        let b = try await store.get(keyB)
        XCTAssertNil(a, file: file, line: line)
        XCTAssertEqual(b, "value-b", file: file, line: line)
    }

    private func assertDeleteAllRemovesEveryKindForOneServerOnly(_ store: any MCPSecretStore, file: StaticString = #filePath, line: UInt = #line) async throws {
        try await store.set("a-env", forKey: .env(serverID: serverA, name: "MYVAR"))
        try await store.set("a-header", forKey: .header(serverID: serverA, name: "X-Region"))
        try await store.set("a-tokens", forKey: .oauthTokens(serverID: serverA))
        try await store.set("a-secret", forKey: .clientSecret(serverID: serverA))
        try await store.set("b-env", forKey: .env(serverID: serverB, name: "MYVAR"))

        try await store.deleteAll(forServer: serverA)

        let aEnv = try await store.get(.env(serverID: serverA, name: "MYVAR"))
        let aHeader = try await store.get(.header(serverID: serverA, name: "X-Region"))
        let aTokens = try await store.get(.oauthTokens(serverID: serverA))
        let aSecret = try await store.get(.clientSecret(serverID: serverA))
        XCTAssertNil(aEnv, file: file, line: line)
        XCTAssertNil(aHeader, file: file, line: line)
        XCTAssertNil(aTokens, file: file, line: line)
        XCTAssertNil(aSecret, file: file, line: line)

        let bEnv = try await store.get(.env(serverID: serverB, name: "MYVAR"))
        XCTAssertEqual(bEnv, "b-env", file: file, line: line)
    }

    // MARK: - File store

    func test_fileStore_setThenGet_roundTrips() async throws {
        try await assertSetThenGetRoundTrips(FileMCPSecretStore(directory: tempDir))
    }

    func test_fileStore_getMissingKey_returnsNil() async throws {
        try await assertGetMissingKeyReturnsNil(FileMCPSecretStore(directory: tempDir))
    }

    func test_fileStore_delete_removesTheValue() async throws {
        try await assertDeleteRemovesTheValue(FileMCPSecretStore(directory: tempDir))
    }

    func test_fileStore_distinctKeys_isolated() async throws {
        try await assertDistinctKeysAreIsolated(FileMCPSecretStore(directory: tempDir))
    }

    func test_fileStore_deleteAll_removesEveryKindForOneServerOnly() async throws {
        try await assertDeleteAllRemovesEveryKindForOneServerOnly(FileMCPSecretStore(directory: tempDir))
    }

    func test_fileStore_onDiskFile_mode0600() async throws {
        let store = FileMCPSecretStore(directory: tempDir)
        try await store.set("xyz", forKey: .env(serverID: serverA, name: "MYVAR"))

        let contents = try FileManager.default.contentsOfDirectory(atPath: tempDir)
        XCTAssertFalse(contents.isEmpty, "the store must have written at least one file under the given directory")
        for name in contents {
            let attributes = try FileManager.default.attributesOfItem(atPath: (tempDir as NSString).appendingPathComponent(name))
            let permissions = (attributes[.posixPermissions] as? NSNumber)?.uint16Value
            XCTAssertEqual(permissions, 0o600, "secret file \(name) must be 0600")
        }
    }

    func test_fileStore_oneFilePerKey_countMatches() async throws {
        let store = FileMCPSecretStore(directory: tempDir)
        try await store.set("v1", forKey: .env(serverID: serverA, name: "MYVAR"))
        try await store.set("v2", forKey: .header(serverID: serverA, name: "X-Region"))
        try await store.set("v3", forKey: .oauthTokens(serverID: serverA))

        let contents = try FileManager.default.contentsOfDirectory(atPath: tempDir)
        XCTAssertEqual(contents.count, 3)
    }

    func test_fileStore_filename_containsNeitherKeyTextNorValueText() async throws {
        let store = FileMCPSecretStore(directory: tempDir)
        let key = MCPSecretKey.env(serverID: serverA, name: "MYVAR")
        try await store.set("xyzsecretvalue", forKey: key)

        let contents = try FileManager.default.contentsOfDirectory(atPath: tempDir)
        XCTAssertEqual(contents.count, 1)
        let filename = contents[0]
        XCTAssertFalse(filename.contains(key.storageKey), "filename must not contain the raw storage key text")
        XCTAssertFalse(filename.lowercased().contains("myvar"), "filename must not contain the env var name")
        XCTAssertFalse(filename.contains("xyzsecretvalue"), "filename must not contain the secret value")
        XCTAssertFalse(filename.lowercased().contains("env"), "filename must not contain the key kind literal either")
    }

    func test_fileStore_delete_removesTheFile() async throws {
        let store = FileMCPSecretStore(directory: tempDir)
        let key = MCPSecretKey.env(serverID: serverA, name: "MYVAR")
        try await store.set("xyz", forKey: key)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: tempDir).count, 1)

        try await store.delete(key)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: tempDir).count, 0)
    }

    // MARK: - In-memory store

    func test_inMemoryStore_setThenGet_roundTrips() async throws {
        try await assertSetThenGetRoundTrips(InMemoryMCPSecretStore())
    }

    func test_inMemoryStore_getMissingKey_returnsNil() async throws {
        try await assertGetMissingKeyReturnsNil(InMemoryMCPSecretStore())
    }

    func test_inMemoryStore_delete_removesTheValue() async throws {
        try await assertDeleteRemovesTheValue(InMemoryMCPSecretStore())
    }

    func test_inMemoryStore_distinctKeys_isolated() async throws {
        try await assertDistinctKeysAreIsolated(InMemoryMCPSecretStore())
    }

    func test_inMemoryStore_deleteAll_removesEveryKindForOneServerOnly() async throws {
        try await assertDeleteAllRemovesEveryKindForOneServerOnly(InMemoryMCPSecretStore())
    }

    // MARK: - MCPSecretKey.storageKey (SS7.10)

    func test_storageKey_env_matchesDeclaredFormat() {
        let key = MCPSecretKey.env(serverID: serverA, name: "MYVAR")
        let expected = "\(serverA.rawValue.uuidString).env.MYVAR"
        XCTAssertEqual(key.storageKey.lowercased(), expected.lowercased())
    }

    func test_storageKey_distinctKindsAreDistinct() {
        let env = MCPSecretKey.env(serverID: serverA, name: "MYVAR").storageKey
        let header = MCPSecretKey.header(serverID: serverA, name: "MYVAR").storageKey
        let tokens = MCPSecretKey.oauthTokens(serverID: serverA).storageKey
        let secret = MCPSecretKey.clientSecret(serverID: serverA).storageKey
        XCTAssertEqual(Set([env, header, tokens, secret]).count, 4)
    }

    func test_storageKey_allPrefixedByTheServerID() {
        let idPrefix = serverA.rawValue.uuidString.lowercased()
        for storageKey in [
            MCPSecretKey.env(serverID: serverA, name: "MYVAR").storageKey,
            MCPSecretKey.header(serverID: serverA, name: "MYVAR").storageKey,
            MCPSecretKey.oauthTokens(serverID: serverA).storageKey,
            MCPSecretKey.clientSecret(serverID: serverA).storageKey
        ] {
            XCTAssertTrue(storageKey.lowercased().hasPrefix(idPrefix), "\(storageKey) must be prefixed by the owning server's id")
        }
    }

    func test_oauthClientRegistrationKey_isKeyedByIssuerOnly_andSurvivesDeleteAllOfAServer() async throws {
        let key = MCPSecretKey.oauthClientRegistration(issuer: "https://auth.example.com")
        let other = MCPSecretKey.oauthClientRegistration(issuer: "https://other.example.com")
        XCTAssertNil(key.serverID, "a client registration belongs to an issuer, not to a server")
        XCTAssertNotEqual(key.storageKey, other.storageKey)
        XCTAssertFalse(key.storageKey.lowercased().hasPrefix(serverA.rawValue.uuidString.lowercased()))

        let store = FileMCPSecretStore(directory: tempDir)
        try await store.set("registered-client", forKey: key)
        try await store.set("tok", forKey: .oauthTokens(serverID: serverA))
        try await store.deleteAll(forServer: serverA)

        let kept = try await store.get(key)
        XCTAssertEqual(kept, "registered-client", "deleting a server's secrets leaves the per-issuer registration")
    }

    // MARK: - Factory: file store whenever testRoot != nil, Keychain store otherwise (SS7.15 explicit testRoot: parameter)

    func test_factory_nonNilTestRoot_returnsAFileBackedStore_byType() {
        let store = MCPSecretStoreFactory.make(directory: tempDir, testRoot: tempDir)
        XCTAssertTrue(store is FileMCPSecretStore, "a non-nil testRoot must select the file-backed store")
        XCTAssertFalse(store is KeychainMCPSecretStore, "the real keychain must never be reached under a test root")
    }

    func test_factory_nilTestRoot_returnsAKeychainBackedStore_byTypeOnly() {
        // Constructing KeychainMCPSecretStore itself must not touch the
        // real keychain (its init() carries no I/O); only actual get/set
        // calls would, and this suite never performs those against it.
        let store = MCPSecretStoreFactory.make(directory: tempDir, testRoot: nil)
        XCTAssertTrue(store is KeychainMCPSecretStore, "a nil testRoot must select the keychain-backed store")
        XCTAssertFalse(store is FileMCPSecretStore)
    }

    func test_factory_defaultTestRootParameter_reflectsCalyxPathRootTestRoot() {
        // This test process is itself the unit-test host, so
        // `CalyxPathRoot.testRoot` is always non-nil here -- exactly the
        // condition the factory's default argument must react to.
        XCTAssertNotNil(CalyxPathRoot.testRoot, "precondition: this suite must run under a non-nil test root")

        let store = MCPSecretStoreFactory.make(directory: tempDir)
        XCTAssertTrue(store is FileMCPSecretStore, "the default testRoot argument must come from CalyxPathRoot.testRoot")
    }

    func test_factory_underTestRoot_writesUnderTheGivenDirectory() async throws {
        let store = MCPSecretStoreFactory.make(directory: tempDir, testRoot: tempDir)
        try await store.set("xyz", forKey: .env(serverID: serverA, name: "MYVAR"))

        let contents = try FileManager.default.contentsOfDirectory(atPath: tempDir)
        XCTAssertFalse(contents.isEmpty, "the factory-produced store must persist under the given directory, never touching the real keychain")
    }
}
