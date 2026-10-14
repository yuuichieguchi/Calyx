//
//  UsageTelemetryProductionEffectsTests.swift
//  CalyxTests
//
//  G5 (spec note 24, 挙動 2 / テストの強さ 3): the production install and
//  remove bodies, run against a per-test temporary bin directory and
//  settings file (never ~/.claude, never the real bin directory).
//  - install: `calyx-usage-headers` is installed (0755), then the
//    settings file gets the block with the new-form helper and the port.
//  - remove: the settings block is removed, then the script.
//  - a failed script install throws and leaves no Calyx block, even when
//    a legacy `cat` block was there before.
//

import XCTest
@testable import Calyx

final class UsageTelemetryProductionEffectsTests: XCTestCase {

    private typealias Manager = ClaudeUsageTelemetryConfigManager

    private var tempDir = ""
    private var binDir = ""
    private var settingsPath = ""
    private var scriptPath: String { binDir + "/calyx-usage-headers" }

    private static let userContent = "{\n  \"model\": \"opus\"\n}\n"

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("UsageTelemetryProductionEffects-" + UUID().uuidString).path
        binDir = tempDir + "/bin"
        let claudeDir = tempDir + "/.claude"
        settingsPath = claudeDir + "/settings.json"
        try FileManager.default.createDirectory(atPath: claudeDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if !tempDir.isEmpty {
            try? FileManager.default.removeItem(atPath: tempDir)
        }
        try super.tearDownWithError()
    }

    private func read(_ path: String) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: path))
    }

    private func helper() throws -> String? {
        let object = try JSONSerialization.jsonObject(with: try read(settingsPath))
        return (object as? [String: Any])?["otelHeadersHelper"] as? String
    }

    private func mode(of path: String) throws -> Int {
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        return try XCTUnwrap(attrs[.posixPermissions] as? NSNumber).intValue & 0o777
    }

    func test_install_installsTheScript_thenTheConfigWithItsPathAndThePort() throws {
        let outcome = try UsageTelemetryActivation.productionInstall(
            port: 41830, binDirectory: binDir, settingsPath: settingsPath)

        XCTAssertEqual(outcome, .installed(port: 41830))
        XCTAssertEqual(FileManager.default.contents(atPath: scriptPath), Data(UsageHeadersHelperScript.scriptBody.utf8))
        XCTAssertEqual(try mode(of: scriptPath), 0o755)
        XCTAssertEqual(try helper(), "\"\(scriptPath)\" 41830")
        XCTAssertEqual(try Manager.state(settingsPath: settingsPath), .installed(port: 41830))
    }

    func test_remove_removesTheBlock_andTheScript() throws {
        try Data(Self.userContent.utf8).write(to: URL(fileURLWithPath: settingsPath))
        _ = try UsageTelemetryActivation.productionInstall(port: 41830, binDirectory: binDir, settingsPath: settingsPath)

        let outcome = try UsageTelemetryActivation.productionRemove(binDirectory: binDir, settingsPath: settingsPath)

        XCTAssertEqual(outcome, .removed)
        XCTAssertEqual(String(decoding: try read(settingsPath), as: UTF8.self), Self.userContent)
        XCTAssertFalse(FileManager.default.fileExists(atPath: scriptPath))
    }

    func test_remove_whenTheConfigCannotBeRemoved_throws_andKeepsTheScript() throws {
        _ = try UsageTelemetryActivation.productionInstall(port: 41830, binDirectory: binDir, settingsPath: settingsPath)
        try Data("not json".utf8).write(to: URL(fileURLWithPath: settingsPath))

        XCTAssertThrowsError(try UsageTelemetryActivation.productionRemove(binDirectory: binDir, settingsPath: settingsPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: scriptPath), "the script goes only after the config")
    }

    func test_failedScriptInstall_throws_andLeavesNoCalyxBlock() throws {
        try Data(Self.userContent.utf8).write(to: URL(fileURLWithPath: settingsPath))
        // A previous install with another port, then the bin path becomes a regular file.
        _ = try UsageTelemetryActivation.productionInstall(port: 41829, binDirectory: binDir, settingsPath: settingsPath)
        try FileManager.default.removeItem(atPath: binDir)
        try Data("x".utf8).write(to: URL(fileURLWithPath: binDir))

        XCTAssertThrowsError(try UsageTelemetryActivation.productionInstall(
            port: 41830, binDirectory: binDir, settingsPath: settingsPath))

        XCTAssertEqual(try Manager.state(settingsPath: settingsPath), .absent)
        XCTAssertEqual(String(decoding: try read(settingsPath), as: UTF8.self), Self.userContent)
    }

    func test_failedScriptInstall_removesALegacyCatBlock() throws {
        try Data(Self.userContent.utf8).write(to: URL(fileURLWithPath: settingsPath))
        // Build a legacy install: the block plus the pre-G5 cat helper.
        _ = try Manager.install(port: 41829, helperPath: "/tmp/calyx-test/bin/calyx-usage-headers", settingsPath: settingsPath)
        let legacy = "cat '/tmp/calyx-test/usage-otel-headers.json' 2>/dev/null || printf '{}'"
        let legacyDoc = try JSONConfigDocumentEditor.setValue(
            Data(("\"" + legacy + "\"").utf8), at: ["otelHeadersHelper"], in: try read(settingsPath))
        try XCTUnwrap(legacyDoc).write(to: URL(fileURLWithPath: settingsPath))
        XCTAssertEqual(try helper(), legacy)
        XCTAssertEqual(try Manager.state(settingsPath: settingsPath), .installed(port: 41829))
        try Data("x".utf8).write(to: URL(fileURLWithPath: binDir))

        XCTAssertThrowsError(try UsageTelemetryActivation.productionInstall(
            port: 41830, binDirectory: binDir, settingsPath: settingsPath))

        XCTAssertEqual(try Manager.state(settingsPath: settingsPath), .absent)
        XCTAssertNil(try helper())
        XCTAssertEqual(String(decoding: try read(settingsPath), as: UTF8.self), Self.userContent)
    }
}
