//
//  ClaudeHooksConfigManagerTests.swift
//  CalyxTests
//
//  TDD Red Phase for ClaudeHooksConfigManager: writes the "hooks" section of
//  ~/.claude/settings.json for the calyx-agent-hook script, following the
//  same file-safety guarantees as ClaudeConfigManager (see
//  ClaudeConfigManagerTests.swift): symlink rejection, .bak backup, and
//  preservation of unrelated content.
//
//  Coverage:
//  - installHooks on an empty/new file writes all 7 target events, each
//    with a command entry (type=command, timeout, async=true)
//  - PreToolUse / PostToolUse use matcher "*"; Notification uses matcher
//    "permission_prompt"
//  - installHooks preserves the user's own existing hook entries and
//    unrelated top-level keys
//  - Re-installing is idempotent (no duplicate command entries)
//  - removeHooks removes only Calyx's own entries, identified by command
//    path, leaving co-located user hooks untouched
//  - symlink config path is rejected
//  - a .bak backup of the pre-install content is created
//

import XCTest
@testable import Calyx

final class ClaudeHooksConfigManagerTests: XCTestCase {

    // MARK: - Properties

    private var tempDir: String!
    private var configPath: String!
    private var scriptPath: String!

    private static let expectedEvents = [
        "SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse",
        "Notification", "Stop", "SessionEnd",
    ]

    private static let expectedMatcherByEvent: [String: String] = [
        "PreToolUse": "*",
        "PostToolUse": "*",
        "Notification": "permission_prompt",
    ]

