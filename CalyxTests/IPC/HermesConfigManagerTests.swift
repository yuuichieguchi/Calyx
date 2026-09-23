// HermesConfigManagerTests.swift
// CalyxTests
//
// Tests for `HermesConfigManager`.
//
// Coverage:
// - `enableIPC` upsert behavior for `~/.hermes/config.yaml` (Case A: append, Case B: insert as child)
// - Indent learning (2 vs 4 space) from existing `mcp_servers:` children
// - Idempotent replace of existing managed sub-block
// - YAML scalar escaping (quotes, backslashes, newlines, control chars rejected)
// - Self-healing on malformed managed block during enable
// - `disableIPC` removal preserving user content
// - Strict managed-block detection (BEGIN + END + `calyx-ipc:` all required)
// - Security: invalid UTF-8 rejection
// - Symlink following (writes through to the real target file,
//   dangling-link target creation), consistent with the other 6 config
//   managers
// - `isIPCEnabled` true/false for various structural states

import XCTest
@testable import Calyx

final class HermesConfigManagerTests: XCTestCase {

    // MARK: - Properties

    private var tempDir: String!

    // MARK: - Computed

    private var configPath: String { tempDir + "/config.yaml" }

    // MARK: - Constants

    /// Canonical regex-anchored BEGIN line literal as written by enableIPC.
    private let beginLine = "# BEGIN CALYX IPC (managed by Calyx, do not edit)"
    /// Canonical END line literal as written by enableIPC.
    private let endLine = "# END CALYX IPC"

