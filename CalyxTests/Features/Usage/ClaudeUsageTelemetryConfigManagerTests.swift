//
//  ClaudeUsageTelemetryConfigManagerTests.swift
//  CalyxTests
//
//  The file half of the R4a contract: ClaudeUsageTelemetryConfigManager
//  edits a settings file through ConfigFileUtils.withExclusiveConfig.
//  Every call passes an explicit settingsPath inside a per-test temporary
//  directory; ~/.claude is never touched.
//

import XCTest
@testable import Calyx

final class ClaudeUsageTelemetryConfigManagerTests: XCTestCase {

    private typealias Manager = ClaudeUsageTelemetryConfigManager

    private var tempDir = ""
    private var claudeDir = ""
    private var settingsPath = ""

    private static let helperPath = "/tmp/calyx-test/bin/calyx-usage-headers"
    private static let userContent = "{\n  \"env\": {\n    \"FOO\": \"bar\"\n  },\n  \"model\": \"opus\"\n}\n"
    private static let foreignContent = "{\n  \"env\": {\n    \"OTEL_EXPORTER_OTLP_METRICS_ENDPOINT\": \"http://collector:4318/v1/metrics\"\n  }\n}\n"

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("UsageTelemetry-" + UUID().uuidString).path
        claudeDir = tempDir + "/.claude"
        settingsPath = claudeDir + "/settings.json"
        try FileManager.default.createDirectory(atPath: claudeDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if !tempDir.isEmpty {
            try? FileManager.default.removeItem(atPath: tempDir)
        }
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    private func write(_ content: String, to path: String, mode: mode_t = 0o644) throws {
        try Data(content.utf8).write(to: URL(fileURLWithPath: path))
        XCTAssertEqual(chmod(path, mode), 0, "test setup: chmod must succeed")
    }

    private func read(_ path: String) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: path))
    }

    private func mode(of path: String) -> mode_t? {
        var statBuf = stat()
        guard stat(path, &statBuf) == 0 else { return nil }
        return statBuf.st_mode & ~S_IFMT
    }

    private func modificationDate(of path: String) throws -> Date? {
        try FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date
    }

    private func endpoint(in path: String) throws -> String? {
        let object = try JSONSerialization.jsonObject(with: try read(path))
        let env = (object as? [String: Any])?["env"] as? [String: Any]
        return env?["OTEL_EXPORTER_OTLP_METRICS_ENDPOINT"] as? String
    }

    // MARK: - Missing file / missing directory

    func test_install_createsTheFileWhenTheDirectoryExists() throws {
        let outcome = try Manager.install(port: 41830, helperPath: Self.helperPath, settingsPath: settingsPath)
        XCTAssertEqual(outcome, .installed(port: 41830))
        XCTAssertTrue(FileManager.default.fileExists(atPath: settingsPath))
        XCTAssertEqual(try endpoint(in: settingsPath), "http://127.0.0.1:41830/usage/v1/metrics")
    }

    func test_install_returnsClaudeNotFound_andCreatesNothing_whenTheDirectoryIsMissing() throws {
        let missingDir = tempDir + "/no-claude"
        let outcome = try Manager.install(port: 41830, helperPath: Self.helperPath, settingsPath: missingDir + "/settings.json")
        XCTAssertEqual(outcome, .claudeNotFound)
        XCTAssertFalse(FileManager.default.fileExists(atPath: missingDir))
    }

    func test_remove_onAMissingFile_isRemoved_andCreatesNothing() throws {
        let outcome = try Manager.remove(settingsPath: settingsPath)
        XCTAssertEqual(outcome, .removed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: settingsPath))
    }

    func test_remove_returnsClaudeNotFound_andCreatesNothing_whenTheDirectoryIsMissing() throws {
        let missingDir = tempDir + "/no-claude"
        XCTAssertEqual(try Manager.remove(settingsPath: missingDir + "/settings.json"), .claudeNotFound)
        XCTAssertFalse(FileManager.default.fileExists(atPath: missingDir))
    }

    // MARK: - Install / remove round trip

    func test_installThenRemove_restoresTheFileByteForByte() throws {
        try write(Self.userContent, to: settingsPath)
        XCTAssertEqual(try Manager.install(port: 41830, helperPath: Self.helperPath, settingsPath: settingsPath),
                       .installed(port: 41830))
        XCTAssertEqual(try Manager.remove(settingsPath: settingsPath), .removed)
        XCTAssertEqual(try read(settingsPath), Data(Self.userContent.utf8))
    }

    // MARK: - Symbolic link (dotfiles layout)

    private func makeDotfilesLink() throws -> String {
        let dotfiles = tempDir + "/dotfiles/claude"
        try FileManager.default.createDirectory(atPath: dotfiles, withIntermediateDirectories: true)
        let target = dotfiles + "/settings.json"
        try write(Self.userContent, to: target, mode: 0o644)
        try FileManager.default.createSymbolicLink(atPath: settingsPath, withDestinationPath: target)
        return target
    }

    func test_install_throughASymbolicLink_changesTheTarget_keepsTheLink_andKeepsTheMode() throws {
        let target = try makeDotfilesLink()
        let outcome = try Manager.install(port: 41830, helperPath: Self.helperPath, settingsPath: settingsPath)
        XCTAssertEqual(outcome, .installed(port: 41830))
        XCTAssertTrue(ConfigFileUtils.isSymlink(at: settingsPath), "the settings path must stay a symbolic link")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: settingsPath), target)
        XCTAssertEqual(try endpoint(in: target), "http://127.0.0.1:41830/usage/v1/metrics")
        XCTAssertEqual(mode(of: target), 0o644)
    }

    func test_remove_throughASymbolicLink_restoresTheTarget_keepsTheLink_andKeepsTheMode() throws {
        let target = try makeDotfilesLink()
        _ = try Manager.install(port: 41830, helperPath: Self.helperPath, settingsPath: settingsPath)
        XCTAssertEqual(try Manager.remove(settingsPath: settingsPath), .removed)
        XCTAssertTrue(ConfigFileUtils.isSymlink(at: settingsPath), "the settings path must stay a symbolic link")
        XCTAssertEqual(try read(target), Data(Self.userContent.utf8))
        XCTAssertEqual(mode(of: target), 0o644)
    }

    // MARK: - No needless write

    func test_install_unchanged_doesNotTouchTheModificationTime() throws {
        try write(Self.userContent, to: settingsPath)
        _ = try Manager.install(port: 41830, helperPath: Self.helperPath, settingsPath: settingsPath)
        let fixed = Date(timeIntervalSince1970: 1_000_000_000)
        try FileManager.default.setAttributes([.modificationDate: fixed], ofItemAtPath: settingsPath)
        let before = try read(settingsPath)

        let outcome = try Manager.install(port: 41830, helperPath: Self.helperPath, settingsPath: settingsPath)

        XCTAssertEqual(outcome, .installed(port: 41830))
        XCTAssertEqual(try modificationDate(of: settingsPath), fixed)
        XCTAssertEqual(try read(settingsPath), before)
    }

    func test_remove_withNothingToRemove_doesNotTouchTheModificationTime() throws {
        try write(Self.userContent, to: settingsPath)
        let fixed = Date(timeIntervalSince1970: 1_000_000_000)
        try FileManager.default.setAttributes([.modificationDate: fixed], ofItemAtPath: settingsPath)
        XCTAssertEqual(try Manager.remove(settingsPath: settingsPath), .removed)
        XCTAssertEqual(try modificationDate(of: settingsPath), fixed)
    }

    // MARK: - Blocked / errors

    func test_install_blocked_leavesTheFileByteIdentical() throws {
        try write(Self.foreignContent, to: settingsPath)
        let fixed = Date(timeIntervalSince1970: 1_000_000_000)
        try FileManager.default.setAttributes([.modificationDate: fixed], ofItemAtPath: settingsPath)

        let outcome = try Manager.install(port: 41830, helperPath: Self.helperPath, settingsPath: settingsPath)

        XCTAssertEqual(outcome, .blocked(keys: ["OTEL_EXPORTER_OTLP_METRICS_ENDPOINT"]))
        XCTAssertEqual(try read(settingsPath), Data(Self.foreignContent.utf8))
        XCTAssertEqual(try modificationDate(of: settingsPath), fixed)
    }

    func test_remove_onAForeignFile_leavesItByteIdentical() throws {
        try write(Self.foreignContent, to: settingsPath)
        XCTAssertEqual(try Manager.remove(settingsPath: settingsPath), .removed)
        XCTAssertEqual(try read(settingsPath), Data(Self.foreignContent.utf8))
    }

    func test_install_invalidJSON_throws_andLeavesTheFileByteIdentical() throws {
        let broken = "{\n  \"model\": \"opus\",\n"
        try write(broken, to: settingsPath)
        XCTAssertThrowsError(try Manager.install(port: 41830, helperPath: Self.helperPath, settingsPath: settingsPath)) { error in
            XCTAssertEqual(error as? ConfigFileError, .invalidJSON)
        }
        XCTAssertEqual(try read(settingsPath), Data(broken.utf8))
    }

    func test_remove_invalidJSON_throws_andLeavesTheFileByteIdentical() throws {
        let broken = "{\n  \"model\": \"opus\",\n"
        try write(broken, to: settingsPath)
        XCTAssertThrowsError(try Manager.remove(settingsPath: settingsPath)) { error in
            XCTAssertEqual(error as? ConfigFileError, .invalidJSON)
        }
        XCTAssertEqual(try read(settingsPath), Data(broken.utf8))
    }

    func test_installAndRemove_whitespaceCommentOrTrailingComma_throwInvalidJSON_andLeaveTheFileByteIdentical() throws {
        for content in ["  \n\t", "{\n  // comment\n  \"a\": 1\n}\n", "{\"a\": 1,}"] {
            try write(content, to: settingsPath)
            XCTAssertThrowsError(try Manager.install(port: 41830, helperPath: Self.helperPath, settingsPath: settingsPath)) { error in
                XCTAssertEqual(error as? ConfigFileError, .invalidJSON, content.debugDescription)
            }
            XCTAssertThrowsError(try Manager.remove(settingsPath: settingsPath)) { error in
                XCTAssertEqual(error as? ConfigFileError, .invalidJSON, content.debugDescription)
            }
            XCTAssertEqual(try read(settingsPath), Data(content.utf8), content.debugDescription)
        }
    }

    func test_install_nonObjectEnv_throwsTypeConflict_andLeavesTheFileByteIdentical() throws {
        let content = "{\"env\": \"x\"}"
        try write(content, to: settingsPath)
        XCTAssertThrowsError(try Manager.install(port: 41830, helperPath: Self.helperPath, settingsPath: settingsPath)) { error in
            guard case .typeConflict(let key)? = error as? JSONConfigDocumentEditor.EditorError else {
                return XCTFail("expected typeConflict, got \(error)")
            }
            XCTAssertEqual(key, "env")
        }
        XCTAssertEqual(try read(settingsPath), Data(content.utf8))
    }

    // MARK: - state(settingsPath:)

    func test_state_isAbsent_forAMissingFile() throws {
        XCTAssertEqual(try Manager.state(settingsPath: settingsPath), .absent)
    }

    func test_state_isInstalled_afterInstall() throws {
        _ = try Manager.install(port: 41830, helperPath: Self.helperPath, settingsPath: settingsPath)
        XCTAssertEqual(try Manager.state(settingsPath: settingsPath), .installed(port: 41830))
    }

    func test_state_isForeign_forAForeignFile() throws {
        try write(Self.foreignContent, to: settingsPath)
        XCTAssertEqual(try Manager.state(settingsPath: settingsPath), .foreign(keys: ["OTEL_EXPORTER_OTLP_METRICS_ENDPOINT"]))
    }

    func test_state_readsThroughASymbolicLink() throws {
        let target = try makeDotfilesLink()
        try write(Self.foreignContent, to: target)
        XCTAssertEqual(try Manager.state(settingsPath: settingsPath), .foreign(keys: ["OTEL_EXPORTER_OTLP_METRICS_ENDPOINT"]))
    }

    // MARK: - G5: helper form and legacy replacement

    private func helper(in path: String) throws -> String? {
        let object = try JSONSerialization.jsonObject(with: try read(path))
        return (object as? [String: Any])?["otelHeadersHelper"] as? String
    }

    func test_install_writesTheHelperPathAndPort() throws {
        _ = try Manager.install(port: 41830, helperPath: Self.helperPath, settingsPath: settingsPath)
        XCTAssertEqual(try helper(in: settingsPath), "\"/tmp/calyx-test/bin/calyx-usage-headers\" 41830")
    }

    func test_install_withAnotherPort_rewritesEndpointAndHelper() throws {
        _ = try Manager.install(port: 41830, helperPath: Self.helperPath, settingsPath: settingsPath)
        let outcome = try Manager.install(port: 41831, helperPath: Self.helperPath, settingsPath: settingsPath)
        XCTAssertEqual(outcome, .installed(port: 41831))
        XCTAssertEqual(try endpoint(in: settingsPath), "http://127.0.0.1:41831/usage/v1/metrics")
        XCTAssertEqual(try helper(in: settingsPath), "\"/tmp/calyx-test/bin/calyx-usage-headers\" 41831")
    }

    func test_install_overALegacyInstall_replacesTheHelper_andRemoveRestoresTheUsersBytes() throws {
        try write(Self.userContent, to: settingsPath)
        // Build a legacy install by hand: the block plus the pre-G5 cat helper.
        _ = try Manager.install(port: 41830, helperPath: Self.helperPath, settingsPath: settingsPath)
        let legacy = "cat '/tmp/calyx-test/usage-otel-headers.json' 2>/dev/null || printf '{}'"
        let current = try read(settingsPath)
        let legacyDoc = try JSONConfigDocumentEditor.setValue(
            Data(("\"" + legacy + "\"").utf8), at: ["otelHeadersHelper"], in: current)
        try XCTUnwrap(legacyDoc).write(to: URL(fileURLWithPath: settingsPath))
        XCTAssertEqual(try Manager.state(settingsPath: settingsPath), .installed(port: 41830))

        XCTAssertEqual(try Manager.install(port: 41830, helperPath: Self.helperPath, settingsPath: settingsPath),
                       .installed(port: 41830))
        XCTAssertEqual(try helper(in: settingsPath), "\"/tmp/calyx-test/bin/calyx-usage-headers\" 41830")

        XCTAssertEqual(try Manager.remove(settingsPath: settingsPath), .removed)
        XCTAssertEqual(String(decoding: try read(settingsPath), as: UTF8.self), Self.userContent)
    }
}