    // MARK: - Lifecycle

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).path
        try! FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        configPath = tempDir + "/settings.json"
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

    private func writeConfigDict(_ dict: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: dict)
        try data.write(to: URL(fileURLWithPath: configPath))
    }

    private func readConfigDict() throws -> [String: Any] {
        let data = try Data(contentsOf: URL(fileURLWithPath: configPath))
        let obj = try JSONSerialization.jsonObject(with: data)
        return (obj as? [String: Any]) ?? [:]
    }

    private func hookGroups(_ dict: [String: Any], event: String) -> [[String: Any]] {
        let hooks = dict["hooks"] as? [String: Any] ?? [:]
        return hooks[event] as? [[String: Any]] ?? []
    }

    private func commandEntries(_ groups: [[String: Any]]) -> [[String: Any]] {
        groups.flatMap { ($0["hooks"] as? [[String: Any]]) ?? [] }
    }

    // MARK: - installHooks: fresh file

    func test_installHooks_newFile_writesAllSevenEventsWithCommandEntry() throws {
        try ClaudeHooksConfigManager.installHooks(scriptPath: scriptPath, configPath: configPath)

        let dict = try readConfigDict()

        for eventName in Self.expectedEvents {
            let groups = hookGroups(dict, event: eventName)
            XCTAssertFalse(groups.isEmpty, "\(eventName) hook group must be present")

            if let expectedMatcher = Self.expectedMatcherByEvent[eventName] {
                XCTAssertEqual(groups.first?["matcher"] as? String, expectedMatcher,
                               "\(eventName) matcher must be '\(expectedMatcher)'")
            }

            let commands = commandEntries(groups)
            XCTAssertEqual(commands.count, 1, "\(eventName) must contain exactly one command entry")
            let entry = commands.first ?? [:]
            XCTAssertEqual(entry["type"] as? String, "command")
            XCTAssertNotNil(entry["timeout"], "\(eventName) command entry must specify a timeout")
            XCTAssertEqual(entry["async"] as? Bool, true, "\(eventName) command entry must be async")
        }
    }

    // MARK: - installHooks: preserves existing content

    func test_installHooks_preservesExistingUserHooksAndOtherTopLevelKeys() throws {
        let existingConfig: [String: Any] = [
            "hooks": [
                "PreToolUse": [
                    ["matcher": "Bash", "hooks": [
                        ["type": "command", "command": "/usr/local/bin/user-hook", "timeout": 10],
                    ]],
                ],
            ],
            "permissions": ["allow": ["read", "write"]],
        ]
        try writeConfigDict(existingConfig)

        try ClaudeHooksConfigManager.installHooks(scriptPath: scriptPath, configPath: configPath)

        let dict = try readConfigDict()
        let preToolUseGroups = hookGroups(dict, event: "PreToolUse")

        let userGroup = preToolUseGroups.first { ($0["matcher"] as? String) == "Bash" }
        XCTAssertNotNil(userGroup, "The user's existing 'Bash' matcher group must be preserved")

        let calyxGroup = preToolUseGroups.first { ($0["matcher"] as? String) == "*" }
        XCTAssertNotNil(calyxGroup, "Calyx's own '*' matcher group must be added")

        let permissions = dict["permissions"] as? [String: Any]
        XCTAssertEqual(permissions?["allow"] as? [String], ["read", "write"],
                       "Unrelated top-level keys must be preserved")
    }

    // MARK: - installHooks: idempotency

    func test_installHooks_reinstall_isIdempotent() throws {
        try ClaudeHooksConfigManager.installHooks(scriptPath: scriptPath, configPath: configPath)
        try ClaudeHooksConfigManager.installHooks(scriptPath: scriptPath, configPath: configPath)

        let dict = try readConfigDict()

        for eventName in Self.expectedEvents {
            let commands = commandEntries(hookGroups(dict, event: eventName))
            XCTAssertEqual(commands.count, 1,
                           "\(eventName) must contain exactly one Calyx hook entry after reinstalling twice")
        }
    }

    // MARK: - removeHooks

    func test_removeHooks_removesOnlyOwnEntriesByCommandPath() throws {
        let calyxCommand = "\"\(scriptPath!)\""
        let existingConfig: [String: Any] = [
            "hooks": [
                "Stop": [
                    ["hooks": [
                        ["type": "command", "command": calyxCommand, "timeout": 5, "async": true],
                        ["type": "command", "command": "/usr/local/bin/my-other-hook", "timeout": 3],
                    ]],
                ],
                "SessionStart": [
                    ["hooks": [
                        ["type": "command", "command": calyxCommand, "timeout": 5, "async": true],
                    ]],
                ],
            ],
            "permissions": ["allow": ["read"]],
        ]
        try writeConfigDict(existingConfig)

        try ClaudeHooksConfigManager.removeHooks(configPath: configPath)

        let dict = try readConfigDict()

        let stopCommands = commandEntries(hookGroups(dict, event: "Stop"))
        XCTAssertEqual(stopCommands.count, 1,
                       "Only Calyx's own Stop hook entry should be removed; the co-located user hook must remain")
        XCTAssertEqual(stopCommands.first?["command"] as? String, "/usr/local/bin/my-other-hook")

        let sessionStartCommands = commandEntries(hookGroups(dict, event: "SessionStart"))
        XCTAssertTrue(sessionStartCommands.isEmpty,
                      "Calyx's only SessionStart hook entry should leave the group empty")

        let permissions = dict["permissions"] as? [String: Any]
        XCTAssertEqual(permissions?["allow"] as? [String], ["read"], "Unrelated top-level keys must be preserved")
    }

    func test_removeHooks_dropsEmptyEventKeysAndHooksKeyWhenAllEmpty() throws {
        // The 7 events installHooks writes only ever contain Calyx's own
        // entry in a fresh install, so removing them should leave neither
        // a dangling "EventName": [] nor an empty "hooks": {} behind.
        try ClaudeHooksConfigManager.installHooks(scriptPath: scriptPath, configPath: configPath)

        try ClaudeHooksConfigManager.removeHooks(configPath: configPath)

        let dict = try readConfigDict()
        XCTAssertNil(dict["hooks"], "The \"hooks\" key must be removed entirely once every event under it is empty")
    }

    func test_removeHooks_keepsHooksKeyWhenOtherEventsSurvive() throws {
        let calyxCommand = "\"\(scriptPath!)\""
        let existingConfig: [String: Any] = [
            "hooks": [
                "SessionStart": [
                    ["hooks": [
                        ["type": "command", "command": calyxCommand, "timeout": 5, "async": true],
                    ]],
                ],
                "PreToolUse": [
                    ["matcher": "Bash", "hooks": [
                        ["type": "command", "command": "/usr/local/bin/user-hook", "timeout": 10],
                    ]],
                ],
            ],
        ]
        try writeConfigDict(existingConfig)

        try ClaudeHooksConfigManager.removeHooks(configPath: configPath)

        let dict = try readConfigDict()
        XCTAssertNil(dict["hooks"].flatMap { ($0 as? [String: Any])?["SessionStart"] },
                    "SessionStart's now-empty group list must be dropped")
        let preToolUseGroups = hookGroups(dict, event: "PreToolUse")
        XCTAssertFalse(preToolUseGroups.isEmpty, "PreToolUse's surviving user hook must keep the \"hooks\" key present")
    }

    func test_installThenRemove_restoresOriginalConfig() throws {
        let originalConfig: [String: Any] = [
            "hooks": [
                "PreToolUse": [
                    ["matcher": "Bash", "hooks": [
                        ["type": "command", "command": "/usr/local/bin/user-hook", "timeout": 10],
                    ]],
                ],
            ],
            "permissions": ["allow": ["read", "write"]],
        ]
        try writeConfigDict(originalConfig)

        try ClaudeHooksConfigManager.installHooks(scriptPath: scriptPath, configPath: configPath)
        try ClaudeHooksConfigManager.removeHooks(configPath: configPath)

        let dict = try readConfigDict()
        let preToolUseGroups = hookGroups(dict, event: "PreToolUse")
        XCTAssertEqual(preToolUseGroups.count, 1, "Only the user's own PreToolUse group must remain")
        XCTAssertEqual(commandEntries(preToolUseGroups).first?["command"] as? String, "/usr/local/bin/user-hook")

        for eventName in Self.expectedEvents where eventName != "PreToolUse" {
            XCTAssertTrue(hookGroups(dict, event: eventName).isEmpty,
                          "\(eventName) had no user entries, so install→remove must leave it absent")
        }

        let permissions = dict["permissions"] as? [String: Any]
        XCTAssertEqual(permissions?["allow"] as? [String], ["read", "write"], "Unrelated top-level keys must survive install→remove")
    }

    // MARK: - Security

    func test_installHooks_symlinkConfigPath_throws() throws {
        let realFile = tempDir + "/real_settings.json"
        writeConfig("{}")
        try FileManager.default.moveItem(atPath: configPath, toPath: realFile)
        try FileManager.default.createSymbolicLink(atPath: configPath, withDestinationPath: realFile)

        XCTAssertThrowsError(
            try ClaudeHooksConfigManager.installHooks(scriptPath: scriptPath, configPath: configPath),
            "Should reject a symlinked config path"
        )
    }

    // MARK: - Backup

    func test_installHooks_createsBackupOfExistingFile() throws {
        writeConfig("{ \"hooks\": {} }")

        try ClaudeHooksConfigManager.installHooks(scriptPath: scriptPath, configPath: configPath)

        let bakPath = configPath + ".bak"
        XCTAssertTrue(FileManager.default.fileExists(atPath: bakPath),
                     "A backup file must be created before modification")

        let bakContent = try String(contentsOfFile: bakPath, encoding: .utf8)
        XCTAssertFalse(bakContent.contains("calyx-agent-hook"),
                       "Backup must contain the pre-install content, not the newly added Calyx hooks")
    }

    func test_removeHooks_createsBackupOfPreRemovalContent() throws {
        try ClaudeHooksConfigManager.installHooks(scriptPath: scriptPath, configPath: configPath)

        try ClaudeHooksConfigManager.removeHooks(configPath: configPath)

        let bakPath = configPath + ".bak"
        XCTAssertTrue(FileManager.default.fileExists(atPath: bakPath),
                     "removeHooks must also create a backup before modification, like installHooks")

        let bakContent = try String(contentsOfFile: bakPath, encoding: .utf8)
        XCTAssertTrue(bakContent.contains("calyx-agent-hook"),
                      "Backup must contain the pre-removal (installed) content")
    }

    // MARK: - Preserving unrecognized hook shapes

    func test_installHooks_unrecognizedEventShape_isLeftUntouched() throws {
        // A malformed/hand-edited/future-format value for one event
        // (here, a bare dict instead of the expected array-of-groups)
        // must survive installHooks verbatim rather than being silently
        // replaced with just Calyx's own group.
        let existingConfig: [String: Any] = [
            "hooks": [
                "Stop": ["unexpectedShape": true],
            ],
        ]
        try writeConfigDict(existingConfig)

        try ClaudeHooksConfigManager.installHooks(scriptPath: scriptPath, configPath: configPath)

        let dict = try readConfigDict()
        let hooks = dict["hooks"] as? [String: Any]
        let stopValue = hooks?["Stop"] as? [String: Any]
        XCTAssertEqual(stopValue?["unexpectedShape"] as? Bool, true,
                       "An unrecognized existing shape for an event must be left untouched, not discarded")
    }

    // MARK: - areHooksInstalled

    func test_areHooksInstalled_reflectsInstallState() throws {
        XCTAssertFalse(ClaudeHooksConfigManager.areHooksInstalled(configPath: configPath),
                       "No config file yet -> hooks must not be reported as installed")

        try ClaudeHooksConfigManager.installHooks(scriptPath: scriptPath, configPath: configPath)

        XCTAssertTrue(ClaudeHooksConfigManager.areHooksInstalled(configPath: configPath),
                      "After installHooks, hooks must be reported as installed")
    }
}