    // MARK: - Lifecycle

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).path
        try FileManager.default.createDirectory(
            atPath: tempDir,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if let tempDir = tempDir {
            try? FileManager.default.removeItem(atPath: tempDir)
        }
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    /// Write raw string content to `configPath`.
    private func writeConfig(_ content: String) throws {
        try Data(content.utf8).write(to: URL(fileURLWithPath: configPath))
    }

    /// Write raw bytes (e.g. invalid UTF-8) to `configPath`.
    private func writeRaw(_ data: Data) throws {
        try data.write(to: URL(fileURLWithPath: configPath))
    }

    /// Read `configPath` as a UTF-8 string. Returns empty string if missing/unreadable.
    private func readConfig() -> String {
        (try? String(contentsOfFile: configPath, encoding: .utf8)) ?? ""
    }

    /// Count occurrences of a substring in a string.
    private func occurrences(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var search = haystack.startIndex..<haystack.endIndex
        while let r = haystack.range(of: needle, range: search) {
            count += 1
            search = r.upperBound..<haystack.endIndex
        }
        return count
    }

    /// Decode the value of a YAML double-quoted scalar in the form `<key>: "<value>"`.
    /// Returns nil if not found or not in expected form.
    /// Reverses `\\` → `\`, `\"` → `"`, `\n` → newline, `\t` → tab.
    private func decodeQuotedScalar(forKey key: String, in content: String) -> String? {
        // Match: optional indentation + key + ":" + space(s) + quoted value (allow escaped quotes inside)
        // Pattern: "<key>: \"" followed by value with possible escapes, ending with unescaped quote.
        let pattern = #"(?m)^[ \t]*"# + NSRegularExpression.escapedPattern(for: key)
            + #"\s*:\s*"((?:\\.|[^"\\])*)""#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: content,
                range: NSRange(content.startIndex..., in: content)
              ),
              match.numberOfRanges >= 2,
              let valRange = Range(match.range(at: 1), in: content) else {
            return nil
        }
        let raw = String(content[valRange])
        // Undo standard YAML double-quoted escapes used by manager.
        var out = ""
        var i = raw.startIndex
        while i < raw.endIndex {
            let c = raw[i]
            if c == "\\", let next = raw.index(i, offsetBy: 1, limitedBy: raw.endIndex), next < raw.endIndex {
                let n = raw[next]
                switch n {
                case "\\": out.append("\\")
                case "\"": out.append("\"")
                case "n":  out.append("\n")
                case "t":  out.append("\t")
                default:   out.append(n)
                }
                i = raw.index(after: next)
            } else {
                out.append(c)
                i = raw.index(after: i)
            }
        }
        return out
    }

    // MARK: - enableIPC: From scratch

    func test_enableIPC_createsConfigFromScratch() throws {
        // Given: file absent
        XCTAssertFalse(FileManager.default.fileExists(atPath: configPath))

        // When
        try HermesConfigManager.enableIPC(port: 41830, token: "abc123", configPath: configPath)

        // Then: file exists with managed block (Case A) and required content
        XCTAssertTrue(FileManager.default.fileExists(atPath: configPath))
        let content = readConfig()
        XCTAssertTrue(content.contains(beginLine), "Should contain BEGIN line literal")
        XCTAssertTrue(content.contains("calyx-ipc:"), "Should contain calyx-ipc: key")
        XCTAssertTrue(content.contains(endLine), "Should contain END line literal")
        XCTAssertTrue(content.contains("url: \"http://127.0.0.1:41830/mcp\""),
                      "Should contain url scalar with port 41830")
        XCTAssertTrue(content.contains("Authorization: \"Bearer abc123\""),
                      "Should contain Authorization scalar with token")
        XCTAssertTrue(content.contains("X-Calyx-Surface-ID: \"${CALYX_SURFACE_ID}\""),
                      "Hermes must forward the ordinary Calyx surface identity")
        XCTAssertTrue(content.contains("X-Calyx-Session-ID: \"${CALYX_SESSION_ID}\""),
                      "Hermes must forward the stable persistent-session identity when present")
        XCTAssertTrue(content.contains("X-Calyx-Agent-Kind: \"hermes\""),
                      "Hermes MCP initialize must identify the agent kind")
    }

    // MARK: - enableIPC: Append to file without mcp_servers

    func test_enableIPC_appendsToFileWithoutMcpServers() throws {
        // Given: file with unrelated YAML content (no mcp_servers: key)
        let userContent = """
        # User-managed Hermes config
        agent_name: "my-hermes"
        # Some setting comment
        max_tokens: 4096
        """
        try writeConfig(userContent)

        // When
        try HermesConfigManager.enableIPC(port: 41830, token: "tok", configPath: configPath)

        // Then: original lines preserved verbatim AND managed block appended
        let content = readConfig()
        XCTAssertTrue(content.contains("# User-managed Hermes config"),
                      "User comment line should be preserved")
        XCTAssertTrue(content.contains("agent_name: \"my-hermes\""),
                      "User key/value should be preserved")
        XCTAssertTrue(content.contains("# Some setting comment"),
                      "Inline user comment should be preserved")
        XCTAssertTrue(content.contains("max_tokens: 4096"),
                      "User scalar value should be preserved")
        XCTAssertTrue(content.contains(beginLine),
                      "Managed BEGIN line should be appended")
        XCTAssertTrue(content.contains("mcp_servers:"),
                      "Managed block must contain its own mcp_servers: key (Case A)")
        XCTAssertTrue(content.contains("calyx-ipc:"),
                      "Managed block must contain calyx-ipc:")
        XCTAssertTrue(content.contains(endLine),
                      "Managed END line should be appended")
    }

    // MARK: - enableIPC: Insert into existing mcp_servers

    func test_enableIPC_insertsIntoExistingMcpServers() throws {
        // Given: pre-existing mcp_servers: with a child indented 2 spaces
        let existing = """
        agent_name: "hermes"
        mcp_servers:
          stripe:
            url: "https://mcp.stripe.com"
        """
        try writeConfig(existing)

        // When
        try HermesConfigManager.enableIPC(port: 41830, token: "tok", configPath: configPath)

        // Then: stripe entry preserved AND managed sub-block inserted at child indent (2 spaces)
        let content = readConfig()
        XCTAssertTrue(content.contains("stripe:"),
                      "Existing stripe child should be preserved")
        XCTAssertTrue(content.contains("https://mcp.stripe.com"),
                      "Existing stripe url should be preserved")
        XCTAssertTrue(content.contains("calyx-ipc:"),
                      "calyx-ipc child should be added")
        // Marker comments are indented to child level (2 spaces) for Case B.
        XCTAssertTrue(content.contains("  # BEGIN CALYX IPC"),
                      "BEGIN marker should be indented 2 spaces (child level)")
        XCTAssertTrue(content.contains("  # END CALYX IPC"),
                      "END marker should be indented 2 spaces (child level)")
        // Managed block must NOT introduce a SECOND `mcp_servers:` key.
        XCTAssertEqual(occurrences(of: "mcp_servers:", in: content), 1,
                       "Only one mcp_servers: key should exist after Case B insertion")
    }

    // A trailing `# comment` on the `mcp_servers:` header line is valid
    // YAML for a block-style mapping (the comment is not part of the
    // value), so it must be treated as Case B, not rejected as an inline
    // map. The comment survives byte-identically on its own line.
    func test_enableIPC_insertsIntoExistingMcpServers_headerLineHasTrailingComment() throws {
        let existing = """
        mcp_servers: # my servers
          stripe:
            url: "https://mcp.stripe.com"
        """
        try writeConfig(existing)

        try HermesConfigManager.enableIPC(port: 41830, token: "tok", configPath: configPath)

        let expected =
            "mcp_servers: # my servers\n" +
            "  stripe:\n" +
            "    url: \"https://mcp.stripe.com\"\n" +
            "  # BEGIN CALYX IPC (managed by Calyx, do not edit)\n" +
            "  calyx-ipc:\n" +
            "    url: \"http://127.0.0.1:41830/mcp\"\n" +
            "    headers:\n" +
            "      Authorization: \"Bearer tok\"\n" +
            "      X-Calyx-Surface-ID: \"${CALYX_SURFACE_ID}\"\n" +
            "      X-Calyx-Session-ID: \"${CALYX_SESSION_ID}\"\n" +
            "      X-Calyx-Agent-Kind: \"hermes\"\n" +
            "  # END CALYX IPC\n"
        let content = readConfig()
        XCTAssertEqual(content, expected,
                       "The mcp_servers: header's trailing comment must survive byte-identically, and " +
                       "the managed block must be inserted as a Case B child, not rejected as inline")
        XCTAssertEqual(occurrences(of: "mcp_servers:", in: content), 1,
                       "Only one mcp_servers: key should exist after Case B insertion")
    }

    func test_enableIPC_insertsWith4SpaceIndent() throws {
        // Given: pre-existing mcp_servers: with a child indented 4 spaces
        let existing = """
        mcp_servers:
            stripe:
                url: "https://mcp.stripe.com"
        """
        try writeConfig(existing)

        // When
        try HermesConfigManager.enableIPC(port: 41830, token: "tok", configPath: configPath)

        // Then: managed sub-block also indented 4 spaces
        let content = readConfig()
        XCTAssertTrue(content.contains("    # BEGIN CALYX IPC"),
                      "BEGIN marker should match learned 4-space indent")
        XCTAssertTrue(content.contains("    # END CALYX IPC"),
                      "END marker should match learned 4-space indent")
        XCTAssertTrue(content.contains("    calyx-ipc:"),
                      "calyx-ipc: key should be at 4-space indent")
    }

    // MARK: - enableIPC: Idempotency

    func test_enableIPC_idempotentReplacesManagedBlock() throws {
        // Given: file absent
        XCTAssertFalse(FileManager.default.fileExists(atPath: configPath))

        // When: enableIPC is called twice with different ports/tokens
        try HermesConfigManager.enableIPC(port: 41830, token: "first-tok", configPath: configPath)
        try HermesConfigManager.enableIPC(port: 55555, token: "second-tok", configPath: configPath)

        // Then: exactly one BEGIN/END pair with the new values
        let content = readConfig()
        XCTAssertEqual(occurrences(of: beginLine, in: content), 1,
                       "Should have exactly one BEGIN line after second enable")
        XCTAssertEqual(occurrences(of: endLine, in: content), 1,
                       "Should have exactly one END line after second enable")
        XCTAssertTrue(content.contains("http://127.0.0.1:55555/mcp"),
                      "URL should reflect the new port")
        XCTAssertTrue(content.contains("Bearer second-tok"),
                      "Authorization should reflect the new token")
        XCTAssertFalse(content.contains("http://127.0.0.1:41830/mcp"),
                       "Old URL should be gone")
        XCTAssertFalse(content.contains("Bearer first-tok"),
                       "Old token should be gone")
    }

    func test_enableIPC_repeatedUpdatePreservesFollowingTopLevelSection() throws {
        let original = """
        mcp_servers:
          stripe:
            url: "https://mcp.stripe.com"
        toolsets:
          - web
        """
        try writeConfig(original)

        try HermesConfigManager.enableIPC(port: 41830, token: "first", configPath: configPath)
        try HermesConfigManager.enableIPC(port: 55555, token: "second", configPath: configPath)

        let expected = """
        mcp_servers:
          stripe:
            url: "https://mcp.stripe.com"
          # BEGIN CALYX IPC (managed by Calyx, do not edit)
          calyx-ipc:
            url: "http://127.0.0.1:55555/mcp"
            headers:
              Authorization: "Bearer second"
              X-Calyx-Surface-ID: "${CALYX_SURFACE_ID}"
              X-Calyx-Session-ID: "${CALYX_SESSION_ID}"
              X-Calyx-Agent-Kind: "hermes"
          # END CALYX IPC
        toolsets:
          - web
        """
        XCTAssertEqual(readConfig(), expected)
    }

    func test_enableIPC_selfHealingOrphanEndPreservesFollowingTopLevelSection() throws {
        let malformed = """
        mcp_servers:
          stripe:
            url: "https://mcp.stripe.com"
          # END CALYX IPC
        toolsets:
          - web
        """
        try writeConfig(malformed)

        try HermesConfigManager.enableIPC(port: 41830, token: "fresh", configPath: configPath)

        let content = readConfig()
        XCTAssertTrue(content.contains("# END CALYX IPC\ntoolsets:"), content)
        XCTAssertFalse(content.contains("stripe.com\"toolsets:"), content)
        XCTAssertEqual(occurrences(of: endLine, in: content), 1)
    }

    // MARK: - enableIPC: Unsupported YAML structure

    func test_enableIPC_throwsOnInlineMcpServersMap() throws {
        // Given: pre-existing inline-map form `mcp_servers: {}`
        let existing = """
        agent_name: "hermes"
        mcp_servers: {}
        """
        try writeConfig(existing)

        // When/Then: throws .unsupportedYamlStructure
        XCTAssertThrowsError(
            try HermesConfigManager.enableIPC(port: 41830, token: "tok", configPath: configPath)
        ) { error in
            guard let configError = error as? HermesConfigError else {
                XCTFail("Expected HermesConfigError, got \(type(of: error))")
                return
            }
            if case .unsupportedYamlStructure = configError {
                // Expected
            } else {
                XCTFail("Expected .unsupportedYamlStructure, got \(configError)")
            }
        }
    }

    func test_enableIPC_throwsOnTabIndent() throws {
        // Given: pre-existing mcp_servers: with tab-indented children
        let existing = "mcp_servers:\n\tstripe:\n\t\turl: \"https://mcp.stripe.com\"\n"
        try writeConfig(existing)

        // When/Then: throws .unsupportedYamlStructure
        XCTAssertThrowsError(
            try HermesConfigManager.enableIPC(port: 41830, token: "tok", configPath: configPath)
        ) { error in
            guard let configError = error as? HermesConfigError else {
                XCTFail("Expected HermesConfigError, got \(type(of: error))")
                return
            }
            if case .unsupportedYamlStructure = configError {
                // Expected
            } else {
                XCTFail("Expected .unsupportedYamlStructure, got \(configError)")
            }
        }
    }

    // MARK: - enableIPC: Encoding / Security

    // HermesConfigManager operates byte-for-byte via LineDoc rather than
    // decoding the whole file as a `String` up front, so invalid UTF-8
    // bytes elsewhere in the file are no longer a reason to refuse the
    // write: the bytes are preserved verbatim and the managed block is
    // still appended (no line in them decodes to a top-level
    // `mcp_servers:` match, so this always takes Case A).
    func test_enableIPC_invalidUTF8Bytes_preservedVerbatim_managedBlockStillAppended() throws {
        // Given: file with invalid UTF-8 bytes
        let originalBytes = Data([0xFF, 0xFE, 0xFD])
        try writeRaw(originalBytes)

        // When/Then: does not throw
        XCTAssertNoThrow(
            try HermesConfigManager.enableIPC(port: 41830, token: "tok", configPath: configPath)
        )

        let finalData = try Data(contentsOf: URL(fileURLWithPath: configPath))
        XCTAssertTrue(finalData.starts(with: originalBytes),
                      "The original invalid-UTF-8 bytes must be preserved verbatim")
        let finalContent = String(decoding: finalData, as: UTF8.self)
        XCTAssertTrue(finalContent.contains(beginLine), "The managed block should still be appended")
    }

    // Contract: dotfiles-managed setups commonly symlink
    // ~/.hermes/config.yaml to a repo elsewhere, and blanket symlink
    // rejection silently broke IPC configuration entirely for that
    // (legitimate, self-authored) setup — the same fix as the other 6
    // config managers. Calyx now follows the link and writes through to
    // the real target file, leaving the link itself intact.
    func test_enableIPC_symlinkFollowedToRealFile_writesSuccessfullyAndKeepsLinkIntact() throws {
        // Given: configPath is a symlink to a real file
        let realFile = tempDir + "/real_config.yaml"
        try writeConfig("agent_name: \"hermes\"\n")
        try FileManager.default.moveItem(atPath: configPath, toPath: realFile)
        try FileManager.default.createSymbolicLink(
            atPath: configPath,
            withDestinationPath: realFile
        )

        // Sanity check: it really is a symlink.
        let attrs = try FileManager.default.attributesOfItem(atPath: configPath)
        XCTAssertEqual(attrs[.type] as? FileAttributeType, .typeSymbolicLink,
                       "Test setup: configPath should be a symlink")

        // When: enableIPC is called through the symlinked path
        try HermesConfigManager.enableIPC(port: 41830, token: "tok", configPath: configPath)

        // Then: the REAL file received the managed block, and the user's
        // existing content survived alongside it...
        let realContent = try String(contentsOfFile: realFile, encoding: .utf8)
        XCTAssertTrue(realContent.contains(beginLine),
                      "enableIPC must write the managed block through the symlink into the real file")
        XCTAssertTrue(realContent.contains("agent_name: \"hermes\""),
                      "The user's existing content must be preserved in the real file")

        // ...and the symlink itself is still a symlink pointing at the same target.
        let attrsAfter = try FileManager.default.attributesOfItem(atPath: configPath)
        XCTAssertEqual(attrsAfter[.type] as? FileAttributeType, .typeSymbolicLink,
                       "The symlink at configPath must survive the write, not be replaced with a regular file")
        let destination = try FileManager.default.destinationOfSymbolicLink(atPath: configPath)
        XCTAssertEqual(destination, realFile, "The symlink must still point at the same real file")
    }

    func test_enableIPC_danglingSymlink_createsRealFileAtLinkTarget() throws {
        // The classic "pre-linked, target not yet created" dotfiles state:
        // `chezmoi`/`stow`-style tooling can lay down the symlink before
        // the tracked file exists in the repo.
        let dotfilesDir = tempDir + "/dotfiles"
        try FileManager.default.createDirectory(atPath: dotfilesDir, withIntermediateDirectories: true)
        let targetPath = dotfilesDir + "/config.yaml"
        try FileManager.default.createSymbolicLink(atPath: configPath, withDestinationPath: targetPath)
        XCTAssertFalse(FileManager.default.fileExists(atPath: targetPath),
                       "Precondition: the symlink's target must not exist yet (dangling)")

        try HermesConfigManager.enableIPC(port: 41830, token: "tok", configPath: configPath)

        XCTAssertTrue(FileManager.default.fileExists(atPath: targetPath),
                      "enableIPC must create the file at the dangling symlink's target path")
        let content = try String(contentsOfFile: targetPath, encoding: .utf8)
        XCTAssertTrue(content.contains(beginLine))

        let attrs = try FileManager.default.attributesOfItem(atPath: configPath)
        XCTAssertEqual(attrs[.type] as? FileAttributeType, .typeSymbolicLink,
                       "The now-resolved symlink must remain a symlink, not become a regular file")
    }

    // resolveConfigPath follows a multi-hop *dangling*
    // symlink chain (link -> link -> not-yet-existing file) all the way
    // to its final destination, rather than stopping at the first
    // intermediate link. Same shared ConfigFileUtils primitive as every
    // other config manager.
    func test_enableIPC_multiHopDanglingSymlink_writesToFinalDestinationKeepingBothLinksIntact() throws {
        let dotfilesDir = tempDir + "/dotfiles"
        try FileManager.default.createDirectory(atPath: dotfilesDir, withIntermediateDirectories: true)
        let finalTarget = dotfilesDir + "/config.yaml"
        let middleLink = tempDir + "/middle-link.yaml"
        try FileManager.default.createSymbolicLink(atPath: middleLink, withDestinationPath: finalTarget)
        try FileManager.default.createSymbolicLink(atPath: configPath, withDestinationPath: middleLink)

        try HermesConfigManager.enableIPC(port: 41830, token: "tok", configPath: configPath)

        XCTAssertTrue(FileManager.default.fileExists(atPath: finalTarget),
                      "enableIPC must create the file at the multi-hop dangling chain's final destination")
        let content = try String(contentsOfFile: finalTarget, encoding: .utf8)
        XCTAssertTrue(content.contains(beginLine))

        let middleAttrs = try FileManager.default.attributesOfItem(atPath: middleLink)
        XCTAssertEqual(middleAttrs[.type] as? FileAttributeType, .typeSymbolicLink,
                       "The intermediate link must survive as a symlink, not be replaced with a regular file")
    }

    // MARK: - enableIPC: Self-healing

    func test_enableIPC_recoversFromMalformedBlock() throws {
        // Given: file has an orphan BEGIN line with no matching END
        let existing = """
        agent_name: "hermes"
        # BEGIN CALYX IPC (managed by Calyx, do not edit)
        mcp_servers:
          calyx-ipc:
            url: "http://localhost:1111/mcp"
        # No END line — orphan managed block
        max_tokens: 4096
        """
        try writeConfig(existing)

        // When: enableIPC is called — must self-heal (no exception)
        XCTAssertNoThrow(
            try HermesConfigManager.enableIPC(port: 41830, token: "fresh", configPath: configPath),
            "enableIPC should self-heal from a malformed managed block, not throw"
        )

        // Then: result has exactly one BEGIN/END pair (the freshly written one),
        //       no orphan BEGIN remains, and the new token/port are present.
        let content = readConfig()
        XCTAssertEqual(occurrences(of: beginLine, in: content), 1,
                       "After self-heal, exactly one BEGIN line should remain")
        XCTAssertEqual(occurrences(of: endLine, in: content), 1,
                       "After self-heal, exactly one END line should remain")
        XCTAssertTrue(content.contains("Bearer fresh"),
                      "New token should be present")
        XCTAssertTrue(content.contains("http://127.0.0.1:41830/mcp"),
                      "New URL should be present")
        XCTAssertFalse(content.contains("http://localhost:1111/mcp"),
                       "Stale URL from orphan block should be gone")
    }

    // MARK: - enableIPC: Scalar escaping

    func test_enableIPC_escapesTokenWithQuotesAndBackslashes() throws {
        // Given: token containing characters that must be escaped in YAML double-quoted scalars
        let trickyToken = "tk\"with\\and\nnewline"

        // When
        try HermesConfigManager.enableIPC(port: 41830, token: trickyToken, configPath: configPath)

        // Then: written file's Authorization scalar can be re-decoded back to "Bearer <trickyToken>".
        let content = readConfig()
        guard let decoded = decodeQuotedScalar(forKey: "Authorization", in: content) else {
            XCTFail("Could not extract Authorization quoted scalar from written file")
            return
        }
        XCTAssertEqual(decoded, "Bearer " + trickyToken,
                       "Round-tripped Authorization scalar must equal 'Bearer <token>'")

        // And: literal escape form should be present in the file (defensive).
        XCTAssertTrue(content.contains("Authorization: \"Bearer tk\\\"with\\\\and\\nnewline\""),
                      "Authorization line should use YAML double-quoted escapes")
    }

    func test_enableIPC_rejectsControlCharsInToken() throws {
        // Given: token containing a control character (SOH = U+0001)
        let badToken = "abc\u{0001}def"

        // When/Then: throws .invalidScalarValue
        XCTAssertThrowsError(
            try HermesConfigManager.enableIPC(port: 41830, token: badToken, configPath: configPath)
        ) { error in
            guard let configError = error as? HermesConfigError else {
                XCTFail("Expected HermesConfigError, got \(type(of: error))")
                return
            }
            if case .invalidScalarValue = configError {
                // Expected
            } else {
                XCTFail("Expected .invalidScalarValue, got \(configError)")
            }
        }
    }

    // MARK: - disableIPC: Removal

    func test_disableIPC_removesManagedBlock_preservesUserContent() throws {
        // Given: Case A setup (managed block at end after user content)
        let userPrefix = """
        agent_name: "hermes"
        max_tokens: 4096
        """
        try writeConfig(userPrefix)
        try HermesConfigManager.enableIPC(port: 41830, token: "tok", configPath: configPath)

        // Sanity: enable produced a managed block.
        XCTAssertTrue(readConfig().contains(beginLine),
                      "Test setup: enable should have written a managed block")

        // When
        try HermesConfigManager.disableIPC(configPath: configPath)

        // Then: user content remains, managed block is gone.
        let content = readConfig()
        XCTAssertTrue(content.contains("agent_name: \"hermes\""),
                      "User key should be preserved")
        XCTAssertTrue(content.contains("max_tokens: 4096"),
                      "User key should be preserved")
        XCTAssertFalse(content.contains(beginLine),
                       "BEGIN line should be removed")
        XCTAssertFalse(content.contains(endLine),
                       "END line should be removed")
        XCTAssertFalse(content.contains("calyx-ipc:"),
                       "calyx-ipc key should be removed")
    }

    func test_disableIPC_restoresContentAroundMiddleManagedBlockExactly() throws {
        let original = """
        mcp_servers:
          stripe:
            url: "https://mcp.stripe.com"
        toolsets:
          - web
        """
        try writeConfig(original)
        try HermesConfigManager.enableIPC(port: 41830, token: "tok", configPath: configPath)

        try HermesConfigManager.disableIPC(configPath: configPath)

        XCTAssertEqual(readConfig(), original)
    }

    func test_disableIPC_restoresCaseAWithSingleFinalNewline() throws {
        let original = "agent_name: \"hermes\"\nmax_tokens: 4096\n"
        try writeConfig(original)
        try HermesConfigManager.enableIPC(port: 41830, token: "tok", configPath: configPath)

        try HermesConfigManager.disableIPC(configPath: configPath)

        XCTAssertEqual(readConfig(), original)
    }

    func test_disableIPC_keepsExistingMcpServers() throws {
        // Given: Case B setup with stripe + managed sub-block (created by enableIPC)
        let existing = """
        mcp_servers:
          stripe:
            url: "https://mcp.stripe.com"
        """
        try writeConfig(existing)
        try HermesConfigManager.enableIPC(port: 41830, token: "tok", configPath: configPath)

        // Sanity: enable produced a managed sub-block under the existing key.
        let afterEnable = readConfig()
        XCTAssertTrue(afterEnable.contains("stripe:"))
        XCTAssertTrue(afterEnable.contains("calyx-ipc:"))

        // When
        try HermesConfigManager.disableIPC(configPath: configPath)

        // Then: stripe child remains AND parent mcp_servers: remains, managed sub-block gone.
        let content = readConfig()
        XCTAssertTrue(content.contains("stripe:"),
                      "Existing stripe child should be preserved")
        XCTAssertTrue(content.contains("https://mcp.stripe.com"),
                      "Existing stripe url should be preserved")
        XCTAssertTrue(content.contains("mcp_servers:"),
                      "mcp_servers: parent key should remain")
        XCTAssertFalse(content.contains(beginLine),
                       "BEGIN marker (managed) should be removed")
        XCTAssertFalse(content.contains(endLine),
                       "END marker (managed) should be removed")
        XCTAssertFalse(content.contains("calyx-ipc:"),
                       "calyx-ipc child should be removed")
    }

    func test_disableIPC_removesEmptyMcpServersWhenOnlyChild() throws {
        // Given: Case A setup — mcp_servers: was created by enableIPC and contains only calyx-ipc
        try HermesConfigManager.enableIPC(port: 41830, token: "tok", configPath: configPath)

        // Sanity: file has the managed block including its own mcp_servers: key.
        let afterEnable = readConfig()
        XCTAssertTrue(afterEnable.contains("mcp_servers:"))
        XCTAssertTrue(afterEnable.contains("calyx-ipc:"))

        // When
        try HermesConfigManager.disableIPC(configPath: configPath)

        // Then: the entire mcp_servers: key is removed (since it was inside the managed block).
        let content = readConfig()
        XCTAssertFalse(content.contains("mcp_servers:"),
                       "mcp_servers: should be removed when it was wholly inside the managed block")
        XCTAssertFalse(content.contains("calyx-ipc:"),
                       "calyx-ipc: should be removed")
        XCTAssertFalse(content.contains(beginLine),
                       "BEGIN line should be removed")
        XCTAssertFalse(content.contains(endLine),
                       "END line should be removed")
    }

    func test_disableIPC_missingFile_noop() {
        // Given: no file
        XCTAssertFalse(FileManager.default.fileExists(atPath: configPath))

        // When/Then: no throw
        XCTAssertNoThrow(try HermesConfigManager.disableIPC(configPath: configPath))

        // And: no file created
        XCTAssertFalse(FileManager.default.fileExists(atPath: configPath),
                       "disableIPC must not create the file when it does not exist")
    }

    // An orphan BEGIN (no matching END) now self-heals instead of
    // throwing: `isOwnBodyLine` recognizes the stale mcp_servers:/
    // calyx-ipc:/url: body that follows it as Calyx's own, so the whole
    // orphan span is removed, leaving the surrounding user content intact.
    func test_disableIPC_orphanBeginOnly_selfHealsInsteadOfThrowing() throws {
        // Given: pre-existing BEGIN line with no matching END
        let existing = """
        agent_name: "hermes"
        # BEGIN CALYX IPC (managed by Calyx, do not edit)
        mcp_servers:
          calyx-ipc:
            url: "http://localhost:1111/mcp"
        max_tokens: 4096
        """
        try writeConfig(existing)

        // When/Then: does not throw
        XCTAssertNoThrow(try HermesConfigManager.disableIPC(configPath: configPath))

        let content = readConfig()
        XCTAssertEqual(content, "agent_name: \"hermes\"\nmax_tokens: 4096")
    }

    // An orphan END (no matching BEGIN) now self-heals instead of
    // throwing: only the orphan END marker itself is removed -- content
    // that never had a BEGIN marker over it was never inside Calyx's owned
    // span, so it survives untouched.
    func test_disableIPC_orphanEndOnly_selfHealsInsteadOfThrowing() throws {
        // Given: pre-existing END line with no matching BEGIN
        let existing = """
        agent_name: "hermes"
        mcp_servers:
          calyx-ipc:
            url: "http://localhost:1111/mcp"
        # END CALYX IPC
        max_tokens: 4096
        """
        try writeConfig(existing)

        // When/Then: does not throw
        XCTAssertNoThrow(try HermesConfigManager.disableIPC(configPath: configPath))

        let content = readConfig()
        XCTAssertEqual(
            content,
            "agent_name: \"hermes\"\nmcp_servers:\n  calyx-ipc:\n    url: \"http://localhost:1111/mcp\"\nmax_tokens: 4096"
        )
    }

    // A well-formed BEGIN/END pair whose body has no calyx-ipc: line is
    // still Calyx-owned territory (the marker span, not its content,
    // establishes ownership), but nothing in the body was identified as
    // Calyx's own -- so the whole body is foreign and is preserved in
    // place of the removed markers, instead of throwing.
    func test_disableIPC_beginEndWithNoCalyxIpcBody_preservesBodyInsteadOfThrowing() throws {
        // Given: pre-existing BEGIN/END pair but NO calyx-ipc: key between them
        let existing = """
        agent_name: "hermes"
        # BEGIN CALYX IPC (managed by Calyx, do not edit)
        # someone deleted the calyx-ipc body
        # END CALYX IPC
        max_tokens: 4096
        """
        try writeConfig(existing)

        // When/Then: does not throw
        XCTAssertNoThrow(try HermesConfigManager.disableIPC(configPath: configPath))

        let content = readConfig()
        XCTAssertEqual(
            content,
            "agent_name: \"hermes\"\n# someone deleted the calyx-ipc body\nmax_tokens: 4096"
        )
    }

    // Contract: see the enableIPC symlink tests above —
    // disableIPC now follows the link and removes the managed block from
    // the real target file, leaving the link itself intact.
    func test_disableIPC_symlinkFollowedToRealFile_removesSuccessfullyAndKeepsLinkIntact() throws {
        // Given: configPath is a symlink to a real file that already has
        // a well-formed managed block.
        let realFile = tempDir + "/real_config.yaml"
        let existing = """
        agent_name: "hermes"
        \(beginLine)
        mcp_servers:
          calyx-ipc:
            url: "http://localhost:41830/mcp"
        \(endLine)
        """
        try writeConfig(existing)
        try FileManager.default.moveItem(atPath: configPath, toPath: realFile)
        try FileManager.default.createSymbolicLink(
            atPath: configPath,
            withDestinationPath: realFile
        )

        // When: disableIPC is called through the symlinked path
        try HermesConfigManager.disableIPC(configPath: configPath)

        // Then: the managed block is gone from the REAL file, and the
        // user's content survived...
        let realContent = try String(contentsOfFile: realFile, encoding: .utf8)
        XCTAssertFalse(realContent.contains(beginLine),
                       "disableIPC must remove the managed block from the real file reached through the symlink")
        XCTAssertTrue(realContent.contains("agent_name: \"hermes\""),
                      "The user's existing content must be preserved in the real file")

        // ...and the symlink itself survives.
        let attrsAfter = try FileManager.default.attributesOfItem(atPath: configPath)
        XCTAssertEqual(attrsAfter[.type] as? FileAttributeType, .typeSymbolicLink,
                       "The symlink at configPath must survive the write")
    }

    // Same byte-for-byte reasoning as enableIPC's invalid-UTF-8 case above:
    // no BEGIN/END marker byte sequence matches inside invalid UTF-8 bytes,
    // so disableIPC finds nothing of its own to remove and leaves the file
    // untouched rather than throwing.
    func test_disableIPC_invalidUTF8Bytes_leftUntouched() throws {
        // Given: file with invalid UTF-8 bytes
        let originalBytes = Data([0xFF, 0xFE, 0xFD])
        try writeRaw(originalBytes)

        // When/Then: does not throw
        XCTAssertNoThrow(try HermesConfigManager.disableIPC(configPath: configPath))

        let finalData = try Data(contentsOf: URL(fileURLWithPath: configPath))
        XCTAssertEqual(finalData, originalBytes, "disableIPC must leave unrecognized bytes untouched")
    }

    // MARK: - isIPCEnabled

    func test_isIPCEnabled_trueForCompleteManagedBlock() throws {
        // Given: complete managed block written by enableIPC
        try HermesConfigManager.enableIPC(port: 41830, token: "tok", configPath: configPath)

        // When/Then
        XCTAssertTrue(HermesConfigManager.isIPCEnabled(configPath: configPath))
    }

    // An orphan BEGIN (no matching END) is still Calyx-owned territory:
    // disableIPC's own markerEditor.removeBlock self-heals it (see
    // isOwnBodyLine) rather than leaving it untouched. isIPCEnabled must
    // use the same detection rule, so it must report true here too.
    func test_isIPCEnabled_trueForOrphanBeginOnly() throws {
        // Given: BEGIN line only (no END)
        let existing = """
        # BEGIN CALYX IPC (managed by Calyx, do not edit)
        mcp_servers:
          calyx-ipc:
            url: "http://localhost:1111/mcp"
        """
        try writeConfig(existing)

        // When/Then
        XCTAssertTrue(HermesConfigManager.isIPCEnabled(configPath: configPath))
    }

    // Same reasoning as the orphan-BEGIN case above: an orphan END (no
    // matching BEGIN) self-heals too, so isIPCEnabled must report true.
    func test_isIPCEnabled_trueForOrphanEndOnly() throws {
        // Given: END line only
        let existing = """
        mcp_servers:
          calyx-ipc:
            url: "http://localhost:1111/mcp"
        # END CALYX IPC
        """
        try writeConfig(existing)

        // When/Then
        XCTAssertTrue(HermesConfigManager.isIPCEnabled(configPath: configPath))
    }

    // A BEGIN/END pair with no calyx-ipc: line between them is still
    // Calyx-owned territory: disableIPC's own markerEditor.removeBlock
    // requires only a matched BEGIN/END pair and would remove this exact
    // block. isIPCEnabled must use the same detection rule, so it must
    // report true here too.
    func test_isIPCEnabled_trueForBeginEndWithoutCalyxIpc() throws {
        let existing = """
        # BEGIN CALYX IPC (managed by Calyx, do not edit)
        # nothing useful here
        # END CALYX IPC
        """
        try writeConfig(existing)

        XCTAssertTrue(HermesConfigManager.isIPCEnabled(configPath: configPath))
    }

    // Same content as above, with the document's line endings all CRLF.
    func test_isIPCEnabled_trueForBeginEndWithoutCalyxIpc_crlfFile() throws {
        let existing = [
            "# BEGIN CALYX IPC (managed by Calyx, do not edit)",
            "# nothing useful here",
            "# END CALYX IPC",
        ].joined(separator: "\r\n")
        try writeConfig(existing)

        XCTAssertTrue(HermesConfigManager.isIPCEnabled(configPath: configPath))
    }

    func test_isIPCEnabled_falseForMissingFile() {
        // Given: no file
        XCTAssertFalse(FileManager.default.fileExists(atPath: configPath))

        // When/Then
        XCTAssertFalse(HermesConfigManager.isIPCEnabled(configPath: configPath))
    }

    func test_isIPCEnabled_falseAfterDisable() throws {
        // Given: enabled, then disabled
        try HermesConfigManager.enableIPC(port: 41830, token: "tok", configPath: configPath)
        XCTAssertTrue(HermesConfigManager.isIPCEnabled(configPath: configPath),
                      "Test setup: should be enabled after enableIPC")
        try HermesConfigManager.disableIPC(configPath: configPath)

        // When/Then
        XCTAssertFalse(HermesConfigManager.isIPCEnabled(configPath: configPath),
                       "Should be disabled after disableIPC")
    }

    func test_isIPCEnabled_ignoresUserCommentMentioningBeginCalyxIpc() throws {
        // Given: a user-written line that mentions "BEGIN CALYX IPC" mid-line —
        // this is NOT a real managed block start because the regex requires line-start.
        let existing = """
        agent_name: "hermes"
        # something # BEGIN CALYX IPC blah blah — note from a user, not a real marker
        mcp_servers:
          calyx-ipc:
            url: "http://localhost:1111/mcp"
        """
        try writeConfig(existing)

        // When/Then: not a real managed block (no real BEGIN/END pair surrounding calyx-ipc)
        XCTAssertFalse(HermesConfigManager.isIPCEnabled(configPath: configPath),
                       "isIPCEnabled should ignore mid-line mentions of BEGIN CALYX IPC")
    }

    // MARK: - Never delete a user-owned file

    func test_disableIPC_afterEnable_onUserCreatedEmptyFile_leavesFilePresentAndEmpty() throws {
        FileManager.default.createFile(atPath: configPath, contents: Data())
        XCTAssertTrue(FileManager.default.fileExists(atPath: configPath), "precondition: empty file exists")

        try HermesConfigManager.enableIPC(port: 41830, token: "tok", configPath: configPath)
        try HermesConfigManager.disableIPC(configPath: configPath)

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: configPath),
            "a file the user created must never be deleted by Calyx, even once it became entirely Calyx's own region"
        )
        let data = try Data(contentsOf: URL(fileURLWithPath: configPath))
        XCTAssertEqual(data, Data(), "the file must be left behind empty, not with a leftover blank line or deleted")
    }

    func test_disableIPC_onAbsentFile_leavesFileAbsent() throws {
        XCTAssertFalse(FileManager.default.fileExists(atPath: configPath))
        try HermesConfigManager.disableIPC(configPath: configPath)
        XCTAssertFalse(FileManager.default.fileExists(atPath: configPath), "disableIPC must never create a file that never existed")
    }

    // MARK: - An existing block is replaced in place, never moved to EOF

    func test_enableIPC_caseABlockFollowedByUserKey_samePortToken_isNoOpByteIdenticalAndUnwritten() throws {
        try HermesConfigManager.enableIPC(port: 41830, token: "tok", configPath: configPath)
        let generatedBlock = readConfig()
        let userKey = "other_setting: 1\n"
        try writeConfig(generatedBlock + userKey)

        let attrsBefore = try FileManager.default.attributesOfItem(atPath: configPath)
        let inodeBefore = attrsBefore[.systemFileNumber] as? Int

        try HermesConfigManager.enableIPC(port: 41830, token: "tok", configPath: configPath)

        let content = readConfig()
        XCTAssertEqual(
            content, generatedBlock + userKey,
            "re-enabling with identical port/token must leave the file byte-identical, the block staying in " +
            "place before the user's key rather than moving to EOF"
        )
        let attrsAfter = try FileManager.default.attributesOfItem(atPath: configPath)
        XCTAssertEqual(
            inodeBefore, attrsAfter[.systemFileNumber] as? Int,
            "byte-identical output must skip the write entirely (inode unchanged)"
        )
    }

    func test_enableIPC_caseABlockFollowedByUserKey_differentToken_keepsPositionChangesOnlyAuthorization() throws {
        try HermesConfigManager.enableIPC(port: 41830, token: "old-tok", configPath: configPath)
        let generatedBlock = readConfig()
        let userKey = "other_setting: 1\n"
        try writeConfig(generatedBlock + userKey)

        try HermesConfigManager.enableIPC(port: 41830, token: "new-tok", configPath: configPath)

        let content = readConfig()
        XCTAssertTrue(content.hasSuffix(userKey), "the user's key must remain at EOF, untouched")
        XCTAssertTrue(content.contains("Bearer new-tok"))
        XCTAssertFalse(content.contains("Bearer old-tok"))
        let beginRange = try XCTUnwrap(content.range(of: beginLine))
        let userRange = try XCTUnwrap(content.range(of: "other_setting: 1"))
        XCTAssertLessThan(
            beginRange.lowerBound, userRange.lowerBound,
            "the block must stay before the user's key, not move to after it"
        )
    }

    func test_enableIPC_caseBBlockFollowedByAnotherUserChild_samePortToken_isNoOpByteIdenticalAndUnwritten() throws {
        try writeConfig("mcp_servers:\n  other:\n    url: \"x\"\n")
        try HermesConfigManager.enableIPC(port: 41830, token: "tok", configPath: configPath)
        let afterFirstEnable = readConfig()
        let fixture = afterFirstEnable + "  another_child: 2\n"
        try writeConfig(fixture)

        let attrsBefore = try FileManager.default.attributesOfItem(atPath: configPath)
        let inodeBefore = attrsBefore[.systemFileNumber] as? Int

        try HermesConfigManager.enableIPC(port: 41830, token: "tok", configPath: configPath)

        let content = readConfig()
        XCTAssertEqual(
            content, fixture,
            "re-enabling with identical port/token must leave the file byte-identical, the Case B block " +
            "staying in place before the mapping's other child rather than moving to EOF"
        )
        let attrsAfter = try FileManager.default.attributesOfItem(atPath: configPath)
        XCTAssertEqual(
            inodeBefore, attrsAfter[.systemFileNumber] as? Int,
            "byte-identical output must skip the write entirely (inode unchanged)"
        )
    }

    func test_enableIPC_caseBBlockFollowedByAnotherUserChild_differentToken_keepsPosition() throws {
        try writeConfig("mcp_servers:\n  other:\n    url: \"x\"\n")
        try HermesConfigManager.enableIPC(port: 41830, token: "old-tok", configPath: configPath)
        let afterFirstEnable = readConfig()
        try writeConfig(afterFirstEnable + "  another_child: 2\n")

        try HermesConfigManager.enableIPC(port: 41830, token: "new-tok", configPath: configPath)

        let content = readConfig()
        XCTAssertTrue(content.hasSuffix("  another_child: 2\n"), "the sibling child must remain the mapping's last child, untouched")
        XCTAssertTrue(content.contains("Bearer new-tok"))
        XCTAssertFalse(content.contains("Bearer old-tok"))
        let beginRange = try XCTUnwrap(content.range(of: beginLine))
        let siblingRange = try XCTUnwrap(content.range(of: "another_child: 2"))
        XCTAssertLessThan(
            beginRange.lowerBound, siblingRange.lowerBound,
            "the block must stay before the sibling child, not move to after it"
        )
    }

    /// Builds a Case B document in which a column-0 YAML comment line sits
    /// between the user's first child and Calyx's block, with another user
    /// child after the block. A column-0 comment does not end the
    /// `mcp_servers:` mapping, so the block is still a child of it.
    private func caseBFixtureWithColumnZeroCommentBeforeBlock(token: String) throws -> String {
        try writeConfig("mcp_servers:\n  other:\n    url: \"x\"\n")
        try HermesConfigManager.enableIPC(port: 41830, token: token, configPath: configPath)
        let afterFirstEnable = readConfig()
        let blockStart = try XCTUnwrap(afterFirstEnable.range(of: "  " + beginLine))
        return afterFirstEnable[..<blockStart.lowerBound] + "# user note\n" +
            afterFirstEnable[blockStart.lowerBound...] + "  another_child: 2\n"
    }

    func test_enableIPC_caseBBlockAfterColumnZeroComment_samePortToken_isNoOpByteIdenticalAndUnwritten() throws {
        let fixture = try caseBFixtureWithColumnZeroCommentBeforeBlock(token: "tok")
        try writeConfig(fixture)

        let attrsBefore = try FileManager.default.attributesOfItem(atPath: configPath)
        let inodeBefore = attrsBefore[.systemFileNumber] as? Int

        try HermesConfigManager.enableIPC(port: 41830, token: "tok", configPath: configPath)

        let content = readConfig()
        XCTAssertEqual(
            content, fixture,
            "re-enabling with identical port/token must leave the file byte-identical: a column-0 comment " +
            "between mcp_servers: and the Case B block does not end the mapping"
        )
        let attrsAfter = try FileManager.default.attributesOfItem(atPath: configPath)
        XCTAssertEqual(
            inodeBefore, attrsAfter[.systemFileNumber] as? Int,
            "byte-identical output must skip the write entirely (inode unchanged)"
        )
    }

    func test_enableIPC_caseBBlockAfterColumnZeroComment_differentToken_keepsPositionChangesOnlyAuthorization() throws {
        let fixture = try caseBFixtureWithColumnZeroCommentBeforeBlock(token: "old-tok")
        try writeConfig(fixture)

        try HermesConfigManager.enableIPC(port: 41830, token: "new-tok", configPath: configPath)

        let content = readConfig()
        XCTAssertEqual(
            content, fixture.replacingOccurrences(of: "Bearer old-tok", with: "Bearer new-tok"),
            "only the Authorization value may change; the block must stay in place after the comment and " +
            "before the later sibling child"
        )
        let beginRange = try XCTUnwrap(content.range(of: beginLine))
        let siblingRange = try XCTUnwrap(content.range(of: "another_child: 2"))
        XCTAssertLessThan(
            beginRange.lowerBound, siblingRange.lowerBound,
            "the block must stay before the sibling child, not move to after it"
        )
    }

    /// Regression guard: a stale Case A block (its own self-contained
    /// `mcp_servers:` parent) plus the user's OWN, separate top-level
    /// `mcp_servers:` mapping elsewhere in the file. After enable, the
    /// file must have exactly one top-level `mcp_servers:` key, with
    /// `calyx-ipc` nested under it alongside the user's own child.
    func test_enableIPC_staleCaseABlockPlusUsersOwnTopLevelMcpServers_mergesIntoSingleMapping() throws {
        let staleBlock =
            beginLine + "\n" +
            "mcp_servers:\n" +
            "  calyx-ipc:\n" +
            "    url: \"http://127.0.0.1:9999/mcp\"\n" +
            "    headers:\n" +
            "      Authorization: \"Bearer stale\"\n" +
            endLine + "\n"
        let usersOwnMapping = "mcp_servers:\n  their_own: 1\n"
        try writeConfig(staleBlock + "\n" + usersOwnMapping)

        try HermesConfigManager.enableIPC(port: 41830, token: "fresh", configPath: configPath)

        let content = readConfig()
        XCTAssertEqual(
            occurrences(of: "mcp_servers:", in: content), 1,
            "there must be exactly one top-level mcp_servers: key after merging the stale Case A block into it"
        )
        XCTAssertTrue(content.contains("their_own: 1"), "the user's own child must survive")
        XCTAssertTrue(content.contains("calyx-ipc:"), "calyx-ipc must be nested under the single mcp_servers: mapping")
        XCTAssertTrue(content.contains("Bearer fresh"))
        XCTAssertFalse(content.contains("Bearer stale"))
    }
}
