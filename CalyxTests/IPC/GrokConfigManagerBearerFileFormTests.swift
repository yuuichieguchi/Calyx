//
//  GrokConfigManagerBearerFileFormTests.swift
//  CalyxTests
//
//  C-D17 / spec note 6: with a bearer-file path, each
//  `[mcp_servers.<name>]` table carries `bearer_token_file = "<abs path>"`
//  (plain, not shell-quoted) and its headers sub-table has no
//  Authorization line; other header lines unchanged; 0600 still enforced.
//  nil keeps today's form.
//

import XCTest
@testable import Calyx

final class GrokConfigManagerBearerFileFormTests: XCTestCase {

    private var tempDir: String!
    private var configPath: String!
    private let filePath = "/Users/u/Library/Application Support/Calyx/calyx-bearer-token"
    private let secret = "AIza" + String(repeating: "C", count: 35)

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        try! FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        configPath = tempDir + "/config.toml"
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: tempDir)
        super.tearDown()
    }

    private func read(_ path: String) -> String { (try? String(contentsOfFile: path, encoding: .utf8)) ?? "" }

    private func enableFile(token: String? = nil) throws {
        try GrokConfigManager.enableIPC(port: 41830, token: token ?? secret, bearerTokenFilePath: filePath, configPath: configPath)
    }

    func test_fileForm_calyxIPC_tables_exactLines() throws {
        try enableFile()
        let text = read(configPath)
        XCTAssertEqual(tomlSectionLines("[mcp_servers.calyx-ipc]", in: text), [
            #"url = "http://127.0.0.1:41830/mcp""#,
            #"bearer_token_file = ""# + filePath + #"""#,
        ])
        XCTAssertEqual(tomlSectionLines("[mcp_servers.calyx-ipc.headers]", in: text), [
            #"X-Calyx-Agent-Kind = "grok""#,
            #"X-Calyx-Session-ID = "${CALYX_SESSION_ID:-}""#,
            #"X-Calyx-Surface-ID = "${CALYX_SURFACE_ID:-}""#,
        ])
    }

    func test_fileForm_calyxMCP_tables_exactLines() throws {
        try enableFile()
        let text = read(configPath)
        XCTAssertEqual(tomlSectionLines("[mcp_servers.calyx-mcp]", in: text), [
            #"url = "http://127.0.0.1:41830/calyx-mcp""#,
            #"bearer_token_file = ""# + filePath + #"""#,
        ])
        XCTAssertEqual(tomlSectionLines("[mcp_servers.calyx-mcp.headers]", in: text), [
            #"X-Calyx-Agent-Kind = "grok""#,
            #"X-Calyx-Session-ID = "${CALYX_SESSION_ID:-}""#,
            #"X-Calyx-Surface-ID = "${CALYX_SURFACE_ID:-}""#,
            #"X-Calyx-Herdr-Pane-ID = "${HERDR_PANE_ID:-}""#,
            #"X-Calyx-Herdr-Socket-Path = "${HERDR_SOCKET_PATH:-}""#,
        ])
    }

    func test_fileForm_noAuthorizationOrTokenAnywhere() throws {
        try enableFile()
        XCTAssertFalse(read(configPath).contains("Authorization"))
        XCTAssertFalse(read(configPath).contains(secret))
    }

    func test_fileForm_reEnable_isByteIdentical_evenWithANewToken() throws {
        try enableFile()
        let first = read(configPath)
        try enableFile(token: "AIza" + String(repeating: "D", count: 35))
        XCTAssertEqual(read(configPath), first)
    }

    func test_fileForm_enforces0600() throws {
        try Data("[other]\nk = 1\n".utf8).write(to: URL(fileURLWithPath: configPath))
        chmod(configPath, 0o644)
        try enableFile()
        let attrs = try FileManager.default.attributesOfItem(atPath: configPath)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func test_nil_isByteIdenticalToTodaysForm() throws {
        let seed = "[other]\nk = 1\n"
        let todayPath = tempDir + "/today.toml"
        try Data(seed.utf8).write(to: URL(fileURLWithPath: todayPath))
        try Data(seed.utf8).write(to: URL(fileURLWithPath: configPath))
        try GrokConfigManager.enableIPC(port: 41830, token: secret, configPath: todayPath)
        try GrokConfigManager.enableIPC(port: 41830, token: secret, bearerTokenFilePath: nil, configPath: configPath)
        XCTAssertEqual(read(configPath), read(todayPath))
        XCTAssertFalse(read(configPath).contains("bearer_token_file"))
    }

    func test_fileForm_detection_andRoundTrip() throws {
        let seed = "[other]\nk = 1\n"
        try Data(seed.utf8).write(to: URL(fileURLWithPath: configPath))
        try enableFile()
        XCTAssertTrue(GrokConfigManager.isIPCEnabled(configPath: configPath))
        try GrokConfigManager.disableIPC(configPath: configPath)
        XCTAssertFalse(GrokConfigManager.isIPCEnabled(configPath: configPath))
        XCTAssertEqual(read(configPath), seed)
    }
}
