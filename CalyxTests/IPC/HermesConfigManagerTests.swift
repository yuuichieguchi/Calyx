// HermesConfigManagerTests.swift
// CalyxTests
//
// TDD red-phase tests for `HermesConfigManager`.
//
// Coverage:
// - `enableIPC` upsert behavior for `~/.hermes/config.yaml` (Case A: append, Case B: insert as child)
// - Indent learning (2 vs 4 space) from existing `mcp_servers:` children
// - Idempotent replace of existing managed sub-block
// - YAML scalar escaping (quotes, backslashes, newlines, control chars rejected)
// - Self-healing on malformed managed block during enable
// - `disableIPC` removal preserving user content
// - Strict managed-block detection (BEGIN + END + `calyx-ipc:` all required)
// - Security: symlink rejection, invalid UTF-8 rejection
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
        XCTAssertTrue(content.contains("url: \"http://localhost:41830/mcp\""),
                      "Should contain url scalar with port 41830")
        XCTAssertTrue(content.contains("Authorization: \"Bearer abc123\""),
                      "Should contain Authorization scalar with token")
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
        XCTAssertTrue(content.contains("http://localhost:55555/mcp"),
                      "URL should reflect the new port")
        XCTAssertTrue(content.contains("Bearer second-tok"),
                      "Authorization should reflect the new token")
        XCTAssertFalse(content.contains("http://localhost:41830/mcp"),
                       "Old URL should be gone")
        XCTAssertFalse(content.contains("Bearer first-tok"),
                       "Old token should be gone")
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

    func test_enableIPC_throwsOnInvalidEncoding() throws {
        // Given: file with invalid UTF-8 bytes
        try writeRaw(Data([0xFF, 0xFE, 0xFD]))

        // When/Then: throws .invalidEncoding
        XCTAssertThrowsError(
            try HermesConfigManager.enableIPC(port: 41830, token: "tok", configPath: configPath)
        ) { error in
            guard let configError = error as? HermesConfigError else {
                XCTFail("Expected HermesConfigError, got \(type(of: error))")
                return
            }
            if case .invalidEncoding = configError {
                // Expected
            } else {
                XCTFail("Expected .invalidEncoding, got \(configError)")
            }
        }
    }

    func test_enableIPC_rejectsSymlink() throws {
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

        // When/Then: throws .symlinkDetected
        XCTAssertThrowsError(
            try HermesConfigManager.enableIPC(port: 41830, token: "tok", configPath: configPath)
        ) { error in
            guard let configError = error as? HermesConfigError else {
                XCTFail("Expected HermesConfigError, got \(type(of: error))")
                return
            }
            if case .symlinkDetected = configError {
                // Expected
            } else {
                XCTFail("Expected .symlinkDetected, got \(configError)")
            }
        }
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
        XCTAssertTrue(content.contains("http://localhost:41830/mcp"),
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

    func test_disableIPC_throwsOnMalformedBlock_beginOnly() throws {
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

        // When/Then: throws .malformedManagedBlock
        XCTAssertThrowsError(
            try HermesConfigManager.disableIPC(configPath: configPath)
        ) { error in
            guard let configError = error as? HermesConfigError else {
                XCTFail("Expected HermesConfigError, got \(type(of: error))")
                return
            }
            if case .malformedManagedBlock = configError {
                // Expected
            } else {
                XCTFail("Expected .malformedManagedBlock, got \(configError)")
            }
        }
    }

    func test_disableIPC_throwsOnMalformedBlock_endOnly() throws {
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

        // When/Then: throws .malformedManagedBlock
        XCTAssertThrowsError(
            try HermesConfigManager.disableIPC(configPath: configPath)
        ) { error in
            guard let configError = error as? HermesConfigError else {
                XCTFail("Expected HermesConfigError, got \(type(of: error))")
                return
            }
            if case .malformedManagedBlock = configError {
                // Expected
            } else {
                XCTFail("Expected .malformedManagedBlock, got \(configError)")
            }
        }
    }

    func test_disableIPC_throwsOnMalformedBlock_missingCalyxIpc() throws {
        // Given: pre-existing BEGIN/END pair but NO calyx-ipc: key between them
        let existing = """
        agent_name: "hermes"
        # BEGIN CALYX IPC (managed by Calyx, do not edit)
        # someone deleted the calyx-ipc body
        # END CALYX IPC
        max_tokens: 4096
        """
        try writeConfig(existing)

        // When/Then: throws .malformedManagedBlock
        XCTAssertThrowsError(
            try HermesConfigManager.disableIPC(configPath: configPath)
        ) { error in
            guard let configError = error as? HermesConfigError else {
                XCTFail("Expected HermesConfigError, got \(type(of: error))")
                return
            }
            if case .malformedManagedBlock = configError {
                // Expected
            } else {
                XCTFail("Expected .malformedManagedBlock, got \(configError)")
            }
        }
    }

    func test_disableIPC_rejectsSymlink() throws {
        // Given: configPath is a symlink
        let realFile = tempDir + "/real_config.yaml"
        try writeConfig("agent_name: \"hermes\"\n")
        try FileManager.default.moveItem(atPath: configPath, toPath: realFile)
        try FileManager.default.createSymbolicLink(
            atPath: configPath,
            withDestinationPath: realFile
        )

        // When/Then: throws .symlinkDetected
        XCTAssertThrowsError(
            try HermesConfigManager.disableIPC(configPath: configPath)
        ) { error in
            guard let configError = error as? HermesConfigError else {
                XCTFail("Expected HermesConfigError, got \(type(of: error))")
                return
            }
            if case .symlinkDetected = configError {
                // Expected
            } else {
                XCTFail("Expected .symlinkDetected, got \(configError)")
            }
        }
    }

    func test_disableIPC_throwsOnInvalidEncoding() throws {
        // Given: file with invalid UTF-8 bytes
        try writeRaw(Data([0xFF, 0xFE, 0xFD]))

        // When/Then: throws .invalidEncoding
        XCTAssertThrowsError(
            try HermesConfigManager.disableIPC(configPath: configPath)
        ) { error in
            guard let configError = error as? HermesConfigError else {
                XCTFail("Expected HermesConfigError, got \(type(of: error))")
                return
            }
            if case .invalidEncoding = configError {
                // Expected
            } else {
                XCTFail("Expected .invalidEncoding, got \(configError)")
            }
        }
    }

    // MARK: - isIPCEnabled

    func test_isIPCEnabled_trueForCompleteManagedBlock() throws {
        // Given: complete managed block written by enableIPC
        try HermesConfigManager.enableIPC(port: 41830, token: "tok", configPath: configPath)

        // When/Then
        XCTAssertTrue(HermesConfigManager.isIPCEnabled(configPath: configPath))
    }

    func test_isIPCEnabled_falseForBeginOnly() throws {
        // Given: BEGIN line only (no END, no calyx-ipc body in well-formed pair)
        let existing = """
        # BEGIN CALYX IPC (managed by Calyx, do not edit)
        mcp_servers:
          calyx-ipc:
            url: "http://localhost:1111/mcp"
        """
        try writeConfig(existing)

        // When/Then
        XCTAssertFalse(HermesConfigManager.isIPCEnabled(configPath: configPath))
    }

    func test_isIPCEnabled_falseForEndOnly() throws {
        // Given: END line only
        let existing = """
        mcp_servers:
          calyx-ipc:
            url: "http://localhost:1111/mcp"
        # END CALYX IPC
        """
        try writeConfig(existing)

        // When/Then
        XCTAssertFalse(HermesConfigManager.isIPCEnabled(configPath: configPath))
    }

    func test_isIPCEnabled_falseForBeginEndWithoutCalyxIpc() throws {
        // Given: BEGIN/END pair but no calyx-ipc: between
        let existing = """
        # BEGIN CALYX IPC (managed by Calyx, do not edit)
        # nothing useful here
        # END CALYX IPC
        """
        try writeConfig(existing)

        // When/Then
        XCTAssertFalse(HermesConfigManager.isIPCEnabled(configPath: configPath))
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
}
