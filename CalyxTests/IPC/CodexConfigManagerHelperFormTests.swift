//
//  CodexConfigManagerHelperFormTests.swift
//  CalyxTests
//
//  C-D17 / spec note 5 / V3-3: with a helper path, both Codex tables carry
//  `http_headers_helper = "\"<path>\""` and `http_headers` keeps only
//  `X-Calyx-Agent-Kind` (an explicit Authorization there would win over the
//  helper); `env_http_headers` unchanged. nil keeps today's form.
//

import XCTest
@testable import Calyx

final class CodexConfigManagerHelperFormTests: XCTestCase {

    private var tempDir: String!
    private var configPath: String!
    private let helperPath = "/Users/u/Library/Application Support/Calyx/bin/calyx-mcp-headers"
    private let secret = String(repeating: "7c", count: 32)

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

    private func enableHelper(token: String? = nil) throws {
        try CodexConfigManager.enableIPC(port: 41830, token: token ?? secret, headersHelperPath: helperPath, configPath: configPath)
    }

    private var helperLine: String { #"http_headers_helper = "\""# + helperPath + #"\"""# }

    func test_helperForm_calyxIPCTable_exactLines() throws {
        try enableHelper()
        XCTAssertEqual(tomlSectionLines("[mcp_servers.calyx-ipc]", in: read(configPath)), [
            #"url = "http://127.0.0.1:41830/mcp""#,
            helperLine,
            #"http_headers = { "X-Calyx-Agent-Kind" = "codex" }"#,
            #"env_http_headers = { "X-Calyx-Surface-ID" = "CALYX_SURFACE_ID", "X-Calyx-Session-ID" = "CALYX_SESSION_ID" }"#,
        ])
    }

    func test_helperForm_calyxMCPTable_exactLines() throws {
        try enableHelper()
        XCTAssertEqual(tomlSectionLines("[mcp_servers.calyx-mcp]", in: read(configPath)), [
            #"url = "http://127.0.0.1:41830/calyx-mcp""#,
            helperLine,
            #"http_headers = { "X-Calyx-Agent-Kind" = "codex" }"#,
            #"env_http_headers = { "X-Calyx-Surface-ID" = "CALYX_SURFACE_ID", "X-Calyx-Session-ID" = "CALYX_SESSION_ID", "X-Calyx-Herdr-Pane-ID" = "HERDR_PANE_ID", "X-Calyx-Herdr-Socket-Path" = "HERDR_SOCKET_PATH" }"#,
        ])
    }

    func test_helperForm_noAuthorizationOrTokenAnywhere() throws {
        try enableHelper()
        let text = read(configPath)
        XCTAssertFalse(text.contains("Authorization"))
        XCTAssertFalse(text.contains(secret))
    }

    func test_helperForm_reEnable_isByteIdentical_evenWithANewToken() throws {
        try enableHelper()
        let first = read(configPath)
        try enableHelper()
        XCTAssertEqual(read(configPath), first)
        try enableHelper(token: String(repeating: "2b", count: 32))
        XCTAssertEqual(read(configPath), first)
    }

    func test_nil_isByteIdenticalToTodaysForm() throws {
        let seed = "model = \"x\"\n\n[other]\nk = 1\n"
        let todayPath = tempDir + "/today.toml"
        try Data(seed.utf8).write(to: URL(fileURLWithPath: todayPath))
        try Data(seed.utf8).write(to: URL(fileURLWithPath: configPath))
        try CodexConfigManager.enableIPC(port: 41830, token: secret, configPath: todayPath)
        try CodexConfigManager.enableIPC(port: 41830, token: secret, headersHelperPath: nil, configPath: configPath)
        XCTAssertEqual(read(configPath), read(todayPath))
        XCTAssertFalse(read(configPath).contains("http_headers_helper"))
    }

    func test_helperForm_preservesForeignContent_andDetection() throws {
        let seed = "model = \"x\"\n\n[other]\nk = 1\n"
        try Data(seed.utf8).write(to: URL(fileURLWithPath: configPath))
        try enableHelper()
        XCTAssertTrue(CodexConfigManager.isIPCEnabled(configPath: configPath))
        try CodexConfigManager.disableIPC(configPath: configPath)
        XCTAssertFalse(CodexConfigManager.isIPCEnabled(configPath: configPath))
        XCTAssertEqual(read(configPath), seed)
    }
}
