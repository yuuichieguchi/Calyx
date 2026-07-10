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
//  - installHooks on an empty/new file writes all 8 target events, each
//    with a command entry (type=command, timeout, async=true)
//  - PreToolUse / PostToolUse / PermissionRequest (Round 4) use matcher
//    "*"; Notification uses matcher "permission_prompt"
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
    private var approvalScriptPath: String!

    // Round 4: PermissionRequest fires in sync with the permission dialog
    // appearing, unlike Notification(permission_prompt) which can lag
    // behind it by several seconds — subscribing to it too lets the
    // sidebar flip to blocked immediately instead of waiting for the
    // delayed Notification hook.
    private static let expectedEvents = [
        "SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse",
        "Notification", "Stop", "SessionEnd", "PermissionRequest",
    ]

    // Round 4 review: PermissionRequest's matcher was unified with
    // PreToolUse/PostToolUse's "*" (previously omitted entirely) — see
    // ClaudeHooksConfigManager.targetEvents' doc comment.
    private static let expectedMatcherByEvent: [String: String] = [
        "PreToolUse": "*",
        "PostToolUse": "*",
        "PermissionRequest": "*",
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
        approvalScriptPath = tempDir + "/bin/calyx-approval-hook"
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
        try writeConfigDict(dict, to: configPath)
    }

    private func writeConfigDict(_ dict: [String: Any], to path: String) throws {
        let data = try JSONSerialization.data(withJSONObject: dict)
        try data.write(to: URL(fileURLWithPath: path))
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

    // Round 4: renamed from ...writesAllSevenEventsWithCommandEntry — the
    // contract is now 8 events (PermissionRequest added, see
    // `expectedEvents`'s doc comment).
    //
    // Stage C: PreToolUse alone now carries a SECOND Calyx-owned command
    // entry (the synchronous approval entry, see
    // `test_installHooks_preToolUse_writesMonitorAndApprovalEntriesWithCorrectShapes`
    // below) alongside the pre-existing async monitor entry every other
    // event still gets exactly one of.
    func test_installHooks_newFile_writesAllEightEventsWithCommandEntry() throws {
        try ClaudeHooksConfigManager.installHooks(scriptPath: scriptPath, approvalScriptPath: approvalScriptPath, configPath: configPath)

        let dict = try readConfigDict()

        for eventName in Self.expectedEvents {
            let groups = hookGroups(dict, event: eventName)
            XCTAssertFalse(groups.isEmpty, "\(eventName) hook group must be present")

            if let expectedMatcher = Self.expectedMatcherByEvent[eventName] {
                XCTAssertEqual(groups.first?["matcher"] as? String, expectedMatcher,
                               "\(eventName) matcher must be '\(expectedMatcher)'")
            }

            let commands = commandEntries(groups)

            if eventName == "PreToolUse" {
                XCTAssertEqual(commands.count, 2,
                               "PreToolUse must contain both the async monitor entry and the " +
                               "sync approval entry")
                continue
            }

            XCTAssertEqual(commands.count, 1, "\(eventName) must contain exactly one command entry")
            let entry = commands.first ?? [:]
            XCTAssertEqual(entry["type"] as? String, "command")
            XCTAssertNotNil(entry["timeout"], "\(eventName) command entry must specify a timeout")
            XCTAssertEqual(entry["async"] as? Bool, true, "\(eventName) command entry must be async")
        }
    }

    // Round 4 review: PermissionRequest's matcher contract changed from
    // "no matcher key at all" to `"*"` (unified with PreToolUse/
    // PostToolUse — see targetEvents' doc comment), so this test — pre-review
    // named ...hasCommandEntryAndNoMatcherKey and asserting `XCTAssertNil`
    // — is renamed and its assertion flipped accordingly. The loop above
    // already covers the same matcher value via `expectedMatcherByEvent`;
    // this test additionally pins down PermissionRequest's command-entry
    // shape (type/timeout/async) on its own.
    func test_installHooks_permissionRequest_hasCommandEntryAndWildcardMatcher() throws {
        try ClaudeHooksConfigManager.installHooks(scriptPath: scriptPath, approvalScriptPath: approvalScriptPath, configPath: configPath)

        let dict = try readConfigDict()
        let groups = hookGroups(dict, event: "PermissionRequest")

        XCTAssertFalse(groups.isEmpty, "PermissionRequest hook group must be present")
        XCTAssertEqual(groups.first?["matcher"] as? String, "*",
                       "PermissionRequest's matcher must be \"*\", unified with PreToolUse/PostToolUse")

        let commands = commandEntries(groups)
        XCTAssertEqual(commands.count, 1, "PermissionRequest must contain exactly one command entry")
        let entry = commands.first ?? [:]
        XCTAssertEqual(entry["type"] as? String, "command")
        XCTAssertNotNil(entry["timeout"], "PermissionRequest command entry must specify a timeout")
        XCTAssertEqual(entry["async"] as? Bool, true, "PermissionRequest command entry must be async")
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

        try ClaudeHooksConfigManager.installHooks(scriptPath: scriptPath, approvalScriptPath: approvalScriptPath, configPath: configPath)

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
        try ClaudeHooksConfigManager.installHooks(scriptPath: scriptPath, approvalScriptPath: approvalScriptPath, configPath: configPath)
        try ClaudeHooksConfigManager.installHooks(scriptPath: scriptPath, approvalScriptPath: approvalScriptPath, configPath: configPath)

        let dict = try readConfigDict()

        for eventName in Self.expectedEvents {
            let commands = commandEntries(hookGroups(dict, event: eventName))
            let expectedCount = eventName == "PreToolUse" ? 2 : 1
            XCTAssertEqual(commands.count, expectedCount,
                           "\(eventName) must contain exactly \(expectedCount) Calyx hook entry(ies) " +
                           "after reinstalling twice")
        }
    }

    // MARK: - Stage C: PreToolUse monitor + approval entries

    // Stage C: PreToolUse's group now carries two Calyx-owned command
    // entries -- the pre-existing async monitor entry (unchanged shape)
    // and a new synchronous approval entry that blocks the tool call
    // until Calyx's own /approval-request long-poll resolves.
    func test_installHooks_preToolUse_writesMonitorAndApprovalEntriesWithCorrectShapes() throws {
        try ClaudeHooksConfigManager.installHooks(scriptPath: scriptPath, approvalScriptPath: approvalScriptPath, configPath: configPath)

        let dict = try readConfigDict()
        let commands = commandEntries(hookGroups(dict, event: "PreToolUse"))
        XCTAssertEqual(commands.count, 2, "PreToolUse must have exactly two Calyx command entries")

        let monitor = try XCTUnwrap(
            commands.first { ($0["command"] as? String) == "\"\(scriptPath!)\"" },
            "The existing async monitor entry (command = scriptPath) must survive unchanged"
        )
        XCTAssertEqual(monitor["type"] as? String, "command")
        XCTAssertEqual(monitor["timeout"] as? Int, 5)
        XCTAssertEqual(monitor["async"] as? Bool, true)

        let approval = try XCTUnwrap(
            commands.first { ($0["command"] as? String) == "\"\(approvalScriptPath!)\"" },
            "A new synchronous approval entry (command = approvalScriptPath) must be added"
        )
        XCTAssertEqual(approval["type"] as? String, "command")
        XCTAssertEqual(approval["timeout"] as? Int, ApprovalHookTiming.hookEntryTimeoutSeconds)
        XCTAssertNil(approval["async"], "The approval entry must be synchronous -- no \"async\" key at all")
    }

    func test_installHooks_preToolUseApprovalEntry_hasNoAsyncKeyAndCorrectTimeout() throws {
        try ClaudeHooksConfigManager.installHooks(scriptPath: scriptPath, approvalScriptPath: approvalScriptPath, configPath: configPath)

        let dict = try readConfigDict()
        let commands = commandEntries(hookGroups(dict, event: "PreToolUse"))
        let approvalEntry = try XCTUnwrap(
            commands.first { ($0["command"] as? String) == "\"\(approvalScriptPath!)\"" },
            "The approval entry (command = approvalScriptPath) must be present"
        )

        XCTAssertEqual(approvalEntry["timeout"] as? Int, 600,
                       "The approval entry's timeout must equal ApprovalHookTiming.hookEntryTimeoutSeconds (600)")
        XCTAssertNil(approvalEntry["async"], "The approval entry must have no \"async\" key -- it runs synchronously")
    }

    // Upgrade path: a config written by a pre-Stage-C Calyx version has
    // PreToolUse's group with only the async monitor entry. installHooks
    // must add the approval entry alongside it without duplicating the
    // monitor entry or creating a second "*" matcher group.
    func test_installHooks_upgradesOldSinglePreToolUseEntry_toTwoEntriesNoDuplicates() throws {
        let existingConfig: [String: Any] = [
            "hooks": [
                "PreToolUse": [
                    ["matcher": "*", "hooks": [
                        ["type": "command", "command": "\"\(scriptPath!)\"", "timeout": 5, "async": true],
                    ]],
                ],
            ],
        ]
        try writeConfigDict(existingConfig)

        try ClaudeHooksConfigManager.installHooks(scriptPath: scriptPath, approvalScriptPath: approvalScriptPath, configPath: configPath)

        let dict = try readConfigDict()
        let groups = hookGroups(dict, event: "PreToolUse")
        let wildcardGroups = groups.filter { ($0["matcher"] as? String) == "*" }
        XCTAssertEqual(wildcardGroups.count, 1, "Upgrading must not create a second '*' matcher group")

        let commands = commandEntries(groups)
        XCTAssertEqual(commands.count, 2,
                       "Upgrading an old single-entry PreToolUse group must yield exactly the " +
                       "monitor + approval pair")
        XCTAssertEqual(commands.filter { ($0["command"] as? String) == "\"\(scriptPath!)\"" }.count, 1,
                       "The pre-existing monitor entry must not be duplicated")
        XCTAssertEqual(commands.filter { ($0["command"] as? String) == "\"\(approvalScriptPath!)\"" }.count, 1,
                       "Exactly one approval entry must be added")
    }

    // isOwnCommandEntry must recognize calyx-approval-hook's own filename
    // directly -- independent of ever having gone through installHooks --
    // so a group containing only the approval entry still gets stripped
    // correctly by removeHooks.
    func test_removeHooks_stripsApprovalOnlyEntryByCommandPath() throws {
        let approvalCommand = "\"\(approvalScriptPath!)\""
        let existingConfig: [String: Any] = [
            "hooks": [
                "PreToolUse": [
                    ["matcher": "*", "hooks": [
                        ["type": "command", "command": approvalCommand, "timeout": 600],
                        ["type": "command", "command": "/usr/local/bin/user-approval-hook", "timeout": 3],
                    ]],
                ],
            ],
        ]
        try writeConfigDict(existingConfig)

        try ClaudeHooksConfigManager.removeHooks(configPath: configPath)

        let dict = try readConfigDict()
        let commands = commandEntries(hookGroups(dict, event: "PreToolUse"))
        XCTAssertEqual(commands.count, 1, "Only Calyx's own approval entry should be removed")
        XCTAssertEqual(commands.first?["command"] as? String, "/usr/local/bin/user-approval-hook")
    }

    func test_removeHooks_stripsBothMonitorAndApprovalEntriesPreservingUserEntries() throws {
        let userCommand = "/usr/local/bin/user-hook"
        let existingConfig: [String: Any] = [
            "hooks": [
                "PreToolUse": [
                    ["matcher": "Bash", "hooks": [
                        ["type": "command", "command": userCommand, "timeout": 10],
                    ]],
                ],
            ],
        ]
        try writeConfigDict(existingConfig)

        try ClaudeHooksConfigManager.installHooks(scriptPath: scriptPath, approvalScriptPath: approvalScriptPath, configPath: configPath)
        try ClaudeHooksConfigManager.removeHooks(configPath: configPath)

        let dict = try readConfigDict()
        let groups = hookGroups(dict, event: "PreToolUse")
        XCTAssertEqual(groups.count, 1, "Only the user's own 'Bash' matcher group must remain")
        XCTAssertEqual(commandEntries(groups).first?["command"] as? String, userCommand)
    }

    func test_areHooksInstalled_trueWhenOnlyApprovalEntryPresent() throws {
        let existingConfig: [String: Any] = [
            "hooks": [
                "PreToolUse": [
                    ["matcher": "*", "hooks": [
                        ["type": "command", "command": "\"\(approvalScriptPath!)\"", "timeout": 600],
                    ]],
                ],
            ],
        ]
        try writeConfigDict(existingConfig)

        XCTAssertTrue(ClaudeHooksConfigManager.areHooksInstalled(configPath: configPath),
                     "areHooksInstalled must recognize the approval entry alone, without the " +
                     "monitor entry present")
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

    // Round 4: covers the full installHooks -> removeHooks round trip for
    // PermissionRequest specifically, alongside a co-located third-party
    // hook (e.g. claude-remote-approver) the user installed themselves —
    // installHooks must add Calyx's own entry without disturbing it, and
    // removeHooks must take only Calyx's entry back out.
    func test_installThenRemove_permissionRequest_preservesUserOwnHookAndRemovesOnlyCalyxEntry() throws {
        let existingConfig: [String: Any] = [
            "hooks": [
                "PermissionRequest": [
                    ["hooks": [
                        ["type": "command", "command": "/usr/local/bin/claude-remote-approver", "timeout": 3],
                    ]],
                ],
            ],
        ]
        try writeConfigDict(existingConfig)

        try ClaudeHooksConfigManager.installHooks(scriptPath: scriptPath, approvalScriptPath: approvalScriptPath, configPath: configPath)

        let afterInstall = try readConfigDict()
        let installedCommands = commandEntries(hookGroups(afterInstall, event: "PermissionRequest"))
        XCTAssertEqual(installedCommands.count, 2,
                       "installHooks must add Calyx's own PermissionRequest entry alongside the " +
                       "user's pre-existing one, not replace or skip it")

        try ClaudeHooksConfigManager.removeHooks(configPath: configPath)

        let afterRemove = try readConfigDict()
        let remainingCommands = commandEntries(hookGroups(afterRemove, event: "PermissionRequest"))
        XCTAssertEqual(remainingCommands.count, 1,
                       "removeHooks must remove only Calyx's own PermissionRequest entry")
        XCTAssertEqual(remainingCommands.first?["command"] as? String, "/usr/local/bin/claude-remote-approver",
                       "The user's own PermissionRequest hook (e.g. claude-remote-approver) must " +
                       "survive removeHooks")
    }

    func test_removeHooks_dropsEmptyEventKeysAndHooksKeyWhenAllEmpty() throws {
        // The 8 events installHooks writes only ever contain Calyx's own
        // entry in a fresh install, so removing them should leave neither
        // a dangling "EventName": [] nor an empty "hooks": {} behind.
        try ClaudeHooksConfigManager.installHooks(scriptPath: scriptPath, approvalScriptPath: approvalScriptPath, configPath: configPath)

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

        try ClaudeHooksConfigManager.installHooks(scriptPath: scriptPath, approvalScriptPath: approvalScriptPath, configPath: configPath)
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

    // Contract changed (Round 3): ~/.claude/settings.json is commonly a
    // dotfiles-managed symlink, and blanket symlink rejection is exactly
    // the bug that silently broke hooks installation end-to-end in that
    // setup (see the dotfiles-fixture tests below for the full
    // real-environment reproduction). Calyx now follows the link and
    // writes through to the real target file, leaving the link intact.
    func test_installHooks_symlinkConfigPath_followsToRealFileAndKeepsLinkIntact() throws {
        let realFile = tempDir + "/real_settings.json"
        writeConfig("{}")
        try FileManager.default.moveItem(atPath: configPath, toPath: realFile)
        try FileManager.default.createSymbolicLink(atPath: configPath, withDestinationPath: realFile)

        try ClaudeHooksConfigManager.installHooks(scriptPath: scriptPath, approvalScriptPath: approvalScriptPath, configPath: configPath)

        let realFileData = try Data(contentsOf: URL(fileURLWithPath: realFile))
        let realFileDict = (try JSONSerialization.jsonObject(with: realFileData) as? [String: Any]) ?? [:]
        XCTAssertFalse(hookGroups(realFileDict, event: "SessionStart").isEmpty,
                       "installHooks must write through the symlink into the real file")

        let attrsAfter = try FileManager.default.attributesOfItem(atPath: configPath)
        XCTAssertEqual(attrsAfter[.type] as? FileAttributeType, .typeSymbolicLink,
                       "The symlink at configPath must survive the write, not be replaced with a regular file")
        let destination = try FileManager.default.destinationOfSymbolicLink(atPath: configPath)
        XCTAssertEqual(destination, realFile, "The symlink must still point at the same real file")
    }

    // MARK: - Backup

    func test_installHooks_createsBackupOfExistingFile() throws {
        writeConfig("{ \"hooks\": {} }")

        try ClaudeHooksConfigManager.installHooks(scriptPath: scriptPath, approvalScriptPath: approvalScriptPath, configPath: configPath)

        let bakPath = configPath + ".bak"
        XCTAssertTrue(FileManager.default.fileExists(atPath: bakPath),
                     "A backup file must be created before modification")

        let bakContent = try String(contentsOfFile: bakPath, encoding: .utf8)
        XCTAssertFalse(bakContent.contains("calyx-agent-hook"),
                       "Backup must contain the pre-install content, not the newly added Calyx hooks")
    }

    func test_removeHooks_createsBackupOfPreRemovalContent() throws {
        try ClaudeHooksConfigManager.installHooks(scriptPath: scriptPath, approvalScriptPath: approvalScriptPath, configPath: configPath)

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

        try ClaudeHooksConfigManager.installHooks(scriptPath: scriptPath, approvalScriptPath: approvalScriptPath, configPath: configPath)

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

        try ClaudeHooksConfigManager.installHooks(scriptPath: scriptPath, approvalScriptPath: approvalScriptPath, configPath: configPath)

        XCTAssertTrue(ClaudeHooksConfigManager.areHooksInstalled(configPath: configPath),
                      "After installHooks, hooks must be reported as installed")
    }

    // MARK: - Round 3: dotfiles symlink real-environment reproduction
    //
    // This reproduces the exact layout that broke hooks in production:
    // `~/dotfiles/.claude/settings.json` holding the real, user-managed
    // content, with `~/.claude/settings.json` symlinked to it. Earlier
    // rounds' unit tests all passed against the old "reject symlinks"
    // contract precisely because they treated that contract as correct —
    // no test exercised this real directory shape. These do, with no
    // mocking of the filesystem.

    private func makeDotfilesFixture(existingConfig: [String: Any]) throws -> (dotfilesSettingsPath: String, homeSettingsPath: String) {
        let dotfilesDir = tempDir + "/dotfiles/.claude"
        let homeDir = tempDir + "/home/.claude"
        try FileManager.default.createDirectory(atPath: dotfilesDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: homeDir, withIntermediateDirectories: true)

        let dotfilesSettingsPath = dotfilesDir + "/settings.json"
        let data = try JSONSerialization.data(withJSONObject: existingConfig)
        try data.write(to: URL(fileURLWithPath: dotfilesSettingsPath))

        let homeSettingsPath = homeDir + "/settings.json"
        try FileManager.default.createSymbolicLink(atPath: homeSettingsPath, withDestinationPath: dotfilesSettingsPath)

        return (dotfilesSettingsPath, homeSettingsPath)
    }

    func test_installHooks_dotfilesSymlinkedSettingsJSON_writesRealFilePreservesUserHooksAndKeepsLinkIntact() throws {
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
        let (dotfilesSettingsPath, homeSettingsPath) = try makeDotfilesFixture(existingConfig: existingConfig)

        try ClaudeHooksConfigManager.installHooks(scriptPath: scriptPath, approvalScriptPath: approvalScriptPath, configPath: homeSettingsPath)

        // The real dotfiles-managed file received Calyx's 8 events...
        let realData = try Data(contentsOf: URL(fileURLWithPath: dotfilesSettingsPath))
        let realDict = try XCTUnwrap(try JSONSerialization.jsonObject(with: realData) as? [String: Any])
        for eventName in Self.expectedEvents {
            XCTAssertFalse(hookGroups(realDict, event: eventName).isEmpty,
                           "\(eventName) must be installed into the real dotfiles-managed file")
        }

        // ...the user's own pre-existing PreToolUse hook survived alongside it...
        let preToolUseGroups = hookGroups(realDict, event: "PreToolUse")
        XCTAssertTrue(preToolUseGroups.contains { ($0["matcher"] as? String) == "Bash" },
                      "The user's existing 'Bash' matcher group must be preserved in the real file")

        // ...unrelated top-level keys survived too...
        let permissions = realDict["permissions"] as? [String: Any]
        XCTAssertEqual(permissions?["allow"] as? [String], ["read", "write"])

        // ...and ~/.claude/settings.json is still a symlink, not replaced
        // by a plain file (a dotfiles manager tracking that path would
        // otherwise see it "go missing" from its symlink inventory).
        let attrs = try FileManager.default.attributesOfItem(atPath: homeSettingsPath)
        XCTAssertEqual(attrs[.type] as? FileAttributeType, .typeSymbolicLink,
                       "~/.claude/settings.json must remain a symlink after installHooks")
        let destination = try FileManager.default.destinationOfSymbolicLink(atPath: homeSettingsPath)
        XCTAssertEqual(destination, dotfilesSettingsPath)
    }

    func test_installThenRemove_dotfilesSymlink_restoresRealFileAndKeepsLinkIntact() throws {
        let existingConfig: [String: Any] = [
            "hooks": [
                "PreToolUse": [
                    ["matcher": "Bash", "hooks": [
                        ["type": "command", "command": "/usr/local/bin/user-hook", "timeout": 10],
                    ]],
                ],
            ],
        ]
        let (dotfilesSettingsPath, homeSettingsPath) = try makeDotfilesFixture(existingConfig: existingConfig)

        try ClaudeHooksConfigManager.installHooks(scriptPath: scriptPath, approvalScriptPath: approvalScriptPath, configPath: homeSettingsPath)
        try ClaudeHooksConfigManager.removeHooks(configPath: homeSettingsPath)

        let realData = try Data(contentsOf: URL(fileURLWithPath: dotfilesSettingsPath))
        let realDict = try XCTUnwrap(try JSONSerialization.jsonObject(with: realData) as? [String: Any])

        let preToolUseGroups = hookGroups(realDict, event: "PreToolUse")
        XCTAssertEqual(preToolUseGroups.count, 1, "Only the user's own PreToolUse group must remain in the real file")
        XCTAssertEqual(commandEntries(preToolUseGroups).first?["command"] as? String, "/usr/local/bin/user-hook")

        let attrs = try FileManager.default.attributesOfItem(atPath: homeSettingsPath)
        XCTAssertEqual(attrs[.type] as? FileAttributeType, .typeSymbolicLink,
                       "~/.claude/settings.json must remain a symlink after install+remove")
    }

    func test_installHooks_danglingDotfilesSymlink_createsRealFileAtLinkTarget() throws {
        // The classic "pre-linked, target not yet created" dotfiles state:
        // `chezmoi`/`stow`-style tooling can lay down the symlink before
        // the tracked file exists in the repo.
        let dotfilesDir = tempDir + "/dotfiles/.claude"
        let homeDir = tempDir + "/home/.claude"
        try FileManager.default.createDirectory(atPath: dotfilesDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: homeDir, withIntermediateDirectories: true)
        let dotfilesSettingsPath = dotfilesDir + "/settings.json"
        let homeSettingsPath = homeDir + "/settings.json"
        try FileManager.default.createSymbolicLink(atPath: homeSettingsPath, withDestinationPath: dotfilesSettingsPath)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dotfilesSettingsPath),
                       "Precondition: the symlink's target must not exist yet (dangling)")

        try ClaudeHooksConfigManager.installHooks(scriptPath: scriptPath, approvalScriptPath: approvalScriptPath, configPath: homeSettingsPath)

        XCTAssertTrue(FileManager.default.fileExists(atPath: dotfilesSettingsPath),
                      "installHooks must create the file at the dangling symlink's target path")
        let realData = try Data(contentsOf: URL(fileURLWithPath: dotfilesSettingsPath))
        let realDict = try XCTUnwrap(try JSONSerialization.jsonObject(with: realData) as? [String: Any])
        XCTAssertFalse(hookGroups(realDict, event: "SessionStart").isEmpty)

        let attrs = try FileManager.default.attributesOfItem(atPath: homeSettingsPath)
        XCTAssertEqual(attrs[.type] as? FileAttributeType, .typeSymbolicLink,
                       "The now-resolved symlink must remain a symlink, not become a regular file")
    }

    // Round 3 fix: resolveConfigPath now follows a multi-hop *dangling*
    // symlink chain (link -> link -> not-yet-existing file) all the way
    // to its final destination, rather than stopping at the first
    // intermediate link. Same shared ConfigFileUtils primitive as every
    // other config manager.
    func test_installHooks_multiHopDanglingSymlink_createsRealFileAtFinalDestination() throws {
        let finalTarget = tempDir + "/dotfiles/.claude/settings.json"
        try FileManager.default.createDirectory(
            atPath: (finalTarget as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        let middleLink = tempDir + "/middle-link.json"
        try FileManager.default.createSymbolicLink(atPath: middleLink, withDestinationPath: finalTarget)
        try FileManager.default.createSymbolicLink(atPath: configPath, withDestinationPath: middleLink)

        try ClaudeHooksConfigManager.installHooks(scriptPath: scriptPath, approvalScriptPath: approvalScriptPath, configPath: configPath)

        XCTAssertTrue(FileManager.default.fileExists(atPath: finalTarget),
                      "installHooks must create the file at the multi-hop dangling chain's final destination")
        let realData = try Data(contentsOf: URL(fileURLWithPath: finalTarget))
        let realDict = try XCTUnwrap(try JSONSerialization.jsonObject(with: realData) as? [String: Any])
        XCTAssertFalse(hookGroups(realDict, event: "SessionStart").isEmpty)

        let middleAttrs = try FileManager.default.attributesOfItem(atPath: middleLink)
        XCTAssertEqual(middleAttrs[.type] as? FileAttributeType, .typeSymbolicLink,
                       "The intermediate link must survive as a symlink, not be replaced with a regular file")
    }

    func test_installHooks_symlinkedParentDotClaudeDirectory_writesThroughToRealDirectory() throws {
        // A less common but real dotfiles pattern: the whole `.claude`
        // directory is symlinked (`ln -s ~/dotfiles/.claude ~/.claude`)
        // rather than the individual settings.json file.
        let dotfilesClaudeDir = tempDir + "/dotfiles/.claude"
        try FileManager.default.createDirectory(atPath: dotfilesClaudeDir, withIntermediateDirectories: true)
        let dotfilesSettingsPath = dotfilesClaudeDir + "/settings.json"
        try writeConfigDict(
            ["hooks": ["PreToolUse": [["matcher": "Bash", "hooks": [
                ["type": "command", "command": "/usr/local/bin/user-hook", "timeout": 10],
            ]]]]],
            to: dotfilesSettingsPath
        )

        let homeClaudeDir = tempDir + "/home/.claude"
        try FileManager.default.createDirectory(
            atPath: (homeClaudeDir as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(atPath: homeClaudeDir, withDestinationPath: dotfilesClaudeDir)
        let homeSettingsPath = homeClaudeDir + "/settings.json"

        try ClaudeHooksConfigManager.installHooks(scriptPath: scriptPath, approvalScriptPath: approvalScriptPath, configPath: homeSettingsPath)

        let realData = try Data(contentsOf: URL(fileURLWithPath: dotfilesSettingsPath))
        let realDict = try XCTUnwrap(try JSONSerialization.jsonObject(with: realData) as? [String: Any])
        XCTAssertFalse(hookGroups(realDict, event: "SessionStart").isEmpty,
                       "installHooks must write into the real directory reached through the symlinked parent")
        XCTAssertTrue(hookGroups(realDict, event: "PreToolUse").contains { ($0["matcher"] as? String) == "Bash" },
                      "The user's existing hook in the real directory must be preserved")

        let parentAttrs = try FileManager.default.attributesOfItem(atPath: homeClaudeDir)
        XCTAssertEqual(parentAttrs[.type] as? FileAttributeType, .typeSymbolicLink,
                       "The symlinked .claude directory itself must remain a symlink")
    }
}
