//
//  MCPHeadersHelperCommandTests.swift
//  CalyxTests
//
//  Slice 4c (spec note 18): `MCPHeadersHelperScript.helperCommand(path:port:)`
//  is the single source of the command Claude Code (`headersHelper`) and
//  Codex (`http_headers_helper`) run: the double-quoted path, one space,
//  the port. Kept apart from `MCPHeadersHelperScriptTests` so that class
//  compiles before the API exists.
//

import XCTest
@testable import Calyx

final class MCPHeadersHelperCommandTests: XCTestCase {

    func test_helperCommand_isQuotedPathSpacePort() {
        XCTAssertEqual(MCPHeadersHelperScript.helperCommand(path: "/Users/u/Library/Application Support/Calyx/bin/calyx-mcp-headers",
                                                            port: 41830),
                       "\"/Users/u/Library/Application Support/Calyx/bin/calyx-mcp-headers\" 41830")
    }

    func test_helperCommand_otherPort() {
        XCTAssertEqual(MCPHeadersHelperScript.helperCommand(path: "/a/b", port: 1), "\"/a/b\" 1")
    }

    func test_claudeEntry_usesHelperCommand() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let config = dir + "/claude.json"
        let path = "/opt/calyx dir/bin/calyx-mcp-headers"
        try ClaudeConfigManager.enableIPC(port: 41834, token: String(repeating: "aa", count: 32),
                                          headersHelperPath: path, configPath: config)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: FileManager.default.contents(atPath: config) ?? Data()) as? [String: Any])
        let servers = try XCTUnwrap(json["mcpServers"] as? [String: [String: Any]])
        XCTAssertEqual(servers["calyx-ipc"]?["headersHelper"] as? String,
                       MCPHeadersHelperScript.helperCommand(path: path, port: 41834))
    }
}
