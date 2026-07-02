//
//  ConfigFileUtilsTests.swift
//  CalyxTests
//
//  Direct unit coverage for ConfigFileUtils.directoryExists(at:), added
//  when AgentHooksCoordinator / IPCConfigManager / CodexHooksConfigManager /
//  CodexConfigManager's four duplicated directory-existence-check
//  implementations were consolidated into this single shared helper.
//

import XCTest
@testable import Calyx

final class ConfigFileUtilsTests: XCTestCase {

    // MARK: - Properties

    private var tempDir: String!

    // MARK: - Lifecycle

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).path
        try! FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: tempDir)
        super.tearDown()
    }

    // MARK: - directoryExists(at:)

    func test_directoryExists_existingDirectory_returnsTrue() {
        XCTAssertTrue(ConfigFileUtils.directoryExists(at: tempDir))
    }

    func test_directoryExists_nonexistentPath_returnsFalse() {
        XCTAssertFalse(ConfigFileUtils.directoryExists(at: tempDir + "/does-not-exist"))
    }

    func test_directoryExists_pathIsAFileNotADirectory_returnsFalse() {
        let filePath = tempDir + "/a-file"
        FileManager.default.createFile(atPath: filePath, contents: Data("x".utf8))

        XCTAssertFalse(ConfigFileUtils.directoryExists(at: filePath),
                       "A regular file must not be reported as a directory")
    }
}
