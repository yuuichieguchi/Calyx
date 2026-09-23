//
//  GrokConfigManagerTests.swift
//  CalyxTests
//
//  Coverage for GrokConfigManager, which owns the
//  `[mcp_servers.calyx-ipc]` entry in `~/.grok/config.toml`.
//
//  Grok's remote-MCP shape differs from Codex's in two ways this suite
//  pins: headers live in a `[mcp_servers.calyx-ipc.headers]` sub-table
//  rather than an inline `http_headers` value, and Grok expands
//  `${VAR}` / `${VAR:-default}` inside every `[mcp_servers.*]` string
//  field at load time, so the surface and session identities are written
//  as `${CALYX_SURFACE_ID:-}` / `${CALYX_SESSION_ID:-}` literals rather
//  than through Codex's separate `env_http_headers` mapping table.
//
//  The takeover test replicates the exact unmarked entry an earlier
//  hand-run experiment leaves on a real machine: same section header,
//  same sub-table, same four header keys, no Calyx ownership marker.
//  Adoption has to be idempotent, or every enable would stack another
//  copy of the entry.
//
//  Every token here is a dummy composed at runtime; no test writes a
//  contiguous secret-shaped literal, and no test touches the real
//  ~/.grok.
//

import XCTest
@testable import Calyx

final class GrokConfigManagerTests: XCTestCase {

    // MARK: - Properties

    private var tempDir: String!
    private var configPath: String!

    /// A credential-shaped dummy assembled at runtime so no contiguous
    /// secret-format literal is ever committed.
    private let dummyToken = "AIza" + String(repeating: "A", count: 35)
    private let priorDummyToken = "AIza" + String(repeating: "B", count: 35)

