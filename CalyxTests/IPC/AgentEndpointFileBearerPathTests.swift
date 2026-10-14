//
//  AgentEndpointFileBearerPathTests.swift
//  CalyxTests
//
//  The `bearerFileName(port:)` / `bearerFilePath(directory:port:)` API
//  (C-D17, slice 4c spec note 18: the Grok bearer file is named for the
//  port, so a session configured for an older port finds no file). Kept
//  apart from `AgentEndpointFileBearerFileTests` so that class compiles
//  before the API exists.
//

import XCTest
@testable import Calyx

final class AgentEndpointFileBearerPathTests: XCTestCase {

    func test_bearerFileName_carriesThePort() {
        XCTAssertEqual(AgentEndpointFile.bearerFileName(port: 41830), "calyx-bearer-token-41830")
        XCTAssertEqual(AgentEndpointFile.bearerFileName(port: 1), "calyx-bearer-token-1")
    }

    func test_bearerFilePath_isDirectorySlashName() {
        XCTAssertEqual(AgentEndpointFile.bearerFilePath(directory: "/tmp/a b/Calyx", port: 41831),
                       "/tmp/a b/Calyx/calyx-bearer-token-41831")
    }

    func test_bearerFilePath_defaultDirectory_sitsNextToTheEndpointFile() {
        let expected = (AgentEndpointFile.path as NSString).deletingLastPathComponent + "/calyx-bearer-token-41830"
        XCTAssertEqual(AgentEndpointFile.bearerFilePath(directory: AgentEndpointFile.defaultDirectory, port: 41830), expected)
    }

    func test_write_createsTheFileAtBearerFilePath() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let token = String(repeating: "ab", count: 32)
        try writeTestEndpointFile(port: 41833, token: token,
                                  wakeProofKey: IPCWakeProofKey(bytes: Data(repeating: 0x01, count: 32)), directory: dir)
        XCTAssertEqual(FileManager.default.contents(atPath: AgentEndpointFile.bearerFilePath(directory: dir, port: 41833)),
                       Data(token.utf8))
    }
}
