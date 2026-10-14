//
//  AgentEndpointFileTests.swift
//  CalyxTests
//
//  Tests for AgentEndpointFile.remove(directory:port:token:): the
//  ownership-checked delete that only removes agent-endpoint.json when
//  the caller can prove it published the exact port+token currently on
//  disk. See CalyxMCPServer.stop(), the only caller, and
//  CalyxMCPServerTests.test_stop_onNeverStartedServer_doesNotDeleteAnotherServersEndpointFile
//  for the regression this exists to close.
//
//  Coverage:
//  - remove() deletes a file whose port+token match exactly
//  - remove() leaves a file whose port and/or token differ untouched
//  - remove(token: "") never deletes anything, even with a matching port
//  - remove() leaves an unparsable file untouched
//

import XCTest
@testable import Calyx

final class AgentEndpointFileTests: XCTestCase {

    // MARK: - Properties

    private var tempDir: String!
    private var filePath: String!

    // MARK: - Lifecycle

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).path
        try! FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        filePath = tempDir + "/agent-endpoint.json"
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: tempDir)
        tempDir = nil
        filePath = nil
        super.tearDown()
    }

    // MARK: - Matching port+token

    func test_remove_deletesFile_whenPortAndTokenMatch() throws {
        try writeTestEndpointFile(port: 41830, token: "test-token-abc", wakeProofKey: IPCWakeProofKey.random(), directory: tempDir)
        XCTAssertTrue(FileManager.default.fileExists(atPath: filePath),
                     "Precondition: file must exist before remove")

        AgentEndpointFile.remove(directory: tempDir, port: 41830, token: "test-token-abc")

        XCTAssertFalse(FileManager.default.fileExists(atPath: filePath),
                       "remove() must delete agent-endpoint.json when port and token both match")
    }

    // MARK: - Mismatched port and/or token

    func test_remove_leavesFileUntouched_whenPortDiffers() throws {
        try writeTestEndpointFile(port: 41830, token: "test-token-abc", wakeProofKey: IPCWakeProofKey.random(), directory: tempDir)

        AgentEndpointFile.remove(directory: tempDir, port: 41831, token: "test-token-abc")

        XCTAssertTrue(FileManager.default.fileExists(atPath: filePath),
                     "remove() must not delete agent-endpoint.json when the port doesn't match")
    }

    func test_remove_leavesFileUntouched_whenTokenDiffers() throws {
        try writeTestEndpointFile(port: 41830, token: "test-token-abc", wakeProofKey: IPCWakeProofKey.random(), directory: tempDir)

        AgentEndpointFile.remove(directory: tempDir, port: 41830, token: "different-token")

        XCTAssertTrue(FileManager.default.fileExists(atPath: filePath),
                     "remove() must not delete agent-endpoint.json when the token doesn't match")
    }

    func test_remove_leavesFileUntouched_whenPortAndTokenBothDiffer() throws {
        try writeTestEndpointFile(port: 41830, token: "test-token-abc", wakeProofKey: IPCWakeProofKey.random(), directory: tempDir)

        AgentEndpointFile.remove(directory: tempDir, port: 9999, token: "different-token")

        XCTAssertTrue(FileManager.default.fileExists(atPath: filePath),
                     "remove() must not delete agent-endpoint.json when neither port nor token match")
    }

    // MARK: - Empty token (never-started server)

    func test_remove_neverDeletes_whenCallerTokenIsEmpty_evenIfOnDiskTokenIsAlsoEmptyAndPortMatches() throws {
        // The on-disk token is also "" here, so an ordinary equality
        // check on port and token would treat this as a match and
        // delete the file. The empty-token guard exists to override
        // that: an empty caller token must never be treated as proof
        // of ownership, even when it equals the file's own token.
        try writeTestEndpointFile(port: 0, token: "", wakeProofKey: IPCWakeProofKey.random(), directory: tempDir)

        AgentEndpointFile.remove(directory: tempDir, port: 0, token: "")

        XCTAssertTrue(FileManager.default.fileExists(atPath: filePath),
                     "remove() must never delete agent-endpoint.json when the caller's token is empty, even if the on-disk token is also empty")
    }

    // MARK: - Invalid JSON on disk

    func test_remove_leavesFileUntouched_whenExistingFileIsInvalidJSON() throws {
        FileManager.default.createFile(atPath: filePath, contents: Data("not valid json".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: filePath),
                     "Precondition: file must exist before remove")

        AgentEndpointFile.remove(directory: tempDir, port: 41830, token: "test-token-abc")

        XCTAssertTrue(FileManager.default.fileExists(atPath: filePath),
                     "remove() must not delete a file it cannot parse as its own port+token")
    }
}
