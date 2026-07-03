import XCTest
@testable import Calyx

final class ClaudeConfigManagerTests: XCTestCase {

    // MARK: - Properties

    private var tempDir: String!
    private var configPath: String!

    // MARK: - Lifecycle

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).path
        try! FileManager.default.createDirectory(
            atPath: tempDir,
            withIntermediateDirectories: true
        )
        configPath = tempDir + "/claude.json"
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: tempDir)
        super.tearDown()
    }

    // MARK: - Helpers

    /// Write raw string content to the config file.
    private func writeConfig(_ content: String) {
        FileManager.default.createFile(
            atPath: configPath,
            contents: Data(content.utf8)
        )
    }

    /// Read config file and parse as JSON dictionary.
    private func readConfigDict() throws -> [String: Any] {
        let data = try Data(contentsOf: URL(fileURLWithPath: configPath))
        let obj = try JSONSerialization.jsonObject(with: data)
        return obj as! [String: Any]
    }

    // MARK: - enableIPC

    func test_enableIPC_createsConfigFromScratch() throws {
        // Given: no config file exists
        XCTAssertFalse(FileManager.default.fileExists(atPath: configPath))

        // When: enableIPC is called
        try ClaudeConfigManager.enableIPC(port: 41830, token: "abc123", configPath: configPath)

        // Then: file is created with correct calyx-ipc entry
        let dict = try readConfigDict()
        let mcpServers = dict["mcpServers"] as? [String: Any]
        XCTAssertNotNil(mcpServers, "mcpServers key should exist")

        let calyxIPC = mcpServers?["calyx-ipc"] as? [String: Any]
        XCTAssertNotNil(calyxIPC, "calyx-ipc entry should exist")
        XCTAssertEqual(calyxIPC?["type"] as? String, "http")
        XCTAssertEqual(calyxIPC?["url"] as? String, "http://127.0.0.1:41830/mcp")

        let headers = calyxIPC?["headers"] as? [String: String]
        XCTAssertEqual(headers?["Authorization"], "Bearer abc123")
    }

    func test_enableIPC_addsToExistingConfig() throws {
        // Given: config already has another MCP server
        let existingJSON = """
        {
            "mcpServers": {
                "other-server": {
                    "type": "http",
                    "url": "http://localhost:9999/mcp"
                }
            }
        }
        """
        writeConfig(existingJSON)

        // When: enableIPC is called
        try ClaudeConfigManager.enableIPC(port: 41830, token: "tok1", configPath: configPath)

        // Then: calyx-ipc is added, other-server is preserved
        let dict = try readConfigDict()
        let mcpServers = dict["mcpServers"] as? [String: Any]
        XCTAssertNotNil(mcpServers?["calyx-ipc"], "calyx-ipc should be added")
        XCTAssertNotNil(mcpServers?["other-server"], "other-server should be preserved")
    }

    func test_enableIPC_updatesExistingEntry() throws {
        // Given: calyx-ipc already exists with old token
        let existingJSON = """
        {
            "mcpServers": {
                "calyx-ipc": {
                    "type": "http",
                    "url": "http://localhost:40000/mcp",
                    "headers": {
                        "Authorization": "Bearer old-token"
                    }
                }
            }
        }
        """
        writeConfig(existingJSON)

        // When: enableIPC is called with new port and token
        try ClaudeConfigManager.enableIPC(port: 55555, token: "new-token", configPath: configPath)

        // Then: calyx-ipc is updated with new values
        let dict = try readConfigDict()
        let mcpServers = dict["mcpServers"] as? [String: Any]
        let calyxIPC = mcpServers?["calyx-ipc"] as? [String: Any]
        XCTAssertEqual(calyxIPC?["url"] as? String, "http://127.0.0.1:55555/mcp")

        let headers = calyxIPC?["headers"] as? [String: String]
        XCTAssertEqual(headers?["Authorization"], "Bearer new-token")
    }

    func test_enableIPC_invalidJSON_throws() {
        // Given: file contains invalid JSON
        writeConfig("this is not json {{{")

        // When/Then: enableIPC should throw
        XCTAssertThrowsError(
            try ClaudeConfigManager.enableIPC(port: 41830, token: "tok", configPath: configPath)
        ) { error in
            // Should not silently overwrite the file
            let content = try? String(contentsOfFile: self.configPath, encoding: .utf8)
            XCTAssertEqual(content, "this is not json {{{",
                           "Invalid JSON file should not be overwritten")
        }
    }

    func test_enableIPC_createsBackup() throws {
        // Given: existing valid config
        let existingJSON = """
        {
            "mcpServers": {}
        }
        """
        writeConfig(existingJSON)

        // When: enableIPC is called
        try ClaudeConfigManager.enableIPC(port: 41830, token: "tok", configPath: configPath)

        // Then: a .bak file should exist with the original content
        let bakPath = configPath + ".bak"
        XCTAssertTrue(FileManager.default.fileExists(atPath: bakPath),
                      "Backup file should be created before modification")

        let bakContent = try String(contentsOfFile: bakPath, encoding: .utf8)
        // The backup should contain the original JSON (before modification)
        XCTAssertTrue(bakContent.contains("\"mcpServers\""),
                      "Backup should contain original config content")
        XCTAssertFalse(bakContent.contains("calyx-ipc"),
                       "Backup should not contain the newly added calyx-ipc entry")
    }

    func test_enableIPC_preservesOtherKeys() throws {
        // Given: config has other top-level keys
        let existingJSON = """
        {
            "permissions": {
                "allow": ["read", "write"]
            },
            "colors": {
                "theme": "dark"
            },
            "mcpServers": {}
        }
        """
        writeConfig(existingJSON)

        // When: enableIPC is called
        try ClaudeConfigManager.enableIPC(port: 41830, token: "tok", configPath: configPath)

        // Then: all other keys are preserved
        let dict = try readConfigDict()
        let permissions = dict["permissions"] as? [String: Any]
        XCTAssertNotNil(permissions, "permissions key should be preserved")
        let allow = permissions?["allow"] as? [String]
        XCTAssertEqual(allow, ["read", "write"], "permissions.allow should be preserved")

        let colors = dict["colors"] as? [String: Any]
        XCTAssertEqual(colors?["theme"] as? String, "dark", "colors.theme should be preserved")

        // And calyx-ipc should be added
        let mcpServers = dict["mcpServers"] as? [String: Any]
        XCTAssertNotNil(mcpServers?["calyx-ipc"], "calyx-ipc should be added")
    }

    func test_enableIPC_correctURLFormat() throws {
        // Given/When
        try ClaudeConfigManager.enableIPC(port: 12345, token: "t", configPath: configPath)

        // Then: URL format is http://localhost:{port}/mcp
        let dict = try readConfigDict()
        let mcpServers = dict["mcpServers"] as? [String: Any]
        let calyxIPC = mcpServers?["calyx-ipc"] as? [String: Any]
        XCTAssertEqual(calyxIPC?["url"] as? String, "http://127.0.0.1:12345/mcp",
                       "URL should be http://localhost:{port}/mcp")
    }

    func test_enableIPC_correctBearerFormat() throws {
        // Given/When
        try ClaudeConfigManager.enableIPC(port: 41830, token: "my-secret-token", configPath: configPath)

        // Then: Authorization header is "Bearer {token}"
        let dict = try readConfigDict()
        let mcpServers = dict["mcpServers"] as? [String: Any]
        let calyxIPC = mcpServers?["calyx-ipc"] as? [String: Any]
        let headers = calyxIPC?["headers"] as? [String: String]
        XCTAssertEqual(headers?["Authorization"], "Bearer my-secret-token",
                       "Authorization header should be 'Bearer {token}'")
    }

    // Round 4: the MCP connection itself must carry the pane's surface ID,
    // via Claude Code's documented `${VAR}` header env-expansion, so the
    // server can bind surface -> peer at `initialize` time even for a
    // passive recipient that never calls a calyx-ipc tool (and so never
    // fires the PreToolUse/PostToolUse hook the old binding path relied
    // on). Must be the `${CALYX_SURFACE_ID:-}` empty-default form — an
    // undefined var with no default fails Claude Code's config parse
    // entirely, which would break every *other* terminal too.
    func test_enableIPC_headers_includeSurfaceIDPlaceholderWithEmptyDefault() throws {
        // Given/When
        try ClaudeConfigManager.enableIPC(port: 41830, token: "abc123", configPath: configPath)

        // Then: headers contain exactly Authorization and X-Calyx-Surface-ID,
        // the latter as the literal `${CALYX_SURFACE_ID:-}` expansion string.
        let dict = try readConfigDict()
        let mcpServers = dict["mcpServers"] as? [String: Any]
        let calyxIPC = mcpServers?["calyx-ipc"] as? [String: Any]
        let headers = calyxIPC?["headers"] as? [String: String]

        XCTAssertEqual(headers?["Authorization"], "Bearer abc123")
        XCTAssertEqual(headers?["X-Calyx-Surface-ID"], "${CALYX_SURFACE_ID:-}",
                       "X-Calyx-Surface-ID must be the literal ${CALYX_SURFACE_ID:-} placeholder " +
                       "(empty default) so Claude Code's own env expansion fills it per-pane, and an " +
                       "external terminal with no CALYX_SURFACE_ID env still parses the config")
        XCTAssertEqual(headers?.count, 2,
                       "headers must contain exactly Authorization and X-Calyx-Surface-ID, no more")
    }

    func test_enableIPC_updatesExistingEntry_headersIncludeSurfaceIDPlaceholder() throws {
        // Given: calyx-ipc already exists from a pre-Round-4 config (single header)
        let existingJSON = """
        {
            "mcpServers": {
                "calyx-ipc": {
                    "type": "http",
                    "url": "http://localhost:40000/mcp",
                    "headers": {
                        "Authorization": "Bearer old-token"
                    }
                }
            }
        }
        """
        writeConfig(existingJSON)

        // When: enableIPC is called again (e.g. re-running "Enable AI Agent IPC")
        try ClaudeConfigManager.enableIPC(port: 55555, token: "new-token", configPath: configPath)

        // Then: the regenerated entry gains the X-Calyx-Surface-ID header too
        let dict = try readConfigDict()
        let mcpServers = dict["mcpServers"] as? [String: Any]
        let calyxIPC = mcpServers?["calyx-ipc"] as? [String: Any]
        let headers = calyxIPC?["headers"] as? [String: String]

        XCTAssertEqual(headers?["Authorization"], "Bearer new-token")
        XCTAssertEqual(headers?["X-Calyx-Surface-ID"], "${CALYX_SURFACE_ID:-}",
                       "Re-running enableIPC on a pre-Round-4 entry must add X-Calyx-Surface-ID, " +
                       "not just refresh Authorization")
    }

    // MARK: - disableIPC

    func test_disableIPC_removesCalyxEntry() throws {
        // Given: config has calyx-ipc and another server
        let existingJSON = """
        {
            "mcpServers": {
                "calyx-ipc": {
                    "type": "http",
                    "url": "http://localhost:41830/mcp",
                    "headers": {
                        "Authorization": "Bearer tok"
                    }
                },
                "other-server": {
                    "type": "http",
                    "url": "http://localhost:9999/mcp"
                }
            }
        }
        """
        writeConfig(existingJSON)

        // When: disableIPC is called
        try ClaudeConfigManager.disableIPC(configPath: configPath)

        // Then: calyx-ipc is removed, other-server is preserved
        let dict = try readConfigDict()
        let mcpServers = dict["mcpServers"] as? [String: Any]
        XCTAssertNil(mcpServers?["calyx-ipc"], "calyx-ipc should be removed")
        XCTAssertNotNil(mcpServers?["other-server"], "other-server should be preserved")
    }

    func test_disableIPC_removesMcpServersIfEmpty() throws {
        // Given: config has only calyx-ipc in mcpServers
        let existingJSON = """
        {
            "mcpServers": {
                "calyx-ipc": {
                    "type": "http",
                    "url": "http://localhost:41830/mcp",
                    "headers": {
                        "Authorization": "Bearer tok"
                    }
                }
            },
            "otherKey": "value"
        }
        """
        writeConfig(existingJSON)

        // When: disableIPC is called
        try ClaudeConfigManager.disableIPC(configPath: configPath)

        // Then: mcpServers key itself is removed since it would be empty
        let dict = try readConfigDict()
        XCTAssertNil(dict["mcpServers"],
                     "mcpServers key should be removed when it becomes empty")
        XCTAssertEqual(dict["otherKey"] as? String, "value",
                       "Other top-level keys should be preserved")
    }

    func test_disableIPC_noConfigFile() {
        // Given: no config file exists
        XCTAssertFalse(FileManager.default.fileExists(atPath: configPath))

        // When/Then: disableIPC should not throw
        XCTAssertNoThrow(try ClaudeConfigManager.disableIPC(configPath: configPath))

        // And no file should be created
        XCTAssertFalse(FileManager.default.fileExists(atPath: configPath),
                       "No file should be created when disabling with no existing config")
    }

    // MARK: - isIPCEnabled

    func test_isIPCEnabled_trueWhenPresent() {
        // Given: config has calyx-ipc
        let existingJSON = """
        {
            "mcpServers": {
                "calyx-ipc": {
                    "type": "http",
                    "url": "http://localhost:41830/mcp",
                    "headers": {
                        "Authorization": "Bearer tok"
                    }
                }
            }
        }
        """
        writeConfig(existingJSON)

        // When/Then
        XCTAssertTrue(ClaudeConfigManager.isIPCEnabled(configPath: configPath))
    }

    func test_isIPCEnabled_falseWhenAbsent() {
        // Given: config has mcpServers but no calyx-ipc
        let existingJSON = """
        {
            "mcpServers": {
                "other-server": {
                    "type": "http",
                    "url": "http://localhost:9999/mcp"
                }
            }
        }
        """
        writeConfig(existingJSON)

        // When/Then
        XCTAssertFalse(ClaudeConfigManager.isIPCEnabled(configPath: configPath))
    }

    func test_isIPCEnabled_falseWhenNoFile() {
        // Given: no config file exists
        XCTAssertFalse(FileManager.default.fileExists(atPath: configPath))

        // When/Then
        XCTAssertFalse(ClaudeConfigManager.isIPCEnabled(configPath: configPath))
    }

    // MARK: - Security

    // Contract changed (Round 3): dotfiles-managed setups commonly symlink
    // ~/.claude.json to a repo elsewhere (e.g. `~/dotfiles/.claude.json`),
    // and blanket symlink rejection silently broke IPC configuration
    // entirely for that (legitimate, self-authored) setup. Calyx now
    // follows the link and writes through to the real target file,
    // leaving the link itself intact — a single-user desktop app
    // following the user's own symlink is standard behavior, not a
    // security boundary to enforce.
    func test_symlink_followedToRealFile_writesSuccessfullyAndKeepsLinkIntact() throws {
        // Given: configPath is a symlink to a real file
        let realFile = tempDir + "/real_claude.json"
        writeConfig("{}")  // Write to configPath first
        try FileManager.default.moveItem(atPath: configPath, toPath: realFile)
        try FileManager.default.createSymbolicLink(atPath: configPath, withDestinationPath: realFile)

        // Verify it is indeed a symlink
        var isSymlink = false
        let attrs = try FileManager.default.attributesOfItem(atPath: configPath)
        isSymlink = attrs[.type] as? FileAttributeType == .typeSymbolicLink

        XCTAssertTrue(isSymlink, "Test setup: configPath should be a symlink")

        // When: enableIPC is called through the symlinked path
        try ClaudeConfigManager.enableIPC(port: 41830, token: "tok", configPath: configPath)

        // Then: the REAL file received the write...
        let realFileData = try Data(contentsOf: URL(fileURLWithPath: realFile))
        let realFileJSON = try JSONSerialization.jsonObject(with: realFileData) as? [String: Any]
        let mcpServers = realFileJSON?["mcpServers"] as? [String: Any]
        XCTAssertNotNil(mcpServers?["calyx-ipc"], "enableIPC must write through the symlink into the real file")

        // ...and the symlink itself is still a symlink pointing at the same target.
        let attrsAfter = try FileManager.default.attributesOfItem(atPath: configPath)
        XCTAssertEqual(attrsAfter[.type] as? FileAttributeType, .typeSymbolicLink,
                       "The symlink at configPath must survive the write, not be replaced with a regular file")
        let destination = try FileManager.default.destinationOfSymbolicLink(atPath: configPath)
        XCTAssertEqual(destination, realFile, "The symlink must still point at the same real file")
    }

    // Round 3 fix: resolveConfigPath now follows a multi-hop *dangling*
    // symlink chain all the way to its final destination, rather than
    // stopping at the first intermediate link (which used to cause the
    // write to replace that intermediate link with a regular file,
    // orphaning the real intended target). Same behavior for every
    // config manager, since they all route through the same shared
    // ConfigFileUtils.resolveConfigPath/atomicWrite.
    func test_multiHopDanglingSymlink_writesToFinalDestinationKeepingBothLinksIntact() throws {
        let finalTarget = tempDir + "/dotfiles/.claude.json"
        try FileManager.default.createDirectory(
            atPath: (finalTarget as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        let middleLink = tempDir + "/middle-link.json"
        try FileManager.default.createSymbolicLink(atPath: middleLink, withDestinationPath: finalTarget)
        try FileManager.default.createSymbolicLink(atPath: configPath, withDestinationPath: middleLink)

        try ClaudeConfigManager.enableIPC(port: 41830, token: "tok", configPath: configPath)

        XCTAssertTrue(FileManager.default.fileExists(atPath: finalTarget),
                      "enableIPC must create the file at the final destination of a multi-hop dangling chain")
        let data = try Data(contentsOf: URL(fileURLWithPath: finalTarget))
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNotNil((json?["mcpServers"] as? [String: Any])?["calyx-ipc"])

        let middleAttrs = try FileManager.default.attributesOfItem(atPath: middleLink)
        XCTAssertEqual(middleAttrs[.type] as? FileAttributeType, .typeSymbolicLink,
                       "The intermediate link must survive as a symlink, not be replaced with a regular file")
        let outerAttrs = try FileManager.default.attributesOfItem(atPath: configPath)
        XCTAssertEqual(outerAttrs[.type] as? FileAttributeType, .typeSymbolicLink)
    }

    // MARK: - Concurrency

    func test_concurrentEnableDisable_noCorruption() throws {
        // Given: a valid starting config
        writeConfig("{}")

        let group = DispatchGroup()
        var errors: [Error] = []
        let errorLock = NSLock()

        // When: 10 concurrent enable/disable calls
        for i in 0..<10 {
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                do {
                    if i % 2 == 0 {
                        try ClaudeConfigManager.enableIPC(
                            port: 41830 + i,
                            token: "token-\(i)",
                            configPath: self.configPath
                        )
                    } else {
                        try ClaudeConfigManager.disableIPC(configPath: self.configPath)
                    }
                } catch {
                    errorLock.lock()
                    errors.append(error)
                    errorLock.unlock()
                }
            }
        }

        let result = group.wait(timeout: .now() + 10)
        XCTAssertEqual(result, .success, "All concurrent operations should complete within timeout")

        // Then: file should be valid JSON (no corruption)
        if FileManager.default.fileExists(atPath: configPath) {
            let data = try Data(contentsOf: URL(fileURLWithPath: configPath))
            let parsed = try? JSONSerialization.jsonObject(with: data)
            XCTAssertNotNil(parsed, "Config file should be valid JSON after concurrent access")
        }
        // Note: some errors are acceptable (contention), but the file must not be corrupted
    }
}
