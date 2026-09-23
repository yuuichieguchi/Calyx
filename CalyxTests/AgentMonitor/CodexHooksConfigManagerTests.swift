//
//  CodexHooksConfigManagerTests.swift
//  CalyxTests
//
//  Covers CodexHooksConfigManager (Phase 2): writes a
//  BEGIN/END-delimited managed block of `[[hooks.<Event>]]` TOML
//  array-of-tables entries into `~/.codex/config.toml` for the
//  calyx-agent-hook script. Follows the tempDir + configPath injection
//  style of ClaudeHooksConfigManagerTests / CodexConfigManagerTests, and
//  the BEGIN/END managed-block conventions of HermesConfigManagerTests.
//
//  Coverage:
//  - installHooks on an empty/new file writes all 9 target events, each as
//    a `[[hooks.X]]` + `[[hooks.X.hooks]]` pair with type="command",
//    command = '"<scriptPath>" codex', timeout = 5, wrapped in BEGIN/END
//    markers -- SessionEnd included, so a Codex session ending reaches
//    AgentRegistry's existing SessionEnd -> .done mapping instead of
//    leaving the sidebar row stuck at .idle forever
//  - installHooks preserves the user's existing root keys, an unrelated
//    [mcp_servers.other] section, and the user's own [[hooks.SessionStart]]
//    block verbatim; the managed block is appended at the end
//  - Re-installing is idempotent (exactly one BEGIN marker)
//  - Re-installing over an older, well-formed six-event managed block
//    (the shape `preSessionEndEvents` models) adds SessionEnd exactly
//    once, without duplicating any of the other six events
//  - Codex-owned [hooks.state] trust/disable records and any other foreign
//    TOML tables injected inside the comment-delimited Calyx block survive
//    remove -> reinstall
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
    private var approvalScriptPath: String!

    private static let expectedEvents = [
        "SessionStart", "UserPromptSubmit", "PreToolUse",
        "PostToolUse", "PermissionRequest", "Stop", "SessionEnd",
        "SubagentStart", "SubagentStop",
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
        approvalScriptPath = tempDir + "/bin/calyx-approval-hook"
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: tempDir)
        super.tearDown()
    }

    // MARK: - Helpers

    private func writeConfig(_ content: String) {
        try! Data(content.utf8).write(to: URL(fileURLWithPath: configPath))
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

    private var expectedApprovalCommandLine: String {
        "command = '\"\(approvalScriptPath!)\" codex'"
    }

    // MARK: - installHooks: fresh file

    func test_installHooks_newFile_writesAllNineEventPairsWithCommandEntry() throws {
        try CodexHooksConfigManager.installHooks(scriptPath: scriptPath, approvalScriptPath: approvalScriptPath, configPath: configPath)

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
                       "Each of the 9 events must still get its own exact monitor command entry")
        XCTAssertEqual(occurrences(of: "type = \"command\"", in: content), Self.expectedEvents.count + 1,
                       "9 monitor entries plus PermissionRequest's extra synchronous approval entry")
        XCTAssertEqual(occurrences(of: "timeout = 5", in: content), Self.expectedEvents.count,
                       "Only the 9 monitor entries use timeout = 5")

        // PermissionRequest alone gets a second [[hooks.PermissionRequest]]
        // pair for the new synchronous approval entry; PreToolUse keeps
        // only its single monitor-entry pair.
        XCTAssertEqual(occurrences(of: "[[hooks.PreToolUse]]", in: content), 1,
                       "PreToolUse must have exactly one array-of-tables pair: the monitor entry only")
        XCTAssertEqual(occurrences(of: "[[hooks.PermissionRequest]]", in: content), 2,
                       "PermissionRequest must have two array-of-tables pairs: the monitor entry and the approval entry")
        XCTAssertEqual(occurrences(of: expectedApprovalCommandLine, in: content), 1,
                       "PermissionRequest's approval entry must POST through calyx-approval-hook with the codex argv")
        XCTAssertEqual(occurrences(of: "timeout = 600", in: content), 1,
                       "The approval entry's timeout must be 600 (ApprovalHookTiming.hookEntryTimeoutSeconds)")
    }

    // The approval entry's own contiguous TOML block must sit under
    // [[hooks.PermissionRequest]], never under [[hooks.PreToolUse]] --
    // PermissionRequest fires only once the CLI has already decided it
    // needs to show a confirmation prompt, unlike PreToolUse, which fires
    // for every tool call regardless of whether it needs approval.
    func test_installHooks_approvalEntry_isNestedUnderPermissionRequestNotPreToolUse() throws {
        try CodexHooksConfigManager.installHooks(scriptPath: scriptPath, approvalScriptPath: approvalScriptPath, configPath: configPath)
        let content = readConfig()

        let approvalUnderPermissionRequest = """
        [[hooks.PermissionRequest]]
        [[hooks.PermissionRequest.hooks]]
        type = "command"
        \(expectedApprovalCommandLine)
        timeout = 600
        """
        XCTAssertTrue(content.contains(approvalUnderPermissionRequest),
                      "The approval entry's exact contiguous TOML block must be nested under " +
                      "[[hooks.PermissionRequest]]")

        let approvalUnderPreToolUse = """
        [[hooks.PreToolUse]]
        [[hooks.PreToolUse.hooks]]
        type = "command"
        \(expectedApprovalCommandLine)
        timeout = 600
        """
        XCTAssertFalse(content.contains(approvalUnderPreToolUse),
                       "The approval entry must never be nested under [[hooks.PreToolUse]]")
    }

    func test_installHooks_eachEventPairsTableThenHooksTableInOrder() throws {
        try CodexHooksConfigManager.installHooks(scriptPath: scriptPath, approvalScriptPath: approvalScriptPath, configPath: configPath)
        let content = readConfig()

        for eventName in Self.expectedEvents {
            let escaped = NSRegularExpression.escapedPattern(for: eventName)
            let pattern = #"\[\[hooks\."# + escaped + #"\]\]\s*\n\[\[hooks\."# + escaped + #"\.hooks\]\]"#
            XCTAssertNotNil(content.range(of: pattern, options: .regularExpression),
                            "\(eventName)'s table header must be immediately followed by its .hooks table header")
        }
    }

    // SessionEnd is what lets a Codex session ending reach
    // AgentRegistry's existing SessionEnd -> .done mapping instead of
    // leaving the sidebar row stuck at .idle forever (Codex has no other
    // hook that fires on session exit). This pins its exact contiguous
    // TOML block to the identical shape every other monitor event gets,
    // not merely that its pieces appear somewhere in the file.
    func test_installHooks_sessionEndEntry_matchesExactCommandShapeOfOtherEvents() throws {
        try CodexHooksConfigManager.installHooks(scriptPath: scriptPath, approvalScriptPath: approvalScriptPath, configPath: configPath)
        let content = readConfig()

        let expectedSessionEndBlock = """
        [[hooks.SessionEnd]]
        [[hooks.SessionEnd.hooks]]
        type = "command"
        \(expectedCommandLine)
        timeout = 5
        """
        XCTAssertTrue(content.contains(expectedSessionEndBlock),
                      "SessionEnd's exact contiguous TOML block must match the other monitor events' shape: " +
                      "type = \"command\", the same command = '\"<scriptPath>\" codex' entry, and timeout = 5")
    }

    // SubagentStart / SubagentStop must get the exact same monitor-entry
    // shape every other event gets: type = "command", the same
    // command = '"<scriptPath>" codex' entry, and timeout = 5.
    func test_installHooks_subagentStartAndStop_matchExactCommandShapeOfOtherEvents() throws {
        try CodexHooksConfigManager.installHooks(scriptPath: scriptPath, approvalScriptPath: approvalScriptPath, configPath: configPath)
        let content = readConfig()

        for eventName in ["SubagentStart", "SubagentStop"] {
            let expectedBlock = """
            [[hooks.\(eventName)]]
            [[hooks.\(eventName).hooks]]
            type = "command"
            \(expectedCommandLine)
            timeout = 5
            """
            XCTAssertTrue(content.contains(expectedBlock),
                          "\(eventName)'s exact contiguous TOML block must match the other monitor events' shape")
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

        try CodexHooksConfigManager.installHooks(scriptPath: scriptPath, approvalScriptPath: approvalScriptPath, configPath: configPath)

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
        try CodexHooksConfigManager.installHooks(scriptPath: scriptPath, approvalScriptPath: approvalScriptPath, configPath: configPath)
        let beforeModificationDate = try FileManager.default.attributesOfItem(atPath: configPath)[.modificationDate] as? Date
        Thread.sleep(forTimeInterval: 0.2)
        try CodexHooksConfigManager.installHooks(scriptPath: scriptPath, approvalScriptPath: approvalScriptPath, configPath: configPath)

        let content = readConfig()
        XCTAssertEqual(occurrences(of: Self.beginLine, in: content), 1,
                       "Reinstalling must not duplicate the BEGIN marker")
        XCTAssertEqual(occurrences(of: Self.endLine, in: content), 1)
        XCTAssertEqual(occurrences(of: expectedCommandLine, in: content), Self.expectedEvents.count,
                       "Reinstalling must not duplicate per-event monitor command entries")
        XCTAssertEqual(occurrences(of: expectedApprovalCommandLine, in: content), 1,
                       "Reinstalling must not duplicate the PermissionRequest approval command entry")
        let afterModificationDate = try FileManager.default.attributesOfItem(atPath: configPath)[.modificationDate] as? Date
        XCTAssertEqual(beforeModificationDate, afterModificationDate,
                       "An unchanged reinstall must not rewrite Codex's shared config file")
    }

    func test_removeThenInstall_preservesCodexHookTrustStateInjectedInsideManagedBlock() throws {
        try CodexHooksConfigManager.installHooks(
            scriptPath: scriptPath,
            approvalScriptPath: approvalScriptPath,
            configPath: configPath
        )

        // Codex persists both trust and per-hook disablement in config.toml.
        // Its config writer can place that table between Calyx's hook entries,
        // which means comment markers alone do not prove every enclosed line
        // belongs to Calyx.
        let trustedHash = "sha256:" + String(repeating: "a", count: 64)
        let stateKey = "\(configPath!):session_start:0:0"
        let codexState = """
        [hooks.state]

        [hooks.state."\(stateKey)"]
        trusted_hash = "\(trustedHash)"
        disabled = true
        """
        let installed = readConfig()
        let withCodexState = installed.replacingOccurrences(
            of: Self.endLine,
            with: codexState + "\n" + Self.endLine
        )
        XCTAssertNotEqual(installed, withCodexState, "Precondition: trust state must be injected inside the markers")
        writeConfig(withCodexState)

        try CodexHooksConfigManager.removeHooks(configPath: configPath)

        let disabled = readConfig()
        XCTAssertFalse(disabled.contains(Self.beginLine))
        XCTAssertFalse(disabled.contains(expectedCommandLine))
        XCTAssertTrue(disabled.contains("[hooks.state]"),
                      "Disabling Calyx IPC must not delete Codex-owned hook state")
        XCTAssertTrue(disabled.contains("[hooks.state.\"\(stateKey)\"]"))
        XCTAssertTrue(disabled.contains("trusted_hash = \"\(trustedHash)\""),
                      "A previously reviewed hook must remain trusted across disable")
        XCTAssertTrue(disabled.contains("disabled = true"),
                      "A user's per-hook disabled choice must remain intact too")

        try CodexHooksConfigManager.installHooks(
            scriptPath: scriptPath,
            approvalScriptPath: approvalScriptPath,
            configPath: configPath
        )

        let reinstalled = readConfig()
        XCTAssertEqual(occurrences(of: "trusted_hash = \"\(trustedHash)\"", in: reinstalled), 1)
        XCTAssertEqual(occurrences(of: "disabled = true", in: reinstalled), 1)
        XCTAssertEqual(occurrences(of: Self.beginLine, in: reinstalled), 1)
        XCTAssertEqual(occurrences(of: expectedCommandLine, in: reinstalled), Self.expectedEvents.count)

        let stateRange = reinstalled.range(of: "[hooks.state]")
        let beginRange = reinstalled.range(of: Self.beginLine)
        XCTAssertNotNil(stateRange)
        XCTAssertNotNil(beginRange)
        if let stateRange, let beginRange {
            XCTAssertLessThan(stateRange.lowerBound, beginRange.lowerBound,
                              "Preserved Codex state must be moved outside Calyx's deletable block")
        }
    }

    func test_removeThenInstall_preservesForeignTOMLTableInjectedInsideManagedBlock() throws {
        try CodexHooksConfigManager.installHooks(
            scriptPath: scriptPath,
            approvalScriptPath: approvalScriptPath,
            configPath: configPath
        )

        // Codex's config writer is free to append another top-level table
        // while the final active table happens to be inside Calyx's comment
        // markers. Comments have no ownership semantics in TOML, so Calyx
        // must retain every table it cannot positively identify as its own.
        let foreignTable = """
        [shell_environment_policy.set]
        USER_OWNED_SETTING = "preserve-me"
        """
        let approvalEntry = """
        [[hooks.PermissionRequest]]
        [[hooks.PermissionRequest.hooks]]
        type = "command"
        \(expectedApprovalCommandLine)
        timeout = 600
        """
        let installed = readConfig()
        let withForeignTable = installed.replacingOccurrences(
            of: approvalEntry,
            with: foreignTable + "\n" + approvalEntry
        )
        XCTAssertNotEqual(installed, withForeignTable,
                          "Precondition: foreign table must be injected inside the markers")
        writeConfig(withForeignTable)

        try CodexHooksConfigManager.removeHooks(configPath: configPath)

        let disabled = readConfig()
        XCTAssertFalse(disabled.contains(Self.beginLine))
        XCTAssertFalse(disabled.contains(expectedCommandLine))
        XCTAssertTrue(disabled.contains("[shell_environment_policy.set]"),
                      "Disabling Calyx IPC must not delete an unrelated TOML table")
        XCTAssertTrue(disabled.contains("USER_OWNED_SETTING = \"preserve-me\""),
                      "The complete foreign table body must remain verbatim")

        try CodexHooksConfigManager.installHooks(
            scriptPath: scriptPath,
            approvalScriptPath: approvalScriptPath,
            configPath: configPath
        )

        let reinstalled = readConfig()
        XCTAssertEqual(occurrences(of: "[shell_environment_policy.set]", in: reinstalled), 1)
        XCTAssertEqual(occurrences(of: "USER_OWNED_SETTING = \"preserve-me\"", in: reinstalled), 1)
        XCTAssertEqual(occurrences(of: Self.beginLine, in: reinstalled), 1)

        let foreignRange = reinstalled.range(of: "[shell_environment_policy.set]")
        let beginRange = reinstalled.range(of: Self.beginLine)
        XCTAssertNotNil(foreignRange)
        XCTAssertNotNil(beginRange)
        if let foreignRange, let beginRange {
            XCTAssertLessThan(foreignRange.lowerBound, beginRange.lowerBound,
                              "Preserved foreign tables must move outside Calyx's deletable block")
        }
    }

    // MARK: - foreignTableBytes: two shapes not addressed by a table header

    /// A non-table-header line sitting before the block's first
    /// `[[hooks.*]]` header (Codex, or a user, wrote it directly under
    /// the BEGIN comment) is foreign content with no table header of its
    /// own to anchor a chunk -- it must still survive byte-for-byte,
    /// same as a foreign table that comes after a header.
    func test_removeHooks_preservesForeignLineBeforeFirstTableHeaderInsideBlock_lf() throws {
        let content = [
            "profile = \"default\"",
            Self.beginLine,
            "my_key = 1",
            "[[hooks.Stop]]",
            "[[hooks.Stop.hooks]]",
            "type = \"command\"",
            expectedCommandLine,
            "timeout = 5",
            Self.endLine,
            "",
        ].joined(separator: "\n")
        writeConfig(content)

        try CodexHooksConfigManager.removeHooks(configPath: configPath)

        let disabled = readConfig()
        XCTAssertFalse(disabled.contains(Self.beginLine))
        XCTAssertFalse(disabled.contains(expectedCommandLine))
        XCTAssertTrue(disabled.contains("my_key = 1"),
                      "A line preceding the block's first table header must survive as foreign content, " +
                      "not be silently dropped")
        XCTAssertTrue(disabled.contains("profile = \"default\""))
    }

    func test_removeHooks_preservesForeignLineBeforeFirstTableHeaderInsideBlock_crlf() throws {
        let content = [
            "profile = \"default\"",
            Self.beginLine,
            "my_key = 1",
            "[[hooks.Stop]]",
            "[[hooks.Stop.hooks]]",
            "type = \"command\"",
            expectedCommandLine,
            "timeout = 5",
            Self.endLine,
            "",
        ].joined(separator: "\r\n")
        writeConfig(content)

        try CodexHooksConfigManager.removeHooks(configPath: configPath)

        let disabled = readConfig()
        XCTAssertFalse(disabled.contains(Self.beginLine))
        XCTAssertFalse(disabled.contains(expectedCommandLine))
        XCTAssertTrue(disabled.contains("my_key = 1"),
                      "A line preceding the block's first table header must survive as foreign content in a " +
                      "CRLF file too")
        XCTAssertTrue(disabled.contains("profile = \"default\""))
    }

    /// A block body with no table header at all cannot be identified as
    /// Calyx's own content by any means -- the whole body must be
    /// preserved as foreign, matching HermesConfigManager.foreignBodyBytes's
    /// rule for a span with no recognizable calyx-ipc line.
    func test_removeHooks_preservesEntireBodyWhenNoTableHeaderPresent_lf() throws {
        let content = [
            "profile = \"default\"",
            Self.beginLine,
            "not_a_table_at_all = true",
            Self.endLine,
            "",
        ].joined(separator: "\n")
        writeConfig(content)

        try CodexHooksConfigManager.removeHooks(configPath: configPath)

        let disabled = readConfig()
        XCTAssertFalse(disabled.contains(Self.beginLine))
        XCTAssertTrue(disabled.contains("not_a_table_at_all = true"),
                      "A block body with no table header at all must be preserved in full, not discarded")
        XCTAssertTrue(disabled.contains("profile = \"default\""))
    }

    func test_removeHooks_preservesEntireBodyWhenNoTableHeaderPresent_crlf() throws {
        let content = [
            "profile = \"default\"",
            Self.beginLine,
            "not_a_table_at_all = true",
            Self.endLine,
            "",
        ].joined(separator: "\r\n")
        writeConfig(content)

        try CodexHooksConfigManager.removeHooks(configPath: configPath)

        let disabled = readConfig()
        XCTAssertFalse(disabled.contains(Self.beginLine))
        XCTAssertTrue(disabled.contains("not_a_table_at_all = true"),
                      "A block body with no table header at all must be preserved in full in a CRLF file too")
        XCTAssertTrue(disabled.contains("profile = \"default\""))
    }

    // MARK: - Migration: approval entry moves from PreToolUse to PermissionRequest

    /// The event list a pre-SessionEnd install wrote to its config.
    /// Pinned independently of `expectedEvents` (production's current
    /// target event list) so the migration fixtures below keep
    /// representing a real older file regardless of how `expectedEvents`
    /// changes.
    private static let preSessionEndEvents = [
        "SessionStart", "UserPromptSubmit", "PreToolUse",
        "PostToolUse", "PermissionRequest", "Stop",
    ]

    /// One event's `[[hooks.X]]` + `[[hooks.X.hooks]]` pair using
    /// `scriptPath`, hand-built to match `CodexHooksConfigManager`'s own
    /// private `hookEntry(eventName:scriptPath:)` shape -- reproduced
    /// here (rather than called directly, since it's private) so this
    /// file can hand-construct a specific pre-migration fixture
    /// independent of the very code that fixture exists to protect.
    private func monitorEntry(eventName: String) -> String {
        """
        [[hooks.\(eventName)]]
        [[hooks.\(eventName).hooks]]
        type = "command"
        command = '"\(scriptPath!)" codex'
        timeout = 5
        """
    }

    /// The exact contiguous TOML block `CodexHooksConfigManager`'s own
    /// `approvalHookEntry` generated before this migration: nested under
    /// `[[hooks.PreToolUse]]` (alongside PreToolUse's own monitor entry)
    /// rather than `[[hooks.PermissionRequest]]`.
    private var preMigrationApprovalEntryUnderPreToolUse: String {
        """
        [[hooks.PreToolUse]]
        [[hooks.PreToolUse.hooks]]
        type = "command"
        \(expectedApprovalCommandLine)
        timeout = 600
        """
    }

    /// A full, well-formed (BEGIN...END, no orphan) config a pre-migration
    /// Calyx version would have written: a user-owned `profile` root key,
    /// then the 6 monitor entries, then the synchronous approval entry
    /// nested under `[[hooks.PreToolUse]]`.
    private var preMigrationConfig: String {
        (["profile = \"default\"", Self.beginLine]
            + Self.preSessionEndEvents.map { monitorEntry(eventName: $0) }
            + [preMigrationApprovalEntryUnderPreToolUse, Self.endLine]).joined(separator: "\n")
    }

    /// A config written by a pre-migration Calyx version has the
    /// synchronous approval entry nested under `[[hooks.PreToolUse]]`
    /// alongside its own monitor entry -- the shape
    /// `CodexHooksConfigManager.approvalHookEntry` generated before this
    /// migration. Reinstalling with the current implementation must
    /// relocate it to `[[hooks.PermissionRequest]]`, without duplicating
    /// any event's monitor entry -- installHooks' own idempotent re-run
    /// doubles as the migration path, with no separate migration function
    /// needed. Mirrors ClaudeHooksConfigManagerTests'
    /// test_installHooks_reinstallOverOldPreToolUseApprovalEntry_migratesApprovalEntryToPermissionRequest.
    ///
    /// This is the actual upgrade path a user who installed Calyx before
    /// this migration goes through, so it pins `removingManagedBlock` /
    /// `foreignTableLines` / `isCalyxGeneratedBlockLine` against a future
    /// change that stops recognizing the old PreToolUse-nested approval
    /// entry as Calyx-owned -- which would instead preserve it as foreign
    /// TOML outside the markers, leaving a stale synchronous PreToolUse
    /// approval hook active indefinitely.
    func test_installHooks_reinstallOverOldPreToolUseApprovalEntry_migratesApprovalEntryToPermissionRequest() throws {
        writeConfig(preMigrationConfig)

        try CodexHooksConfigManager.installHooks(scriptPath: scriptPath, approvalScriptPath: approvalScriptPath, configPath: configPath)

        let content = readConfig()
        XCTAssertTrue(content.contains("profile = \"default\""), "The user's own root key must survive the migration")
        XCTAssertEqual(occurrences(of: "[[hooks.PreToolUse]]", in: content), 1,
                       "PreToolUse must end up with exactly one pair -- its own monitor entry -- once the " +
                       "pre-migration approval entry has moved to PermissionRequest")
        XCTAssertEqual(occurrences(of: "[[hooks.PermissionRequest]]", in: content), 2,
                       "PermissionRequest must end up with both pairs: its own monitor entry and the " +
                       "migrated approval entry")
        XCTAssertEqual(occurrences(of: expectedCommandLine, in: content), Self.expectedEvents.count,
                       "Reinstalling over a pre-migration config must not duplicate any event's monitor entry")
        XCTAssertEqual(occurrences(of: expectedApprovalCommandLine, in: content), 1,
                       "The approval entry must reappear exactly once, not duplicated")

        let approvalUnderPermissionRequest = """
        [[hooks.PermissionRequest]]
        [[hooks.PermissionRequest.hooks]]
        type = "command"
        \(expectedApprovalCommandLine)
        timeout = 600
        """
        XCTAssertTrue(content.contains(approvalUnderPermissionRequest),
                      "The migrated approval entry's exact contiguous TOML block must be nested under " +
                      "[[hooks.PermissionRequest]]")
    }

    /// The same pre-migration shape run through `removeHooks` instead of
    /// a reinstall: the old PreToolUse-nested approval entry must be
    /// removed as part of the whole managed block, not preserved as
    /// foreign TOML outside the markers -- surviving there would leave a
    /// stale synchronous PreToolUse approval hook active even after
    /// uninstall. The user's own `profile` root key must still survive,
    /// so an implementation that over-deletes (e.g. stripping everything
    /// including unrelated user content) can't pass this vacuously.
    func test_removeHooks_preMigrationConfig_removesOldPreToolUseApprovalEntryToo() throws {
        writeConfig(preMigrationConfig)

        try CodexHooksConfigManager.removeHooks(configPath: configPath)

        let content = readConfig()
        XCTAssertTrue(content.contains("profile = \"default\""),
                      "The user's own root key must survive an uninstall of a pre-migration config")
        XCTAssertFalse(content.contains(Self.beginLine), "The whole managed block must be removed")
        XCTAssertFalse(content.contains(expectedCommandLine), "No monitor entry may survive")
        XCTAssertFalse(content.contains(expectedApprovalCommandLine),
                       "The pre-migration PreToolUse-nested approval entry must be removed too, not " +
                       "preserved as foreign TOML outside the markers")
        XCTAssertFalse(content.contains("[[hooks.PreToolUse]]"))
    }

    // MARK: - Upgrade: adds SessionEnd to an older six-event managed block

    /// The approval entry's current, correctly-migrated shape -- nested
    /// under `[[hooks.PermissionRequest]]`, unlike
    /// `preMigrationApprovalEntryUnderPreToolUse` above. Used (together
    /// with `preSessionEndEvents`) to build a fixture representing a
    /// well-formed six-event managed block that already has the approval
    /// entry in the right place, just missing SessionEnd.
    private var approvalEntryUnderPermissionRequest: String {
        """
        [[hooks.PermissionRequest]]
        [[hooks.PermissionRequest.hooks]]
        type = "command"
        \(expectedApprovalCommandLine)
        timeout = 600
        """
    }

    /// A full, well-formed (BEGIN...END, no orphan) config with the 6
    /// `preSessionEndEvents` monitor entries plus the approval entry
    /// already correctly nested under `[[hooks.PermissionRequest]]`, and
    /// no SessionEnd entry.
    private var olderSixEventManagedBlock: String {
        (["profile = \"default\"", Self.beginLine]
            + Self.preSessionEndEvents.map { monitorEntry(eventName: $0) }
            + [approvalEntryUnderPermissionRequest, Self.endLine]).joined(separator: "\n")
    }

    /// Guards the ordinary block-replacement path (a matched BEGIN...END
    /// pair, not the orphan self-heal path covered separately below):
    /// reinstalling over a well-formed six-event managed block (the
    /// `olderSixEventManagedBlock` shape) must add SessionEnd exactly
    /// once, without duplicating any of the other six events or the
    /// approval entry.
    func test_installHooks_reinstallOverOlderSixEventManagedBlock_addsSessionEndWithoutDuplicating() throws {
        writeConfig(olderSixEventManagedBlock)

        try CodexHooksConfigManager.installHooks(scriptPath: scriptPath, approvalScriptPath: approvalScriptPath, configPath: configPath)

        let content = readConfig()
        XCTAssertTrue(content.contains("profile = \"default\""), "The user's own root key must survive the upgrade")
        XCTAssertEqual(occurrences(of: Self.beginLine, in: content), 1,
                       "Reinstalling over an older six-event managed block must leave exactly one managed block")
        XCTAssertEqual(occurrences(of: Self.endLine, in: content), 1)
        XCTAssertEqual(occurrences(of: "[[hooks.SessionEnd]]", in: content), 1,
                       "SessionEnd must be added exactly once, not left missing or duplicated")
        XCTAssertEqual(occurrences(of: "[[hooks.SessionEnd.hooks]]", in: content), 1)
        for eventName in Self.expectedEvents {
            XCTAssertTrue(content.contains("[[hooks.\(eventName)]]"),
                          "\(eventName) must be present after upgrading an older six-event managed block")
        }
        XCTAssertEqual(occurrences(of: expectedCommandLine, in: content), Self.expectedEvents.count,
                       "All seven events, including the newly added SessionEnd, must get exactly one " +
                       "monitor command entry -- none of the original six may be duplicated either")
        XCTAssertEqual(occurrences(of: expectedApprovalCommandLine, in: content), 1,
                       "Reinstalling must not duplicate the approval entry")
    }

    // MARK: - removeHooks

    func test_removeHooks_removesManagedBlockOnlyAndRestoresUserContent() throws {
        let existing = """
        profile = "default"

        [mcp_servers.other]
        url = "http://localhost:9999/mcp"
        """
        writeConfig(existing)
        try CodexHooksConfigManager.installHooks(scriptPath: scriptPath, approvalScriptPath: approvalScriptPath, configPath: configPath)

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
        try CodexHooksConfigManager.installHooks(scriptPath: scriptPath, approvalScriptPath: approvalScriptPath, configPath: configPath)
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

        try CodexHooksConfigManager.installHooks(scriptPath: scriptPath, approvalScriptPath: approvalScriptPath, configPath: configPath)

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

    // isCalyxGeneratedBlockLine must also recognize a command line
    // referencing calyx-approval-hook (not just calyx-agent-hook), so an
    // orphan BEGIN left over from a Calyx version that already installed
    // the approval entry self-heals cleanly too, rather than leaving the
    // stale approval command line behind as unrecognized "real user
    // content".
    func test_installHooks_orphanBeginMarker_withStaleApprovalCommand_selfHeals() throws {
        let staleApprovalPath = tempDir + "/old-install/calyx-approval-hook"
        let existing = """
        profile = "default"
        \(Self.beginLine)
        [[hooks.PreToolUse]]
        [[hooks.PreToolUse.hooks]]
        type = "command"
        command = '"\(staleApprovalPath)" codex'
        timeout = 600
        """
        writeConfig(existing)

        try CodexHooksConfigManager.installHooks(scriptPath: scriptPath, approvalScriptPath: approvalScriptPath, configPath: configPath)

        let content = readConfig()
        XCTAssertTrue(content.contains("profile = \"default\""),
                      "Unrelated content before the orphan block must survive")
        XCTAssertFalse(content.contains(staleApprovalPath),
                       "The orphaned approval entry's stale path must be stripped, not left duplicated")
        XCTAssertEqual(occurrences(of: Self.beginLine, in: content), 1,
                       "Self-healing an orphan BEGIN (with a stale approval entry) and reinstalling " +
                       "must leave exactly one BEGIN marker")
        XCTAssertEqual(occurrences(of: "[[hooks.PreToolUse]]", in: content), 1,
                       "A clean reinstall must write PreToolUse's monitor entry only -- the approval " +
                       "entry no longer belongs there")
        XCTAssertEqual(occurrences(of: "[[hooks.PermissionRequest]]", in: content), 2,
                       "A clean reinstall must write both PermissionRequest pairs (monitor + approval)")
        XCTAssertEqual(occurrences(of: expectedApprovalCommandLine, in: content), 1,
                       "The freshly-wrapped approval entry must reference the current approvalScriptPath")
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

    // Contract: ~/.codex/config.toml is commonly a
    // dotfiles-managed symlink, and blanket symlink rejection silently
    // broke hooks installation entirely in that setup. Calyx now follows
    // the link and writes through to the real target file, leaving the
    // link itself intact.
    func test_installHooks_symlinkConfigPath_followsToRealFileAndKeepsLinkIntact() throws {
        let realFile = tempDir + "/real_config.toml"
        FileManager.default.createFile(atPath: realFile, contents: Data("".utf8))
        try FileManager.default.createSymbolicLink(atPath: configPath, withDestinationPath: realFile)

        try CodexHooksConfigManager.installHooks(scriptPath: scriptPath, approvalScriptPath: approvalScriptPath, configPath: configPath)

        let realContent = try String(contentsOfFile: realFile, encoding: .utf8)
        XCTAssertTrue(realContent.contains(Self.beginLine),
                      "installHooks must write the managed block through the symlink into the real file")

        let attrsAfter = try FileManager.default.attributesOfItem(atPath: configPath)
        XCTAssertEqual(attrsAfter[.type] as? FileAttributeType, .typeSymbolicLink,
                       "The symlink at configPath must survive the write")
        let destination = try FileManager.default.destinationOfSymbolicLink(atPath: configPath)
        XCTAssertEqual(destination, realFile)
    }

    // resolveConfigPath follows a multi-hop *dangling*
    // symlink chain (link -> link -> not-yet-existing file) all the way
    // to its final destination, rather than stopping at the first
    // intermediate link. Same shared ConfigFileUtils primitive as every
    // other config manager.
    func test_installHooks_multiHopDanglingSymlink_createsRealFileAtFinalDestination() throws {
        let finalTarget = tempDir + "/dotfiles/config.toml"
        try FileManager.default.createDirectory(
            atPath: (finalTarget as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        let middleLink = tempDir + "/middle-link.toml"
        try FileManager.default.createSymbolicLink(atPath: middleLink, withDestinationPath: finalTarget)
        try FileManager.default.createSymbolicLink(atPath: configPath, withDestinationPath: middleLink)

        try CodexHooksConfigManager.installHooks(scriptPath: scriptPath, approvalScriptPath: approvalScriptPath, configPath: configPath)

        let realContent = try String(contentsOfFile: finalTarget, encoding: .utf8)
        XCTAssertTrue(realContent.contains(Self.beginLine),
                      "installHooks must create the file at the multi-hop dangling chain's final destination")

        let middleAttrs = try FileManager.default.attributesOfItem(atPath: middleLink)
        XCTAssertEqual(middleAttrs[.type] as? FileAttributeType, .typeSymbolicLink,
                       "The intermediate link must survive as a symlink, not be replaced with a regular file")
    }

    func test_removeHooks_symlinkConfigPath_followsToRealFileAndKeepsLinkIntact() throws {
        let realFile = tempDir + "/real_config.toml"
        writeConfig("profile = \"default\"\n" + CodexHooksConfigManager.beginLine + "\n" +
                    "[[hooks.Stop]]\n" + CodexHooksConfigManager.endLine + "\n")
        try FileManager.default.moveItem(atPath: configPath, toPath: realFile)
        try FileManager.default.createSymbolicLink(atPath: configPath, withDestinationPath: realFile)

        try CodexHooksConfigManager.removeHooks(configPath: configPath)

        let realContent = try String(contentsOfFile: realFile, encoding: .utf8)
        XCTAssertFalse(realContent.contains(Self.beginLine),
                       "removeHooks must remove the managed block from the real file reached through the symlink")
        XCTAssertTrue(realContent.contains("profile = \"default\""))

        let attrsAfter = try FileManager.default.attributesOfItem(atPath: configPath)
        XCTAssertEqual(attrsAfter[.type] as? FileAttributeType, .typeSymbolicLink,
                       "The symlink at configPath must survive the write")
    }

    func test_installHooks_scriptPathContainingSingleQuote_throws() {
        let badScriptPath = tempDir + "/it's-a-path/calyx-agent-hook"

        XCTAssertThrowsError(
            try CodexHooksConfigManager.installHooks(
                scriptPath: badScriptPath, approvalScriptPath: approvalScriptPath, configPath: configPath
            ),
            "A scriptPath containing a single quote would break the TOML literal string and must be rejected"
        )
    }

    // Single-quote guard applies to approvalScriptPath too -- it's embedded
    // in the exact same TOML literal-string shape as scriptPath.
    func test_installHooks_approvalScriptPathContainingSingleQuote_throws() {
        let badApprovalScriptPath = tempDir + "/it's-a-path/calyx-approval-hook"

        XCTAssertThrowsError(
            try CodexHooksConfigManager.installHooks(
                scriptPath: scriptPath, approvalScriptPath: badApprovalScriptPath, configPath: configPath
            ),
            "An approvalScriptPath containing a single quote would break the TOML literal string and must be rejected"
        )
    }

    // MARK: - areHooksInstalled

    func test_areHooksInstalled_reflectsInstallState() throws {
        XCTAssertFalse(CodexHooksConfigManager.areHooksInstalled(configPath: configPath),
                       "No config file yet -> hooks must not be reported as installed")

        try CodexHooksConfigManager.installHooks(scriptPath: scriptPath, approvalScriptPath: approvalScriptPath, configPath: configPath)

        XCTAssertTrue(CodexHooksConfigManager.areHooksInstalled(configPath: configPath),
                      "After installHooks, hooks must be reported as installed")

        try CodexHooksConfigManager.removeHooks(configPath: configPath)

        XCTAssertFalse(CodexHooksConfigManager.areHooksInstalled(configPath: configPath),
                       "After removeHooks, hooks must no longer be reported as installed")
    }

    // areHooksInstalled must use the same whitespace-tolerant, byte-level
    // BEGIN-line match the write side (markerEditor / findBeginLineIndex)
    // uses, not a separate String-based exact-line match: a second
    // detection rule for the same file lets a user's own reformatting
    // (leading/trailing whitespace on the BEGIN line) make this read-only
    // check disagree with what removeHooks would actually find.
    func test_areHooksInstalled_beginLineWithSurroundingWhitespace_lfFile_isTrue() throws {
        let content = [
            "profile = \"default\"",
            "  " + Self.beginLine + "  ",
            "[[hooks.Stop]]",
            Self.endLine,
            "",
        ].joined(separator: "\n")
        writeConfig(content)

        XCTAssertTrue(CodexHooksConfigManager.areHooksInstalled(configPath: configPath),
                      "A BEGIN line with leading/trailing whitespace must still be recognized as installed, " +
                      "matching the write side's own whitespace-tolerant marker scan")
    }

    func test_areHooksInstalled_beginLineWithSurroundingWhitespace_crlfFile_isTrue() throws {
        let content = [
            "profile = \"default\"",
            "  " + Self.beginLine + "  ",
            "[[hooks.Stop]]",
            Self.endLine,
            "",
        ].joined(separator: "\r\n")
        writeConfig(content)

        XCTAssertTrue(CodexHooksConfigManager.areHooksInstalled(configPath: configPath),
                      "A CRLF file with a whitespace-padded BEGIN line must still be recognized as installed")
    }

    func test_areHooksInstalled_noManagedBlock_isFalse() throws {
        writeConfig("profile = \"default\"\n")

        XCTAssertFalse(CodexHooksConfigManager.areHooksInstalled(configPath: configPath),
                       "A file with no Calyx managed block must not be reported as installed")
    }

    // MARK: - Never delete a user-owned file

    func test_removeHooks_afterInstall_onUserCreatedEmptyFile_leavesFilePresentAndEmpty() throws {
        FileManager.default.createFile(atPath: configPath, contents: Data())
        XCTAssertTrue(FileManager.default.fileExists(atPath: configPath), "precondition: empty file exists")

        try CodexHooksConfigManager.installHooks(scriptPath: scriptPath, approvalScriptPath: approvalScriptPath, configPath: configPath)
        try CodexHooksConfigManager.removeHooks(configPath: configPath)

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: configPath),
            "a file the user created must never be deleted by Calyx, even once it became entirely Calyx's own region"
        )
        let data = try Data(contentsOf: URL(fileURLWithPath: configPath))
        XCTAssertEqual(data, Data(), "the file must be left behind empty, not with a leftover blank line or deleted")
    }

    func test_removeHooks_onAbsentFile_leavesFileAbsent() throws {
        XCTAssertFalse(FileManager.default.fileExists(atPath: configPath))
        try CodexHooksConfigManager.removeHooks(configPath: configPath)
        XCTAssertFalse(FileManager.default.fileExists(atPath: configPath), "removeHooks must never create a file that never existed")
    }

    // MARK: - An existing managed block is replaced in place, never moved to EOF

    func test_installHooks_blockFollowedByUserTable_sameScriptPath_isNoOpByteIdenticalAndUnwritten() throws {
        try CodexHooksConfigManager.installHooks(scriptPath: scriptPath, approvalScriptPath: approvalScriptPath, configPath: configPath)
        let generatedBlock = readConfig()
        let userTable = "\n[profiles.work]\nkey = \"value\"\n"
        writeConfig(generatedBlock + userTable)

        let attrsBefore = try FileManager.default.attributesOfItem(atPath: configPath)
        let inodeBefore = attrsBefore[.systemFileNumber] as? Int

        try CodexHooksConfigManager.installHooks(scriptPath: scriptPath, approvalScriptPath: approvalScriptPath, configPath: configPath)

        let content = readConfig()
        XCTAssertEqual(
            content, generatedBlock + userTable,
            "re-installing with an identical scriptPath must leave the file byte-identical, the managed " +
            "block staying in place before the user's table rather than moving to EOF"
        )
        let attrsAfter = try FileManager.default.attributesOfItem(atPath: configPath)
        XCTAssertEqual(
            inodeBefore, attrsAfter[.systemFileNumber] as? Int,
            "byte-identical output must skip the write entirely (inode unchanged)"
        )
    }

    func test_installHooks_blockFollowedByUserTable_differentScriptPath_keepsPositionChangesOnlyBody() throws {
        try CodexHooksConfigManager.installHooks(scriptPath: scriptPath, approvalScriptPath: approvalScriptPath, configPath: configPath)
        let generatedBlock = readConfig()
        let userTable = "\n[profiles.work]\nkey = \"value\"\n"
        writeConfig(generatedBlock + userTable)

        let newScriptPath = tempDir + "/bin2/calyx-agent-hook"
        try CodexHooksConfigManager.installHooks(scriptPath: newScriptPath, approvalScriptPath: approvalScriptPath, configPath: configPath)

        let content = readConfig()
        XCTAssertTrue(content.hasSuffix(userTable), "the user's table must remain at EOF, untouched")
        XCTAssertTrue(content.contains("\"\(newScriptPath)\" codex"), "the block body must use the new scriptPath")
        XCTAssertFalse(content.contains(expectedCommandLine), "the old scriptPath's command line must no longer appear")

        let beginRange = try XCTUnwrap(content.range(of: Self.beginLine))
        let tableRange = try XCTUnwrap(content.range(of: "[profiles.work]"))
        XCTAssertLessThan(
            beginRange.lowerBound, tableRange.lowerBound,
            "the block must stay before the user's table, not move to after it"
        )
    }

    func test_installHooks_foreignTableInsideBlockFollowedByUserTable_liftsBeforeBlockThenSecondInstallIsNoOp() throws {
        try CodexHooksConfigManager.installHooks(scriptPath: scriptPath, approvalScriptPath: approvalScriptPath, configPath: configPath)
        let generatedBlock = readConfig()

        let foreignTable = """
        [shell_environment_policy.set]
        USER_OWNED_SETTING = "preserve-me"
        """
        let approvalEntry = """
        [[hooks.PermissionRequest]]
        [[hooks.PermissionRequest.hooks]]
        type = "command"
        \(expectedApprovalCommandLine)
        timeout = 600
        """
        let withForeignTable = generatedBlock.replacingOccurrences(
            of: approvalEntry, with: foreignTable + "\n" + approvalEntry
        )
        XCTAssertNotEqual(generatedBlock, withForeignTable, "precondition: foreign table injected inside the markers")

        let userTable = "[profiles.work]\nkey = \"value\"\n"
        writeConfig(withForeignTable + userTable)

        try CodexHooksConfigManager.installHooks(scriptPath: scriptPath, approvalScriptPath: approvalScriptPath, configPath: configPath)

        let afterFirstInstall = readConfig()
        XCTAssertTrue(afterFirstInstall.contains("USER_OWNED_SETTING = \"preserve-me\""), "the foreign table's content must survive")
        let foreignRange = try XCTUnwrap(afterFirstInstall.range(of: "[shell_environment_policy.set]"))
        let beginRange = try XCTUnwrap(afterFirstInstall.range(of: Self.beginLine))
        let tableRange = try XCTUnwrap(afterFirstInstall.range(of: "[profiles.work]"))
        XCTAssertLessThan(foreignRange.lowerBound, beginRange.lowerBound, "the foreign table must sit right before the rewritten block")
        XCTAssertLessThan(beginRange.lowerBound, tableRange.lowerBound, "the block must stay before the user's table, not move after it")

        try CodexHooksConfigManager.installHooks(scriptPath: scriptPath, approvalScriptPath: approvalScriptPath, configPath: configPath)
        let afterSecondInstall = readConfig()
        XCTAssertEqual(afterSecondInstall, afterFirstInstall, "a second install with identical inputs must be a no-op")
    }
}
