// CodexConfigManagerTests.swift
// CalyxTests

import XCTest
@testable import Calyx

final class CodexConfigManagerTests: XCTestCase {

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
        configPath = tempDir + "/config.toml"
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: tempDir)
        super.tearDown()
    }

    // MARK: - Helpers

    private func writeConfig(_ content: String) {
        FileManager.default.createFile(atPath: configPath, contents: Data(content.utf8))
    }

    private func readConfig() -> String {
        (try? String(contentsOfFile: configPath, encoding: .utf8)) ?? ""
    }

    // MARK: - Basic Operations

    func test_enableIPC_createsNewFile() throws {
        // Given: no file exists
        XCTAssertFalse(FileManager.default.fileExists(atPath: configPath))

        // When
        try CodexConfigManager.enableIPC(port: 41830, token: "abc123", configPath: configPath)

        // Then: file created with correct TOML section
        let content = readConfig()
        XCTAssertTrue(content.contains("[mcp_servers.calyx-ipc]"))
        XCTAssertTrue(content.contains("http://127.0.0.1:41830/mcp"))
        XCTAssertTrue(content.contains("Bearer abc123"))
    }

    func test_enableIPC_addsToExistingFile() throws {
        // Given: file has other content
        let existing = """
        [general]
        model = "gpt-4"
        temperature = 0.7
        """
        writeConfig(existing)

        // When
        try CodexConfigManager.enableIPC(port: 41830, token: "tok1", configPath: configPath)

        // Then: original content preserved and calyx-ipc appended
        let content = readConfig()
        XCTAssertTrue(content.contains("[general]"))
        XCTAssertTrue(content.contains("model = \"gpt-4\""))
        XCTAssertTrue(content.contains("temperature = 0.7"))
        XCTAssertTrue(content.contains("[mcp_servers.calyx-ipc]"))
        XCTAssertTrue(content.contains("http://127.0.0.1:41830/mcp"))
    }

    func test_enableIPC_updatesExistingEntry() throws {
        // Given: file already has calyx-ipc section with old port/token
        let existing = """
        [mcp_servers.calyx-ipc]
        url = "http://localhost:40000/mcp"
        http_headers = { "Authorization" = "Bearer old-token" }
        """
        writeConfig(existing)

        // When: enableIPC with new port and token
        try CodexConfigManager.enableIPC(port: 55555, token: "new-token", configPath: configPath)

        // Then: updated with new values
        let content = readConfig()
        XCTAssertTrue(content.contains("http://127.0.0.1:55555/mcp"))
        XCTAssertTrue(content.contains("Bearer new-token"))
        // Old values removed
        XCTAssertFalse(content.contains("http://localhost:40000/mcp"))
        XCTAssertFalse(content.contains("Bearer old-token"))
    }

    // MARK: - Preservation Tests

    func test_enableIPC_preservesComments() throws {
        // Given: file has comment lines
        let existing = """
        # This is a top-level comment
        [general]
        # Model setting
        model = "gpt-4"
        """
        writeConfig(existing)

        // When
        try CodexConfigManager.enableIPC(port: 41830, token: "tok", configPath: configPath)

        // Then: comments preserved
        let content = readConfig()
        XCTAssertTrue(content.contains("# This is a top-level comment"))
        XCTAssertTrue(content.contains("# Model setting"))
        XCTAssertTrue(content.contains("[mcp_servers.calyx-ipc]"))
    }

    func test_enableIPC_preservesOtherSections() throws {
        // Given: file has other sections with key-values
        let existing = """
        [other.section]
        key1 = "value1"
        key2 = 42

        [another.section]
        enabled = true
        """
        writeConfig(existing)

        // When
        try CodexConfigManager.enableIPC(port: 41830, token: "tok", configPath: configPath)

        // Then: other sections preserved
        let content = readConfig()
        XCTAssertTrue(content.contains("[other.section]"))
        XCTAssertTrue(content.contains("key1 = \"value1\""))
        XCTAssertTrue(content.contains("key2 = 42"))
        XCTAssertTrue(content.contains("[another.section]"))
        XCTAssertTrue(content.contains("enabled = true"))
        XCTAssertTrue(content.contains("[mcp_servers.calyx-ipc]"))
    }

    func test_enableIPC_preservesOtherMCPServers() throws {
        // Given: file has another mcp_servers entry
        let existing = """
        [mcp_servers.other]
        url = "http://localhost:9999/mcp"
        http_headers = { "Authorization" = "Bearer other-tok" }
        """
        writeConfig(existing)

        // When
        try CodexConfigManager.enableIPC(port: 41830, token: "tok", configPath: configPath)

        // Then: other MCP server preserved
        let content = readConfig()
        XCTAssertTrue(content.contains("[mcp_servers.other]"))
        XCTAssertTrue(content.contains("http://localhost:9999/mcp"))
        XCTAssertTrue(content.contains("[mcp_servers.calyx-ipc]"))
    }

    // MARK: - Disable Tests

    func test_disableIPC_removeSection() throws {
        // Given: file has calyx-ipc section
        let existing = """
        [mcp_servers.calyx-ipc]
        url = "http://localhost:41830/mcp"
        http_headers = { "Authorization" = "Bearer tok" }
        """
        writeConfig(existing)

        // When
        try CodexConfigManager.disableIPC(configPath: configPath)

        // Then: section removed
        let content = readConfig()
        XCTAssertFalse(content.contains("[mcp_servers.calyx-ipc]"))
        XCTAssertFalse(content.contains("http://localhost:41830/mcp"))
    }

    func test_disableIPC_preservesOtherMCPServers() throws {
        // Given: file has calyx-ipc and another mcp server
        let existing = """
        [mcp_servers.other]
        url = "http://localhost:9999/mcp"

        [mcp_servers.calyx-ipc]
        url = "http://localhost:41830/mcp"
        http_headers = { "Authorization" = "Bearer tok" }
        """
        writeConfig(existing)

        // When
        try CodexConfigManager.disableIPC(configPath: configPath)

        // Then: calyx-ipc removed, other preserved
        let content = readConfig()
        XCTAssertFalse(content.contains("[mcp_servers.calyx-ipc]"))
        XCTAssertTrue(content.contains("[mcp_servers.other]"))
        XCTAssertTrue(content.contains("http://localhost:9999/mcp"))
    }

    func test_disableIPC_noFile() {
        // Given: no file exists
        XCTAssertFalse(FileManager.default.fileExists(atPath: configPath))

        // When/Then: no error thrown
        XCTAssertNoThrow(try CodexConfigManager.disableIPC(configPath: configPath))

        // And: no file created
        XCTAssertFalse(FileManager.default.fileExists(atPath: configPath))
    }

    func test_disableIPC_noSection() throws {
        // Given: file exists but has no calyx-ipc section
        let existing = """
        [general]
        model = "gpt-4"
        """
        writeConfig(existing)

        // When
        try CodexConfigManager.disableIPC(configPath: configPath)

        // Then: file unchanged
        let content = readConfig()
        XCTAssertTrue(content.contains("[general]"))
        XCTAssertTrue(content.contains("model = \"gpt-4\""))
        XCTAssertFalse(content.contains("[mcp_servers.calyx-ipc]"))
    }

    func test_disableIPC_unreadableFile() throws {
        // Given: file exists but is unreadable (permission 0o000)
        writeConfig("[mcp_servers.calyx-ipc]\nurl = \"http://localhost:41830/mcp\"\n")
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000],
            ofItemAtPath: configPath
        )

        // When/Then: no error thrown (no-op because file can't be read)
        XCTAssertNoThrow(try CodexConfigManager.disableIPC(configPath: configPath))

        // Cleanup: restore permissions so tearDown can remove the file
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: configPath
        )
    }

    // MARK: - isIPCEnabled Tests

    func test_isIPCEnabled_true() {
        // Given: section exists
        let existing = """
        [mcp_servers.calyx-ipc]
        url = "http://localhost:41830/mcp"
        http_headers = { "Authorization" = "Bearer tok" }
        """
        writeConfig(existing)

        // When/Then
        XCTAssertTrue(CodexConfigManager.isIPCEnabled(configPath: configPath))
    }

    func test_isIPCEnabled_false() {
        // Given: section doesn't exist
        let existing = """
        [general]
        model = "gpt-4"
        """
        writeConfig(existing)

        // When/Then
        XCTAssertFalse(CodexConfigManager.isIPCEnabled(configPath: configPath))
    }

    func test_isIPCEnabled_noFile() {
        // Given: file doesn't exist
        XCTAssertFalse(FileManager.default.fileExists(atPath: configPath))

        // When/Then
        XCTAssertFalse(CodexConfigManager.isIPCEnabled(configPath: configPath))
    }

    // MARK: - Directory Tests

    func test_enableIPC_directoryNotFound() {
        // Given: parent directory doesn't exist
        let badPath = tempDir + "/nonexistent/subdir/config.toml"

        // When/Then: throws directoryNotFound
        XCTAssertThrowsError(
            try CodexConfigManager.enableIPC(port: 41830, token: "tok", configPath: badPath)
        ) { error in
            guard let configError = error as? CodexConfigError else {
                XCTFail("Expected CodexConfigError, got \(type(of: error))")
                return
            }
            if case .directoryNotFound = configError {
                // Expected
            } else {
                XCTFail("Expected .directoryNotFound, got \(configError)")
            }
        }
    }

    // Contract changed (Round 3): dotfiles-managed setups commonly symlink
    // ~/.codex/config.toml to a repo elsewhere, and blanket symlink
    // rejection silently broke IPC configuration for that setup. Calyx
    // now follows the link and writes through to the real target file,
    // leaving the link itself intact.
    func test_enableIPC_symlinkFollowedToRealFile_writesSuccessfullyAndKeepsLinkIntact() throws {
        // Given: configPath is a symlink to a real (empty) file
        let realFile = tempDir + "/real_config.toml"
        FileManager.default.createFile(atPath: realFile, contents: Data("".utf8))
        try FileManager.default.createSymbolicLink(atPath: configPath, withDestinationPath: realFile)

        // Verify it is indeed a symlink
        let attrs = try FileManager.default.attributesOfItem(atPath: configPath)
        XCTAssertEqual(attrs[.type] as? FileAttributeType, .typeSymbolicLink,
                       "Test setup: configPath should be a symlink")

        // When: enableIPC is called through the symlinked path
        try CodexConfigManager.enableIPC(port: 41830, token: "tok", configPath: configPath)

        // Then: the REAL file received the section...
        let realContent = try String(contentsOfFile: realFile, encoding: .utf8)
        XCTAssertTrue(realContent.contains("[mcp_servers.calyx-ipc]"),
                      "enableIPC must write through the symlink into the real file")

        // ...and the symlink itself survives, still pointing at the same target.
        let attrsAfter = try FileManager.default.attributesOfItem(atPath: configPath)
        XCTAssertEqual(attrsAfter[.type] as? FileAttributeType, .typeSymbolicLink,
                       "The symlink at configPath must survive the write")
        let destination = try FileManager.default.destinationOfSymbolicLink(atPath: configPath)
        XCTAssertEqual(destination, realFile)
    }

    // Round 3 fix: resolveConfigPath now follows a multi-hop *dangling*
    // symlink chain (link -> link -> not-yet-existing file) all the way
    // to its final destination, rather than stopping at the first
    // intermediate link. Same shared ConfigFileUtils primitive as every
    // other config manager.
    func test_multiHopDanglingSymlink_writesToFinalDestinationKeepingBothLinksIntact() throws {
        let finalTarget = tempDir + "/dotfiles/config.toml"
        try FileManager.default.createDirectory(
            atPath: (finalTarget as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        let middleLink = tempDir + "/middle-link.toml"
        try FileManager.default.createSymbolicLink(atPath: middleLink, withDestinationPath: finalTarget)
        try FileManager.default.createSymbolicLink(atPath: configPath, withDestinationPath: middleLink)

        try CodexConfigManager.enableIPC(port: 41830, token: "tok", configPath: configPath)

        let realContent = try String(contentsOfFile: finalTarget, encoding: .utf8)
        XCTAssertTrue(realContent.contains("[mcp_servers.calyx-ipc]"),
                      "enableIPC must create the file at the final destination of a multi-hop dangling chain")

        let middleAttrs = try FileManager.default.attributesOfItem(atPath: middleLink)
        XCTAssertEqual(middleAttrs[.type] as? FileAttributeType, .typeSymbolicLink,
                       "The intermediate link must survive as a symlink, not be replaced with a regular file")
    }

    func test_disableIPC_symlinkFollowedToRealFile_removesSuccessfullyAndKeepsLinkIntact() throws {
        // Given: configPath is a symlink to a real file that already has the section
        let realFile = tempDir + "/real_config.toml"
        writeConfig("[mcp_servers.calyx-ipc]\nurl = \"http://localhost:41830/mcp\"\n")
        try FileManager.default.moveItem(atPath: configPath, toPath: realFile)
        try FileManager.default.createSymbolicLink(atPath: configPath, withDestinationPath: realFile)

        // When: disableIPC is called through the symlinked path
        try CodexConfigManager.disableIPC(configPath: configPath)

        // Then: the section is gone from the REAL file...
        let realContent = try String(contentsOfFile: realFile, encoding: .utf8)
        XCTAssertFalse(realContent.contains("[mcp_servers.calyx-ipc]"),
                       "disableIPC must remove the section from the real file reached through the symlink")

        // ...and the symlink itself survives.
        let attrsAfter = try FileManager.default.attributesOfItem(atPath: configPath)
        XCTAssertEqual(attrsAfter[.type] as? FileAttributeType, .typeSymbolicLink,
                       "The symlink at configPath must survive the write")
    }

    // MARK: - Edge Cases

    func test_enableIPC_CRLFLineEndings() throws {
        // Given: file has \r\n line endings
        let existing = "[general]\r\nmodel = \"gpt-4\"\r\ntemperature = 0.7\r\n"
        writeConfig(existing)

        // When
        try CodexConfigManager.enableIPC(port: 41830, token: "tok", configPath: configPath)

        // Then: handled correctly, content normalized to \n
        let content = readConfig()
        XCTAssertFalse(content.contains("\r\n"), "CRLF should be normalized to LF")
        XCTAssertTrue(content.contains("[general]"))
        XCTAssertTrue(content.contains("model = \"gpt-4\""))
        XCTAssertTrue(content.contains("[mcp_servers.calyx-ipc]"))
        XCTAssertTrue(content.contains("http://127.0.0.1:41830/mcp"))
    }

    func test_enableIPC_noTrailingNewline() throws {
        // Given: file doesn't end with \n
        let existing = "[general]\nmodel = \"gpt-4\""
        writeConfig(existing)

        // When
        try CodexConfigManager.enableIPC(port: 41830, token: "tok", configPath: configPath)

        // Then: still works, section is appended
        let content = readConfig()
        XCTAssertTrue(content.contains("[general]"))
        XCTAssertTrue(content.contains("model = \"gpt-4\""))
        XCTAssertTrue(content.contains("[mcp_servers.calyx-ipc]"))
        XCTAssertTrue(content.contains("http://127.0.0.1:41830/mcp"))
    }

    func test_enableIPC_duplicateSections() throws {
        // Given: file has TWO calyx-ipc sections
        let existing = """
        [mcp_servers.calyx-ipc]
        url = "http://localhost:40000/mcp"
        http_headers = { "Authorization" = "Bearer first" }

        [other.section]
        key = "value"

        [mcp_servers.calyx-ipc]
        url = "http://localhost:50000/mcp"
        http_headers = { "Authorization" = "Bearer second" }
        """
        writeConfig(existing)

        // When
        try CodexConfigManager.enableIPC(port: 41830, token: "new-tok", configPath: configPath)

        // Then: both old sections removed, one fresh section added
        let content = readConfig()
        XCTAssertTrue(content.contains("[other.section]"))
        XCTAssertTrue(content.contains("key = \"value\""))
        XCTAssertTrue(content.contains("[mcp_servers.calyx-ipc]"))
        XCTAssertTrue(content.contains("http://127.0.0.1:41830/mcp"))
        XCTAssertTrue(content.contains("Bearer new-tok"))
        // Old values must be gone
        XCTAssertFalse(content.contains("http://localhost:40000/mcp"))
        XCTAssertFalse(content.contains("http://localhost:50000/mcp"))
        XCTAssertFalse(content.contains("Bearer first"))
        XCTAssertFalse(content.contains("Bearer second"))

        // Exactly one calyx-ipc section header
        let headerCount = content.components(separatedBy: "[mcp_servers.calyx-ipc]").count - 1
        XCTAssertEqual(headerCount, 1, "Should have exactly one calyx-ipc section")
    }

    func test_enableIPC_arrayOfTablesIgnored() throws {
        // Given: file has [[array_of_tables]] immediately after the
        // calyx-ipc section header, with no blank-line separator.
        //
        // NOTE: this test's expectation was flipped from the original
        // (which asserted the [[array_of_tables]] block was removed along
        // with calyx-ipc). Per TOML semantics, `[[array_of_tables]]` is
        // itself a table header — it always starts a new table, which means
        // it always ends the calyx-ipc table that precedes it, regardless
        // of adjacency. The old behavior (treating `[[` as "not a
        // boundary") was a semantics bug: it caused a real [[hooks.*]] or
        // other array-of-tables block placed directly after calyx-ipc (no
        // blank line) to be silently swallowed and deleted. The section
        // terminator was corrected to match TOML's actual rule (see
        // CodexConfigManager.anyTableHeaderPattern), so the array-of-tables
        // block below is now correctly preserved instead of removed.
        let existing = """
        [mcp_servers.calyx-ipc]
        url = "http://localhost:40000/mcp"
        [[array_of_tables]]
        name = "should be removed with the section"
        http_headers = { "Authorization" = "Bearer old" }
        """
        writeConfig(existing)

        // When
        try CodexConfigManager.enableIPC(port: 41830, token: "tok", configPath: configPath)

        // Then: calyx-ipc's own body is removed, but [[array_of_tables]]
        // (a table header, hence a section boundary) and everything under
        // it survives.
        let content = readConfig()
        XCTAssertTrue(content.contains("[[array_of_tables]]"),
                       "[[array_of_tables]] is a table header and ends the calyx-ipc section")
        XCTAssertTrue(content.contains("name = \"should be removed with the section\""))
        XCTAssertTrue(content.contains("http_headers = { \"Authorization\" = \"Bearer old\" }"))
        XCTAssertFalse(content.contains("http://localhost:40000/mcp"))
        // Fresh section added
        XCTAssertTrue(content.contains("[mcp_servers.calyx-ipc]"))
        XCTAssertTrue(content.contains("http://127.0.0.1:41830/mcp"))
    }

    // MARK: - Regression (Phase 2): [[hooks.*]] adjacent to calyx-ipc section

    func test_disableIPC_preservesAdjacentCodexHooksArrayOfTablesBlock() throws {
        // Regression: anyTableHeaderPattern's `^[ \t]*\[(?!\[)` excludes
        // array-of-tables headers (`[[`), so a `[[hooks.SessionStart]]`
        // block immediately following `[mcp_servers.calyx-ipc]` was never
        // recognized as the section's boundary and got swallowed as if it
        // were part of the calyx-ipc section body.
        let existing = """
        [mcp_servers.calyx-ipc]
        url = "http://localhost:41830/mcp"
        http_headers = { "Authorization" = "Bearer tok" }

        [[hooks.SessionStart]]
        [[hooks.SessionStart.hooks]]
        type = "command"
        command = "some-other-hook"
        timeout = 5
        """
        writeConfig(existing)

        try CodexConfigManager.disableIPC(configPath: configPath)

        let content = readConfig()
        XCTAssertFalse(content.contains("[mcp_servers.calyx-ipc]"), "calyx-ipc section must be removed")
        XCTAssertTrue(content.contains("[[hooks.SessionStart]]"),
                      "A [[hooks.*]] array-of-tables block immediately after [mcp_servers.calyx-ipc] " +
                      "must survive disableIPC")
        XCTAssertTrue(content.contains("[[hooks.SessionStart.hooks]]"))
        XCTAssertTrue(content.contains("command = \"some-other-hook\""))
        XCTAssertTrue(content.contains("timeout = 5"))
    }

    func test_disableIPC_preservesAdjacentCalyxAgentHooksManagedBlock() throws {
        // Regression: the same bug applied to Calyx's own future
        // CodexHooksConfigManager-managed block — its BEGIN marker line is
        // an ordinary comment line (not a table header), so it too got
        // swallowed by the calyx-ipc section removal.
        let existing = """
        [mcp_servers.calyx-ipc]
        url = "http://localhost:41830/mcp"
        http_headers = { "Authorization" = "Bearer tok" }

        # BEGIN CALYX AGENT HOOKS (managed by Calyx, do not edit)
        [[hooks.SessionStart]]
        [[hooks.SessionStart.hooks]]
        type = "command"
        command = '"/path/to/calyx-agent-hook" codex'
        timeout = 5
        # END CALYX AGENT HOOKS
        """
        writeConfig(existing)

        try CodexConfigManager.disableIPC(configPath: configPath)

        let content = readConfig()
        XCTAssertFalse(content.contains("[mcp_servers.calyx-ipc]"), "calyx-ipc section must be removed")
        XCTAssertTrue(content.contains("# BEGIN CALYX AGENT HOOKS"),
                      "The managed block's BEGIN marker line itself must survive disableIPC")
        XCTAssertTrue(content.contains("[[hooks.SessionStart]]"))
        XCTAssertTrue(content.contains("# END CALYX AGENT HOOKS"),
                      "The managed block's END marker line must survive disableIPC")
    }

    // MARK: - Regression (Phase 2 fix): terminator = table header, not blank line

    func test_disableIPC_noBlankLineBeforeHooksArrayOfTablesBlock_survives() throws {
        // Regression: the section terminator is "any table header line"
        // (including `[[`), not "a blank line". A [[hooks.*]] block
        // immediately following calyx-ipc with NO blank-line separator must
        // still survive disableIPC.
        let existing = """
        [mcp_servers.calyx-ipc]
        url = "http://localhost:41830/mcp"
        http_headers = { "Authorization" = "Bearer tok" }
        [[hooks.SessionStart]]
        [[hooks.SessionStart.hooks]]
        type = "command"
        command = "some-other-hook"
        timeout = 5
        """
        writeConfig(existing)

        try CodexConfigManager.disableIPC(configPath: configPath)

        let content = readConfig()
        XCTAssertFalse(content.contains("[mcp_servers.calyx-ipc]"))
        XCTAssertFalse(content.contains("Bearer tok"))
        XCTAssertTrue(content.contains("[[hooks.SessionStart]]"))
        XCTAssertTrue(content.contains("[[hooks.SessionStart.hooks]]"))
        XCTAssertTrue(content.contains("command = \"some-other-hook\""))
        XCTAssertTrue(content.contains("timeout = 5"))
    }

    func test_disableIPC_noBlankLineBeforeCalyxAgentHooksMarker_survives() throws {
        // Regression: same as above, but for the `# BEGIN CALYX` managed
        // block marker directly abutting calyx-ipc with no blank line.
        let existing = """
        [mcp_servers.calyx-ipc]
        url = "http://localhost:41830/mcp"
        http_headers = { "Authorization" = "Bearer tok" }
        # BEGIN CALYX AGENT HOOKS (managed by Calyx, do not edit)
        [[hooks.SessionStart]]
        [[hooks.SessionStart.hooks]]
        type = "command"
        command = '"/path/to/calyx-agent-hook" codex'
        timeout = 5
        # END CALYX AGENT HOOKS
        """
        writeConfig(existing)

        try CodexConfigManager.disableIPC(configPath: configPath)

        let content = readConfig()
        XCTAssertFalse(content.contains("[mcp_servers.calyx-ipc]"))
        XCTAssertFalse(content.contains("Bearer tok"))
        XCTAssertTrue(content.contains("# BEGIN CALYX AGENT HOOKS"))
        XCTAssertTrue(content.contains("[[hooks.SessionStart]]"))
        XCTAssertTrue(content.contains("# END CALYX AGENT HOOKS"))
    }

    func test_disableIPC_blankLineInsideSectionBody_wholeSectionRemoved() throws {
        // Regression: a blank line used to terminate the section
        // prematurely, leaving the rest of the section's body — including a
        // token-bearing `http_headers` line — behind in the file after
        // disableIPC. Blank lines are no longer a terminator, so the whole
        // section (up to the next real table header) must be removed
        // together, even when a blank line appears in the middle of it.
        let existing = """
        [mcp_servers.calyx-ipc]
        url = "http://localhost:41830/mcp"

        http_headers = { "Authorization" = "Bearer secret-token" }

        [other.section]
        key = "value"
        """
        writeConfig(existing)

        try CodexConfigManager.disableIPC(configPath: configPath)

        let content = readConfig()
        XCTAssertFalse(content.contains("[mcp_servers.calyx-ipc]"))
        XCTAssertFalse(content.contains("Bearer secret-token"),
                       "Bearer token line must not survive even when separated from " +
                       "the section header by a blank line")
        XCTAssertTrue(content.contains("[other.section]"))
        XCTAssertTrue(content.contains("key = \"value\""))
    }

    func test_disableIPC_removesCalyxIpcSubTables() throws {
        // A [mcp_servers.calyx-ipc.*] / [[mcp_servers.calyx-ipc.*]]
        // sub-table header is still part of the calyx-ipc entry per TOML's
        // dotted-key semantics, so it must NOT terminate the section — it
        // must be removed along with the rest of it.
        let existing = """
        [mcp_servers.calyx-ipc]
        url = "http://localhost:41830/mcp"
        http_headers = { "Authorization" = "Bearer tok" }
        [mcp_servers.calyx-ipc.env]
        FOO = "bar"
        [[mcp_servers.calyx-ipc.extra]]
        name = "baz"
        [other.section]
        key = "value"
        """
        writeConfig(existing)

        try CodexConfigManager.disableIPC(configPath: configPath)

        let content = readConfig()
        XCTAssertFalse(content.contains("[mcp_servers.calyx-ipc]"))
        XCTAssertFalse(content.contains("[mcp_servers.calyx-ipc.env]"))
        XCTAssertFalse(content.contains("FOO = \"bar\""))
        XCTAssertFalse(content.contains("[[mcp_servers.calyx-ipc.extra]]"))
        XCTAssertFalse(content.contains("name = \"baz\""))
        XCTAssertTrue(content.contains("[other.section]"))
        XCTAssertTrue(content.contains("key = \"value\""))
    }

    // MARK: - Concurrency

    func test_concurrentEnableDisable_noCorruption() throws {
        // Given: a valid starting config
        writeConfig("")

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
                        try CodexConfigManager.enableIPC(
                            port: 41830 + i,
                            token: "token-\(i)",
                            configPath: self.configPath
                        )
                    } else {
                        try CodexConfigManager.disableIPC(configPath: self.configPath)
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

        // Then: file should be valid TOML (not corrupted)
        // We check structural validity: no mangled section headers, no partial writes
        if FileManager.default.fileExists(atPath: configPath) {
            let content = readConfig()

            // Every line that looks like a section header should be well-formed
            let lines = content.components(separatedBy: "\n")
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("[") && !trimmed.hasPrefix("[[") {
                    // Single-bracket section header should have matching closing bracket
                    XCTAssertTrue(trimmed.contains("]"),
                                  "Section header should be well-formed: \(trimmed)")
                }
            }

            // If calyx-ipc section exists, it should have the url key
            if content.contains("[mcp_servers.calyx-ipc]") {
                XCTAssertTrue(content.contains("url = \"http://127.0.0.1:"),
                              "calyx-ipc section should have url key")
            }
        }
        // Note: some errors are acceptable (contention), but the file must not be corrupted
    }
}