    // MARK: - Lifecycle

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).path
        try! FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        configPath = tempDir + "/config.toml"
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: tempDir)
        tempDir = nil
        configPath = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func writeConfig(_ content: String) {
        FileManager.default.createFile(atPath: configPath, contents: Data(content.utf8))
    }

    private func readConfig() -> String {
        (try? String(contentsOfFile: configPath, encoding: .utf8)) ?? ""
    }

    private func occurrences(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }

    // MARK: - enableIPC: managed shape

    func test_enableIPC_writesSectionHeadersSubTableAndEnvInterpolatedIdentities() throws {
        try GrokConfigManager.enableIPC(port: 41830, token: dummyToken, configPath: configPath)

        let content = readConfig()
        XCTAssertTrue(content.contains("[mcp_servers.calyx-ipc]"),
                      "Grok reads remote MCP servers from [mcp_servers.<name>]")
        XCTAssertTrue(content.contains("url = \"http://127.0.0.1:41830/mcp\""),
                      "The endpoint must be the loopback MCP path on the server's live port")
        XCTAssertTrue(content.contains("[mcp_servers.calyx-ipc.headers]"),
                      "Grok's static request headers live in a headers sub-table, not an inline " +
                      "http_headers value")
        XCTAssertTrue(content.contains("Authorization = \"Bearer \(dummyToken)\""))
        XCTAssertTrue(content.contains("X-Calyx-Agent-Kind = \"grok\""),
                      "The kind header is what makes initialize create a Grok row rather than " +
                      "defaulting the connection to claude-code")
        XCTAssertTrue(content.contains("X-Calyx-Surface-ID = \"${CALYX_SURFACE_ID:-}\""),
                      "Grok expands ${VAR:-default} in header values at load time, so the surface " +
                      "identity is interpolated rather than baked in at write time")
        XCTAssertTrue(content.contains("X-Calyx-Session-ID = \"${CALYX_SESSION_ID:-}\""),
                      "A persistent pane's calyx-session ID outlives its surface UUID, and the server " +
                      "resolves X-Calyx-Session-ID first")
    }

    func test_enableIPC_preservesUnrelatedContent() throws {
        writeConfig("""
        [compat.claude]
        hooks = true

        [mcp_servers.other]
        url = "http://localhost:9999/mcp"

        [[hooks.PreToolUse]]
        matcher = "Bash"
        hooks = [{ type = "command", command = "/opt/guard/check.sh", timeout = 10 }]
        """)

        try GrokConfigManager.enableIPC(port: 41830, token: dummyToken, configPath: configPath)

        let content = readConfig()
        XCTAssertTrue(content.contains("[compat.claude]"))
        XCTAssertTrue(content.contains("hooks = true"))
        XCTAssertTrue(content.contains("[mcp_servers.other]"))
        XCTAssertTrue(content.contains("http://localhost:9999/mcp"))
        XCTAssertTrue(content.contains("[[hooks.PreToolUse]]"),
                      "A user's own config-file hooks are array-of-tables entries and must survive")
        XCTAssertTrue(content.contains("command = \"/opt/guard/check.sh\""))
        XCTAssertTrue(content.contains("[mcp_servers.calyx-ipc]"))
    }

    // MARK: - Adoption of an unmarked pre-existing entry

    func test_enableIPC_adoptsUnmarkedExistingEntry_withoutDuplicating() throws {
        // The exact shape a prior hand-run experiment leaves behind: no
        // Calyx marker, already in the managed layout, stale port/token.
        writeConfig("""
        [compat.claude]
        hooks = true

        [mcp_servers.calyx-ipc]
        url = "http://127.0.0.1:40000/mcp"

        [mcp_servers.calyx-ipc.headers]
        Authorization = "Bearer \(priorDummyToken)"
        X-Calyx-Surface-ID = "${CALYX_SURFACE_ID:-}"
        X-Calyx-Session-ID = "${CALYX_SESSION_ID:-}"
        X-Calyx-Agent-Kind = "grok"
        """)

        try GrokConfigManager.enableIPC(port: 41830, token: dummyToken, configPath: configPath)

        let content = readConfig()
        XCTAssertEqual(occurrences(of: "[mcp_servers.calyx-ipc]", in: content), 1,
                       "An unmarked pre-existing entry must be adopted and rewritten, never duplicated: " +
                       "two entries of the same name would leave Grok connecting on a dead port")
        XCTAssertEqual(occurrences(of: "[mcp_servers.calyx-ipc.headers]", in: content), 1,
                       "The headers sub-table belongs to the entry and must be replaced with it, not " +
                       "left behind as an orphan alongside the new one")
        XCTAssertFalse(content.contains(priorDummyToken),
                       "The stale bearer token must not survive the rewrite")
        XCTAssertFalse(content.contains("http://127.0.0.1:40000/mcp"),
                       "The stale port must not survive the rewrite")
        XCTAssertTrue(content.contains("url = \"http://127.0.0.1:41830/mcp\""))
        XCTAssertTrue(content.contains("Authorization = \"Bearer \(dummyToken)\""))
        XCTAssertTrue(content.contains("[compat.claude]"), "Unrelated content still survives adoption")
    }

    func test_enableIPC_runTwice_leavesExactlyOneEntry() throws {
        try GrokConfigManager.enableIPC(port: 41830, token: priorDummyToken, configPath: configPath)
        try GrokConfigManager.enableIPC(port: 41831, token: dummyToken, configPath: configPath)

        let content = readConfig()
        XCTAssertEqual(occurrences(of: "[mcp_servers.calyx-ipc]", in: content), 1,
                       "Re-enabling (a port or token rotation) rewrites the entry in place")
        XCTAssertEqual(occurrences(of: "[mcp_servers.calyx-ipc.headers]", in: content), 1)
        XCTAssertFalse(content.contains(priorDummyToken), "The rotated-out token must be gone")
        XCTAssertTrue(content.contains("url = \"http://127.0.0.1:41831/mcp\""))
    }

    // MARK: - A sub-table that does not sit next to its parent

    /// TOML lets `[mcp_servers.calyx-ipc.headers]` sit anywhere in the
    /// file, so a hand-written entry can separate it from its own
    /// `[mcp_servers.calyx-ipc]` parent. A sub-table left behind on that
    /// layout is not a cosmetic leftover: the fresh entry appends a
    /// second `[mcp_servers.calyx-ipc.headers]`, defining one TOML table
    /// twice, which is a parse error. Grok then fails to load the whole
    /// config file, losing every other MCP server and every [ui]/[cli]
    /// setting in it.
    func test_enableIPC_subTableSeparatedFromParent_leavesOneHeadersTable() throws {
        writeConfig("""
        [mcp_servers.calyx-ipc]
        url = "http://127.0.0.1:40000/mcp"

        [ui]
        theme = "dark"

        [mcp_servers.calyx-ipc.headers]
        Authorization = "Bearer \(priorDummyToken)"
        X-Calyx-Agent-Kind = "grok"
        """)

        try GrokConfigManager.enableIPC(port: 41830, token: dummyToken, configPath: configPath)

        let content = readConfig()
        XCTAssertEqual(occurrences(of: "[mcp_servers.calyx-ipc.headers]", in: content), 1,
                       "A second definition of the same table is a TOML parse error, so the detached " +
                       "sub-table must be removed with its entry rather than appended to")
        XCTAssertEqual(occurrences(of: "[mcp_servers.calyx-ipc]", in: content), 1)
        XCTAssertFalse(content.contains(priorDummyToken),
                       "The stale bearer token in the detached sub-table must not survive the rewrite")
        XCTAssertTrue(content.contains("Authorization = \"Bearer \(dummyToken)\""))
        XCTAssertTrue(content.contains("[ui]"),
                      "The unrelated table between the parent and its sub-table must survive")
        XCTAssertTrue(content.contains("theme = \"dark\""),
                      "Only the calyx-ipc entry is removed, never the body of the table between them")
    }

    func test_disableIPC_subTableSeparatedFromParent_removesItAndItsToken() throws {
        writeConfig("""
        [mcp_servers.calyx-ipc]
        url = "http://127.0.0.1:41830/mcp"

        [mcp_servers.other]
        url = "http://localhost:9999/mcp"

        [mcp_servers.calyx-ipc.headers]
        Authorization = "Bearer \(dummyToken)"
        X-Calyx-Agent-Kind = "grok"
        """)

        try GrokConfigManager.disableIPC(configPath: configPath)

        let content = readConfig()
        XCTAssertFalse(content.contains("[mcp_servers.calyx-ipc]"))
        XCTAssertFalse(content.contains("[mcp_servers.calyx-ipc.headers]"),
                       "The sub-table belongs to the entry wherever it sits in the file")
        XCTAssertFalse(content.contains(dummyToken),
                       "A bearer token left behind in a disabled config is a live credential in a file " +
                       "the user believes is clean")
        XCTAssertTrue(content.contains("[mcp_servers.other]"))
        XCTAssertTrue(content.contains("http://localhost:9999/mcp"),
                      "The table sitting between the entry and its sub-table keeps its own body")
    }

    // MARK: - Directory guard

    func test_enableIPC_parentDirectoryMissing_throwsDirectoryNotFound() {
        let badPath = tempDir + "/nonexistent/config.toml"

        XCTAssertThrowsError(
            try GrokConfigManager.enableIPC(port: 41830, token: dummyToken, configPath: badPath),
            "Grok not being installed must never make Calyx create ~/.grok on the user's behalf"
        ) { error in
            guard let configError = error as? GrokConfigError, case .directoryNotFound = configError else {
                XCTFail("Expected GrokConfigError.directoryNotFound, got \(error)")
                return
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: badPath))
    }

    // MARK: - disableIPC

    func test_disableIPC_removesEntryAndItsHeadersSubTable_preservingNeighbours() throws {
        writeConfig("""
        [mcp_servers.other]
        url = "http://localhost:9999/mcp"

        [mcp_servers.calyx-ipc]
        url = "http://127.0.0.1:41830/mcp"

        [mcp_servers.calyx-ipc.headers]
        Authorization = "Bearer \(dummyToken)"
        X-Calyx-Agent-Kind = "grok"

        [[hooks.Stop]]
        hooks = [{ type = "command", command = "/opt/guard/stop.sh" }]
        """)

        try GrokConfigManager.disableIPC(configPath: configPath)

        let content = readConfig()
        XCTAssertFalse(content.contains("[mcp_servers.calyx-ipc]"))
        XCTAssertFalse(content.contains("[mcp_servers.calyx-ipc.headers]"),
                       "The sub-table is part of the entry, so it must go with it")
        XCTAssertFalse(content.contains(dummyToken),
                       "A bearer token left behind in a disabled config is a live credential in a file " +
                       "the user believes is clean")
        XCTAssertTrue(content.contains("[mcp_servers.other]"))
        XCTAssertTrue(content.contains("http://localhost:9999/mcp"))
        XCTAssertTrue(content.contains("[[hooks.Stop]]"),
                      "An array-of-tables header ends the calyx-ipc entry and must survive removal")
    }

    func test_disableIPC_noFile_isNoOpAndCreatesNothing() {
        XCTAssertNoThrow(try GrokConfigManager.disableIPC(configPath: configPath))
        XCTAssertFalse(FileManager.default.fileExists(atPath: configPath))
    }

    // MARK: - Never delete a user-owned file

    func test_disableIPC_afterEnable_onUserCreatedEmptyFile_leavesFilePresentAndEmpty() throws {
        FileManager.default.createFile(atPath: configPath, contents: Data())
        XCTAssertTrue(FileManager.default.fileExists(atPath: configPath), "precondition: empty file exists")

        try GrokConfigManager.enableIPC(port: 41830, token: dummyToken, configPath: configPath)
        try GrokConfigManager.disableIPC(configPath: configPath)

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: configPath),
            "a file the user created must never be deleted by Calyx, even once it became entirely Calyx's own region"
        )
        let data = try Data(contentsOf: URL(fileURLWithPath: configPath))
        XCTAssertEqual(data, Data(), "the file must be left behind empty, not with a leftover blank line or deleted")
    }

    func test_disableIPC_onAbsentFile_leavesFileAbsent() throws {
        XCTAssertFalse(FileManager.default.fileExists(atPath: configPath))
        try GrokConfigManager.disableIPC(configPath: configPath)
        XCTAssertFalse(FileManager.default.fileExists(atPath: configPath), "disableIPC must never create a file that never existed")
    }

    // MARK: - isIPCEnabled

    func test_isIPCEnabled_trueOnlyWhenSectionPresent() throws {
        writeConfig("[compat.claude]\nhooks = true\n")
        XCTAssertFalse(GrokConfigManager.isIPCEnabled(configPath: configPath))

        try GrokConfigManager.enableIPC(port: 41830, token: dummyToken, configPath: configPath)
        XCTAssertTrue(GrokConfigManager.isIPCEnabled(configPath: configPath))

        try GrokConfigManager.disableIPC(configPath: configPath)
        XCTAssertFalse(GrokConfigManager.isIPCEnabled(configPath: configPath))
    }

    func test_isIPCEnabled_noFile_returnsFalse() {
        XCTAssertFalse(GrokConfigManager.isIPCEnabled(configPath: configPath))
    }

    // MARK: - Symlinked config (dotfiles setups)

    func test_enableIPC_writesThroughSymlinkAndKeepsLinkIntact() throws {
        let realFile = tempDir + "/dotfiles-config.toml"
        FileManager.default.createFile(atPath: realFile, contents: Data("".utf8))
        try FileManager.default.createSymbolicLink(atPath: configPath, withDestinationPath: realFile)

        try GrokConfigManager.enableIPC(port: 41830, token: dummyToken, configPath: configPath)

        let realContent = try String(contentsOfFile: realFile, encoding: .utf8)
        XCTAssertTrue(realContent.contains("[mcp_servers.calyx-ipc]"),
                      "A dotfiles-managed config.toml is commonly a symlink into a repo; the write must " +
                      "follow it rather than replacing the link with a regular file")
        let attributes = try FileManager.default.attributesOfItem(atPath: configPath)
        XCTAssertEqual(attributes[.type] as? FileAttributeType, .typeSymbolicLink)
    }
}
