//
//  AgentHookScriptTests.swift
//  CalyxTests
//
//  TDD Red Phase for AgentHookScript / AgentEndpointFile: the
//  calyx-agent-hook script body invariants, its 0755 installation, and the
//  0600 agent-endpoint.json port/token file it reads on every invocation.
//
//  Coverage:
//  - scriptBody guards on CALYX_SURFACE_ID being unset, always exits 0,
//    posts stdin verbatim via curl -m 2 --data-binary, sends the
//    X-Calyx-Surface-ID header, and reads agent-endpoint.json
//  - install(toDirectory:) writes the script at 0755 with scriptBody's
//    exact content
//  - AgentEndpointFile.write creates a 0600 JSON file with port/token
//  - AgentEndpointFile.remove deletes it
//

import XCTest
@testable import Calyx

final class AgentHookScriptTests: XCTestCase {

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
        tempDir = nil
        super.tearDown()
    }

    // MARK: - scriptBody invariants

    func test_scriptBody_exitsEarlyWhenSurfaceIDUnset() {
        let body = AgentHookScript.scriptBody

        XCTAssertTrue(body.contains("CALYX_SURFACE_ID"),
                     "Script must reference CALYX_SURFACE_ID")
        XCTAssertTrue(body.contains("exit 0"),
                     "Script must exit 0 when CALYX_SURFACE_ID is unset (external terminals unaffected)")
    }

    func test_scriptBody_terminatesWithExitZero() {
        let trimmed = AgentHookScript.scriptBody.trimmingCharacters(in: .whitespacesAndNewlines)

        XCTAssertTrue(trimmed.hasSuffix("exit 0"),
                     "Script must always terminate with exit 0 so a failed POST never breaks the hook chain")
    }

    func test_scriptBody_usesCurlWithTwoSecondTimeout() {
        let body = AgentHookScript.scriptBody

        XCTAssertTrue(body.contains("curl"), "Script must use curl to POST the event")
        XCTAssertTrue(body.contains("-m 2"), "curl must be bounded to a 2 second timeout")
    }

    func test_scriptBody_forwardsStdinAsRequestBody() {
        XCTAssertTrue(AgentHookScript.scriptBody.contains("--data-binary"),
                     "Script must forward the hook's stdin JSON verbatim via --data-binary")
    }

    func test_scriptBody_sendsSurfaceIDHeader() {
        XCTAssertTrue(AgentHookScript.scriptBody.contains("X-Calyx-Surface-ID"),
                     "Script must send the X-Calyx-Surface-ID header")
    }

    func test_scriptBody_referencesAgentEndpointFile() {
        XCTAssertTrue(AgentHookScript.scriptBody.contains("agent-endpoint.json"),
                     "Script must read port/token from agent-endpoint.json on every invocation")
    }

    // MARK: - install()

    func test_install_writesExecutableScriptWith0755Permissions() throws {
        let scriptPath = try AgentHookScript.install(toDirectory: tempDir)

        XCTAssertTrue(FileManager.default.fileExists(atPath: scriptPath),
                     "install() must write the script to the returned path")
        XCTAssertTrue(scriptPath.hasPrefix(tempDir),
                     "install() must place the script inside the given directory")

        let attrs = try FileManager.default.attributesOfItem(atPath: scriptPath)
        let permissions = (attrs[.posixPermissions] as? NSNumber)?.uint16Value
        XCTAssertEqual(permissions, 0o755, "Installed script must be executable (0755)")

        let content = try String(contentsOfFile: scriptPath, encoding: .utf8)
        XCTAssertEqual(content, AgentHookScript.scriptBody,
                       "Installed script content must match scriptBody")
    }

    // MARK: - AgentEndpointFile

    func test_agentEndpointFile_write_createsFileWithPortTokenAnd0600Permissions() throws {
        try AgentEndpointFile.write(port: 41830, token: "test-token-abc", directory: tempDir)

        let filePath = tempDir + "/agent-endpoint.json"
        XCTAssertTrue(FileManager.default.fileExists(atPath: filePath),
                     "write() must create agent-endpoint.json in the given directory")

        let attrs = try FileManager.default.attributesOfItem(atPath: filePath)
        let permissions = (attrs[.posixPermissions] as? NSNumber)?.uint16Value
        XCTAssertEqual(permissions, 0o600, "agent-endpoint.json must be 0600")

        let data = try Data(contentsOf: URL(fileURLWithPath: filePath))
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(json?["port"] as? Int, 41830)
        XCTAssertEqual(json?["token"] as? String, "test-token-abc")
    }

    func test_agentEndpointFile_write_isAtomicAndLeavesNoTempFile() throws {
        // Regression: write() must go through ConfigFileUtils.atomicWrite
        // (temp file + rename) rather than a direct Data.write, so a
        // concurrent reader (calyx-agent-hook, invoked from every active
        // pane's hooks) never observes a partially-written file, and a
        // re-write doesn't leave a stray `.tmp` sibling behind.
        try AgentEndpointFile.write(port: 41830, token: "token-one", directory: tempDir)
        try AgentEndpointFile.write(port: 41831, token: "token-two", directory: tempDir)

        let filePath = tempDir + "/agent-endpoint.json"
        let data = try Data(contentsOf: URL(fileURLWithPath: filePath))
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(json?["port"] as? Int, 41831, "The second write must fully replace the first")
        XCTAssertEqual(json?["token"] as? String, "token-two")

        XCTAssertFalse(FileManager.default.fileExists(atPath: filePath + ".tmp"),
                       "atomicWrite must not leave a .tmp file behind after renaming")
    }

    func test_agentEndpointFile_remove_deletesFile() throws {
        try AgentEndpointFile.write(port: 41830, token: "test-token-abc", directory: tempDir)
        let filePath = tempDir + "/agent-endpoint.json"
        XCTAssertTrue(FileManager.default.fileExists(atPath: filePath),
                     "Precondition: file must exist before remove")

        AgentEndpointFile.remove(directory: tempDir)

        XCTAssertFalse(FileManager.default.fileExists(atPath: filePath),
                       "remove() must delete agent-endpoint.json")
    }
}
