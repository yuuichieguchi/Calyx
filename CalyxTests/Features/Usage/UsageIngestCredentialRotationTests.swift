//
//  UsageIngestCredentialRotationTests.swift
//  CalyxTests
//
//  Feature C, G5 (J18 / C-D19, spec note 22): the usage token is renewed
//  once per server start whose IPC token rotated.
//  - `UsageIngestCredentialStore.loadOrCreate(directory:makeToken:replaceExisting:)`:
//    `replaceExisting: true` writes the made token over a usable file
//    (same exact bytes format, mode 0600); the default keeps the file.
//  - `UsageIngestCredentialHolder.load(create:directory:rotateForGeneration:)`:
//    a non-nil generation different from the last one it rotated for
//    renews the token; the same generation again, or nil, does not.
//

import XCTest
@testable import Calyx

final class UsageIngestCredentialStoreReplaceTests: XCTestCase {

    private var rootDir = ""
    private var dir = ""
    private let tokenA = String(repeating: "0123456789abcdef", count: 4)
    private let tokenB = String(repeating: "fedcba9876543210", count: 4)

    override func setUp() {
        super.setUp()
        rootDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("UsageIngestCredentialStoreReplaceTests-\(UUID().uuidString)").path
        dir = (rootDir as NSString).appendingPathComponent("Calyx")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: rootDir)
        super.tearDown()
    }

    private var filePath: String { dir + "/usage-otel-credential.json" }

    private func contents(_ token: String) -> Data { Data("{\"Authorization\":\"Bearer \(token)\"}".utf8) }

    private func mode() throws -> Int {
        let attrs = try FileManager.default.attributesOfItem(atPath: filePath)
        return try XCTUnwrap(attrs[.posixPermissions] as? NSNumber).intValue & 0o777
    }

    func test_replaceExisting_writesTheNewToken_overAUsableFile() throws {
        _ = try UsageIngestCredentialStore.loadOrCreate(directory: dir) { self.tokenA }
        let credential = try UsageIngestCredentialStore.loadOrCreate(directory: dir, makeToken: { self.tokenB }, replaceExisting: true)
        XCTAssertEqual(credential, UsageIngestCredential(token: tokenB, headersFilePath: filePath))
        XCTAssertEqual(FileManager.default.contents(atPath: filePath), contents(tokenB))
        XCTAssertEqual(try mode(), 0o600)
        XCTAssertEqual(UsageIngestCredentialStore.read(directory: dir)?.token, tokenB)
    }

    func test_replaceExisting_tightensA0644FileTo0600() throws {
        _ = try UsageIngestCredentialStore.loadOrCreate(directory: dir) { self.tokenA }
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: filePath)
        _ = try UsageIngestCredentialStore.loadOrCreate(directory: dir, makeToken: { self.tokenB }, replaceExisting: true)
        XCTAssertEqual(try mode(), 0o600)
        XCTAssertEqual(FileManager.default.contents(atPath: filePath), contents(tokenB))
    }

    func test_replaceExistingFalse_keepsTheExistingToken() throws {
        _ = try UsageIngestCredentialStore.loadOrCreate(directory: dir) { self.tokenA }
        let credential = try UsageIngestCredentialStore.loadOrCreate(directory: dir, makeToken: { self.tokenB }, replaceExisting: false)
        XCTAssertEqual(credential.token, tokenA)
        XCTAssertEqual(FileManager.default.contents(atPath: filePath), contents(tokenA))
    }

    func test_replaceExisting_withNoFile_creates() throws {
        let credential = try UsageIngestCredentialStore.loadOrCreate(directory: dir, makeToken: { self.tokenB }, replaceExisting: true)
        XCTAssertEqual(credential.token, tokenB)
        XCTAssertEqual(FileManager.default.contents(atPath: filePath), contents(tokenB))
        XCTAssertEqual(try mode(), 0o600)
    }

    func test_replaceExisting_malformedMadeToken_throws_andKeepsTheFile() throws {
        _ = try UsageIngestCredentialStore.loadOrCreate(directory: dir) { self.tokenA }
        XCTAssertThrowsError(try UsageIngestCredentialStore.loadOrCreate(
            directory: dir, makeToken: { "NOT-HEX" }, replaceExisting: true)) { error in
            XCTAssertEqual(error as? UsageIngestCredentialError, .malformedGeneratedToken)
        }
        XCTAssertEqual(FileManager.default.contents(atPath: filePath), contents(tokenA))
    }
}

