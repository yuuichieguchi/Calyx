import XCTest
@testable import Calyx

/// Tests for `OpenCodeConfigManager`.
///
/// Coverage:
/// - `enableIPC` upsert behavior for `opencode.json` and `AGENTS.md`
/// - `disableIPC` removal behavior for both files
/// - `isIPCEnabled` detection
/// - Security: symlink rejection
/// - Edge cases: missing files, invalid JSON, preservation of user content
/// - Concurrency: no corruption under concurrent access
final class OpenCodeConfigManagerTests: XCTestCase {

    // MARK: - Properties

    private var configDir: String!
    private var opencodeJsonPath: String!
    private var agentsMDPath: String!

    // MARK: - Delimiter / canary constants

    /// BEGIN delimiter marker for the Calyx IPC managed block in AGENTS.md.
    private let beginDelimiter = "<!-- BEGIN CALYX IPC"
    /// END delimiter marker for the Calyx IPC managed block in AGENTS.md.
    private let endDelimiter = "<!-- END CALYX IPC -->"
    /// Canary substring that must appear inside the managed block body.
    /// Chosen to be a stable invariant — do not hard-code the full block text.
    private let canarySubstring = "call register_peer once"

    // MARK: - Lifecycle

    override func setUp() {
        super.setUp()
        configDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).path
        try! FileManager.default.createDirectory(
            atPath: configDir,
            withIntermediateDirectories: true
        )
        opencodeJsonPath = configDir + "/opencode.json"
        agentsMDPath = configDir + "/AGENTS.md"
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: configDir)
        super.tearDown()
    }

    // MARK: - Helpers

    /// Write raw string content to `opencode.json`.
    private func writeOpenCodeJSON(_ content: String) {
        FileManager.default.createFile(
            atPath: opencodeJsonPath,
            contents: Data(content.utf8)
        )
    }

    /// Write raw string content to `AGENTS.md`.
    private func writeAgentsMD(_ content: String) {
        FileManager.default.createFile(
            atPath: agentsMDPath,
            contents: Data(content.utf8)
        )
    }

    /// Read `opencode.json` and parse as JSON dictionary.
    private func readOpenCodeDict() throws -> [String: Any] {
        let data = try Data(contentsOf: URL(fileURLWithPath: opencodeJsonPath))
        let obj = try JSONSerialization.jsonObject(with: data)
        return obj as! [String: Any]
    }

    /// Read `AGENTS.md` as a UTF-8 string.
    private func readAgentsMD() throws -> String {
        try String(contentsOfFile: agentsMDPath, encoding: .utf8)
    }

    /// Count occurrences of a substring in a string.
    private func occurrences(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var searchRange = haystack.startIndex..<haystack.endIndex
        while let found = haystack.range(of: needle, range: searchRange) {
            count += 1
            searchRange = found.upperBound..<haystack.endIndex
        }
        return count
    }

    // MARK: - enableIPC: opencode.json

    func test_enableIPC_createsOpenCodeJSONFromScratch() throws {
        // Given: no files exist
        XCTAssertFalse(FileManager.default.fileExists(atPath: opencodeJsonPath))
        XCTAssertFalse(FileManager.default.fileExists(atPath: agentsMDPath))

        // When
        try OpenCodeConfigManager.enableIPC(port: 41830, token: "abc123", configDir: configDir)

        // Then: opencode.json is created with correct structure
        let dict = try readOpenCodeDict()
        let mcp = dict["mcp"] as? [String: Any]
        XCTAssertNotNil(mcp, "mcp key should exist")

        let calyxIPC = mcp?["calyx-ipc"] as? [String: Any]
        XCTAssertNotNil(calyxIPC, "calyx-ipc entry should exist")
        XCTAssertEqual(calyxIPC?["type"] as? String, "remote",
                       "OpenCode MCP entry type should be 'remote'")
        XCTAssertEqual(calyxIPC?["url"] as? String, "http://127.0.0.1:41830/mcp")

        let headers = calyxIPC?["headers"] as? [String: String]
        XCTAssertEqual(headers?["Authorization"], "Bearer abc123")
    }

    func test_enableIPC_createsAgentsMDFromScratch() throws {
        // Given: no files exist
        XCTAssertFalse(FileManager.default.fileExists(atPath: agentsMDPath))

        // When
        try OpenCodeConfigManager.enableIPC(port: 41830, token: "abc123", configDir: configDir)

        // Then: AGENTS.md is created with BEGIN/END delimiters and canary substring
        let content = try readAgentsMD()
        XCTAssertTrue(content.contains(beginDelimiter),
                      "AGENTS.md should contain BEGIN CALYX IPC delimiter")
        XCTAssertTrue(content.contains(endDelimiter),
                      "AGENTS.md should contain END CALYX IPC delimiter")
        XCTAssertTrue(content.contains(canarySubstring),
                      "AGENTS.md should contain canary substring '\(canarySubstring)'")
    }

    func test_enableIPC_preservesOtherMCPServers() throws {
        // Given: opencode.json has another MCP server
        let existingJSON = """
        {
            "mcp": {
                "other-server": {
                    "type": "remote",
                    "url": "http://localhost:9999/mcp"
                }
            }
        }
        """
        writeOpenCodeJSON(existingJSON)

        // When
        try OpenCodeConfigManager.enableIPC(port: 41830, token: "tok1", configDir: configDir)

        // Then: other-server preserved, calyx-ipc added
        let dict = try readOpenCodeDict()
        let mcp = dict["mcp"] as? [String: Any]
        XCTAssertNotNil(mcp?["other-server"], "other-server should be preserved")
        XCTAssertNotNil(mcp?["calyx-ipc"], "calyx-ipc should be added")

        let other = mcp?["other-server"] as? [String: Any]
        XCTAssertEqual(other?["url"] as? String, "http://localhost:9999/mcp",
                       "other-server url should be preserved unchanged")
    }

    func test_enableIPC_preservesOtherTopLevelKeys() throws {
        // Given: opencode.json has other top-level keys
        let existingJSON = """
        {
            "theme": "dark",
            "model": "claude-sonnet",
            "mcp": {}
        }
        """
        writeOpenCodeJSON(existingJSON)

        // When
        try OpenCodeConfigManager.enableIPC(port: 41830, token: "tok", configDir: configDir)

        // Then: theme and model still present, calyx-ipc added
        let dict = try readOpenCodeDict()
        XCTAssertEqual(dict["theme"] as? String, "dark",
                       "theme top-level key should be preserved")
        XCTAssertEqual(dict["model"] as? String, "claude-sonnet",
                       "model top-level key should be preserved")

        let mcp = dict["mcp"] as? [String: Any]
        XCTAssertNotNil(mcp?["calyx-ipc"], "calyx-ipc should be added")
    }

    func test_enableIPC_upsertsExistingCalyxEntry() throws {
        // Given: opencode.json already has calyx-ipc with old port/token
        let existingJSON = """
        {
            "mcp": {
                "calyx-ipc": {
                    "type": "remote",
                    "url": "http://localhost:40000/mcp",
                    "headers": {
                        "Authorization": "Bearer old-token"
                    }
                }
            }
        }
        """
        writeOpenCodeJSON(existingJSON)

        // When: enableIPC is called with new port and token
        try OpenCodeConfigManager.enableIPC(port: 55555, token: "new-token", configDir: configDir)

        // Then: calyx-ipc is REPLACED with new values (not duplicated, not merged)
        let dict = try readOpenCodeDict()
        let mcp = dict["mcp"] as? [String: Any]
        XCTAssertEqual(mcp?.count, 1, "There should be only one entry under mcp (no duplicates)")

        let calyxIPC = mcp?["calyx-ipc"] as? [String: Any]
        XCTAssertEqual(calyxIPC?["url"] as? String, "http://127.0.0.1:55555/mcp",
                       "URL should be updated to new port")

        let headers = calyxIPC?["headers"] as? [String: String]
        XCTAssertEqual(headers?["Authorization"], "Bearer new-token",
                       "Authorization should be updated to new token")
        XCTAssertEqual(headers?.count, 1,
                       "Headers dict should not retain stale merged keys")
    }

    func test_enableIPC_correctBearerFormat() throws {
        // When
        try OpenCodeConfigManager.enableIPC(
            port: 41830,
            token: "my-secret-token",
            configDir: configDir
        )

        // Then: Authorization header is exactly "Bearer <token>"
        let dict = try readOpenCodeDict()
        let mcp = dict["mcp"] as? [String: Any]
        let calyxIPC = mcp?["calyx-ipc"] as? [String: Any]
        let headers = calyxIPC?["headers"] as? [String: String]
        XCTAssertEqual(headers?["Authorization"], "Bearer my-secret-token",
                       "Authorization header should be 'Bearer <token>' exactly")
    }

    func test_enableIPC_correctURLFormat() throws {
        // When
        try OpenCodeConfigManager.enableIPC(port: 12345, token: "t", configDir: configDir)

        // Then: URL is exactly "http://localhost:<port>/mcp"
        let dict = try readOpenCodeDict()
        let mcp = dict["mcp"] as? [String: Any]
        let calyxIPC = mcp?["calyx-ipc"] as? [String: Any]
        XCTAssertEqual(calyxIPC?["url"] as? String, "http://127.0.0.1:12345/mcp",
                       "URL should be 'http://localhost:<port>/mcp' exactly")
    }

    // MARK: - enableIPC: AGENTS.md

    func test_enableIPC_preservesAgentsMDUserContent() throws {
        // Given: AGENTS.md has user-written content
        let userContent = "# My Rules\n- be nice\n- write tests\n"
        writeAgentsMD(userContent)

        // When
        try OpenCodeConfigManager.enableIPC(port: 41830, token: "tok", configDir: configDir)

        // Then: user content preserved AND Calyx IPC block present
        let content = try readAgentsMD()
        XCTAssertTrue(content.contains("# My Rules"),
                      "User heading should be preserved")
        XCTAssertTrue(content.contains("- be nice"),
                      "User bullet should be preserved")
        XCTAssertTrue(content.contains("- write tests"),
                      "User bullet should be preserved")
        XCTAssertTrue(content.contains(beginDelimiter),
                      "Calyx IPC BEGIN delimiter should be appended")
        XCTAssertTrue(content.contains(endDelimiter),
                      "Calyx IPC END delimiter should be appended")
        XCTAssertTrue(content.contains(canarySubstring),
                      "Calyx IPC canary substring should be present")
    }

    func test_enableIPC_replacesExistingCalyxBlock() throws {
        // Given: AGENTS.md already contains a (stale) Calyx IPC block, plus user content
        let stale = """
        # User Rules

        do what you need to

        \(beginDelimiter) (managed by Calyx, do not edit) -->
        ## Calyx IPC

        Old placeholder body. call register_peer once (stale).
        \(endDelimiter)

        # Trailing user section
        """
        writeAgentsMD(stale)

        // When
        try OpenCodeConfigManager.enableIPC(port: 55555, token: "fresh", configDir: configDir)

        // Then: exactly ONE managed block exists, and user content (before/after) is preserved
        let content = try readAgentsMD()

        let beginCount = occurrences(of: beginDelimiter, in: content)
        let endCount = occurrences(of: endDelimiter, in: content)
        XCTAssertEqual(beginCount, 1,
                       "There must be exactly one BEGIN delimiter after upsert (no duplicates)")
        XCTAssertEqual(endCount, 1,
                       "There must be exactly one END delimiter after upsert (no duplicates)")

        XCTAssertTrue(content.contains("# User Rules"),
                      "User heading before the block should be preserved")
        XCTAssertTrue(content.contains("do what you need to"),
                      "User content before the block should be preserved")
        XCTAssertTrue(content.contains("# Trailing user section"),
                      "User content after the block should be preserved")

        XCTAssertFalse(content.contains("Old placeholder body"),
                       "Stale managed block body should be replaced")
        XCTAssertTrue(content.contains(canarySubstring),
                      "Fresh managed block should contain canary substring")
    }

    // MARK: - enableIPC: Security / Errors

    // Contract changed (Round 3): a dotfiles-managed OpenCode config
    // root commonly symlinks opencode.json / AGENTS.md elsewhere, and
    // blanket symlink rejection silently broke IPC configuration in that
    // setup. enableIPC now follows the link and writes through to the
    // real target file, leaving the link itself intact.
    func test_enableIPC_symlinkFollowedToRealFile_opencodeJson() throws {
        // Given: opencode.json path is a symlink to a real file
        let realFile = configDir + "/real_opencode.json"
        writeOpenCodeJSON("{}")
        try FileManager.default.moveItem(atPath: opencodeJsonPath, toPath: realFile)
        try FileManager.default.createSymbolicLink(
            atPath: opencodeJsonPath,
            withDestinationPath: realFile
        )

        // Verify it is indeed a symlink
        let attrs = try FileManager.default.attributesOfItem(atPath: opencodeJsonPath)
        XCTAssertEqual(attrs[.type] as? FileAttributeType, .typeSymbolicLink,
                       "Test setup: opencode.json should be a symlink")

        // When: enableIPC is called through the symlinked path
        try OpenCodeConfigManager.enableIPC(port: 41830, token: "tok", configDir: configDir)

        // Then: the real file received the calyx-ipc entry...
        let realData = try Data(contentsOf: URL(fileURLWithPath: realFile))
        let realDict = try JSONSerialization.jsonObject(with: realData) as? [String: Any]
        let mcp = realDict?["mcp"] as? [String: Any]
        XCTAssertNotNil(mcp?["calyx-ipc"], "enableIPC must write through the symlink into the real opencode.json")

        // ...and the symlink itself survives.
        let attrsAfter = try FileManager.default.attributesOfItem(atPath: opencodeJsonPath)
        XCTAssertEqual(attrsAfter[.type] as? FileAttributeType, .typeSymbolicLink,
                       "opencode.json must remain a symlink after enableIPC")
    }

    func test_enableIPC_symlinkFollowedToRealFile_agentsMD() throws {
        // Given: AGENTS.md path is a symlink to a real file
        let realFile = configDir + "/real_AGENTS.md"
        writeAgentsMD("# User\n")
        try FileManager.default.moveItem(atPath: agentsMDPath, toPath: realFile)
        try FileManager.default.createSymbolicLink(
            atPath: agentsMDPath,
            withDestinationPath: realFile
        )

        // Verify it is indeed a symlink
        let attrs = try FileManager.default.attributesOfItem(atPath: agentsMDPath)
        XCTAssertEqual(attrs[.type] as? FileAttributeType, .typeSymbolicLink,
                       "Test setup: AGENTS.md should be a symlink")

        // When: enableIPC is called through the symlinked path
        try OpenCodeConfigManager.enableIPC(port: 41830, token: "tok", configDir: configDir)

        // Then: the real file received the managed block and the user's heading survived...
        let realContent = try String(contentsOfFile: realFile, encoding: .utf8)
        XCTAssertTrue(realContent.contains("# User"), "The user's existing AGENTS.md content must be preserved")
        XCTAssertTrue(realContent.contains(canarySubstring),
                      "enableIPC must write the managed block through the symlink into the real AGENTS.md")

        // ...and the symlink itself survives.
        let attrsAfter = try FileManager.default.attributesOfItem(atPath: agentsMDPath)
        XCTAssertEqual(attrsAfter[.type] as? FileAttributeType, .typeSymbolicLink,
                       "AGENTS.md must remain a symlink after enableIPC")
    }

    // Round 3 fix: resolveConfigPath now follows a multi-hop *dangling*
    // symlink chain (link -> link -> not-yet-existing file) all the way
    // to its final destination, rather than stopping at the first
    // intermediate link. Same shared ConfigFileUtils primitive as every
    // other config manager — exercised here via AGENTS.md's path, with
    // opencode.json left as a plain (non-symlinked) path so the test also
    // confirms a multi-hop chain on one file doesn't disturb the other.
    func test_enableIPC_multiHopDanglingSymlink_agentsMD_writesToFinalDestination() throws {
        let dotfilesDir = configDir + "/dotfiles"
        try FileManager.default.createDirectory(atPath: dotfilesDir, withIntermediateDirectories: true)
        let finalTarget = dotfilesDir + "/AGENTS.md"
        let middleLink = configDir + "/middle-link.md"
        try FileManager.default.createSymbolicLink(atPath: middleLink, withDestinationPath: finalTarget)
        try FileManager.default.createSymbolicLink(atPath: agentsMDPath, withDestinationPath: middleLink)

        try OpenCodeConfigManager.enableIPC(port: 41830, token: "tok", configDir: configDir)

        XCTAssertTrue(FileManager.default.fileExists(atPath: finalTarget),
                      "enableIPC must create AGENTS.md at the multi-hop dangling chain's final destination")
        let content = try String(contentsOfFile: finalTarget, encoding: .utf8)
        XCTAssertTrue(content.contains(canarySubstring))

        let middleAttrs = try FileManager.default.attributesOfItem(atPath: middleLink)
        XCTAssertEqual(middleAttrs[.type] as? FileAttributeType, .typeSymbolicLink,
                       "The intermediate link must survive as a symlink, not be replaced with a regular file")

        // opencode.json (a plain, non-symlinked path here) must also have
        // been written normally.
        XCTAssertTrue(FileManager.default.fileExists(atPath: opencodeJsonPath))
    }

    func test_enableIPC_invalidJSON_throws() {
        // Given: opencode.json contains garbage
        let garbage = "this is not json {{{"
        writeOpenCodeJSON(garbage)

        // When/Then: enableIPC throws AND file is not overwritten
        XCTAssertThrowsError(
            try OpenCodeConfigManager.enableIPC(
                port: 41830,
                token: "tok",
                configDir: configDir
            )
        ) { _ in
            let content = try? String(contentsOfFile: self.opencodeJsonPath, encoding: .utf8)
            XCTAssertEqual(content, garbage,
                           "Garbage opencode.json should not be overwritten on throw")
        }
    }

    func test_enableIPC_partialFailure_jsonWrittenAgentsFailed() throws {
        // Given: AGENTS.md's path itself is a directory, causing the
        // AGENTS.md write to fail AFTER opencode.json has already been
        // written. This is a distinct failure mode from the Round 3
        // preflight fix below (`test_enableIPC_agentsMDResolvedParent...`):
        // the preflight only checks each resolved path's PARENT directory
        // exists, not that the path itself is free of a conflicting
        // directory — this scenario's parent (configDir) does exist, so
        // the preflight passes and the pre-existing non-atomic
        // cross-file-write behavior documented here is unchanged.
        try FileManager.default.createDirectory(
            atPath: agentsMDPath,
            withIntermediateDirectories: false
        )

        // When: enableIPC is called
        XCTAssertThrowsError(
            try OpenCodeConfigManager.enableIPC(
                port: 41830,
                token: "token",
                configDir: configDir
            )
        )

        // Then: opencode.json has been written — documenting cross-file non-atomicity.
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: opencodeJsonPath),
            "opencode.json should exist after partial-failure (documents non-atomic cross-file behavior)"
        )

        let data = try Data(contentsOf: URL(fileURLWithPath: opencodeJsonPath))
        let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let mcp = parsed?["mcp"] as? [String: Any]
        XCTAssertNotNil(mcp?["calyx-ipc"], "partial-failure leaves calyx-ipc entry in opencode.json")
    }

    // Round 3 fix: preflight both files' resolved paths for writability
    // (their parent directory exists) before writing either one, so a
    // predictable failure mode — a not-yet-created parent directory,
    // e.g. behind a dangling symlink — can't leave opencode.json enabled
    // while AGENTS.md was never touched.
    func test_enableIPC_agentsMDResolvedParentDirectoryMissing_preflightThrows_opencodeJSONUntouched() throws {
        let missingParentTarget = configDir + "/does-not-exist/AGENTS.md"
        try FileManager.default.createSymbolicLink(atPath: agentsMDPath, withDestinationPath: missingParentTarget)

        XCTAssertThrowsError(
            try OpenCodeConfigManager.enableIPC(port: 41830, token: "token", configDir: configDir)
        )

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: opencodeJsonPath),
            "A preflight failure on AGENTS.md's resolved path must prevent opencode.json from being " +
            "written at all — no partial enable"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: missingParentTarget),
            "AGENTS.md's resolved target must also never be written"
        )
    }

    func test_enableIPC_nullRootJSON_throws() throws {
        try "null".write(toFile: opencodeJsonPath, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(
            try OpenCodeConfigManager.enableIPC(
                port: 41830,
                token: "token",
                configDir: configDir
            )
        ) { error in
            if case OpenCodeConfigError.invalidJSON = error {
                // pass
            } else {
                XCTFail("Expected .invalidJSON, got \(error)")
            }
        }

        let content = try String(contentsOfFile: opencodeJsonPath, encoding: .utf8)
        XCTAssertEqual(content, "null")
    }

    func test_enableIPC_arrayRootJSON_throws() throws {
        try "[]".write(toFile: opencodeJsonPath, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(
            try OpenCodeConfigManager.enableIPC(
                port: 41830,
                token: "token",
                configDir: configDir
            )
        ) { error in
            if case OpenCodeConfigError.invalidJSON = error {
                // pass
            } else {
                XCTFail("Expected .invalidJSON, got \(error)")
            }
        }

        let content = try String(contentsOfFile: opencodeJsonPath, encoding: .utf8)
        XCTAssertEqual(content, "[]")
    }

    func test_enableIPC_numberRootJSON_throws() throws {
        try "42".write(toFile: opencodeJsonPath, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(
            try OpenCodeConfigManager.enableIPC(
                port: 41830,
                token: "token",
                configDir: configDir
            )
        ) { error in
            if case OpenCodeConfigError.invalidJSON = error {
                // pass
            } else {
                XCTFail("Expected .invalidJSON, got \(error)")
            }
        }

        let content = try String(contentsOfFile: opencodeJsonPath, encoding: .utf8)
        XCTAssertEqual(content, "42")
    }

    // MARK: - disableIPC

    func test_disableIPC_removesCalyxFromOpenCodeJSON() throws {
        // Given: opencode.json has calyx-ipc and another server
        let existingJSON = """
        {
            "mcp": {
                "calyx-ipc": {
                    "type": "remote",
                    "url": "http://localhost:41830/mcp",
                    "headers": {
                        "Authorization": "Bearer tok"
                    }
                },
                "other-server": {
                    "type": "remote",
                    "url": "http://localhost:9999/mcp"
                }
            }
        }
        """
        writeOpenCodeJSON(existingJSON)

        // When
        try OpenCodeConfigManager.disableIPC(configDir: configDir)

        // Then: calyx-ipc removed, other-server preserved
        let dict = try readOpenCodeDict()
        let mcp = dict["mcp"] as? [String: Any]
        XCTAssertNil(mcp?["calyx-ipc"], "calyx-ipc should be removed")
        XCTAssertNotNil(mcp?["other-server"], "other-server should be preserved")
    }

    func test_disableIPC_removesMcpKeyIfEmpty() throws {
        // Given: opencode.json has only calyx-ipc under mcp, plus another top-level key
        let existingJSON = """
        {
            "mcp": {
                "calyx-ipc": {
                    "type": "remote",
                    "url": "http://localhost:41830/mcp",
                    "headers": {
                        "Authorization": "Bearer tok"
                    }
                }
            },
            "theme": "dark"
        }
        """
        writeOpenCodeJSON(existingJSON)

        // When
        try OpenCodeConfigManager.disableIPC(configDir: configDir)

        // Then: mcp key removed entirely (parity with ClaudeConfigManager);
        //       other top-level keys preserved
        let dict = try readOpenCodeDict()
        XCTAssertNil(dict["mcp"],
                     "mcp key should be removed when it becomes empty")
        XCTAssertEqual(dict["theme"] as? String, "dark",
                       "Other top-level keys should be preserved")
    }

    func test_disableIPC_removesBlockFromAgentsMD() throws {
        // Given: AGENTS.md has user content surrounding a Calyx IPC block
        let userPrefix = "# My Rules\n- be nice\n"
        let userSuffix = "\n# Trailing\nmore user content\n"
        let existing = """
        \(userPrefix)
        \(beginDelimiter) (managed by Calyx, do not edit) -->
        ## Calyx IPC

        Some body. \(canarySubstring) with the old token.
        \(endDelimiter)
        \(userSuffix)
        """
        writeAgentsMD(existing)

        // When
        try OpenCodeConfigManager.disableIPC(configDir: configDir)

        // Then: user content preserved, managed block gone
        let content = try readAgentsMD()
        XCTAssertTrue(content.contains("# My Rules"),
                      "User heading should be preserved")
        XCTAssertTrue(content.contains("- be nice"),
                      "User bullet should be preserved")
        XCTAssertTrue(content.contains("# Trailing"),
                      "User trailing heading should be preserved")
        XCTAssertTrue(content.contains("more user content"),
                      "User trailing content should be preserved")

        XCTAssertFalse(content.contains(beginDelimiter),
                       "BEGIN delimiter should be removed")
        XCTAssertFalse(content.contains(endDelimiter),
                       "END delimiter should be removed")
        XCTAssertFalse(content.contains(canarySubstring),
                       "Managed block body should be removed")
    }

    func test_disableIPC_noFilesExist_noOp() {
        // Given: neither file exists
        XCTAssertFalse(FileManager.default.fileExists(atPath: opencodeJsonPath))
        XCTAssertFalse(FileManager.default.fileExists(atPath: agentsMDPath))

        // When/Then: disableIPC returns without throwing
        XCTAssertNoThrow(try OpenCodeConfigManager.disableIPC(configDir: configDir))

        // And no files should be created
        XCTAssertFalse(FileManager.default.fileExists(atPath: opencodeJsonPath),
                       "opencode.json should not be created by disableIPC")
        XCTAssertFalse(FileManager.default.fileExists(atPath: agentsMDPath),
                       "AGENTS.md should not be created by disableIPC")
    }

    func test_disableIPC_onlyOpenCodeJsonExists() throws {
        // Given: only opencode.json exists (with calyx-ipc)
        let existingJSON = """
        {
            "mcp": {
                "calyx-ipc": {
                    "type": "remote",
                    "url": "http://localhost:41830/mcp",
                    "headers": {
                        "Authorization": "Bearer tok"
                    }
                }
            }
        }
        """
        writeOpenCodeJSON(existingJSON)
        XCTAssertFalse(FileManager.default.fileExists(atPath: agentsMDPath))

        // When
        try OpenCodeConfigManager.disableIPC(configDir: configDir)

        // Then: opencode.json has calyx-ipc removed; AGENTS.md still missing
        let dict = try readOpenCodeDict()
        let mcp = dict["mcp"] as? [String: Any]
        XCTAssertNil(mcp?["calyx-ipc"], "calyx-ipc should be removed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: agentsMDPath),
                       "AGENTS.md should not be created by disableIPC")
    }

    func test_disableIPC_onlyAgentsMDExists() throws {
        // Given: only AGENTS.md exists (with Calyx block)
        let existing = """
        # Header

        \(beginDelimiter) (managed by Calyx, do not edit) -->
        ## Calyx IPC

        \(canarySubstring) body.
        \(endDelimiter)
        """
        writeAgentsMD(existing)
        XCTAssertFalse(FileManager.default.fileExists(atPath: opencodeJsonPath))

        // When
        try OpenCodeConfigManager.disableIPC(configDir: configDir)

        // Then: AGENTS.md has block removed; opencode.json still missing
        let content = try readAgentsMD()
        XCTAssertFalse(content.contains(beginDelimiter),
                       "BEGIN delimiter should be removed")
        XCTAssertFalse(content.contains(endDelimiter),
                       "END delimiter should be removed")
        XCTAssertTrue(content.contains("# Header"),
                      "User heading should be preserved")
        XCTAssertFalse(FileManager.default.fileExists(atPath: opencodeJsonPath),
                       "opencode.json should not be created by disableIPC")
    }

    // Contract changed (Round 3): see the enableIPC symlink tests above —
    // disableIPC now follows the link and removes the entry from the
    // real target file, leaving the link itself intact.
    func test_disableIPC_symlinkFollowedToRealFile() throws {
        // Given: opencode.json is a symlink to a real file with the entry present
        let realFile = configDir + "/real_opencode.json"
        writeOpenCodeJSON("""
        {
            "mcp": {
                "calyx-ipc": {
                    "type": "remote",
                    "url": "http://localhost:41830/mcp",
                    "headers": { "Authorization": "Bearer tok" }
                }
            }
        }
        """)
        try FileManager.default.moveItem(atPath: opencodeJsonPath, toPath: realFile)
        try FileManager.default.createSymbolicLink(
            atPath: opencodeJsonPath,
            withDestinationPath: realFile
        )

        // When: disableIPC is called through the symlinked path
        try OpenCodeConfigManager.disableIPC(configDir: configDir)

        // Then: the entry is gone from the real file...
        let realData = try Data(contentsOf: URL(fileURLWithPath: realFile))
        let realDict = try JSONSerialization.jsonObject(with: realData) as? [String: Any]
        let mcp = realDict?["mcp"] as? [String: Any]
        XCTAssertNil(mcp?["calyx-ipc"], "disableIPC must remove the entry from the real file reached through the symlink")

        // ...and the symlink itself survives.
        let attrsAfter = try FileManager.default.attributesOfItem(atPath: opencodeJsonPath)
        XCTAssertEqual(attrsAfter[.type] as? FileAttributeType, .typeSymbolicLink,
                       "opencode.json must remain a symlink after disableIPC")
    }

    // MARK: - isIPCEnabled

    func test_isIPCEnabled_trueWhenPresent() {
        // Given: opencode.json has calyx-ipc entry
        let existingJSON = """
        {
            "mcp": {
                "calyx-ipc": {
                    "type": "remote",
                    "url": "http://localhost:41830/mcp",
                    "headers": {
                        "Authorization": "Bearer tok"
                    }
                }
            }
        }
        """
        writeOpenCodeJSON(existingJSON)

        // When/Then
        XCTAssertTrue(OpenCodeConfigManager.isIPCEnabled(configDir: configDir))
    }

    func test_isIPCEnabled_falseWhenAbsent() {
        // Given: opencode.json has mcp but no calyx-ipc
        let existingJSON = """
        {
            "mcp": {
                "other-server": {
                    "type": "remote",
                    "url": "http://localhost:9999/mcp"
                }
            }
        }
        """
        writeOpenCodeJSON(existingJSON)

        // When/Then
        XCTAssertFalse(OpenCodeConfigManager.isIPCEnabled(configDir: configDir))
    }

    func test_isIPCEnabled_falseWhenNoFile() {
        // Given: no opencode.json
        XCTAssertFalse(FileManager.default.fileExists(atPath: opencodeJsonPath))

        // When/Then
        XCTAssertFalse(OpenCodeConfigManager.isIPCEnabled(configDir: configDir))
    }

    // MARK: - Concurrency

    func test_concurrentEnableDisable_noCorruption() throws {
        // Given: an empty valid opencode.json
        writeOpenCodeJSON("{}")

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
                        try OpenCodeConfigManager.enableIPC(
                            port: 41830 + i,
                            token: "token-\(i)",
                            configDir: self.configDir
                        )
                    } else {
                        try OpenCodeConfigManager.disableIPC(configDir: self.configDir)
                    }
                } catch {
                    errorLock.lock()
                    errors.append(error)
                    errorLock.unlock()
                }
            }
        }

        let result = group.wait(timeout: .now() + 10)
        XCTAssertEqual(result, .success,
                       "All concurrent operations should complete within timeout")

        // Then: opencode.json (if present) is still parseable JSON
        if FileManager.default.fileExists(atPath: opencodeJsonPath) {
            let data = try Data(contentsOf: URL(fileURLWithPath: opencodeJsonPath))
            let parsed = try? JSONSerialization.jsonObject(with: data)
            XCTAssertNotNil(parsed,
                            "opencode.json should remain valid JSON after concurrent access")
        }

        // Then: AGENTS.md (if present) has balanced delimiters
        if FileManager.default.fileExists(atPath: agentsMDPath) {
            let content = try readAgentsMD()
            let beginCount = occurrences(of: beginDelimiter, in: content)
            let endCount = occurrences(of: endDelimiter, in: content)
            XCTAssertEqual(beginCount, endCount,
                           "AGENTS.md BEGIN and END delimiters must be balanced after concurrent access")
            XCTAssertLessThanOrEqual(beginCount, 1,
                                     "AGENTS.md should contain at most one managed block after concurrent access")
        }
        // Note: some errors are acceptable under contention, but files must not be corrupted.
    }
}
