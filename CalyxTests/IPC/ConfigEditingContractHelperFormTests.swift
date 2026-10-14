//
//  ConfigEditingContractHelperFormTests.swift
//  CalyxTests
//
//  The L1 editing contract of `ConfigEditingContractTests` (bytes outside
//  Calyx's owned region survive enable -> disable; no extra file left;
//  detection agrees with disable) applied to the slice-4b forms: Claude
//  `headersHelper`, Codex `http_headers_helper`, Grok `bearer_token_file`.
//  Slice 4c: the helper value carries the port (`"\"<path>\" <port>"`) and
//  the Grok bearer file is `calyx-bearer-token-<port>`.
//  A separate class because the original's driver is private to its file
//  and these calls need the new parameters.
//

import XCTest
@testable import Calyx

final class ConfigEditingContractHelperFormTests: XCTestCase {

    private var tempDir: String!
    private let helperPath = "/opt/calyx dir/bin/calyx-mcp-headers"
    private let bearerPath = "/opt/calyx dir/calyx-bearer-token-41830"

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        try! FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: tempDir)
        super.tearDown()
    }

    private let jsonFixtures: [String] = [
        "{\n  \"zebra\": 1,\n  \"apple\": 2,\n  \"other\": {\n    \"nested\": true\n  }\n}\n",
        "{\r\n  \"other\": \"a\\tb\"\r\n}\r\n",
        "{\n    \"other\": [1, 2, 3]\n}",
        "{\n  \"mcpServers\": {\n    \"mine\": {\"type\": \"http\"}\n  },\n  \"other\": 1\n}\n",
    ]

    private let tomlFixtures: [String] = [
        "# user comment\nmodel = \"x\"\n\n[profiles.a]\nk = 1\n",
        "model = \"x\"\r\n\r\n[other]\r\nk = 1\r\n",
        "[mcp_servers.mine]\nurl = \"http://example\"\n\n\n",
    ]

    private func roundTrip(
        _ label: String, fixture: String, file name: String,
        enable: (String) throws -> Void, disable: (String) throws -> Void, detect: (String) -> Bool,
        line: UInt = #line
    ) throws {
        let root = tempDir + "/" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let path = root + "/" + name
        try Data(fixture.utf8).write(to: URL(fileURLWithPath: path))
        try enable(path)
        XCTAssertTrue(detect(path), "\(label): detected after enable", line: line)
        try disable(path)
        XCTAssertFalse(detect(path), "\(label): not detected after disable", line: line)
        XCTAssertEqual(String(decoding: FileManager.default.contents(atPath: path) ?? Data(), as: UTF8.self), fixture,
                       "\(label): bytes outside the owned region survive", line: line)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root), [name],
                       "\(label): no extra file", line: line)
    }

    func test_claudeHelperForm_preservesBytes_andDetectionAgrees() throws {
        for (i, fixture) in jsonFixtures.enumerated() {
            try roundTrip("Claude #\(i)", fixture: fixture, file: "claude.json",
                          enable: { try ClaudeConfigManager.enableIPC(port: 41830, token: "contract-x", headersHelperPath: self.helperPath, configPath: $0) },
                          disable: { try ClaudeConfigManager.disableIPC(configPath: $0) },
                          detect: { ClaudeConfigManager.isIPCEnabled(configPath: $0) })
        }
    }

    func test_codexHelperForm_preservesBytes_andDetectionAgrees() throws {
        for (i, fixture) in tomlFixtures.enumerated() {
            try roundTrip("Codex #\(i)", fixture: fixture, file: "config.toml",
                          enable: { try CodexConfigManager.enableIPC(port: 41830, token: "contract-x", headersHelperPath: self.helperPath, configPath: $0) },
                          disable: { try CodexConfigManager.disableIPC(configPath: $0) },
                          detect: { CodexConfigManager.isIPCEnabled(configPath: $0) })
        }
    }

    func test_grokBearerFileForm_preservesBytes_andDetectionAgrees() throws {
        for (i, fixture) in tomlFixtures.enumerated() {
            try roundTrip("Grok #\(i)", fixture: fixture, file: "config.toml",
                          enable: { try GrokConfigManager.enableIPC(port: 41830, token: "contract-x", bearerTokenFilePath: self.bearerPath, configPath: $0) },
                          disable: { try GrokConfigManager.disableIPC(configPath: $0) },
                          detect: { GrokConfigManager.isIPCEnabled(configPath: $0) })
        }
    }

    func test_switchingForms_thenDisable_preservesBytes() throws {
        let fixture = jsonFixtures[0]
        try roundTrip("Claude baked-in -> helper", fixture: fixture, file: "claude.json",
                      enable: {
                          try ClaudeConfigManager.enableIPC(port: 41830, token: "contract-x", headersHelperPath: nil, configPath: $0)
                          try ClaudeConfigManager.enableIPC(port: 41830, token: "contract-x", headersHelperPath: self.helperPath, configPath: $0)
                      },
                      disable: { try ClaudeConfigManager.disableIPC(configPath: $0) },
                      detect: { ClaudeConfigManager.isIPCEnabled(configPath: $0) })
        try roundTrip("Codex baked-in -> helper", fixture: tomlFixtures[0], file: "config.toml",
                      enable: {
                          try CodexConfigManager.enableIPC(port: 41830, token: "contract-x", headersHelperPath: nil, configPath: $0)
                          try CodexConfigManager.enableIPC(port: 41830, token: "contract-x", headersHelperPath: self.helperPath, configPath: $0)
                      },
                      disable: { try CodexConfigManager.disableIPC(configPath: $0) },
                      detect: { CodexConfigManager.isIPCEnabled(configPath: $0) })
        try roundTrip("Grok baked-in -> file", fixture: tomlFixtures[0], file: "config.toml",
                      enable: {
                          try GrokConfigManager.enableIPC(port: 41830, token: "contract-x", bearerTokenFilePath: nil, configPath: $0)
                          try GrokConfigManager.enableIPC(port: 41830, token: "contract-x", bearerTokenFilePath: self.bearerPath, configPath: $0)
                      },
                      disable: { try GrokConfigManager.disableIPC(configPath: $0) },
                      detect: { GrokConfigManager.isIPCEnabled(configPath: $0) })
    }

    func test_helperForms_carryThePortArgument() throws {
        let claude = tempDir + "/claude.json"
        try ClaudeConfigManager.enableIPC(port: 41830, token: "contract-x", headersHelperPath: helperPath, configPath: claude)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: FileManager.default.contents(atPath: claude) ?? Data()) as? [String: Any])
        let servers = try XCTUnwrap(json["mcpServers"] as? [String: [String: Any]])
        for name in ["calyx-ipc", "calyx-mcp"] {
            XCTAssertEqual(servers[name]?["headersHelper"] as? String, "\"" + helperPath + "\" 41830", name)
        }
        let codex = tempDir + "/config.toml"
        try CodexConfigManager.enableIPC(port: 41830, token: "contract-x", headersHelperPath: helperPath, configPath: codex)
        let codexText = (try? String(contentsOfFile: codex, encoding: .utf8)) ?? ""
        XCTAssertEqual(codexText.components(separatedBy: #"http_headers_helper = "\""# + helperPath + #"\" 41830""#).count - 1, 2)
    }
}
