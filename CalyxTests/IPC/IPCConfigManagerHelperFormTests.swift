//
//  IPCConfigManagerHelperFormTests.swift
//  CalyxTests
//
//  Slice 4b wiring in `IPCConfigManager` (C-D17, spec notes 3 and 6):
//  - enableIPC installs `calyx-mcp-headers` (0755) into
//    `AgentHookScript.defaultInstallDirectory` and hands its path to
//    Claude Code and Codex; disableIPC removes it.
//  - Slice 4c: Claude/Codex get the helper COMMAND `"<path>" <port>`, and
//    Grok's bearer file is `<defaultDirectory>/calyx-bearer-token-<port>`.
//  - Grok gets `bearer_token_file = <that path>` only when the given version supports
//    it (>= 1.0.52); older or unknown keeps the baked-in Authorization.
//  - A helper install failure falls back to the baked-in form for Claude
//    and Codex without adding a result axis or failing one.
//
//  Runs against the default paths, which lie beneath
//  `CalyxPathRoot.testRoot` in the unit-test host (refuses otherwise).
//  Pre-existing state at those paths is moved aside and restored, as in
//  `AgentHooksCoordinatorWakeScriptTests`. `grokVersion` is always passed
//  explicitly so no real `grok` runs.
//

import XCTest
@testable import Calyx

final class IPCConfigManagerHelperFormTests: XCTestCase {

    private struct UnsafeEnvironment: Error, CustomStringConvertible { let description: String }

    private var claudeDirectory: String!
    private var claudeConfigPath: String!
    private var codexDirectory: String!
    private var grokDirectory: String!
    private var installDirectory: String!
    private var helperPath: String!
    private var ownsCreatedPaths = false
    private var movedAside: [String: String] = [:]
    private var asideDirectory: String?

    private let secret = String(repeating: "5e", count: 32)