@MainActor
final class UsageIngestCredentialHolderRotationTests: XCTestCase {

    private var rootDir = ""
    private var dir = ""
    private let tokenA = String(repeating: "0123456789abcdef", count: 4)

    override func setUp() async throws {
        try await super.setUp()
        rootDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("UsageIngestCredentialHolderRotationTests-\(UUID().uuidString)").path
        dir = (rootDir as NSString).appendingPathComponent("Calyx")
        _ = try UsageIngestCredentialStore.loadOrCreate(directory: dir) { self.tokenA }
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(atPath: rootDir)
        try await super.tearDown()
    }

    private func fileToken() -> String? { UsageIngestCredentialStore.read(directory: dir)?.token }

    func test_nilGeneration_keepsTheExistingToken() async throws {
        let holder = UsageIngestCredentialHolder()
        let loaded = try await holder.load(create: true, directory: dir, rotateForGeneration: nil)
        XCTAssertEqual(loaded?.token, tokenA)
        XCTAssertEqual(fileToken(), tokenA)
    }

    func test_defaultGeneration_keepsTheExistingToken() async throws {
        let holder = UsageIngestCredentialHolder()
        let loaded = try await holder.load(create: true, directory: dir)
        XCTAssertEqual(loaded?.token, tokenA)
    }

    func test_generation_rotatesOnce_thenSameGenerationKeeps_thenNewGenerationRotatesAgain() async throws {
        let holder = UsageIngestCredentialHolder()

        let first = try await holder.load(create: true, directory: dir, rotateForGeneration: 1)
        let token1 = try XCTUnwrap(first?.token)
        XCTAssertNotEqual(token1, tokenA, "generation 1 renews the token")
        XCTAssertEqual(fileToken(), token1)
        XCTAssertEqual(holder.credential?.token, token1)

        let again = try await holder.load(create: true, directory: dir, rotateForGeneration: 1)
        XCTAssertEqual(again?.token, token1, "the same generation does not rotate twice")
        XCTAssertEqual(fileToken(), token1)

        let unrotated = try await holder.load(create: true, directory: dir, rotateForGeneration: nil)
        XCTAssertEqual(unrotated?.token, token1, "nil never rotates")

        let second = try await holder.load(create: true, directory: dir, rotateForGeneration: 2)
        let token2 = try XCTUnwrap(second?.token)
        XCTAssertNotEqual(token2, token1, "a different generation rotates again")
        XCTAssertEqual(fileToken(), token2)
    }

    private struct MakeFailure: Error {}

    func test_failedRenewal_doesNotRecordTheGeneration_andTheNextLoadRenews() async throws {
        let holder = UsageIngestCredentialHolder()
        do {
            _ = try await holder.load(create: true, directory: dir, rotateForGeneration: 3, makeToken: { "not-hex" })
            XCTFail("a malformed token must throw")
        } catch let error as UsageIngestCredentialError {
            XCTAssertEqual(error, .malformedGeneratedToken)
        }
        XCTAssertNil(holder.lastRotatedGeneration)
        XCTAssertEqual(fileToken(), tokenA, "a failed renewal leaves the file as it was")

        do {
            _ = try await holder.load(create: true, directory: dir, rotateForGeneration: 3, makeToken: { throw MakeFailure() })
            XCTFail("a throwing maker must throw")
        } catch is MakeFailure {}
        XCTAssertNil(holder.lastRotatedGeneration)

        let renewed = try await holder.load(create: true, directory: dir, rotateForGeneration: 3)
        let token = try XCTUnwrap(renewed?.token)
        XCTAssertNotEqual(token, tokenA, "the next load for the same generation renews")
        XCTAssertEqual(fileToken(), token)
        XCTAssertEqual(holder.lastRotatedGeneration, 3)
    }
}
