//
//  ClaudeConfigManagerHelperFormTests.swift
//  CalyxTests
//
//  J6 / C-D3: with a headers-helper path, both `~/.claude.json` entries
//  carry `"headersHelper": "\"<path>\" <port>"` (shell-quoted path, a
//  space, the configured port: slice 4c binds the fetched token to that
//  port) and no `Authorization` header; the other headers are unchanged.
//  `headersHelperPath: nil` must produce today's baked-in bytes exactly.
//  Kept apart from `ClaudeConfigManagerTests` so that class still compiles
//  before the new parameter exists.
//

import XCTest
@testable import Calyx

final class ClaudeConfigManagerHelperFormTests: XCTestCase {

    private var tempDir: String!
    private var configPath: String!
    private let helperPath = "/Users/u/Library/Application Support/Calyx/bin/calyx-mcp-headers"
    private let secret = String(repeating: "9f", count: 32)

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        try! FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        configPath = tempDir + "/claude.json"
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: tempDir)
        super.tearDown()
    }

    private func bytes(_ path: String) -> Data { FileManager.default.contents(atPath: path) ?? Data() }

    private func entries(_ path: String) throws -> (ipc: NSDictionary, mcp: NSDictionary) {
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: bytes(path)) as? [String: Any])
        let servers = try XCTUnwrap(json["mcpServers"] as? [String: Any])
        return (try XCTUnwrap(servers["calyx-ipc"] as? NSDictionary), try XCTUnwrap(servers["calyx-mcp"] as? NSDictionary))
    }

    func test_helperForm_calyxIPCEntry_exactContent() throws {
        try ClaudeConfigManager.enableIPC(port: 41830, token: secret, headersHelperPath: helperPath, configPath: configPath)
        let expected: NSDictionary = [
            "type": "http",
            "url": "http://127.0.0.1:41830/mcp",
            "headersHelper": "\"" + helperPath + "\" 41830",
            "headers": [
                "X-Calyx-Surface-ID": "${CALYX_SURFACE_ID:-}",
                "X-Calyx-Session-ID": "${CALYX_SESSION_ID:-}",
            ],
        ]
        XCTAssertEqual(try entries(configPath).ipc, expected)
    }

    func test_helperForm_calyxMCPEntry_exactContent() throws {
        try ClaudeConfigManager.enableIPC(port: 41830, token: secret, headersHelperPath: helperPath, configPath: configPath)
        let expected: NSDictionary = [
            "type": "http",
            "url": "http://127.0.0.1:41830/calyx-mcp",
            "headersHelper": "\"" + helperPath + "\" 41830",
            "headers": [
                "X-Calyx-Surface-ID": "${CALYX_SURFACE_ID:-}",
                "X-Calyx-Session-ID": "${CALYX_SESSION_ID:-}",
                "X-Calyx-Herdr-Pane-ID": "${HERDR_PANE_ID:-}",
                "X-Calyx-Herdr-Socket-Path": "${HERDR_SOCKET_PATH:-}",
            ],
        ]
        XCTAssertEqual(try entries(configPath).mcp, expected)
    }

    func test_helperForm_fileNeverContainsTheToken() throws {
        try ClaudeConfigManager.enableIPC(port: 41830, token: secret, headersHelperPath: helperPath, configPath: configPath)
        let text = String(decoding: bytes(configPath), as: UTF8.self)
        XCTAssertFalse(text.contains(secret))
        XCTAssertFalse(text.contains("Authorization"))
    }

    func test_helperForm_keysAreSorted() throws {
        try ClaudeConfigManager.enableIPC(port: 41830, token: secret, headersHelperPath: helperPath, configPath: configPath)
        let text = String(decoding: bytes(configPath), as: UTF8.self)
        for entryKey in ["\"calyx-ipc\"", "\"calyx-mcp\""] {
            let start = try XCTUnwrap(text.range(of: entryKey)).upperBound
            let tail = String(text[start...])
            let order = ["\"headers\"", "\"headersHelper\"", "\"type\"", "\"url\""]
                .map { tail.range(of: $0)?.lowerBound }
            let found = order.compactMap { $0 }
            XCTAssertEqual(found.count, 4, entryKey)
            XCTAssertEqual(found, found.sorted(), "\(entryKey): keys in sorted order")
        }
    }

    func test_helperForm_reEnable_isByteIdentical() throws {
        try ClaudeConfigManager.enableIPC(port: 41830, token: secret, headersHelperPath: helperPath, configPath: configPath)
        let first = bytes(configPath)
        try ClaudeConfigManager.enableIPC(port: 41830, token: secret, headersHelperPath: helperPath, configPath: configPath)
        XCTAssertEqual(bytes(configPath), first)
    }

    func test_helperForm_ignoresTokenChanges() throws {
        try ClaudeConfigManager.enableIPC(port: 41830, token: secret, headersHelperPath: helperPath, configPath: configPath)
        let first = bytes(configPath)
        try ClaudeConfigManager.enableIPC(port: 41830, token: String(repeating: "1a", count: 32),
                                          headersHelperPath: helperPath, configPath: configPath)
        XCTAssertEqual(bytes(configPath), first, "a rotated token no longer changes ~/.claude.json")
    }

    func test_nil_isByteIdenticalToTodaysForm() throws {
        let seed = "{\n  \"zebra\": 1,\n  \"mcpServers\": {\n    \"other\": {\"type\": \"http\"}\n  }\n}\n"
        let todayPath = tempDir + "/today.json"
        try Data(seed.utf8).write(to: URL(fileURLWithPath: todayPath))
        try Data(seed.utf8).write(to: URL(fileURLWithPath: configPath))
        try ClaudeConfigManager.enableIPC(port: 41830, token: secret, configPath: todayPath)
        try ClaudeConfigManager.enableIPC(port: 41830, token: secret, headersHelperPath: nil, configPath: configPath)
        XCTAssertEqual(bytes(configPath), bytes(todayPath))
        XCTAssertEqual((try entries(configPath).ipc["headers"] as? [String: String])?["Authorization"], "Bearer " + secret)
    }

    func test_switchingFromBakedInToHelper_dropsAuthorization_andBack() throws {
        try ClaudeConfigManager.enableIPC(port: 41830, token: secret, headersHelperPath: nil, configPath: configPath)
        try ClaudeConfigManager.enableIPC(port: 41830, token: secret, headersHelperPath: helperPath, configPath: configPath)
        XCTAssertNil((try entries(configPath).ipc["headers"] as? [String: String])?["Authorization"])
        try ClaudeConfigManager.enableIPC(port: 41830, token: secret, headersHelperPath: nil, configPath: configPath)
        let e = try entries(configPath)
        XCTAssertNil(e.ipc["headersHelper"])
        XCTAssertNil(e.mcp["headersHelper"])
        XCTAssertEqual((e.ipc["headers"] as? [String: String])?["Authorization"], "Bearer " + secret)
    }

    func test_helperForm_detectedAsEnabled_andDisableRemovesBoth() throws {
        try ClaudeConfigManager.enableIPC(port: 41830, token: secret, headersHelperPath: helperPath, configPath: configPath)
        XCTAssertTrue(ClaudeConfigManager.isIPCEnabled(configPath: configPath))
        try ClaudeConfigManager.disableIPC(configPath: configPath)
        XCTAssertFalse(ClaudeConfigManager.isIPCEnabled(configPath: configPath))
        let text = String(decoding: bytes(configPath), as: UTF8.self)
        XCTAssertFalse(text.contains("calyx-ipc"))
        XCTAssertFalse(text.contains("calyx-mcp"))
    }

    // MARK: - Port argument (slice 4c)

    func test_helperForm_commandCarriesTheConfiguredPort() throws {
        try ClaudeConfigManager.enableIPC(port: 41831, token: secret, headersHelperPath: helperPath, configPath: configPath)
        let e = try entries(configPath)
        XCTAssertEqual(e.ipc["headersHelper"] as? String, "\"" + helperPath + "\" 41831")
        XCTAssertEqual(e.mcp["headersHelper"] as? String, "\"" + helperPath + "\" 41831")
    }

    func test_helperForm_portChange_rewritesTheCommand() throws {
        try ClaudeConfigManager.enableIPC(port: 41830, token: secret, headersHelperPath: helperPath, configPath: configPath)
        try ClaudeConfigManager.enableIPC(port: 41832, token: secret, headersHelperPath: helperPath, configPath: configPath)
        XCTAssertEqual(try entries(configPath).ipc["headersHelper"] as? String, "\"" + helperPath + "\" 41832")
    }
}