    override func setUpWithError() throws {
        try super.setUpWithError()
        let root = try XCTUnwrap(CalyxPathRoot.testRoot, "CalyxPathRoot.testRoot must be set in the unit-test host")
        claudeDirectory = AgentToolPaths.claudeConfigDirectory
        claudeConfigPath = AgentToolPaths.claudeConfigPath
        codexDirectory = AgentToolPaths.codexConfigDirectory
        grokDirectory = AgentToolPaths.grokConfigDirectory
        installDirectory = AgentHookScript.defaultInstallDirectory
        helperPath = (installDirectory as NSString).appendingPathComponent("calyx-mcp-headers")
        let others = [AgentToolPaths.openCodeConfigDirectory, AgentToolPaths.hermesConfigDirectory]
        let all = [claudeDirectory!, claudeConfigPath!, codexDirectory!, grokDirectory!, installDirectory!] + others
        for path in all + [AgentEndpointFile.defaultDirectory] where !path.hasPrefix(root + "/") {
            throw UnsafeEnvironment(description: "\(path) does not lie beneath the test root \(root)")
        }
        let fm = FileManager.default
        movedAside = [:]
        asideDirectory = nil
        for (index, path) in all.enumerated() where fm.fileExists(atPath: path) {
            if asideDirectory == nil {
                let aside = root + "/IPCConfigManagerHelperFormTests-aside-" + UUID().uuidString
                try fm.createDirectory(atPath: aside, withIntermediateDirectories: true)
                asideDirectory = aside
            }
            let destination = asideDirectory! + "/\(index)"
            try fm.moveItem(atPath: path, toPath: destination)
            movedAside[path] = destination
        }
        ownsCreatedPaths = true
        for dir in [claudeDirectory!, codexDirectory!, grokDirectory!] {
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
    }

    override func tearDown() {
        if ownsCreatedPaths {
            let fm = FileManager.default
            for path in [claudeDirectory!, claudeConfigPath!, codexDirectory!, grokDirectory!, installDirectory!] {
                try? fm.removeItem(atPath: path)
            }
            for (original, aside) in movedAside {
                try? fm.removeItem(atPath: original)
                try? fm.moveItem(atPath: aside, toPath: original)
            }
            if let asideDirectory { try? fm.removeItem(atPath: asideDirectory) }
        }
        movedAside = [:]
        asideDirectory = nil
        ownsCreatedPaths = false
        super.tearDown()
    }

    // MARK: - Helpers

    private func read(_ path: String) -> String { (try? String(contentsOfFile: path, encoding: .utf8)) ?? "" }
    private var codexConfig: String { read(codexDirectory + "/config.toml") }
    private var grokConfig: String { read(grokDirectory + "/config.toml") }

    private func claudeEntries() throws -> (ipc: [String: Any], mcp: [String: Any]) {
        let data = try XCTUnwrap(FileManager.default.contents(atPath: claudeConfigPath))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let servers = try XCTUnwrap(json["mcpServers"] as? [String: Any])
        return (try XCTUnwrap(servers["calyx-ipc"] as? [String: Any]), try XCTUnwrap(servers["calyx-mcp"] as? [String: Any]))
    }

    private func isSuccess(_ status: ConfigStatus) -> Bool {
        if case .success = status { return true }
        return false
    }

    private var expectedBearerPath: String {
        expectedBearerPath(port: 41830)
    }

    /// Slice 4c: spelled from the spec (`calyx-bearer-token-<port>` beside
    /// agent-endpoint.json), not from production.
    private func expectedBearerPath(port: Int) -> String {
        AgentEndpointFile.defaultDirectory + "/calyx-bearer-token-\(port)"
    }

    // MARK: - Grok version gate

    func test_grok_1_0_52_getsBearerFile() throws {
        let result = IPCConfigManager.enableIPC(port: 41830, token: secret,
                                                grokVersion: GrokCLIVersion(major: 1, minor: 0, patch: 52))
        XCTAssertTrue(isSuccess(result.grok))
        let text = grokConfig
        XCTAssertEqual(text.components(separatedBy: #"bearer_token_file = ""# + expectedBearerPath + #"""#).count - 1, 2,
                       "both tables carry the bearer file path")
        XCTAssertFalse(text.contains("Authorization"))
        XCTAssertFalse(text.contains(secret))
    }

    func test_grok_1_0_51_keepsBakedInAuthorization() throws {
        let result = IPCConfigManager.enableIPC(port: 41830, token: secret,
                                                grokVersion: GrokCLIVersion(major: 1, minor: 0, patch: 51))
        XCTAssertTrue(isSuccess(result.grok))
        XCTAssertEqual(grokConfig.components(separatedBy: #"Authorization = "Bearer "# + secret + #"""#).count - 1, 2)
        XCTAssertFalse(grokConfig.contains("bearer_token_file"))
    }

    func test_grok_unknownVersion_keepsBakedInAuthorization() throws {
        let result = IPCConfigManager.enableIPC(port: 41830, token: secret, grokVersion: nil)
        XCTAssertTrue(isSuccess(result.grok))
        XCTAssertEqual(grokConfig.components(separatedBy: #"Authorization = "Bearer "# + secret + #"""#).count - 1, 2)
        XCTAssertFalse(grokConfig.contains("bearer_token_file"))
    }

    // MARK: - Helper script

    func test_enable_installsHelper_andClaudeAndCodexReferenceIt() throws {
        let result = IPCConfigManager.enableIPC(port: 41830, token: secret, grokVersion: nil)
        XCTAssertTrue(isSuccess(result.claudeCode))
        XCTAssertTrue(isSuccess(result.codex))

        XCTAssertEqual(FileManager.default.contents(atPath: helperPath), Data(MCPHeadersHelperScript.scriptBody.utf8))
        let attrs = try FileManager.default.attributesOfItem(atPath: helperPath)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o755)

        let quoted = "\"" + helperPath + "\" 41830"
        let entries = try claudeEntries()
        XCTAssertEqual(entries.ipc["headersHelper"] as? String, quoted)
        XCTAssertEqual(entries.mcp["headersHelper"] as? String, quoted)
        XCTAssertNil((entries.ipc["headers"] as? [String: String])?["Authorization"])
        XCTAssertNil((entries.mcp["headers"] as? [String: String])?["Authorization"])

        let codexLine = #"http_headers_helper = "\""# + helperPath + #"\" 41830""#
        XCTAssertEqual(codexConfig.components(separatedBy: codexLine).count - 1, 2)
        XCTAssertFalse(codexConfig.contains("Authorization"))
    }

    func test_disable_removesHelper_andAllConfigs() throws {
        _ = IPCConfigManager.enableIPC(port: 41830, token: secret, grokVersion: GrokCLIVersion(major: 1, minor: 0, patch: 52))
        XCTAssertTrue(FileManager.default.fileExists(atPath: helperPath), "precondition")
        let result = IPCConfigManager.disableIPC()
        XCTAssertTrue(isSuccess(result.claudeCode))
        XCTAssertTrue(isSuccess(result.codex))
        XCTAssertTrue(isSuccess(result.grok))
        XCTAssertFalse(FileManager.default.fileExists(atPath: helperPath))
        let enabled = IPCConfigManager.isIPCEnabled()
        XCTAssertFalse(enabled.claudeCode)
        XCTAssertFalse(enabled.codex)
        XCTAssertFalse(enabled.grok)
    }

    func test_helperInstallFailure_fallsBackToBakedIn_andAxesStillSucceed() throws {
        try FileManager.default.createDirectory(atPath: (installDirectory as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        try Data("not a directory".utf8).write(to: URL(fileURLWithPath: installDirectory))

        let result = IPCConfigManager.enableIPC(port: 41830, token: secret, grokVersion: nil)
        XCTAssertTrue(isSuccess(result.claudeCode), "install failure adds no failure to the Claude axis")
        XCTAssertTrue(isSuccess(result.codex), "install failure adds no failure to the Codex axis")

        let entries = try claudeEntries()
        XCTAssertNil(entries.ipc["headersHelper"])
        XCTAssertNil(entries.mcp["headersHelper"])
        XCTAssertEqual((entries.ipc["headers"] as? [String: String])?["Authorization"], "Bearer " + secret)
        XCTAssertEqual((entries.mcp["headers"] as? [String: String])?["Authorization"], "Bearer " + secret)
        XCTAssertFalse(codexConfig.contains("http_headers_helper"))
        XCTAssertEqual(codexConfig.components(separatedBy: #""Authorization" = "Bearer "# + secret + #"""#).count - 1, 2)
    }

    // MARK: - Port binding (slice 4c)

    func test_enable_onAnotherPort_bindsEveryHelperFormToThatPort() throws {
        let result = IPCConfigManager.enableIPC(port: 41837, token: secret,
                                                grokVersion: GrokCLIVersion(major: 1, minor: 0, patch: 52))
        XCTAssertTrue(isSuccess(result.claudeCode))
        XCTAssertTrue(isSuccess(result.codex))
        XCTAssertTrue(isSuccess(result.grok))

        let command = "\"" + helperPath + "\" 41837"
        let entries = try claudeEntries()
        XCTAssertEqual(entries.ipc["headersHelper"] as? String, command)
        XCTAssertEqual(entries.mcp["headersHelper"] as? String, command)

        XCTAssertEqual(codexConfig.components(
            separatedBy: #"http_headers_helper = "\""# + helperPath + #"\" 41837""#).count - 1, 2)

        let grokLine = #"bearer_token_file = ""# + expectedBearerPath(port: 41837) + #"""#
        XCTAssertEqual(grokConfig.components(separatedBy: grokLine).count - 1, 2,
                       "Grok's bearer file is named for the port: \(grokConfig)")
        XCTAssertTrue(expectedBearerPath(port: 41837).hasSuffix("/calyx-bearer-token-41837"))
    }
}
