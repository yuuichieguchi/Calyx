//
//  CodexHooksConfigManagerTests.swift
//  CalyxTests
//
//  TDD Red Phase for CodexHooksConfigManager (Phase 2): writes a
//  BEGIN/END-delimited managed block of `[[hooks.<Event>]]` TOML
//  array-of-tables entries into `~/.codex/config.toml` for the
//  calyx-agent-hook script. Follows the tempDir + configPath injection
//  style of ClaudeHooksConfigManagerTests / CodexConfigManagerTests, and
//  the BEGIN/END managed-block conventions of HermesConfigManagerTests.
//
//  Coverage:
//  - installHooks on an empty/new file writes all 6 target events, each as
//    a `[[hooks.X]]` + `[[hooks.X.hooks]]` pair with type="command",
//    command = '"<scriptPath>" codex', timeout = 5, wrapped in BEGIN/END
//    markers
//  - installHooks preserves the user's existing root keys, an unrelated
//    [mcp_servers.other] section, and the user's own [[hooks.SessionStart]]
//    block verbatim; the managed block is appended at the end
//  - Re-installing is idempotent (exactly one BEGIN marker)
//  - removeHooks removes only the managed block, restoring user content;
//    no-ops when the file doesn't exist; doesn't rewrite the file when
//    there is no managed block to remove
//  - An orphan BEGIN marker (missing END) self-heals: installHooks/removeHooks
//    strip the BEGIN line plus everything recognizable as Calyx's own
//    generated block body, leaving real user content (even directly
//    abutting the orphan block) untouched, rather than throwing
//  - A symlinked config path is rejected (ConfigFileError.symlinkDetected)
//  - A scriptPath containing a `'` is rejected (would break the TOML
//    literal string)
//  - areHooksInstalled reflects install state
//

import XCTest
@testable import Calyx

final class CodexHooksConfigManagerTests: XCTestCase {

    // MARK: - Properties

    private var tempDir: String!
    private var configPath: String!
    private var scriptPath: String!

    private static let expectedEvents = [
        "SessionStart", "UserPromptSubmit", "PreToolUse",
        "PostToolUse", "PermissionRequest", "Stop",
    ]

    private static let beginLine = "# BEGIN CALYX AGENT HOOKS (managed by Calyx, do not edit)"
    private static let endLine = "# END CALYX AGENT HOOKS"

