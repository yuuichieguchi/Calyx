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

    func test_enableIPC_symlinkRejected() throws {
        // Given: configPath is a symlink
        let realFile = tempDir + "/real_config.toml"
        FileManager.default.createFile(atPath: realFile, contents: Data("".utf8))
        try FileManager.default.createSymbolicLink(atPath: configPath, withDestinationPath: realFile)

        // Verify it is indeed a symlink
        let attrs = try FileManager.default.attributesOfItem(atPath: configPath)
        XCTAssertEqual(attrs[.type] as? FileAttributeType, .typeSymbolicLink,
                       "Test setup: configPath should be a symlink")

        // When/Then: throws symlinkDetected
        XCTAssertThrowsError(
            try CodexConfigManager.enableIPC(port: 41830, token: "tok", configPath: configPath)
        ) { error in
            guard let configError = error as? CodexConfigError else {
                XCTFail("Expected CodexConfigError, got \(type(of: error))")
                return
            }
            if case .symlinkDetected = configError {
                // Expected
            } else {
                XCTFail("Expected .symlinkDetected, got \(configError)")
            }
        }
    }

    func test_disableIPC_symlinkRejected() throws {
        // Given: configPath is a symlink
        let realFile = tempDir + "/real_config.toml"
        writeConfig("[mcp_servers.calyx-ipc]\nurl = \"http://localhost:41830/mcp\"\n")
        try FileManager.default.moveItem(atPath: configPath, toPath: realFile)
        try FileManager.default.createSymbolicLink(atPath: configPath, withDestinationPath: realFile)

        // When/Then: throws symlinkDetected
        XCTAssertThrowsError(
            try CodexConfigManager.disableIPC(configPath: configPath)
        ) { error in
            guard let configError = error as? CodexConfigError else {
                XCTFail("Expected CodexConfigError, got \(type(of: error))")
                return
            }
            if case .symlinkDetected = configError {
                // Expected
            } else {
                XCTFail("Expected .symlinkDetected, got \(configError)")
            }
        }
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
        // Given: file has [[array_of_tables]] inside the calyx-ipc section area
        // The [[double bracket]] should NOT be treated as a section boundary
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

        // Then: entire old section (including [[array_of_tables]] line) removed
        let content = readConfig()
        XCTAssertFalse(content.contains("[[array_of_tables]]"),
                       "[[array_of_tables]] inside calyx-ipc section should be removed")
        XCTAssertFalse(content.contains("should be removed with the section"))
        XCTAssertFalse(content.contains("http://localhost:40000/mcp"))
        // Fresh section added
        XCTAssertTrue(content.contains("[mcp_servers.calyx-ipc]"))
        XCTAssertTrue(content.contains("http://127.0.0.1:41830/mcp"))
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
