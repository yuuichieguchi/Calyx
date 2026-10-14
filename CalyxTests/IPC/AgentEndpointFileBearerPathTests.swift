//
//  AgentEndpointFileBearerPathTests.swift
//  CalyxTests
//
//  The `bearerFileName` / `bearerFilePath(directory:)` API (C-D17). Kept
//  apart from `AgentEndpointFileBearerFileTests` so that class compiles
//  before the API exists.
//

import XCTest
@testable import Calyx

final class AgentEndpointFileBearerPathTests: XCTestCase {

    func test_bearerFileName_isTheSpecName() {
        XCTAssertEqual(AgentEndpointFile.bearerFileName, "calyx-bearer-token")
    }

    func test_bearerFilePath_isDirectorySlashName() {
        XCTAssertEqual(AgentEndpointFile.bearerFilePath(directory: "/tmp/a b/Calyx"),
                       "/tmp/a b/Calyx/calyx-bearer-token")
    }

    func test_bearerFilePath_defaultDirectory_sitsNextToTheEndpointFile() {
        let expected = (AgentEndpointFile.path as NSString).deletingLastPathComponent + "/calyx-bearer-token"
        XCTAssertEqual(AgentEndpointFile.bearerFilePath(directory: AgentEndpointFile.defaultDirectory), expected)
    }
}