    // MARK: - Lifecycle

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).path
        try! FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        configPath = tempDir + "/config.toml"
        scriptPath = tempDir + "/bin/calyx-agent-hook"
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

    private var expectedCommandLine: String {
        "command = '\"\(scriptPath!)\" codex'"
    }

    // MARK: - installHooks: fresh file

    func test_installHooks_newFile_writesAllSixEventPairsWithCommandEntry() throws {
        try CodexHooksConfigManager.installHooks(scriptPath: scriptPath, configPath: configPath)

        let content = readConfig()
        XCTAssertTrue(content.contains(Self.beginLine), "Managed block must start with the BEGIN marker")
        XCTAssertTrue(content.contains(Self.endLine), "Managed block must end with the END marker")

        for eventName in Self.expectedEvents {
            XCTAssertTrue(content.contains("[[hooks.\(eventName)]]"),
                          "\(eventName) array-of-tables header must be present")
            XCTAssertTrue(content.contains("[[hooks.\(eventName).hooks]]"),
                          "\(eventName).hooks array-of-tables header must be present")
        }

        XCTAssertEqual(occurrences(of: expectedCommandLine, in: content), Self.expectedEvents.count,
                       "Each of the 6 events must get its own exact literal-string command entry")
        XCTAssertEqual(occurrences(of: "type = \"command\"", in: content), Self.expectedEvents.count)
        XCTAssertEqual(occurrences(of: "timeout = 5", in: content), Self.expectedEvents.count)
    }

    func test_installHooks_eachEventPairsTableThenHooksTableInOrder() throws {
        try CodexHooksConfigManager.installHooks(scriptPath: scriptPath, configPath: configPath)
        let content = readConfig()

        for eventName in Self.expectedEvents {
            let escaped = NSRegularExpression.escapedPattern(for: eventName)
            let pattern = #"\[\[hooks\."# + escaped + #"\]\]\s*\n\[\[hooks\."# + escaped + #"\.hooks\]\]"#
            XCTAssertNotNil(content.range(of: pattern, options: .regularExpression),
                            "\(eventName)'s table header must be immediately followed by its .hooks table header")
        }
    }

    // MARK: - installHooks: preserves existing content

    func test_installHooks_preservesUserContentAndAppendsManagedBlockAtEnd() throws {
        let existing = """
        profile = "default"

        [mcp_servers.other]
        url = "http://localhost:9999/mcp"

        [[hooks.SessionStart]]
        [[hooks.SessionStart.hooks]]
        type = "command"
        command = "my-own-hook.sh"
        timeout = 3
        """
        writeConfig(existing)

        try CodexHooksConfigManager.installHooks(scriptPath: scriptPath, configPath: configPath)

        let content = readConfig()
        XCTAssertTrue(content.contains("profile = \"default\""), "User's root key must be preserved")
        XCTAssertTrue(content.contains("[mcp_servers.other]"), "Unrelated mcp_servers section must be preserved")
        XCTAssertTrue(content.contains("http://localhost:9999/mcp"))
        XCTAssertTrue(content.contains("command = \"my-own-hook.sh\""),
                      "The user's own SessionStart hook entry must be preserved verbatim")

        let userContentRange = content.range(of: "my-own-hook.sh")
        let beginRange = content.range(of: Self.beginLine)
        XCTAssertNotNil(beginRange, "installHooks must append its own managed block")
        if let userContentRange, let beginRange {
            XCTAssertTrue(userContentRange.upperBound < beginRange.lowerBound,
                          "The managed block must be appended after the user's existing content")
        }
    }

    // MARK: - installHooks: idempotency

    func test_installHooks_reinstall_isIdempotent() throws {
        try CodexHooksConfigManager.installHooks(scriptPath: scriptPath, configPath: configPath)
        try CodexHooksConfigManager.installHooks(scriptPath: scriptPath, configPath: configPath)

        let content = readConfig()
        XCTAssertEqual(occurrences(of: Self.beginLine, in: content), 1,
                       "Reinstalling must not duplicate the BEGIN marker")
        XCTAssertEqual(occurrences(of: Self.endLine, in: content), 1)
        XCTAssertEqual(occurrences(of: expectedCommandLine, in: content), Self.expectedEvents.count,
                       "Reinstalling must not duplicate per-event command entries")
    }

    // MARK: - removeHooks

    func test_removeHooks_removesManagedBlockOnlyAndRestoresUserContent() throws {
        let existing = """
        profile = "default"

        [mcp_servers.other]
        url = "http://localhost:9999/mcp"
        """
        writeConfig(existing)
        try CodexHooksConfigManager.installHooks(scriptPath: scriptPath, configPath: configPath)

        // Sanity: install must actually have added the managed block —
        // otherwise the assertions below would trivially pass against
        // content that was never modified.
        let afterInstall = readConfig()
        XCTAssertTrue(afterInstall.contains(Self.beginLine), "Precondition: install must add the managed block")

        try CodexHooksConfigManager.removeHooks(configPath: configPath)

        let content = readConfig()
        XCTAssertTrue(content.contains("profile = \"default\""))
        XCTAssertTrue(content.contains("[mcp_servers.other]"))
        XCTAssertTrue(content.contains("http://localhost:9999/mcp"))
        XCTAssertFalse(content.contains(Self.beginLine), "BEGIN marker must be removed")
        XCTAssertFalse(content.contains(Self.endLine), "END marker must be removed")
        for eventName in Self.expectedEvents {
            XCTAssertFalse(content.contains("[[hooks.\(eventName)]]"),
                           "\(eventName)'s Calyx entry must be removed")
        }
    }

    func test_removeHooks_noopWhenNothingToRemove() throws {
        // Case A: file doesn't exist -> no-op, no throw, no file created.
        XCTAssertFalse(FileManager.default.fileExists(atPath: configPath))
        XCTAssertNoThrow(try CodexHooksConfigManager.removeHooks(configPath: configPath))
        XCTAssertFalse(FileManager.default.fileExists(atPath: configPath),
                       "removeHooks must not create a file when none exists")

        // Case B: file exists but has no managed block -> content/mtime unchanged.
        let existing = "profile = \"default\"\n"
        writeConfig(existing)
        let beforeAttrs = try FileManager.default.attributesOfItem(atPath: configPath)
        let beforeModDate = beforeAttrs[.modificationDate] as? Date

        // Allow the filesystem's mtime clock to tick forward so a spurious
        // rewrite would be observable even at coarse mtime resolution.
        Thread.sleep(forTimeInterval: 0.2)

        try CodexHooksConfigManager.removeHooks(configPath: configPath)

        let afterAttrs = try FileManager.default.attributesOfItem(atPath: configPath)
        let afterModDate = afterAttrs[.modificationDate] as? Date
        XCTAssertEqual(beforeModDate, afterModDate,
                       "removeHooks must not rewrite the file when there is no managed block to remove")
        XCTAssertEqual(readConfig(), existing, "Content must be unchanged when there is nothing to remove")

        // Sanity: confirm removeHooks actually does something when a
        // managed block IS present — otherwise cases A/B above would be
        // indistinguishable from a permanently no-op implementation.
        try CodexHooksConfigManager.installHooks(scriptPath: scriptPath, configPath: configPath)
        XCTAssertTrue(readConfig().contains(Self.beginLine), "Precondition: install must add the managed block")
        try CodexHooksConfigManager.removeHooks(configPath: configPath)
        XCTAssertFalse(readConfig().contains(Self.beginLine), "removeHooks must remove an actual managed block")
    }

    // MARK: - Orphan managed block (self-heal)

    func test_installHooks_orphanBeginMarker_selfHealsWithoutDuplicating() throws {
        // Contract changed (final review pass): an orphan BEGIN marker (no
        // matching END) used to make installHooks throw
        // `.orphanManagedBlock`. Following that error's own recovery advice
        // (delete only the BEGIN line) left the orphaned [[hooks.*]]
        // entries behind as unrecognized TOML content — a subsequent
        // reinstall then appended a second, freshly-wrapped set on top,
        // duplicating every hook. Self-healing (mirroring
        // HermesConfigManager.enableIPC's precedent) instead recognizes and
        // strips a stale/partial set of Calyx's own entries — identified by
        // their `command` line referencing calyx-agent-hook's own script
        // filename — so a reinstall produces exactly one clean block.
        let staleScriptPath = tempDir + "/old-install/calyx-agent-hook"
        let existing = """
        profile = "default"
        \(Self.beginLine)
        [[hooks.SessionStart]]
        [[hooks.SessionStart.hooks]]
        type = "command"
        command = '"\(staleScriptPath)" codex'
        timeout = 5
        """
        writeConfig(existing)

        try CodexHooksConfigManager.installHooks(scriptPath: scriptPath, configPath: configPath)

        let content = readConfig()
        XCTAssertTrue(content.contains("profile = \"default\""),
                      "Unrelated content before the orphan block must survive")
        XCTAssertFalse(content.contains(staleScriptPath),
                       "The orphaned block's own stale entry must be stripped, not left duplicated")
        XCTAssertEqual(occurrences(of: Self.beginLine, in: content), 1,
                       "Self-healing an orphan BEGIN and reinstalling must leave exactly one BEGIN marker")
        XCTAssertEqual(occurrences(of: "[[hooks.SessionStart]]", in: content), 1,
                       "Self-healing must not leave a duplicate, unwrapped [[hooks.SessionStart]] entry " +
                       "alongside the freshly-wrapped one")
        XCTAssertEqual(occurrences(of: expectedCommandLine, in: content), Self.expectedEvents.count,
                       "A clean reinstall must still write exactly one command entry per event")
    }

    func test_removeHooks_orphanBeginImmediatelyFollowedByUserContent_onlyStripsOwnBlockLines() throws {
        // Contract changed (final review pass): self-healing must only
        // remove the BEGIN line plus lines that look like Calyx's own
        // generated block body — real user TOML content directly abutting
        // the orphan block (no blank-line separator) must survive
        // untouched, rather than the whole removeHooks call throwing.
        let staleScriptPath = tempDir + "/old-install/calyx-agent-hook"
        let existing = """
        \(Self.beginLine)
        [[hooks.SessionStart]]
        [[hooks.SessionStart.hooks]]
        type = "command"
        command = '"\(staleScriptPath)" codex'
        timeout = 5
        [other.section]
        key = "value"
        """
        writeConfig(existing)

        try CodexHooksConfigManager.removeHooks(configPath: configPath)

        let content = readConfig()
        XCTAssertFalse(content.contains(Self.beginLine), "The orphan BEGIN marker itself must be removed")
        XCTAssertFalse(content.contains(staleScriptPath), "The orphaned block's own entry must be stripped")
        XCTAssertTrue(content.contains("[other.section]"),
                      "Real user content directly after the orphan block must survive")
        XCTAssertTrue(content.contains("key = \"value\""))
    }

    // MARK: - Security

    func test_installHooks_symlinkConfigPath_throwsSymlinkDetected() throws {
        let realFile = tempDir + "/real_config.toml"
        FileManager.default.createFile(atPath: realFile, contents: Data("".utf8))
        try FileManager.default.createSymbolicLink(atPath: configPath, withDestinationPath: realFile)

        XCTAssertThrowsError(
            try CodexHooksConfigManager.installHooks(scriptPath: scriptPath, configPath: configPath)
        ) { error in
            guard let configError = error as? ConfigFileError else {
                XCTFail("Expected ConfigFileError, got \(type(of: error))")
                return
            }
            guard case .symlinkDetected = configError else {
                XCTFail("Expected .symlinkDetected, got \(configError)")
                return
            }
        }
    }

    func test_removeHooks_symlinkConfigPath_throwsSymlinkDetected() throws {
        let realFile = tempDir + "/real_config.toml"
        writeConfig("profile = \"default\"\n")
        try FileManager.default.moveItem(atPath: configPath, toPath: realFile)
        try FileManager.default.createSymbolicLink(atPath: configPath, withDestinationPath: realFile)

        XCTAssertThrowsError(
            try CodexHooksConfigManager.removeHooks(configPath: configPath)
        ) { error in
            guard let configError = error as? ConfigFileError else {
                XCTFail("Expected ConfigFileError, got \(type(of: error))")
                return
            }
            guard case .symlinkDetected = configError else {
                XCTFail("Expected .symlinkDetected, got \(configError)")
                return
            }
        }
    }

    func test_installHooks_scriptPathContainingSingleQuote_throws() {
        let badScriptPath = tempDir + "/it's-a-path/calyx-agent-hook"

        XCTAssertThrowsError(
            try CodexHooksConfigManager.installHooks(scriptPath: badScriptPath, configPath: configPath),
            "A scriptPath containing a single quote would break the TOML literal string and must be rejected"
        )
    }

    // MARK: - areHooksInstalled

    func test_areHooksInstalled_reflectsInstallState() throws {
        XCTAssertFalse(CodexHooksConfigManager.areHooksInstalled(configPath: configPath),
                       "No config file yet -> hooks must not be reported as installed")

        try CodexHooksConfigManager.installHooks(scriptPath: scriptPath, configPath: configPath)

        XCTAssertTrue(CodexHooksConfigManager.areHooksInstalled(configPath: configPath),
                      "After installHooks, hooks must be reported as installed")

        try CodexHooksConfigManager.removeHooks(configPath: configPath)

        XCTAssertFalse(CodexHooksConfigManager.areHooksInstalled(configPath: configPath),
                       "After removeHooks, hooks must no longer be reported as installed")
    }
}
