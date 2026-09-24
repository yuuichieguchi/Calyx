//
//  ConfigEditingContractTests.swift
//  CalyxTests
//
//  Pins the L1 editing contract from `.claude/plans/ipc-toggle.md`: after
//  any enable and any disable, a config file is byte-identical to what it
//  was everywhere outside the exact region Calyx owns. Key order,
//  indentation, whitespace, trailing newline, and line endings all
//  survive.
//
//  The contract is applied through ONE driver to every manager in all
//  three F15 groups (verified by reading each manager, not by trusting
//  the design doc's table):
//    A.   JSON key-path:    ClaudeConfigManager (mcpServers.calyx-ipc),
//                            OpenCodeConfigManager's opencode.json half
//                            (mcp.calyx-ipc)
//    A-2. JSON array element: ClaudeHooksConfigManager (hooks.<Event>[],
//                            entries identified by command path)
//    B.   Marker block:     HermesConfigManager, CodexHooksConfigManager,
//                            OpenCodeConfigManager's AGENTS.md half
//    B-2. TOML table:       CodexConfigManager, GrokConfigManager (their
//                            owned region is [mcp_servers.calyx-ipc], not
//                            a comment-delimited marker span)
//    C.   Calyx-owned file: GrokHooksConfigManager, OpenCodePluginManager,
//                            PiExtensionManager
//
//  A single test method drives every group through the same fixture
//  matrix so no group can quietly keep a per-agent exception.
//

import XCTest
@testable import Calyx

final class ConfigEditingContractTests: XCTestCase {

    // MARK: - Properties

    private var tempDir: String!

    // MARK: - Lifecycle

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).path
        try! FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: tempDir)
        tempDir = nil
        super.tearDown()
    }

    // MARK: - Fixtures
    //
    // Each fixture isolates one destruction (full JSON reformat, CRLF ->
    // LF normalization, trailing-blank-line eating) plus the other
    // byte-survival properties the contract states explicitly. Every
    // fixture must be VALID in its own format -- an input that
    // legitimately throws (e.g. tab INDENTATION under Hermes's existing
    // top-level `mcp_servers:`) is not a destruction, so tab bytes sit
    // inside a quoted scalar/string instead, and YAML fixtures avoid a
    // pre-existing `mcp_servers:` key so that guard never triggers.

    private struct Fixture {
        let label: String
        let content: String
    }

    /// Group A / A-2 (JSON). Each fixture is a top-level JSON object with
    /// an unrelated sibling key ("other") so insertion/removal of
    /// Calyx's own key(s) can be verified not to disturb it. None of
    /// these contain "mcpServers"/"mcp"/"hooks", so the "owned parent
    /// absent" case from L1.3.1 is covered by every one of them.
    private let jsonFixtures: [Fixture] = [
        Fixture(
            label: "non-alphabetical key order",
            content: "{\n  \"zebra\": 1,\n  \"apple\": 2,\n  \"other\": {\n    \"nested\": true\n  }\n}\n"
        ),
        Fixture(
            label: "tab indentation",
            content: "{\n\t\"zebra\": 1,\n\t\"apple\": 2\n}\n"
        ),
        Fixture(
            label: "CRLF line endings",
            content: "{\r\n  \"zebra\": 1,\r\n  \"apple\": 2\r\n}\r\n"
        ),
        Fixture(
            label: "no trailing newline",
            content: "{\"zebra\":1,\"apple\":2}"
        ),
        Fixture(
            label: "mixed line endings",
            content: "{\r\n  \"zebra\": 1,\n  \"apple\": 2\r\n}\n"
        ),
    ]

    /// Group B-2 / TOML table (Codex, Grok). Calyx's own table is
    /// appended at EOF, so the fixture's existing content is exactly the
    /// "outside the owned region" the contract must preserve. The last
    /// fixture pins F16: `removeSections`'s `while hasSuffix("\n\n")
    /// dropLast` trims a user's own trailing blank lines down to one
    /// newline, which is not Calyx's region to touch.
    private let tomlTableFixtures: [Fixture] = [
        Fixture(
            label: "non-alphabetical key order",
            content: "[other]\nzeta = 1\nalpha = 2\n"
        ),
        Fixture(
            label: "tab byte inside a quoted string value",
            content: "[other]\nlabel = \"a\tb\"\n"
        ),
        Fixture(
            label: "CRLF line endings",
            content: "[other]\r\nzeta = 1\r\nalpha = 2\r\n"
        ),
        Fixture(
            label: "no trailing newline",
            content: "alpha = 1"
        ),
        Fixture(
            label: "mixed line endings",
            content: "[other]\r\nzeta = 1\nalpha = 2\r\n"
        ),
        Fixture(
            label: "trailing blank lines (F16)",
            content: "[other]\nzeta = 1\nalpha = 2\n\n\n"
        ),
    ]

    /// Group B / marker block, TOML-syntax half (CodexHooksConfigManager
    /// shares `~/.codex/config.toml` with CodexConfigManager, but owns a
    /// BEGIN/END span there, not a table).
    private let codexHooksMarkerFixtures: [Fixture] = [
        Fixture(
            label: "non-alphabetical key order",
            content: "[other]\nzeta = 1\nalpha = 2\n"
        ),
        Fixture(
            label: "tab byte inside a quoted string value",
            content: "[other]\nlabel = \"a\tb\"\n"
        ),
        Fixture(
            label: "CRLF line endings",
            content: "[other]\r\nzeta = 1\r\nalpha = 2\r\n"
        ),
        Fixture(
            label: "no trailing newline",
            content: "alpha = 1"
        ),
        Fixture(
            label: "mixed line endings",
            content: "[other]\r\nzeta = 1\nalpha = 2\r\n"
        ),
    ]

    /// Group B / YAML (Hermes). No top-level `mcp_servers:` key, so every
    /// fixture takes Hermes's Case A (append) path and never exercises
    /// `learnIndentUnit`'s legitimate tab-indentation rejection.
    private let yamlFixtures: [Fixture] = [
        Fixture(
            label: "non-alphabetical key order",
            content: "other:\n  zeta: 1\n  alpha: 2\n"
        ),
        Fixture(
            label: "tab byte inside a quoted scalar",
            content: "other:\n  note: \"a\tb\"\n"
        ),
        Fixture(
            label: "CRLF line endings",
            content: "other:\r\n  zeta: 1\r\n  alpha: 2\r\n"
        ),
        Fixture(
            label: "no trailing newline",
            content: "other: 1"
        ),
        Fixture(
            label: "mixed line endings",
            content: "other:\r\n  zeta: 1\n  alpha: 2\r\n"
        ),
    ]

    /// Group B / Markdown (OpenCode's AGENTS.md). Plain text: no format
    /// syntax to stay valid against.
    private let markdownFixtures: [Fixture] = [
        Fixture(
            label: "arbitrary prose content",
            content: "# Notes\n\nSome instructions.\n\nMore text below.\n"
        ),
        Fixture(
            label: "tab-indented list",
            content: "# Notes\n\n\t- item one\n\t- item two\n"
        ),
        Fixture(
            label: "CRLF line endings",
            content: "# Notes\r\n\r\nSome instructions.\r\n"
        ),
        Fixture(
            label: "no trailing newline",
            content: "# Notes\n\nSome instructions."
        ),
        Fixture(
            label: "mixed line endings",
            content: "# Notes\r\n\nSome instructions.\r\n"
        ),
    ]

    /// Baseline content for OpenCode's SECONDARY file in a check that
    /// isn't varying it: non-empty and never solely-Calyx-owned, so it
    /// survives the cycle regardless (its own bytes are verified by the
    /// checks that DO vary it).
    private let openCodeBaselineJSON = "{\n  \"theme\": \"dark\"\n}\n"
    private let openCodeBaselineAgentsMD = "# User AGENTS.md\n\nExisting instructions.\n"

    // MARK: - Contract check descriptor

    private struct ContractCheck {
        let managerName: String
        let fixtureLabel: String
        let relativePath: String
        /// `nil` means the file must NOT exist after the cycle (L1.3.2's
        /// "whole file becomes Calyx's region -> transform returns nil").
        let expectedFinalContent: String?
        /// The exact set of file names expected in `relativePath`'s
        /// parent directory after the cycle (its own name included only
        /// when `expectedFinalContent != nil`).
        let expectedSiblingRelativePaths: [String]
        let prepareRoot: (String) throws -> Void
        let enable: (String) throws -> Void
        let disable: (String) throws -> Void
        /// When non-nil, `runContractCheck` also asserts the checked
        /// file's mode still equals this value after the enable ->
        /// disable cycle: the mode half of the byte-identity contract
        /// for a secret-free, user-owned file -- Calyx must leave a mode
        /// it never asked to own exactly as it leaves bytes outside its
        /// own region.
        let expectedMode: mode_t?
    }

    /// A round-trip check where the fixture's own bytes ARE the expected
    /// final content (the common case: content outside Calyx's region).
    ///
    /// `fixtureMode`, when non-nil, is `chmod`ed onto the fixture file
    /// right after it's written, and `runContractCheck` then asserts the
    /// file still carries that exact mode after the enable -> disable
    /// cycle -- the mode half of the byte-identity contract, for a
    /// manager whose write carries no secret and therefore must never
    /// touch a mode it didn't set.
    private func roundTripCheck(
        managerName: String,
        fixture: Fixture,
        relativePath: String,
        additionalPrepare: @escaping (String) throws -> Void = { _ in },
        additionalSiblings: [String] = [],
        fixtureMode: mode_t? = nil,
        enable: @escaping (String) throws -> Void,
        disable: @escaping (String) throws -> Void
    ) -> ContractCheck {
        ContractCheck(
            managerName: managerName,
            fixtureLabel: fixture.label,
            relativePath: relativePath,
            expectedFinalContent: fixture.content,
            expectedSiblingRelativePaths: [relativePath] + additionalSiblings,
            prepareRoot: { root in
                let path = root + "/" + relativePath
                try Data(fixture.content.utf8).write(to: URL(fileURLWithPath: path))
                if let fixtureMode {
                    XCTAssertEqual(chmod(path, fixtureMode), 0, "test setup: chmod must succeed")
                }
                try additionalPrepare(root)
            },
            enable: enable,
            disable: disable,
            expectedMode: fixtureMode
        )
    }

    /// A round-trip check with an explicit, hand-computed expected final
    /// content different from the initial content -- used for L1.3.1's
    /// owned-parent-container cases (an empty parent that becomes solely
    /// Calyx's own is removed by the enable -> disable cascade; that is
    /// the region's definition, not a violation).
    private func customCheck(
        managerName: String,
        fixtureLabel: String,
        relativePath: String,
        initialContent: String,
        expectedFinalContent: String,
        additionalSiblings: [String] = [],
        enable: @escaping (String) throws -> Void,
        disable: @escaping (String) throws -> Void
    ) -> ContractCheck {
        ContractCheck(
            managerName: managerName,
            fixtureLabel: fixtureLabel,
            relativePath: relativePath,
            expectedFinalContent: expectedFinalContent,
            expectedSiblingRelativePaths: [relativePath] + additionalSiblings,
            prepareRoot: { root in
                try Data(initialContent.utf8).write(to: URL(fileURLWithPath: root + "/" + relativePath))
            },
            enable: enable,
            disable: disable,
            expectedMode: nil
        )
    }

    /// A check for the marker-block editors' "whole file becomes Calyx's
    /// region" case: no fixture is written up front, and the file must
    /// still be PRESENT, empty, after the cycle. Calyx never deletes a
    /// user-owned file: `MarkerConfigDocumentEditor.removeBlock` returns
    /// empty `Data()`, never `nil`, once nothing but Calyx's own block
    /// remains -- the accepted consequence being that a never-before-seen
    /// file Calyx itself creates on enable, then fully empties on disable,
    /// is left behind as a 0-byte file rather than removed. `nil` in still
    /// means `nil` out (an absent file is never conjured into existence by
    /// a disable that finds nothing to remove); this check starts the file
    /// absent specifically to pin the "went through a real Calyx-owned
    /// span" path, not that no-op path.
    private func absentBecomesPresentButEmptyCheck(
        managerName: String,
        relativePath: String,
        expectedSiblings: [String] = [],
        prepareRoot: @escaping (String) throws -> Void = { _ in },
        enable: @escaping (String) throws -> Void,
        disable: @escaping (String) throws -> Void
    ) -> ContractCheck {
        ContractCheck(
            managerName: managerName,
            fixtureLabel: "absent file becomes fully Calyx-owned, then left behind empty (never deleted)",
            relativePath: relativePath,
            expectedFinalContent: "",
            expectedSiblingRelativePaths: [relativePath] + expectedSiblings,
            prepareRoot: prepareRoot,
            enable: enable,
            disable: disable,
            expectedMode: nil
        )
    }

    // MARK: - Group A / A-2 checks (byte-preservation matrix)

    private func claudeConfigCheck(_ fixture: Fixture) -> ContractCheck {
        roundTripCheck(
            managerName: "ClaudeConfigManager",
            fixture: fixture,
            relativePath: "claude.json",
            enable: { root in
                try ClaudeConfigManager.enableIPC(port: 41830, token: "contract-token", configPath: root + "/claude.json")
            },
            disable: { root in
                try ClaudeConfigManager.disableIPC(configPath: root + "/claude.json")
            }
        )
    }

    private func claudeHooksConfigCheck(_ fixture: Fixture) -> ContractCheck {
        roundTripCheck(
            managerName: "ClaudeHooksConfigManager",
            fixture: fixture,
            relativePath: "settings.json",
            // 0644: settings.json is user-owned and this write carries no
            // secret, so its mode must survive the cycle untouched.
            fixtureMode: 0o644,
            enable: { root in
                try ClaudeHooksConfigManager.installHooks(
                    scriptPath: "/opt/calyx/bin/calyx-agent-hook",
                    approvalScriptPath: "/opt/calyx/bin/calyx-approval-hook",
                    configPath: root + "/settings.json"
                )
            },
            disable: { root in
                try ClaudeHooksConfigManager.removeHooks(configPath: root + "/settings.json")
            }
        )
    }

    private func openCodeJSONCheck(_ fixture: Fixture) -> ContractCheck {
        roundTripCheck(
            managerName: "OpenCodeConfigManager (opencode.json)",
            fixture: fixture,
            relativePath: "opencode.json",
            additionalPrepare: { root in
                try Data(self.openCodeBaselineAgentsMD.utf8).write(to: URL(fileURLWithPath: root + "/AGENTS.md"))
            },
            additionalSiblings: ["AGENTS.md"],
            enable: { root in
                try OpenCodeConfigManager.enableIPC(port: 41830, token: "contract-token", configDir: root)
            },
            disable: { root in
                try OpenCodeConfigManager.disableIPC(configDir: root)
            }
        )
    }

    // MARK: - Group B-2 / TOML table checks

    /// Like `roundTripCheck`, but for the managers that insert Calyx's
    /// region by appending at end of file (Group B-2's TOML table editor
    /// and Group B's marker editor): when the file's final line arrives
    /// unterminated, inserting there requires terminating that line first,
    /// and the terminator remains after disable -- "the file ended without
    /// a newline" and "the file ended with a newline" become the same byte
    /// state once Calyx's own region is stripped back out. Exactly one EOL
    /// at the boundary changes; nothing else does. This does not apply to
    /// the JSON editor (Group A/A-2), which inserts inside the document
    /// and keeps exact byte identity even for an unterminated last line.
    private func appendAtEOFRoundTripCheck(
        managerName: String,
        fixture: Fixture,
        relativePath: String,
        additionalPrepare: @escaping (String) throws -> Void = { _ in },
        additionalSiblings: [String] = [],
        fixtureMode: mode_t? = nil,
        enable: @escaping (String) throws -> Void,
        disable: @escaping (String) throws -> Void
    ) -> ContractCheck {
        guard fixture.label == "no trailing newline" else {
            return roundTripCheck(
                managerName: managerName,
                fixture: fixture,
                relativePath: relativePath,
                additionalPrepare: additionalPrepare,
                additionalSiblings: additionalSiblings,
                fixtureMode: fixtureMode,
                enable: enable,
                disable: disable
            )
        }
        return ContractCheck(
            managerName: managerName,
            fixtureLabel: fixture.label,
            relativePath: relativePath,
            expectedFinalContent: fixture.content + "\n",
            expectedSiblingRelativePaths: [relativePath] + additionalSiblings,
            prepareRoot: { root in
                let path = root + "/" + relativePath
                try Data(fixture.content.utf8).write(to: URL(fileURLWithPath: path))
                if let fixtureMode {
                    XCTAssertEqual(chmod(path, fixtureMode), 0, "test setup: chmod must succeed")
                }
                try additionalPrepare(root)
            },
            enable: enable,
            disable: disable,
            expectedMode: fixtureMode
        )
    }

    private func codexConfigCheck(_ fixture: Fixture) -> ContractCheck {
        appendAtEOFRoundTripCheck(
            managerName: "CodexConfigManager",
            fixture: fixture,
            relativePath: "config.toml",
            enable: { root in
                try CodexConfigManager.enableIPC(port: 41830, token: "contract-token", configPath: root + "/config.toml")
            },
            disable: { root in
                try CodexConfigManager.disableIPC(configPath: root + "/config.toml")
            }
        )
    }

    private func grokConfigCheck(_ fixture: Fixture) -> ContractCheck {
        appendAtEOFRoundTripCheck(
            managerName: "GrokConfigManager",
            fixture: fixture,
            relativePath: "config.toml",
            enable: { root in
                try GrokConfigManager.enableIPC(port: 41830, token: "contract-token", configPath: root + "/config.toml")
            },
            disable: { root in
                try GrokConfigManager.disableIPC(configPath: root + "/config.toml")
            }
        )
    }

    // MARK: - Group B / marker checks

    private func codexHooksConfigCheck(_ fixture: Fixture) -> ContractCheck {
        appendAtEOFRoundTripCheck(
            managerName: "CodexHooksConfigManager",
            fixture: fixture,
            relativePath: "config.toml",
            // 0644: this hooks block carries no secret, so config.toml's
            // mode must survive the cycle untouched.
            fixtureMode: 0o644,
            enable: { root in
                try CodexHooksConfigManager.installHooks(
                    scriptPath: "/opt/calyx/bin/calyx-agent-hook",
                    approvalScriptPath: "/opt/calyx/bin/calyx-approval-hook",
                    configPath: root + "/config.toml"
                )
            },
            disable: { root in
                try CodexHooksConfigManager.removeHooks(configPath: root + "/config.toml")
            }
        )
    }

    private func hermesConfigCheck(_ fixture: Fixture) -> ContractCheck {
        appendAtEOFRoundTripCheck(
            managerName: "HermesConfigManager",
            fixture: fixture,
            relativePath: "config.yaml",
            enable: { root in
                try HermesConfigManager.enableIPC(port: 41830, token: "contract-token", configPath: root + "/config.yaml")
            },
            disable: { root in
                try HermesConfigManager.disableIPC(configPath: root + "/config.yaml")
            }
        )
    }

    private func openCodeAgentsMDCheck(_ fixture: Fixture) -> ContractCheck {
        appendAtEOFRoundTripCheck(
            managerName: "OpenCodeConfigManager (AGENTS.md)",
            fixture: fixture,
            relativePath: "AGENTS.md",
            additionalPrepare: { root in
                try Data(self.openCodeBaselineJSON.utf8).write(to: URL(fileURLWithPath: root + "/opencode.json"))
            },
            additionalSiblings: ["opencode.json"],
            // 0644: AGENTS.md is a user-owned prompt file with no secret
            // in it, so its mode must survive the cycle untouched.
            fixtureMode: 0o644,
            enable: { root in
                try OpenCodeConfigManager.enableIPC(port: 41830, token: "contract-token", configDir: root)
            },
            disable: { root in
                try OpenCodeConfigManager.disableIPC(configDir: root)
            }
        )
    }

    // MARK: - L1.3.1 JSON owned-region boundary checks

    private func jsonBoundaryChecks() -> [ContractCheck] {
        [
            // Claude: parent present as {} -- becomes solely Calyx-owned
            // once calyx-ipc is inserted, so the cascade removes it.
            customCheck(
                managerName: "ClaudeConfigManager",
                fixtureLabel: "owned parent present as empty object",
                relativePath: "claude.json",
                initialContent: "{\n  \"other\": 1,\n  \"mcpServers\": {}\n}\n",
                expectedFinalContent: "{\n  \"other\": 1\n}\n",
                enable: { root in
                    try ClaudeConfigManager.enableIPC(port: 41830, token: "t", configPath: root + "/claude.json")
                },
                disable: { root in
                    try ClaudeConfigManager.disableIPC(configPath: root + "/claude.json")
                }
            ),
            // Claude: parent has an unrelated sibling entry -- parent
            // itself is not solely Calyx's, so it survives untouched.
            customCheck(
                managerName: "ClaudeConfigManager",
                fixtureLabel: "owned parent has an unrelated sibling entry",
                relativePath: "claude.json",
                initialContent: "{\n  \"other\": 1,\n  \"mcpServers\": {\n    \"other-server\": {\n      \"type\": \"http\"\n    }\n  }\n}\n",
                expectedFinalContent: "{\n  \"other\": 1,\n  \"mcpServers\": {\n    \"other-server\": {\n      \"type\": \"http\"\n    }\n  }\n}\n",
                enable: { root in
                    try ClaudeConfigManager.enableIPC(port: 41830, token: "t", configPath: root + "/claude.json")
                },
                disable: { root in
                    try ClaudeConfigManager.disableIPC(configPath: root + "/claude.json")
                }
            ),
            claudeKeyPositionCheck(
                label: "pre-existing calyx-ipc key FIRST among siblings",
                initialContent:
                    "{\n  \"mcpServers\": {\n    \"calyx-ipc\": {\n      \"type\": \"http\",\n      \"url\": \"http://stale/mcp\"\n    },\n" +
                    "    \"a-server\": {\n      \"type\": \"http\"\n    },\n    \"z-server\": {\n      \"type\": \"http\"\n    }\n  }\n}\n"
            ),
            claudeKeyPositionCheck(
                label: "pre-existing calyx-ipc key MIDDLE among siblings",
                initialContent:
                    "{\n  \"mcpServers\": {\n    \"a-server\": {\n      \"type\": \"http\"\n    },\n" +
                    "    \"calyx-ipc\": {\n      \"type\": \"http\",\n      \"url\": \"http://stale/mcp\"\n    },\n" +
                    "    \"z-server\": {\n      \"type\": \"http\"\n    }\n  }\n}\n"
            ),
            claudeKeyPositionCheck(
                label: "pre-existing calyx-ipc key LAST among siblings",
                initialContent:
                    "{\n  \"mcpServers\": {\n    \"a-server\": {\n      \"type\": \"http\"\n    },\n" +
                    "    \"z-server\": {\n      \"type\": \"http\"\n    },\n" +
                    "    \"calyx-ipc\": {\n      \"type\": \"http\",\n      \"url\": \"http://stale/mcp\"\n    }\n  }\n}\n"
            ),

            // ClaudeHooks: parent present as {} -- ten event keys are
            // inserted then fully removed, cascading the empty "hooks"
            // key away too.
            customCheck(
                managerName: "ClaudeHooksConfigManager",
                fixtureLabel: "owned parent present as empty object",
                relativePath: "settings.json",
                initialContent: "{\n  \"other\": 1,\n  \"hooks\": {}\n}\n",
                expectedFinalContent: "{\n  \"other\": 1\n}\n",
                enable: { root in
                    try ClaudeHooksConfigManager.installHooks(
                        scriptPath: "/opt/calyx/bin/calyx-agent-hook",
                        approvalScriptPath: "/opt/calyx/bin/calyx-approval-hook",
                        configPath: root + "/settings.json"
                    )
                },
                disable: { root in
                    try ClaudeHooksConfigManager.removeHooks(configPath: root + "/settings.json")
                }
            ),
            // ClaudeHooks: an unrelated event ("PreCompact", not one of
            // Calyx's 10 targets) must survive untouched, and "hooks"
            // must not be cascade-removed since it is not solely Calyx's.
            customCheck(
                managerName: "ClaudeHooksConfigManager",
                fixtureLabel: "owned parent has an unrelated sibling event",
                relativePath: "settings.json",
                initialContent:
                    "{\n  \"hooks\": {\n    \"PreCompact\": [\n      {\n        \"hooks\": [\n          {\n" +
                    "            \"type\": \"command\",\n            \"command\": \"my-own-hook\"\n          }\n        ]\n      }\n    ]\n  }\n}\n",
                expectedFinalContent:
                    "{\n  \"hooks\": {\n    \"PreCompact\": [\n      {\n        \"hooks\": [\n          {\n" +
                    "            \"type\": \"command\",\n            \"command\": \"my-own-hook\"\n          }\n        ]\n      }\n    ]\n  }\n}\n",
                enable: { root in
                    try ClaudeHooksConfigManager.installHooks(
                        scriptPath: "/opt/calyx/bin/calyx-agent-hook",
                        approvalScriptPath: "/opt/calyx/bin/calyx-approval-hook",
                        configPath: root + "/settings.json"
                    )
                },
                disable: { root in
                    try ClaudeHooksConfigManager.removeHooks(configPath: root + "/settings.json")
                }
            ),
            // ClaudeHooks: a PreToolUse matcher group
            // pre-existing in the file already mixes a stale Calyx
            // command entry with the user's own hook entry -- not one of
            // Calyx's own writes (Calyx never mixes the two into one
            // group), but the state a hand-edited or pre-L1 config can
            // hold. The user's entry is written in non-alphabetical key
            // order ("type" before "command"/"timeout", not what
            // JSONSerialization's .sortedKeys would produce) and is NOT
            // the last group in the array (a second, unrelated "Bash"
            // group follows it). Both `installHooks` (enable) and
            // `removeHooks` (disable) route the stale Calyx entry's
            // removal through `removingOwnEntriesFromEventGroups`, so
            // the user's entry -- key order and array position both --
            // must survive the full enable -> disable cycle unchanged;
            // only the stale Calyx entry (and, transiently, the fresh
            // group `installHooks` appends and `removeHooks` then
            // removes again) may ever be touched.
            customCheck(
                managerName: "ClaudeHooksConfigManager",
                fixtureLabel: "matcher group mixes a Calyx entry with a user entry, non-alphabetical order, not last",
                relativePath: "settings.json",
                initialContent:
                    "{\n  \"hooks\": {\n    \"PreToolUse\": [\n      {\n        \"matcher\": \"*\",\n        \"hooks\": [\n" +
                    "          {\n            \"type\": \"command\",\n            \"command\": \"\\\"/opt/calyx/bin/calyx-agent-hook\\\"\",\n" +
                    "            \"timeout\": 5,\n            \"async\": true\n          },\n          {\n" +
                    "            \"type\": \"command\",\n            \"command\": \"/usr/local/bin/user-hook\",\n" +
                    "            \"timeout\": 10\n          }\n        ]\n      },\n      {\n        \"matcher\": \"Bash\",\n" +
                    "        \"hooks\": [\n          {\n            \"type\": \"command\",\n" +
                    "            \"command\": \"/usr/local/bin/other-user-hook\",\n            \"timeout\": 3\n          }\n" +
                    "        ]\n      }\n    ]\n  }\n}\n",
                expectedFinalContent:
                    "{\n  \"hooks\": {\n    \"PreToolUse\": [\n      {\n        \"matcher\": \"*\",\n        \"hooks\": [\n" +
                    "          {\n            \"type\": \"command\",\n            \"command\": \"/usr/local/bin/user-hook\",\n" +
                    "            \"timeout\": 10\n          }\n        ]\n      },\n      {\n        \"matcher\": \"Bash\",\n" +
                    "        \"hooks\": [\n          {\n            \"type\": \"command\",\n" +
                    "            \"command\": \"/usr/local/bin/other-user-hook\",\n            \"timeout\": 3\n          }\n" +
                    "        ]\n      }\n    ]\n  }\n}\n",
                enable: { root in
                    try ClaudeHooksConfigManager.installHooks(
                        scriptPath: "/opt/calyx/bin/calyx-agent-hook",
                        approvalScriptPath: "/opt/calyx/bin/calyx-approval-hook",
                        configPath: root + "/settings.json"
                    )
                },
                disable: { root in
                    try ClaudeHooksConfigManager.removeHooks(configPath: root + "/settings.json")
                }
            ),

            // OpenCode json: same two parent-container cases, "mcp" key.
            customCheck(
                managerName: "OpenCodeConfigManager (opencode.json)",
                fixtureLabel: "owned parent present as empty object",
                relativePath: "opencode.json",
                initialContent: "{\n  \"other\": 1,\n  \"mcp\": {}\n}\n",
                expectedFinalContent: "{\n  \"other\": 1\n}\n",
                additionalSiblings: ["AGENTS.md"],
                enable: { root in
                    try OpenCodeConfigManager.enableIPC(port: 41830, token: "t", configDir: root)
                },
                disable: { root in
                    try OpenCodeConfigManager.disableIPC(configDir: root)
                }
            ),
            customCheck(
                managerName: "OpenCodeConfigManager (opencode.json)",
                fixtureLabel: "owned parent has an unrelated sibling entry",
                relativePath: "opencode.json",
                initialContent: "{\n  \"other\": 1,\n  \"mcp\": {\n    \"other-server\": {\n      \"type\": \"remote\"\n    }\n  }\n}\n",
                expectedFinalContent: "{\n  \"other\": 1,\n  \"mcp\": {\n    \"other-server\": {\n      \"type\": \"remote\"\n    }\n  }\n}\n",
                additionalSiblings: ["AGENTS.md"],
                enable: { root in
                    try OpenCodeConfigManager.enableIPC(port: 41830, token: "t", configDir: root)
                },
                disable: { root in
                    try OpenCodeConfigManager.disableIPC(configDir: root)
                }
            ),
        ]
    }

    /// The `a-server`/`z-server` siblings always survive; `calyx-ipc`
    /// always vanishes with its comma correctly repaired, regardless of
    /// which of the three textual positions it started in (this is what
    /// the old `.sortedKeys` writer produced across real user files).
    private func claudeKeyPositionCheck(label: String, initialContent: String) -> ContractCheck {
        let expected =
            "{\n  \"mcpServers\": {\n    \"a-server\": {\n      \"type\": \"http\"\n    },\n" +
            "    \"z-server\": {\n      \"type\": \"http\"\n    }\n  }\n}\n"
        return customCheck(
            managerName: "ClaudeConfigManager",
            fixtureLabel: label,
            relativePath: "claude.json",
            initialContent: initialContent,
            expectedFinalContent: expected,
            enable: { root in
                try ClaudeConfigManager.enableIPC(port: 41830, token: "fresh-token", configPath: root + "/claude.json")
            },
            disable: { root in
                try ClaudeConfigManager.disableIPC(configPath: root + "/claude.json")
            }
        )
    }

    // MARK: - L1.3.2 marker owned-region boundary: "absent -> nil" checks

    private func markerAbsentBecomesPresentButEmptyChecks() -> [ContractCheck] {
        [
            absentBecomesPresentButEmptyCheck(
                managerName: "HermesConfigManager",
                relativePath: "config.yaml",
                enable: { root in
                    try HermesConfigManager.enableIPC(port: 41830, token: "t", configPath: root + "/config.yaml")
                },
                disable: { root in
                    try HermesConfigManager.disableIPC(configPath: root + "/config.yaml")
                }
            ),
            absentBecomesPresentButEmptyCheck(
                managerName: "CodexHooksConfigManager",
                relativePath: "config.toml",
                enable: { root in
                    try CodexHooksConfigManager.installHooks(
                        scriptPath: "/opt/calyx/bin/calyx-agent-hook",
                        approvalScriptPath: "/opt/calyx/bin/calyx-approval-hook",
                        configPath: root + "/config.toml"
                    )
                },
                disable: { root in
                    try CodexHooksConfigManager.removeHooks(configPath: root + "/config.toml")
                }
            ),
            absentBecomesPresentButEmptyCheck(
                managerName: "OpenCodeConfigManager (AGENTS.md)",
                relativePath: "AGENTS.md",
                expectedSiblings: ["opencode.json"],
                enable: { root in
                    try OpenCodeConfigManager.enableIPC(port: 41830, token: "t", configDir: root)
                },
                disable: { root in
                    try OpenCodeConfigManager.disableIPC(configDir: root)
                }
            ),
        ]
    }

    // MARK: - Driver

    private func runContractCheck(_ check: ContractCheck, file: StaticString = #filePath, line: UInt = #line) throws {
        let root = tempDir + "/" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)

        try check.prepareRoot(root)
        try check.enable(root)
        try check.disable(root)

        let checkedPath = root + "/" + check.relativePath

        if let expected = check.expectedFinalContent {
            guard FileManager.default.fileExists(atPath: checkedPath) else {
                XCTFail(
                    "\(check.managerName) [\(check.fixtureLabel)]: Calyx never deletes a user-owned file -- " +
                    "a file that became entirely Calyx's own region must be left behind (empty), not removed",
                    file: file, line: line
                )
                return
            }
            let finalData = try Data(contentsOf: URL(fileURLWithPath: checkedPath))
            let finalContent = String(decoding: finalData, as: UTF8.self)
            XCTAssertEqual(
                finalContent, expected,
                "\(check.managerName) [\(check.fixtureLabel)]: content outside Calyx's owned region must " +
                "survive enable -> disable byte-for-byte",
                file: file, line: line
            )
        } else {
            XCTFail(
                "\(check.managerName) [\(check.fixtureLabel)]: every ContractCheck now expects concrete " +
                "final content -- Calyx never deletes a user-owned file, so no check should reach this " +
                "nil-content branch",
                file: file, line: line
            )
        }

        let siblings = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
        XCTAssertEqual(
            Set(siblings), Set(check.expectedSiblingRelativePaths),
            "\(check.managerName) [\(check.fixtureLabel)]: enable -> disable must not leave any extra file " +
            "(e.g. a .bak backup) behind in \(root), found \(siblings)",
            file: file, line: line
        )

        if let expectedMode = check.expectedMode {
            var statBuf = stat()
            XCTAssertEqual(
                stat(checkedPath, &statBuf), 0,
                "\(check.managerName) [\(check.fixtureLabel)]: file must still exist to check its mode",
                file: file, line: line
            )
            XCTAssertEqual(
                statBuf.st_mode & ~S_IFMT, expectedMode,
                "\(check.managerName) [\(check.fixtureLabel)]: a secret-free, user-owned file's mode must " +
                "survive enable -> disable exactly as its bytes outside Calyx's owned region do",
                file: file, line: line
            )
        }
    }

    // MARK: - The contract test

    func test_enableThenDisable_preservesBytesOutsideOwnedRegion_acrossAllManagerGroups() throws {
        var checks: [ContractCheck] = []

        for fixture in jsonFixtures {
            checks.append(claudeConfigCheck(fixture))
            checks.append(claudeHooksConfigCheck(fixture))
            checks.append(openCodeJSONCheck(fixture))
        }

        for fixture in tomlTableFixtures {
            checks.append(codexConfigCheck(fixture))
            checks.append(grokConfigCheck(fixture))
        }

        for fixture in codexHooksMarkerFixtures {
            checks.append(codexHooksConfigCheck(fixture))
        }

        for fixture in yamlFixtures {
            checks.append(hermesConfigCheck(fixture))
        }

        for fixture in markdownFixtures {
            checks.append(openCodeAgentsMDCheck(fixture))
        }

        checks.append(contentsOf: jsonBoundaryChecks())
        checks.append(contentsOf: markerAbsentBecomesPresentButEmptyChecks())

        for check in checks {
            try runContractCheck(check)
        }
    }

    // MARK: - L1.3.2: an OLD-format block (trailing newline after END) must not leave a stray blank line
    //
    // Verified by hand-simulating each manager's CURRENT removal logic
    // before writing this: `CodexHooksConfigManager.removingManagedBlock`
    // and `OpenCodeConfigManager.stripManagedBlocks` both already consume
    // exactly one separator on either side of a BEGIN/END span for a
    // single-blank-line LF-only fixture, so an old-format fixture through
    // THOSE two would not be red today. `HermesConfigManager
    // .removalRangePreservingLineBoundary` only ever extends FORWARD
    // (never backward), so it leaves the leading blank-line separator
    // behind -- this is the one genuine instance of this destruction.

    /// Hermes: a config that already holds Calyx's old-format block
    /// (trailing newline after END, as `appendCaseA` writes it today)
    /// must, after a plain `disableIPC`, restore exactly the original
    /// user content -- no stray blank line where the block used to be.
    func test_hermesConfigManager_oldFormatBlockWithTrailingNewline_disableLeavesNoStrayBlankLine() throws {
        let userContent = "greeting: hello\n"
        let beginLine = "# BEGIN CALYX IPC (managed by Calyx, do not edit)"
        let endLine = "# END CALYX IPC"
        let oldFormatBlock =
            beginLine + "\n" +
            "mcp_servers:\n" +
            "  calyx-ipc:\n" +
            "    url: \"http://127.0.0.1:41830/mcp\"\n" +
            "    headers:\n" +
            "      Authorization: \"Bearer old-token\"\n" +
            "      X-Calyx-Surface-ID: \"${CALYX_SURFACE_ID}\"\n" +
            "      X-Calyx-Session-ID: \"${CALYX_SESSION_ID}\"\n" +
            "      X-Calyx-Agent-Kind: \"hermes\"\n" +
            endLine + "\n"
        let fixtureContent = userContent + "\n" + oldFormatBlock

        let root = tempDir + "/" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let configPath = root + "/config.yaml"
        try Data(fixtureContent.utf8).write(to: URL(fileURLWithPath: configPath))

        try HermesConfigManager.disableIPC(configPath: configPath)

        let finalContent = try String(contentsOfFile: configPath, encoding: .utf8)
        XCTAssertEqual(
            finalContent, userContent,
            "Removing an old-format block (trailing newline after END) must restore exactly the original " +
            "user content, with no stray blank line left where the block's leading separator was"
        )
    }

    // MARK: - Group C: whole-file managers

    /// Group C owns the entire file, so the byte-preservation half of the
    /// contract is automatically satisfied. Included in the same suite,
    /// not skipped, so a per-group exception can't be introduced
    /// silently: this test pins install -> remove's END STATE (nothing
    /// left behind, no `.bak`). It passes today AND is expected to keep
    /// passing after L1 -- it exists so Group C is not exempted from the
    /// same driver's scrutiny, not because today's behavior is broken.
    /// The concurrency half of Group C's story (F5's direct
    /// `FileManager.removeItem` calls sitting outside any lock) is
    /// covered separately by `ConfigFileUtilsTests`'s lock tests.
    func test_groupC_wholeFileManagers_installThenRemove_leaveNoResidue() throws {
        struct GroupCCheck {
            let managerName: String
            let install: (String) throws -> String
            let remove: (String) throws -> Void
            let installedRelativePath: String
        }

        let checks: [GroupCCheck] = [
            GroupCCheck(
                managerName: "GrokHooksConfigManager",
                install: { root in
                    let path = root + "/hooks/calyx.json"
                    try GrokHooksConfigManager.installHooks(
                        scriptPath: "/opt/calyx/bin/calyx-agent-hook",
                        approvalScriptPath: "/opt/calyx/bin/calyx-approval-hook",
                        configPath: path
                    )
                    return path
                },
                remove: { root in
                    try GrokHooksConfigManager.removeHooks(configPath: root + "/hooks/calyx.json")
                },
                installedRelativePath: "hooks/calyx.json"
            ),
            GroupCCheck(
                managerName: "OpenCodePluginManager",
                install: { root in try OpenCodePluginManager.install(pluginsDirectory: root) },
                remove: { root in try OpenCodePluginManager.remove(pluginsDirectory: root) },
                installedRelativePath: "plugins/calyx-agent-monitor.js"
            ),
            GroupCCheck(
                managerName: "PiExtensionManager",
                install: { root in try PiExtensionManager.install(extensionsDirectory: root) },
                remove: { root in try PiExtensionManager.remove(extensionsDirectory: root) },
                installedRelativePath: "extensions/calyx.ts"
            ),
        ]

        for check in checks {
            let root = tempDir + "/" + UUID().uuidString
            try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)

            XCTAssertFalse(
                FileManager.default.fileExists(atPath: root + "/" + check.installedRelativePath),
                "\(check.managerName): precondition -- nothing installed yet"
            )

            _ = try check.install(root)
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: root + "/" + check.installedRelativePath),
                "\(check.managerName): install must create its owned file"
            )

            try check.remove(root)

            XCTAssertFalse(
                FileManager.default.fileExists(atPath: root + "/" + check.installedRelativePath),
                "\(check.managerName): remove must delete the file it installed"
            )

            let parentDir = (root + "/" + check.installedRelativePath as NSString).deletingLastPathComponent
            if FileManager.default.fileExists(atPath: parentDir) {
                let leftovers = try FileManager.default.contentsOfDirectory(atPath: parentDir)
                XCTAssertTrue(
                    leftovers.isEmpty,
                    "\(check.managerName): install -> remove must not leave any file (e.g. .bak) behind in " +
                    "\(parentDir), found \(leftovers)"
                )
            }
        }
    }

    // MARK: - Two managers, one shared file (~/.codex/config.toml)
    //
    // CodexConfigManager owns a TOML table there; CodexHooksConfigManager
    // owns a BEGIN/END span in the SAME file. Neither manager's own
    // enable/disable cycle may disturb the region the other one wrote.
    // The reference ("what the other manager alone would have produced")
    // is captured from a real call rather than hand-transcribed, so this
    // test does not depend on guessing either manager's exact byte
    // format.

    func test_codexConfigManager_cycle_doesNotDisturbCodexHooksConfigManagersRegion() throws {
        let referenceRoot = tempDir + "/" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: referenceRoot, withIntermediateDirectories: true)
        let referencePath = referenceRoot + "/config.toml"
        try CodexHooksConfigManager.installHooks(
            scriptPath: "/opt/calyx/bin/calyx-agent-hook",
            approvalScriptPath: "/opt/calyx/bin/calyx-approval-hook",
            configPath: referencePath
        )
        let hooksOnlyExpected = try String(contentsOfFile: referencePath, encoding: .utf8)

        let sharedRoot = tempDir + "/" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: sharedRoot, withIntermediateDirectories: true)
        let sharedPath = sharedRoot + "/config.toml"
        try CodexHooksConfigManager.installHooks(
            scriptPath: "/opt/calyx/bin/calyx-agent-hook",
            approvalScriptPath: "/opt/calyx/bin/calyx-approval-hook",
            configPath: sharedPath
        )

        try CodexConfigManager.enableIPC(port: 41830, token: "contract-token", configPath: sharedPath)
        try CodexConfigManager.disableIPC(configPath: sharedPath)

        let finalContent = try String(contentsOfFile: sharedPath, encoding: .utf8)
        XCTAssertEqual(
            finalContent, hooksOnlyExpected,
            "CodexConfigManager's own enable -> disable cycle against a shared config.toml must leave " +
            "CodexHooksConfigManager's BEGIN/END region byte-identical to what installHooks alone produced"
        )
    }

    func test_codexHooksConfigManager_cycle_doesNotDisturbCodexConfigManagersRegion() throws {
        let referenceRoot = tempDir + "/" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: referenceRoot, withIntermediateDirectories: true)
        let referencePath = referenceRoot + "/config.toml"
        try CodexConfigManager.enableIPC(port: 41830, token: "contract-token", configPath: referencePath)
        let ipcOnlyExpected = try String(contentsOfFile: referencePath, encoding: .utf8)

        let sharedRoot = tempDir + "/" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: sharedRoot, withIntermediateDirectories: true)
        let sharedPath = sharedRoot + "/config.toml"
        try CodexConfigManager.enableIPC(port: 41830, token: "contract-token", configPath: sharedPath)

        try CodexHooksConfigManager.installHooks(
            scriptPath: "/opt/calyx/bin/calyx-agent-hook",
            approvalScriptPath: "/opt/calyx/bin/calyx-approval-hook",
            configPath: sharedPath
        )
        try CodexHooksConfigManager.removeHooks(configPath: sharedPath)

        let finalContent = try String(contentsOfFile: sharedPath, encoding: .utf8)
        XCTAssertEqual(
            finalContent, ipcOnlyExpected,
            "CodexHooksConfigManager's own installHooks -> removeHooks cycle against a shared config.toml " +
            "must leave CodexConfigManager's [mcp_servers.calyx-ipc] table byte-identical to what enableIPC " +
            "alone produced"
        )
    }

    // MARK: - CRLF foreign TOML table inside Calyx's managed block (byte-level appendingSection/orphan scan)

    /// A `~/.codex/config.toml` using CRLF, with a foreign TOML table
    /// (simulating Codex itself having written one) sitting inside
    /// Calyx's own BEGIN/END span, must round-trip that foreign table
    /// byte-for-byte -- including its CRLF terminators -- through
    /// `removeHooks`. Pins the fix for the grapheme-cluster bug where
    /// `appendingSection`'s `String.hasSuffix("\n")` / `hasSuffix("\n\n")`
    /// checks silently failed against a CRLF document (a CRLF pair
    /// collapses into a single `Character`) and appended stray bare LF
    /// bytes into an otherwise all-CRLF file.
    func test_codexHooksConfigManager_crlfForeignTableInsideManagedBlock_removeHooksPreservesItByteIdentically() throws {
        let root = tempDir + "/" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let configPath = root + "/config.toml"

        try CodexHooksConfigManager.installHooks(
            scriptPath: "/opt/calyx/bin/calyx-agent-hook",
            approvalScriptPath: "/opt/calyx/bin/calyx-approval-hook",
            configPath: configPath
        )
        let installedLF = try String(contentsOfFile: configPath, encoding: .utf8)
        guard installedLF.contains(CodexHooksConfigManager.endLine) else {
            return XCTFail("fixture setup: installed content must contain the END marker")
        }

        // Simulate Codex itself having serialized a foreign table just
        // before Calyx's END marker, inside the managed BEGIN/END span,
        // then rewrite the whole file as CRLF (a config.toml Codex itself
        // writes with CRLF line endings).
        let foreignTableLF = "[foreign]\nkept = true\n"
        let withForeignLF = installedLF.replacingOccurrences(
            of: CodexHooksConfigManager.endLine,
            with: foreignTableLF + CodexHooksConfigManager.endLine
        )
        let crlfContent = withForeignLF.replacingOccurrences(of: "\n", with: "\r\n")
        try Data(crlfContent.utf8).write(to: URL(fileURLWithPath: configPath))

        try CodexHooksConfigManager.removeHooks(configPath: configPath)

        let finalData = try Data(contentsOf: URL(fileURLWithPath: configPath))
        let finalContent = String(decoding: finalData, as: UTF8.self)
        let expected = foreignTableLF.replacingOccurrences(of: "\n", with: "\r\n")
        XCTAssertEqual(
            finalContent, expected,
            "removeHooks against a CRLF config.toml must preserve a foreign TOML table extracted from " +
            "inside Calyx's managed block byte-for-byte, including its CRLF terminators, never a bare LF"
        )
    }

    // MARK: - CRLF Hermes Case B insertion (byte-level EOL, not a hard-coded "\n")

    /// A `~/.hermes/config.yaml` using CRLF, already holding a top-level
    /// `mcp_servers:` key (Case B: insert as a child, not append at EOF),
    /// must have its freshly inserted Calyx sub-block CRLF-terminated
    /// throughout -- matching the surrounding document -- rather than
    /// `insertCaseB`'s previous hard-coded `"\n"` leaving the inserted
    /// region LF-terminated inside an otherwise-CRLF file.
    func test_hermesConfigManager_crlfCaseBInsertion_usesCRLFThroughout() throws {
        let root = tempDir + "/" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let configPath = root + "/config.yaml"

        let fixtureLF =
            "mcp_servers:\n" +
            "  existing-server:\n" +
            "    url: \"http://example/mcp\"\n" +
            "other: 1\n"
        try Data(fixtureLF.replacingOccurrences(of: "\n", with: "\r\n").utf8)
            .write(to: URL(fileURLWithPath: configPath))

        try HermesConfigManager.enableIPC(port: 41830, token: "t", configPath: configPath)

        let finalData = try Data(contentsOf: URL(fileURLWithPath: configPath))
        let finalContent = String(decoding: finalData, as: UTF8.self)

        let expectedLF =
            "mcp_servers:\n" +
            "  existing-server:\n" +
            "    url: \"http://example/mcp\"\n" +
            "  # BEGIN CALYX IPC (managed by Calyx, do not edit)\n" +
            "  calyx-ipc:\n" +
            "    url: \"http://127.0.0.1:41830/mcp\"\n" +
            "    headers:\n" +
            "      Authorization: \"Bearer t\"\n" +
            "      X-Calyx-Surface-ID: \"${CALYX_SURFACE_ID}\"\n" +
            "      X-Calyx-Session-ID: \"${CALYX_SESSION_ID}\"\n" +
            "      X-Calyx-Agent-Kind: \"hermes\"\n" +
            "  calyx-mcp:\n" +
            "    url: \"http://127.0.0.1:41830/calyx-mcp\"\n" +
            "    headers:\n" +
            "      Authorization: \"Bearer t\"\n" +
            "      X-Calyx-Surface-ID: \"${CALYX_SURFACE_ID}\"\n" +
            "      X-Calyx-Session-ID: \"${CALYX_SESSION_ID}\"\n" +
            "      X-Calyx-Agent-Kind: \"hermes\"\n" +
            "      X-Calyx-Herdr-Pane-ID: \"${HERDR_PANE_ID}\"\n" +
            "      X-Calyx-Herdr-Socket-Path: \"${HERDR_SOCKET_PATH}\"\n" +
            "  # END CALYX IPC\n" +
            "other: 1\n"
        let expected = expectedLF.replacingOccurrences(of: "\n", with: "\r\n")

        XCTAssertEqual(
            finalContent, expected,
            "Case B insertion into a CRLF Hermes config must CRLF-terminate every line of the freshly " +
            "inserted Calyx sub-block, matching the surrounding document, never a bare LF"
        )
    }

    // MARK: - Detection contract: the read-only predicate and disable/remove must agree

    /// Every manager exposes a read-only "is this installed" predicate
    /// (isIPCEnabled / areHooksInstalled / isInstalled) alongside a write
    /// path that disables/removes the same owned region. A predicate that
    /// uses a different detection rule than the write path can disagree
    /// with it: it can report "not installed" for a file the write path
    /// would still edit, or report "installed" for a file the write path
    /// leaves untouched. Every manager, plus a set of hand-crafted edge
    /// fixtures per owned-region format, is driven through ONE generic
    /// check that only trusts each manager's own two entry points against
    /// each other, never a hard-coded expected boolean -- the same
    /// single-driver style `runContractCheck` above already uses for the
    /// byte-preservation half of the contract.

    /// Exercises the ordinary path: a fresh region written by the
    /// manager's own enable/install must read back as installed, and
    /// disabling it must read back as not installed.
    private struct DetectionBasicCheck {
        let managerName: String
        let enable: (String) throws -> Void
        let disable: (String) throws -> Void
        let isEnabled: (String) -> Bool
    }

    private func runDetectionBasicCheck(
        _ check: DetectionBasicCheck, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let root = tempDir + "/" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)

        try check.enable(root)
        XCTAssertTrue(
            check.isEnabled(root),
            "\(check.managerName): the detection predicate must read true immediately after enable/install",
            file: file, line: line
        )

        try check.disable(root)
        XCTAssertFalse(
            check.isEnabled(root),
            "\(check.managerName): the detection predicate must read false immediately after disable/remove",
            file: file, line: line
        )
    }

    private func detectionBasicChecks() -> [DetectionBasicCheck] {
        [
            DetectionBasicCheck(
                managerName: "ClaudeConfigManager.isIPCEnabled",
                enable: { root in
                    try ClaudeConfigManager.enableIPC(port: 41830, token: "contract-token", configPath: root + "/claude.json")
                },
                disable: { root in try ClaudeConfigManager.disableIPC(configPath: root + "/claude.json") },
                isEnabled: { root in ClaudeConfigManager.isIPCEnabled(configPath: root + "/claude.json") }
            ),
            DetectionBasicCheck(
                managerName: "CodexConfigManager.isIPCEnabled",
                enable: { root in
                    try CodexConfigManager.enableIPC(port: 41830, token: "contract-token", configPath: root + "/config.toml")
                },
                disable: { root in try CodexConfigManager.disableIPC(configPath: root + "/config.toml") },
                isEnabled: { root in CodexConfigManager.isIPCEnabled(configPath: root + "/config.toml") }
            ),
            DetectionBasicCheck(
                managerName: "GrokConfigManager.isIPCEnabled",
                enable: { root in
                    try GrokConfigManager.enableIPC(port: 41830, token: "contract-token", configPath: root + "/config.toml")
                },
                disable: { root in try GrokConfigManager.disableIPC(configPath: root + "/config.toml") },
                isEnabled: { root in GrokConfigManager.isIPCEnabled(configPath: root + "/config.toml") }
            ),
            DetectionBasicCheck(
                managerName: "OpenCodeConfigManager.isIPCEnabled",
                enable: { root in
                    try OpenCodeConfigManager.enableIPC(port: 41830, token: "contract-token", configDir: root)
                },
                disable: { root in try OpenCodeConfigManager.disableIPC(configDir: root) },
                isEnabled: { root in OpenCodeConfigManager.isIPCEnabled(configDir: root) }
            ),
            DetectionBasicCheck(
                managerName: "HermesConfigManager.isIPCEnabled",
                enable: { root in
                    try HermesConfigManager.enableIPC(port: 41830, token: "contract-token", configPath: root + "/config.yaml")
                },
                disable: { root in try HermesConfigManager.disableIPC(configPath: root + "/config.yaml") },
                isEnabled: { root in HermesConfigManager.isIPCEnabled(configPath: root + "/config.yaml") }
            ),
            DetectionBasicCheck(
                managerName: "ClaudeHooksConfigManager.areHooksInstalled",
                enable: { root in
                    try ClaudeHooksConfigManager.installHooks(
                        scriptPath: "/opt/calyx/bin/calyx-agent-hook",
                        approvalScriptPath: "/opt/calyx/bin/calyx-approval-hook",
                        configPath: root + "/settings.json"
                    )
                },
                disable: { root in try ClaudeHooksConfigManager.removeHooks(configPath: root + "/settings.json") },
                isEnabled: { root in ClaudeHooksConfigManager.areHooksInstalled(configPath: root + "/settings.json") }
            ),
            DetectionBasicCheck(
                managerName: "CodexHooksConfigManager.areHooksInstalled",
                enable: { root in
                    try CodexHooksConfigManager.installHooks(
                        scriptPath: "/opt/calyx/bin/calyx-agent-hook",
                        approvalScriptPath: "/opt/calyx/bin/calyx-approval-hook",
                        configPath: root + "/config.toml"
                    )
                },
                disable: { root in try CodexHooksConfigManager.removeHooks(configPath: root + "/config.toml") },
                isEnabled: { root in CodexHooksConfigManager.areHooksInstalled(configPath: root + "/config.toml") }
            ),
            DetectionBasicCheck(
                managerName: "GrokHooksConfigManager.areHooksInstalled",
                enable: { root in
                    try GrokHooksConfigManager.installHooks(
                        scriptPath: "/opt/calyx/bin/calyx-agent-hook",
                        approvalScriptPath: "/opt/calyx/bin/calyx-approval-hook",
                        configPath: root + "/hooks/calyx.json"
                    )
                },
                disable: { root in try GrokHooksConfigManager.removeHooks(configPath: root + "/hooks/calyx.json") },
                isEnabled: { root in GrokHooksConfigManager.areHooksInstalled(configPath: root + "/hooks/calyx.json") }
            ),
            DetectionBasicCheck(
                managerName: "OpenCodePluginManager.isInstalled",
                enable: { root in _ = try OpenCodePluginManager.install(pluginsDirectory: root) },
                disable: { root in try OpenCodePluginManager.remove(pluginsDirectory: root) },
                isEnabled: { root in OpenCodePluginManager.isInstalled(pluginsDirectory: root) }
            ),
            DetectionBasicCheck(
                managerName: "PiExtensionManager.isInstalled",
                enable: { root in _ = try PiExtensionManager.install(extensionsDirectory: root) },
                disable: { root in try PiExtensionManager.remove(extensionsDirectory: root) },
                isEnabled: { root in PiExtensionManager.isInstalled(extensionsDirectory: root) }
            ),
            DetectionBasicCheck(
                managerName: "ShellIntegrationInstaller.isInstalled",
                enable: { root in _ = try ShellIntegrationInstaller.install(toDirectory: URL(fileURLWithPath: root)) },
                disable: { root in try ShellIntegrationInstaller.remove(fromDirectory: URL(fileURLWithPath: root)) },
                isEnabled: { root in ShellIntegrationInstaller.isInstalled(inDirectory: URL(fileURLWithPath: root)) }
            ),
        ]
    }

    /// Exercises hand-crafted fixtures none of the managers' own
    /// enable/install ever produces: each represents Calyx's owned
    /// region, written in a still-valid but differently-shaped form, for
    /// one of the three owned-region formats (marker block, TOML table,
    /// JSON key). The predicate's own answer on the SAME fixture decides
    /// which half of the contract applies: if it reads true, disable must
    /// actually clear it (mirrors `DetectionBasicCheck`'s own enable ->
    /// disable pair); if it reads false, disable must leave every byte of
    /// the file exactly as written -- a "not installed" answer that a
    /// subsequent disable still edits means the predicate and the write
    /// path disagree about what Calyx owns. Either direction of mismatch
    /// fails one of the two branches below.
    private struct DetectionEdgeFixtureCheck {
        let managerName: String
        let fixtureLabel: String
        let relativePath: String
        let content: String
        let disable: (String) throws -> Void
        let isEnabled: (String) -> Bool
        /// Non-nil only for a predicate that is, by its own documented
        /// design, blind to `relativePath`
        /// (`OpenCodeConfigManager.isIPCEnabled` reads only
        /// opencode.json, never AGENTS.md -- see that method's own doc
        /// comment), so a `false` reading here never implies disable must
        /// leave `relativePath` untouched.
        let skipByteUnchangedReason: String?
        /// The designed exit for a document JSON itself cannot
        /// parse at all (a missing opening brace, a truncated object): the
        /// predicate reads `false`, and `disable` throws rather than
        /// silently doing nothing or guessing at a shape -- "読めない設定
        /// は throw する" (the design document's failure-state table).
        /// Defaults to `false` so every existing descriptor line above
        /// is unaffected.
        let expectsInvalidDocumentThrow: Bool
        /// `content` starts with a leading UTF-8 BOM, which sits
        /// outside the JSON document itself. The predicate must read this
        /// exactly as it would its no-BOM twin (`content` minus the first
        /// 3 bytes), and `disable`'s result must match that twin's own
        /// disable result byte-for-byte past the BOM, with the BOM itself
        /// surviving unchanged at the front. Defaults to `false` so every
        /// existing descriptor line above is unaffected.
        let expectsBOMPreservedMatchingNoBOMDisable: Bool

        init(
            managerName: String, fixtureLabel: String, relativePath: String, content: String,
            disable: @escaping (String) throws -> Void, isEnabled: @escaping (String) -> Bool,
            skipByteUnchangedReason: String?, expectsInvalidDocumentThrow: Bool = false,
            expectsBOMPreservedMatchingNoBOMDisable: Bool = false
        ) {
            self.managerName = managerName
            self.fixtureLabel = fixtureLabel
            self.relativePath = relativePath
            self.content = content
            self.disable = disable
            self.isEnabled = isEnabled
            self.skipByteUnchangedReason = skipByteUnchangedReason
            self.expectsInvalidDocumentThrow = expectsInvalidDocumentThrow
            self.expectsBOMPreservedMatchingNoBOMDisable = expectsBOMPreservedMatchingNoBOMDisable
        }
    }

    private func runDetectionEdgeFixtureCheck(
        _ fx: DetectionEdgeFixtureCheck, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let root = tempDir + "/" + UUID().uuidString
        let path = root + "/" + fx.relativePath
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true
        )
        try Data(fx.content.utf8).write(to: URL(fileURLWithPath: path))

        let before = try Data(contentsOf: URL(fileURLWithPath: path))
        let detected = fx.isEnabled(root)

        if fx.expectsInvalidDocumentThrow {
            XCTAssertFalse(
                detected,
                "\(fx.managerName) [\(fx.fixtureLabel)]: a document this manager cannot parse at all must " +
                "read as NOT installed, not throw or guess at a shape",
                file: file, line: line
            )
            XCTAssertThrowsError(
                try fx.disable(root),
                "\(fx.managerName) [\(fx.fixtureLabel)]: disable must throw for a document it cannot parse " +
                "at all, rather than silently doing nothing or guessing at a shape",
                file: file, line: line
            )
            let after = try Data(contentsOf: URL(fileURLWithPath: path))
            XCTAssertEqual(
                after, before,
                "\(fx.managerName) [\(fx.fixtureLabel)]: a disable that throws for an unparseable document " +
                "must leave every byte of it unchanged",
                file: file, line: line
            )
            return
        }

        if fx.expectsBOMPreservedMatchingNoBOMDisable {
            XCTAssertTrue(
                detected,
                "\(fx.managerName) [\(fx.fixtureLabel)]: a leading UTF-8 BOM sits outside the JSON " +
                "document and must not change the predicate's reading -- this fixture holds Calyx's own " +
                "entry and must read installed",
                file: file, line: line
            )
        }

        do {
            try fx.disable(root)
        } catch {
            XCTFail(
                "\(fx.managerName) [\(fx.fixtureLabel)]: the predicate read this file as " +
                "\(detected ? "installed" : "NOT installed"), but disable threw \(error) instead of either " +
                "clearing it or leaving it untouched -- the predicate and the write path disagree about " +
                "what Calyx owns here",
                file: file, line: line
            )
            return
        }

        if detected {
            XCTAssertFalse(
                fx.isEnabled(root),
                "\(fx.managerName) [\(fx.fixtureLabel)]: the predicate read this file as installed, so " +
                "disable must actually clear that state -- a predicate reading true while disable leaves " +
                "the file still reading as installed is the same detection/deletion mismatch this contract " +
                "exists to catch",
                file: file, line: line
            )
            if fx.expectsBOMPreservedMatchingNoBOMDisable {
                try assertBOMPreservedMatchingNoBOMDisable(fx, path: path, file: file, line: line)
            }
            return
        }

        if fx.skipByteUnchangedReason != nil {
            return
        }

        guard FileManager.default.fileExists(atPath: path) else {
            XCTFail(
                "\(fx.managerName) [\(fx.fixtureLabel)]: the predicate read this file as NOT installed, so " +
                "disable must never delete it",
                file: file, line: line
            )
            return
        }
        let after = try Data(contentsOf: URL(fileURLWithPath: path))
        XCTAssertEqual(
            after, before,
            "\(fx.managerName) [\(fx.fixtureLabel)]: the predicate read this file as NOT installed, so " +
            "disable must leave every byte of it unchanged -- a predicate reading false while disable " +
            "still edits the file means detection and deletion use two different rules for the same owned " +
            "region",
            file: file, line: line
        )
    }

    /// Verifies the leading UTF-8 BOM in `path`'s already-disabled content
    /// survived byte-for-byte, and that everything past it matches what
    /// `disable` produces for the same fixture's no-BOM twin -- run fresh,
    /// under its own root, from the same starting content minus the BOM.
    private func assertBOMPreservedMatchingNoBOMDisable(
        _ fx: DetectionEdgeFixtureCheck, path: String, file: StaticString, line: UInt
    ) throws {
        let bomBytes: [UInt8] = [0xEF, 0xBB, 0xBF]
        let afterWithBOM = try Data(contentsOf: URL(fileURLWithPath: path))
        XCTAssertEqual(
            Array(afterWithBOM.prefix(3)), bomBytes,
            "\(fx.managerName) [\(fx.fixtureLabel)]: the leading UTF-8 BOM sits outside the JSON document " +
            "and must survive disable byte-for-byte",
            file: file, line: line
        )

        let noBOMContent = String(decoding: Data(fx.content.utf8).dropFirst(3), as: UTF8.self)
        let twinRoot = tempDir + "/" + UUID().uuidString
        let twinPath = twinRoot + "/" + fx.relativePath
        try FileManager.default.createDirectory(
            atPath: (twinPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true
        )
        try Data(noBOMContent.utf8).write(to: URL(fileURLWithPath: twinPath))
        try fx.disable(twinRoot)
        let afterNoBOM = try Data(contentsOf: URL(fileURLWithPath: twinPath))

        XCTAssertEqual(
            afterWithBOM.dropFirst(3), afterNoBOM,
            "\(fx.managerName) [\(fx.fixtureLabel)]: disable's result on a BOM-prefixed document must be " +
            "identical, past the BOM, to disable's result on its no-BOM twin",
            file: file, line: line
        )
    }

    private func joinedLines(_ lines: [String], eol: String) -> String {
        lines.joined(separator: eol) + eol
    }

    private func detectionEdgeFixtureChecks() -> [DetectionEdgeFixtureCheck] {
        var checks: [DetectionEdgeFixtureCheck] = []

        // Marker block: Hermes, CodexHooks, OpenCode AGENTS.md. Two
        // scenarios per manager -- a BEGIN line padded with whitespace
        // around an otherwise complete body, and a well-formed BEGIN/END
        // pair whose body carries none of the manager's own identifying
        // content -- each in both an LF and a CRLF document.
        for eol in ["\n", "\r\n"] {
            let eolLabel = eol == "\n" ? "LF" : "CRLF"

            checks.append(DetectionEdgeFixtureCheck(
                managerName: "HermesConfigManager.isIPCEnabled",
                fixtureLabel: "BEGIN line padded with whitespace (\(eolLabel))",
                relativePath: "config.yaml",
                content: joinedLines([
                    "profile: default",
                    "  # BEGIN CALYX IPC (managed by Calyx, do not edit)  ",
                    "mcp_servers:",
                    "  calyx-ipc:",
                    "    url: \"http://127.0.0.1:41830/mcp\"",
                    "# END CALYX IPC",
                ], eol: eol),
                disable: { root in try HermesConfigManager.disableIPC(configPath: root + "/config.yaml") },
                isEnabled: { root in HermesConfigManager.isIPCEnabled(configPath: root + "/config.yaml") },
                skipByteUnchangedReason: nil
            ))
            checks.append(DetectionEdgeFixtureCheck(
                managerName: "HermesConfigManager.isIPCEnabled",
                fixtureLabel: "BEGIN/END with no calyx-ipc: body line (\(eolLabel))",
                relativePath: "config.yaml",
                content: joinedLines([
                    "profile: default",
                    "# BEGIN CALYX IPC (managed by Calyx, do not edit)",
                    "# nothing useful here",
                    "# END CALYX IPC",
                ], eol: eol),
                disable: { root in try HermesConfigManager.disableIPC(configPath: root + "/config.yaml") },
                isEnabled: { root in HermesConfigManager.isIPCEnabled(configPath: root + "/config.yaml") },
                skipByteUnchangedReason: nil
            ))

            checks.append(DetectionEdgeFixtureCheck(
                managerName: "CodexHooksConfigManager.areHooksInstalled",
                fixtureLabel: "BEGIN line padded with whitespace (\(eolLabel))",
                relativePath: "config.toml",
                content: joinedLines([
                    "profile = \"default\"",
                    "  # BEGIN CALYX AGENT HOOKS (managed by Calyx, do not edit)  ",
                    "[[hooks.Stop]]",
                    "[[hooks.Stop.hooks]]",
                    "type = \"command\"",
                    "command = '\"/opt/calyx/bin/calyx-agent-hook\" codex'",
                    "timeout = 5",
                    "# END CALYX AGENT HOOKS",
                ], eol: eol),
                disable: { root in try CodexHooksConfigManager.removeHooks(configPath: root + "/config.toml") },
                isEnabled: { root in CodexHooksConfigManager.areHooksInstalled(configPath: root + "/config.toml") },
                skipByteUnchangedReason: nil
            ))
            checks.append(DetectionEdgeFixtureCheck(
                managerName: "CodexHooksConfigManager.areHooksInstalled",
                fixtureLabel: "BEGIN/END with no [[hooks.*]] body (\(eolLabel))",
                relativePath: "config.toml",
                content: joinedLines([
                    "profile = \"default\"",
                    "# BEGIN CALYX AGENT HOOKS (managed by Calyx, do not edit)",
                    "# nothing useful here",
                    "# END CALYX AGENT HOOKS",
                ], eol: eol),
                disable: { root in try CodexHooksConfigManager.removeHooks(configPath: root + "/config.toml") },
                isEnabled: { root in CodexHooksConfigManager.areHooksInstalled(configPath: root + "/config.toml") },
                skipByteUnchangedReason: nil
            ))

            let openCodeAgentsSkipReason = "OpenCodeConfigManager.isIPCEnabled reads only opencode.json by " +
                "design (its own doc comment); AGENTS.md alone is never authoritative for it"
            checks.append(DetectionEdgeFixtureCheck(
                managerName: "OpenCodeConfigManager.isIPCEnabled",
                fixtureLabel: "AGENTS.md BEGIN line padded with whitespace (\(eolLabel))",
                relativePath: "AGENTS.md",
                content: joinedLines([
                    "# Project notes",
                    "  <!-- BEGIN CALYX IPC (managed by Calyx, do not edit) -->  ",
                    "Some MCP instructions.",
                    "<!-- END CALYX IPC -->",
                ], eol: eol),
                disable: { root in try OpenCodeConfigManager.disableIPC(configDir: root) },
                isEnabled: { root in OpenCodeConfigManager.isIPCEnabled(configDir: root) },
                skipByteUnchangedReason: openCodeAgentsSkipReason
            ))
            checks.append(DetectionEdgeFixtureCheck(
                managerName: "OpenCodeConfigManager.isIPCEnabled",
                fixtureLabel: "AGENTS.md BEGIN/END with no recognizable body (\(eolLabel))",
                relativePath: "AGENTS.md",
                content: joinedLines([
                    "# Project notes",
                    "<!-- BEGIN CALYX IPC (managed by Calyx, do not edit) -->",
                    "<!-- nothing useful here -->",
                    "<!-- END CALYX IPC -->",
                ], eol: eol),
                disable: { root in try OpenCodeConfigManager.disableIPC(configDir: root) },
                isEnabled: { root in OpenCodeConfigManager.isIPCEnabled(configDir: root) },
                skipByteUnchangedReason: openCodeAgentsSkipReason
            ))
        }

        // TOML table: Codex, Grok. Both already delegate to
        // `TOMLTableConfigDocumentEditor.containsTable`, the same scan
        // `removeTable` uses, which is already whitespace-tolerant around
        // the table header -- included for regression coverage, not
        // because either is currently broken.
        checks.append(DetectionEdgeFixtureCheck(
            managerName: "CodexConfigManager.isIPCEnabled",
            fixtureLabel: "table header padded with whitespace",
            relativePath: "config.toml",
            content: "profile = \"default\"\n  [mcp_servers.calyx-ipc]  \nurl = \"http://127.0.0.1:41830/mcp\"\n",
            disable: { root in try CodexConfigManager.disableIPC(configPath: root + "/config.toml") },
            isEnabled: { root in CodexConfigManager.isIPCEnabled(configPath: root + "/config.toml") },
            skipByteUnchangedReason: nil
        ))
        checks.append(DetectionEdgeFixtureCheck(
            managerName: "GrokConfigManager.isIPCEnabled",
            fixtureLabel: "table header padded with whitespace",
            relativePath: "config.toml",
            content: "profile = \"default\"\n  [mcp_servers.calyx-ipc]  \nurl = \"http://127.0.0.1:41830/mcp\"\n",
            disable: { root in try GrokConfigManager.disableIPC(configPath: root + "/config.toml") },
            isEnabled: { root in GrokConfigManager.isIPCEnabled(configPath: root + "/config.toml") },
            skipByteUnchangedReason: nil
        ))

        // JSON key path: Claude, ClaudeHooks, OpenCode json. All three
        // are structural-parse predicates already, included for
        // regression coverage against a value present at the right key
        // but in an unexpected shape.
        checks.append(DetectionEdgeFixtureCheck(
            managerName: "ClaudeConfigManager.isIPCEnabled",
            fixtureLabel: "calyx-ipc value is a string, not an object",
            relativePath: "claude.json",
            content: "{\"mcpServers\": {\"calyx-ipc\": \"not-an-object\"}, \"other\": true}\n",
            disable: { root in try ClaudeConfigManager.disableIPC(configPath: root + "/claude.json") },
            isEnabled: { root in ClaudeConfigManager.isIPCEnabled(configPath: root + "/claude.json") },
            skipByteUnchangedReason: nil
        ))
        checks.append(DetectionEdgeFixtureCheck(
            managerName: "ClaudeHooksConfigManager.areHooksInstalled",
            fixtureLabel: "hooks.SessionStart value is a string, not an array",
            relativePath: "settings.json",
            content: "{\"hooks\": {\"SessionStart\": \"not-an-array\"}, \"other\": true}\n",
            disable: { root in try ClaudeHooksConfigManager.removeHooks(configPath: root + "/settings.json") },
            isEnabled: { root in ClaudeHooksConfigManager.areHooksInstalled(configPath: root + "/settings.json") },
            skipByteUnchangedReason: nil
        ))
        checks.append(DetectionEdgeFixtureCheck(
            managerName: "OpenCodeConfigManager.isIPCEnabled",
            fixtureLabel: "mcp value is an array, not an object",
            relativePath: "opencode.json",
            content: "{\"mcp\": [\"calyx-ipc\"], \"other\": 1}\n",
            disable: { root in try OpenCodeConfigManager.disableIPC(configDir: root) },
            isEnabled: { root in OpenCodeConfigManager.isIPCEnabled(configDir: root) },
            skipByteUnchangedReason: nil
        ))

        // A document JSON cannot parse at all (missing opening
        // brace, or an object truncated mid-value) -- the designed exit
        // is predicate false, disable throws, bytes unchanged. Two
        // shapes, all three JSON managers. Both JSONSerialization and
        // JParser already reject either shape identically, so this is a
        // regression pin, not a mismatch.
        checks.append(DetectionEdgeFixtureCheck(
            managerName: "ClaudeConfigManager.isIPCEnabled",
            fixtureLabel: "document is not parseable JSON at all (missing opening brace)",
            relativePath: "claude.json",
            content: "\"mcpServers\": {\"calyx-ipc\": {}}}\n",
            disable: { root in try ClaudeConfigManager.disableIPC(configPath: root + "/claude.json") },
            isEnabled: { root in ClaudeConfigManager.isIPCEnabled(configPath: root + "/claude.json") },
            skipByteUnchangedReason: nil,
            expectsInvalidDocumentThrow: true
        ))
        checks.append(DetectionEdgeFixtureCheck(
            managerName: "ClaudeHooksConfigManager.areHooksInstalled",
            fixtureLabel: "document is not parseable JSON at all (missing opening brace)",
            relativePath: "settings.json",
            content: "\"hooks\": {\"Stop\": []}}\n",
            disable: { root in try ClaudeHooksConfigManager.removeHooks(configPath: root + "/settings.json") },
            isEnabled: { root in ClaudeHooksConfigManager.areHooksInstalled(configPath: root + "/settings.json") },
            skipByteUnchangedReason: nil,
            expectsInvalidDocumentThrow: true
        ))
        checks.append(DetectionEdgeFixtureCheck(
            managerName: "OpenCodeConfigManager.isIPCEnabled",
            fixtureLabel: "document is not parseable JSON at all (missing opening brace)",
            relativePath: "opencode.json",
            content: "\"mcp\": {\"calyx-ipc\": {}}}\n",
            disable: { root in try OpenCodeConfigManager.disableIPC(configDir: root) },
            isEnabled: { root in OpenCodeConfigManager.isIPCEnabled(configDir: root) },
            skipByteUnchangedReason: nil,
            expectsInvalidDocumentThrow: true
        ))
        checks.append(DetectionEdgeFixtureCheck(
            managerName: "ClaudeConfigManager.isIPCEnabled",
            fixtureLabel: "document is not parseable JSON at all (truncated mid-object)",
            relativePath: "claude.json",
            content: "{\"mcpServers\": {\"calyx-ipc\": {\n",
            disable: { root in try ClaudeConfigManager.disableIPC(configPath: root + "/claude.json") },
            isEnabled: { root in ClaudeConfigManager.isIPCEnabled(configPath: root + "/claude.json") },
            skipByteUnchangedReason: nil,
            expectsInvalidDocumentThrow: true
        ))
        checks.append(DetectionEdgeFixtureCheck(
            managerName: "ClaudeHooksConfigManager.areHooksInstalled",
            fixtureLabel: "document is not parseable JSON at all (truncated mid-object)",
            relativePath: "settings.json",
            content: "{\"hooks\": {\"Stop\": [{\n",
            disable: { root in try ClaudeHooksConfigManager.removeHooks(configPath: root + "/settings.json") },
            isEnabled: { root in ClaudeHooksConfigManager.areHooksInstalled(configPath: root + "/settings.json") },
            skipByteUnchangedReason: nil,
            expectsInvalidDocumentThrow: true
        ))
        checks.append(DetectionEdgeFixtureCheck(
            managerName: "OpenCodeConfigManager.isIPCEnabled",
            fixtureLabel: "document is not parseable JSON at all (truncated mid-object)",
            relativePath: "opencode.json",
            content: "{\"mcp\": {\"calyx-ipc\": {\n",
            disable: { root in try OpenCodeConfigManager.disableIPC(configDir: root) },
            isEnabled: { root in OpenCodeConfigManager.isIPCEnabled(configDir: root) },
            skipByteUnchangedReason: nil,
            expectsInvalidDocumentThrow: true
        ))

        // A leading UTF-8 BOM sits outside the JSON document itself
        // -- `JParser.parseDocument` skips it (3 bytes: `EF BB BF`)
        // before scanning the document, and it is preserved verbatim on
        // write, since every splice range `JSONEditor` produces starts
        // past it. A BOM-prefixed, calyx-ipc-holding document therefore
        // reads as installed, and disable clears the entry exactly as it
        // would for its no-BOM twin, leaving the BOM itself untouched at
        // the front of the file.
        let bomPrefix = "\u{FEFF}"
        checks.append(DetectionEdgeFixtureCheck(
            managerName: "ClaudeConfigManager.isIPCEnabled",
            fixtureLabel: "leading UTF-8 BOM",
            relativePath: "claude.json",
            content: bomPrefix + "{\"mcpServers\": {\"calyx-ipc\": {}}}\n",
            disable: { root in try ClaudeConfigManager.disableIPC(configPath: root + "/claude.json") },
            isEnabled: { root in ClaudeConfigManager.isIPCEnabled(configPath: root + "/claude.json") },
            skipByteUnchangedReason: nil,
            expectsBOMPreservedMatchingNoBOMDisable: true
        ))
        checks.append(DetectionEdgeFixtureCheck(
            managerName: "ClaudeHooksConfigManager.areHooksInstalled",
            fixtureLabel: "leading UTF-8 BOM",
            relativePath: "settings.json",
            content: bomPrefix + "{\"hooks\": {\"Stop\": [{\"hooks\": [{\"type\": \"command\", " +
                "\"command\": \"\\\"/opt/calyx/bin/calyx-agent-hook\\\"\", \"timeout\": 5, \"async\": true}]}]}}\n",
            disable: { root in try ClaudeHooksConfigManager.removeHooks(configPath: root + "/settings.json") },
            isEnabled: { root in ClaudeHooksConfigManager.areHooksInstalled(configPath: root + "/settings.json") },
            skipByteUnchangedReason: nil,
            expectsBOMPreservedMatchingNoBOMDisable: true
        ))
        checks.append(DetectionEdgeFixtureCheck(
            managerName: "OpenCodeConfigManager.isIPCEnabled",
            fixtureLabel: "leading UTF-8 BOM",
            relativePath: "opencode.json",
            content: bomPrefix + "{\"mcp\": {\"calyx-ipc\": {}}}\n",
            disable: { root in try OpenCodeConfigManager.disableIPC(configDir: root) },
            isEnabled: { root in OpenCodeConfigManager.isIPCEnabled(configDir: root) },
            skipByteUnchangedReason: nil,
            expectsBOMPreservedMatchingNoBOMDisable: true
        ))

        // A duplicate top-level key (one occurrence holds Calyx's
        // own entry, the other doesn't) is syntactically valid JSON, so
        // this is NOT an expectsInvalidDocumentThrow case -- it pins
        // that the predicate and disable resolve the SAME occurrence.
        // Verified directly: JSONSerialization on this platform keeps
        // the FIRST occurrence for a duplicate key (not the last, as
        // JSON has no standard rule), the same occurrence
        // JSONConfigDocumentEditor's JParser-based `.first(where:)`
        // scan resolves -- so this fixture does not currently expose a
        // mismatch; it is included as a regression pin for the
        // first-occurrence-wins agreement the shared scanner establishes
        // (both sides now share the identical JParser scan).
        checks.append(DetectionEdgeFixtureCheck(
            managerName: "ClaudeConfigManager.isIPCEnabled",
            fixtureLabel: "duplicate top-level key, only the first occurrence holds calyx-ipc",
            relativePath: "claude.json",
            content: "{\"mcpServers\": {\"calyx-ipc\": {\"marker\": true}}, \"mcpServers\": {\"other\": 1}}\n",
            disable: { root in try ClaudeConfigManager.disableIPC(configPath: root + "/claude.json") },
            isEnabled: { root in ClaudeConfigManager.isIPCEnabled(configPath: root + "/claude.json") },
            skipByteUnchangedReason: nil
        ))

        return checks
    }

    /// Drives both halves of the detection contract -- the ordinary
    /// enable/disable round trip and the hand-crafted edge fixtures --
    /// through every manager in one test, mirroring
    /// `test_enableThenDisable_preservesBytesOutsideOwnedRegion_acrossAllManagerGroups`'s
    /// own single-driver style for the byte-preservation half of the
    /// contract.
    func test_detectionPredicate_agreesWithDisableRemove_acrossAllManagers() throws {
        for check in detectionBasicChecks() {
            try runDetectionBasicCheck(check)
        }
        for check in detectionEdgeFixtureChecks() {
            try runDetectionEdgeFixtureCheck(check)
        }
    }

    // MARK: - Hermes: foreignBodyBytes structural preservation (marker-block ownership rewrite)
    //
    // HermesConfigManager no longer requires a `calyx-ipc:` line to treat a
    // BEGIN...END span as its own (that used to throw
    // .malformedManagedBlock), and no longer throws on any malformed shape
    // at all -- it self-heals and preserves foreign content the same way
    // CodexHooksConfigManager already does. These fixtures pin the
    // structural (indent-based) foreignBodyBytes rule HermesConfigManager
    // declares to MarkerConfigDocumentEditor. All comparisons are on `Data`,
    // never `String`, so a CRLF terminator surviving (or not) is never
    // masked by grapheme-cluster collapse.

    /// Case B: Calyx's block sits nested under an existing `mcp_servers:`
    /// key, and a user's own multi-line MCP server definition (with its own
    /// child tree) has ended up INSIDE Calyx's BEGIN/END span. `disableIPC`
    /// must preserve every byte of that user definition at the same
    /// position, remove only Calyx's `calyx-ipc:` subtree and the markers,
    /// and leave everything outside the span untouched.
    func test_hermesConfigManager_foreignChildInsideCaseBBlock_disableIPCPreservesItByteIdentically() throws {
        let root = tempDir + "/" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let configPath = root + "/config.yaml"

        let fixture =
            "mcp_servers:\n" +
            "  # BEGIN CALYX IPC (managed by Calyx, do not edit)\n" +
            "  calyx-ipc:\n" +
            "    url: \"http://old/mcp\"\n" +
            "  user-server:\n" +
            "    url: \"https://example.com/mcp\"\n" +
            "    headers:\n" +
            "      X-Api-Key: \"secret\"\n" +
            "  # END CALYX IPC\n" +
            "other: 1\n"
        try Data(fixture.utf8).write(to: URL(fileURLWithPath: configPath))

        try HermesConfigManager.disableIPC(configPath: configPath)

        let expected =
            "mcp_servers:\n" +
            "  user-server:\n" +
            "    url: \"https://example.com/mcp\"\n" +
            "    headers:\n" +
            "      X-Api-Key: \"secret\"\n" +
            "other: 1\n"
        let finalData = try Data(contentsOf: URL(fileURLWithPath: configPath))
        XCTAssertEqual(
            finalData, Data(expected.utf8),
            "disableIPC must preserve a foreign child MCP server entry found inside Calyx's Case B span " +
            "byte-for-byte, removing only Calyx's own calyx-ipc: subtree and markers"
        )
    }

    /// Same fixture as above, with the document's line endings all CRLF.
    func test_hermesConfigManager_foreignChildInsideCaseBBlock_crlf_disableIPCPreservesItByteIdentically() throws {
        let root = tempDir + "/" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let configPath = root + "/config.yaml"

        let fixtureLF =
            "mcp_servers:\n" +
            "  # BEGIN CALYX IPC (managed by Calyx, do not edit)\n" +
            "  calyx-ipc:\n" +
            "    url: \"http://old/mcp\"\n" +
            "  user-server:\n" +
            "    url: \"https://example.com/mcp\"\n" +
            "    headers:\n" +
            "      X-Api-Key: \"secret\"\n" +
            "  # END CALYX IPC\n" +
            "other: 1\n"
        let fixture = fixtureLF.replacingOccurrences(of: "\n", with: "\r\n")
        try Data(fixture.utf8).write(to: URL(fileURLWithPath: configPath))

        try HermesConfigManager.disableIPC(configPath: configPath)

        let expectedLF =
            "mcp_servers:\n" +
            "  user-server:\n" +
            "    url: \"https://example.com/mcp\"\n" +
            "    headers:\n" +
            "      X-Api-Key: \"secret\"\n" +
            "other: 1\n"
        let expected = expectedLF.replacingOccurrences(of: "\n", with: "\r\n")
        let finalData = try Data(contentsOf: URL(fileURLWithPath: configPath))
        XCTAssertEqual(
            finalData, Data(expected.utf8),
            "disableIPC must preserve a foreign child MCP server entry found inside Calyx's Case B span " +
            "byte-for-byte over CRLF, including every CRLF terminator, removing only Calyx's own subtree and markers"
        )
    }

    /// A BEGIN/END span whose body has NO `calyx-ipc:` line at all -- only
    /// a user's own entry. This used to throw `.malformedManagedBlock`;
    /// now the whole body is foreign (nothing was identified as Calyx's
    /// own subtree), so `disableIPC` must preserve it entirely rather than
    /// throw.
    func test_hermesConfigManager_beginEndWithNoCalyxIpcLine_disableIPCPreservesEntireBodyInsteadOfThrowing() throws {
        let root = tempDir + "/" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let configPath = root + "/config.yaml"

        let fixture =
            "mcp_servers:\n" +
            "  # BEGIN CALYX IPC (managed by Calyx, do not edit)\n" +
            "  user-only:\n" +
            "    foo: bar\n" +
            "  # END CALYX IPC\n" +
            "other: 1\n"
        try Data(fixture.utf8).write(to: URL(fileURLWithPath: configPath))

        try HermesConfigManager.disableIPC(configPath: configPath)

        let expected =
            "mcp_servers:\n" +
            "  user-only:\n" +
            "    foo: bar\n" +
            "other: 1\n"
        let finalData = try Data(contentsOf: URL(fileURLWithPath: configPath))
        XCTAssertEqual(
            finalData, Data(expected.utf8),
            "disableIPC must not throw when a BEGIN/END span's body has no calyx-ipc: line -- the whole body " +
            "is foreign and must be preserved byte-for-byte in place of the removed markers"
        )
    }

    /// The body mixes a user's own blank line and comment line with Calyx's
    /// calyx-ipc: subtree and a foreign sibling entry. Every non-Calyx line
    /// -- blank, comment, and entry alike -- must survive byte-for-byte in
    /// its original order and position.
    func test_hermesConfigManager_foreignBlankLinesAndCommentsMixedIntoBody_disableIPCPreservesThemAll() throws {
        let root = tempDir + "/" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let configPath = root + "/config.yaml"

        let fixture =
            "mcp_servers:\n" +
            "  # BEGIN CALYX IPC (managed by Calyx, do not edit)\n" +
            "  calyx-ipc:\n" +
            "    url: \"http://old/mcp\"\n" +
            "\n" +
            "  # a user comment\n" +
            "  user-server:\n" +
            "    url: \"https://example.com/mcp\"\n" +
            "  # END CALYX IPC\n" +
            "other: 1\n"
        try Data(fixture.utf8).write(to: URL(fileURLWithPath: configPath))

        try HermesConfigManager.disableIPC(configPath: configPath)

        let expected =
            "mcp_servers:\n" +
            "\n" +
            "  # a user comment\n" +
            "  user-server:\n" +
            "    url: \"https://example.com/mcp\"\n" +
            "other: 1\n"
        let finalData = try Data(contentsOf: URL(fileURLWithPath: configPath))
        XCTAssertEqual(
            finalData, Data(expected.utf8),
            "disableIPC must preserve a user's own blank line and comment line mixed into the body, in their " +
            "original order and position, along with the foreign sibling entry"
        )
    }

    /// Case A: the whole BEGIN...END span, including its own
    /// `mcp_servers:` parent, is a stale/hand-mixed block that holds both
    /// Calyx's `calyx-ipc:` entry and a foreign sibling entry under that
    /// parent. Since a foreign child remains, the `mcp_servers:` parent
    /// line itself must also be preserved (removing only the parent would
    /// leave the foreign child orphaned outside any mapping, corrupting
    /// the YAML) -- the same parent-container rule L1.3.1 applies to JSON.
    func test_hermesConfigManager_caseAParentWithForeignSiblingUnderIt_disableIPCKeepsParentAndSibling() throws {
        let root = tempDir + "/" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let configPath = root + "/config.yaml"

        let fixture =
            "# BEGIN CALYX IPC (managed by Calyx, do not edit)\n" +
            "mcp_servers:\n" +
            "  user-server:\n" +
            "    url: \"https://example.com/mcp\"\n" +
            "  calyx-ipc:\n" +
            "    url: \"http://old/mcp\"\n" +
            "# END CALYX IPC\n" +
            "other: 1\n"
        try Data(fixture.utf8).write(to: URL(fileURLWithPath: configPath))

        try HermesConfigManager.disableIPC(configPath: configPath)

        let expected =
            "mcp_servers:\n" +
            "  user-server:\n" +
            "    url: \"https://example.com/mcp\"\n" +
            "other: 1\n"
        let finalData = try Data(contentsOf: URL(fileURLWithPath: configPath))
        XCTAssertEqual(
            finalData, Data(expected.utf8),
            "disableIPC must keep the mcp_servers: parent AND the foreign sibling child when a foreign child " +
            "remains under it, removing only Calyx's own calyx-ipc: entry and the markers"
        )
    }

    /// Editor defect A's shape (a mapping's last child is followed by the
    /// user's own blank line, then a following top-level key), driven
    /// through HermesConfigManager's own enableIPC -> disableIPC cycle:
    /// the round trip must be byte-identical, meaning the user's blank
    /// line must never be swallowed or relocated.
    func test_hermesConfigManager_trailingBlankLineBeforeNextTopLevelKey_enableThenDisable_roundTripsByteIdentically() throws {
        let root = tempDir + "/" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let configPath = root + "/config.yaml"

        let original =
            "mcp_servers:\n" +
            "  foo:\n" +
            "    url: \"https://x\"\n" +
            "\n" +
            "other: 1\n"
        try Data(original.utf8).write(to: URL(fileURLWithPath: configPath))

        try HermesConfigManager.enableIPC(port: 41830, token: "t", configPath: configPath)
        try HermesConfigManager.disableIPC(configPath: configPath)

        let finalData = try Data(contentsOf: URL(fileURLWithPath: configPath))
        XCTAssertEqual(
            finalData, Data(original.utf8),
            "enableIPC -> disableIPC must round-trip byte-identically when the mapping's last child is " +
            "followed by the user's own blank line and then a following top-level key"
        )
    }

    /// Editor defect B's shape, driven through HermesConfigManager's own
    /// repeated Case B enableIPC: calling enableIPC twice (different
    /// token/port) against a config whose existing mcp_servers: children
    /// are indented 4 spaces must keep every nesting level of the
    /// re-inserted block at a consistent 4-space-per-level indent, never
    /// flattened to the block's own base indent.
    func test_hermesConfigManager_repeatedCaseBEnable_keepsNestedIndentConsistentAtLearnedUnit() throws {
        let root = tempDir + "/" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let configPath = root + "/config.yaml"

        let original =
            "mcp_servers:\n" +
            "    stripe:\n" +
            "        url: \"https://mcp.stripe.com\"\n"
        try Data(original.utf8).write(to: URL(fileURLWithPath: configPath))

        try HermesConfigManager.enableIPC(port: 1, token: "first", configPath: configPath)
        try HermesConfigManager.enableIPC(port: 2, token: "second", configPath: configPath)

        let expected =
            "mcp_servers:\n" +
            "    stripe:\n" +
            "        url: \"https://mcp.stripe.com\"\n" +
            "    # BEGIN CALYX IPC (managed by Calyx, do not edit)\n" +
            "    calyx-ipc:\n" +
            "        url: \"http://127.0.0.1:2/mcp\"\n" +
            "        headers:\n" +
            "            Authorization: \"Bearer second\"\n" +
            "            X-Calyx-Surface-ID: \"${CALYX_SURFACE_ID}\"\n" +
            "            X-Calyx-Session-ID: \"${CALYX_SESSION_ID}\"\n" +
            "            X-Calyx-Agent-Kind: \"hermes\"\n" +
            "    calyx-mcp:\n" +
            "        url: \"http://127.0.0.1:2/calyx-mcp\"\n" +
            "        headers:\n" +
            "            Authorization: \"Bearer second\"\n" +
            "            X-Calyx-Surface-ID: \"${CALYX_SURFACE_ID}\"\n" +
            "            X-Calyx-Session-ID: \"${CALYX_SESSION_ID}\"\n" +
            "            X-Calyx-Agent-Kind: \"hermes\"\n" +
            "            X-Calyx-Herdr-Pane-ID: \"${HERDR_PANE_ID}\"\n" +
            "            X-Calyx-Herdr-Socket-Path: \"${HERDR_SOCKET_PATH}\"\n" +
            "    # END CALYX IPC\n"
        let finalData = try Data(contentsOf: URL(fileURLWithPath: configPath))
        XCTAssertEqual(
            finalData, Data(expected.utf8),
            "Repeated Case B enableIPC must keep every nesting level of the re-inserted block at a " +
            "consistent 4-space-per-level indent (matching the learned unit), never flattened to the " +
            "block's own base indent"
        )
    }

    // MARK: - OpenCode AGENTS.md: BEGIN...END span is Calyx's own owned region in full

    /// AGENTS.md is Markdown prose Calyx itself writes; unlike Hermes's YAML
    /// or CodexHooks's TOML, there is no structural shape (a child key, a
    /// sub-table) that can distinguish a user's own content from Calyx's
    /// once it ends up inside the BEGIN/END span. A user's own paragraph
    /// spliced into that span (e.g. hand-edited) is therefore NOT preserved:
    /// `disableIPC` removes the whole span, and only bytes strictly outside
    /// BEGIN...END survive, byte-for-byte.
    func test_openCodeConfigManager_agentsMDBlockRemovedInFull_onlyBytesOutsideSpanSurvive() throws {
        let root = tempDir + "/" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        try Data(openCodeBaselineJSON.utf8).write(to: URL(fileURLWithPath: root + "/opencode.json"))
        let agentsPath = root + "/AGENTS.md"

        let userPrefix = "# User notes\nsome text before the block\n\n"
        let userSuffix = "\nmore text after the block\n"
        try Data(userPrefix.utf8).write(to: URL(fileURLWithPath: agentsPath))

        try OpenCodeConfigManager.enableIPC(port: 41830, token: "contract-token", configDir: root)
        let installed = try Data(contentsOf: URL(fileURLWithPath: agentsPath))
        var withForeignAndSuffix = installed
        withForeignAndSuffix.append(Data(userSuffix.utf8))

        let endDelimiter = "<!-- END CALYX IPC -->"
        guard let range = withForeignAndSuffix.range(of: Data(endDelimiter.utf8)) else {
            return XCTFail("fixture setup: installed AGENTS.md must contain the END delimiter")
        }
        let foreignParagraph = "A user's own note that ended up inside the managed span.\n"
        withForeignAndSuffix.replaceSubrange(range.lowerBound..<range.lowerBound, with: Data(foreignParagraph.utf8))
        try withForeignAndSuffix.write(to: URL(fileURLWithPath: agentsPath))

        try OpenCodeConfigManager.disableIPC(configDir: root)

        let finalData = try Data(contentsOf: URL(fileURLWithPath: agentsPath))
        XCTAssertEqual(
            finalData, Data((userPrefix + userSuffix).utf8),
            "disableIPC must remove the whole BEGIN...END span, including any foreign paragraph spliced " +
            "into it; only bytes strictly outside the span survive"
        )
    }

    // MARK: - disable writes no secret, so it must not force a file's mode

    /// A single descriptor per manager whose `disableIPC` removes a
    /// secret (the bearer token) but is not itself the write that
    /// carried it. `enable` sets the mode `enableIPC` legitimately owns
    /// (0600, since it writes the token); the fixture is then chmod'ed
    /// to 0644 -- the user's own choice, made after that enable -- and
    /// `disable` must remove Calyx's entry without reverting that choice.
    private struct DisablePreservesModeDescriptor {
        let managerName: String
        let relativePath: String
        /// Written to `path` before `enable` runs, so the file still has
        /// content outside Calyx's own region after `disable` removes
        /// that region -- otherwise the file becomes fully empty and is
        /// deleted (L1.3.2), leaving nothing to check a mode on.
        let unrelatedFixtureContent: String
        let enable: (String) throws -> Void
        let disable: (String) throws -> Void
        let stillContainsCalyxEntry: (String) -> Bool
    }

    func test_disableIPC_neverForcesModeOnAFileItDoesNotOwnOutright_acrossFiveManagers() throws {
        let descriptors: [DisablePreservesModeDescriptor] = [
            DisablePreservesModeDescriptor(
                managerName: "ClaudeConfigManager",
                relativePath: "claude.json",
                unrelatedFixtureContent: "{\n  \"other\": true\n}\n",
                enable: { path in try ClaudeConfigManager.enableIPC(port: 41830, token: "contract-token", configPath: path) },
                disable: { path in try ClaudeConfigManager.disableIPC(configPath: path) },
                stillContainsCalyxEntry: { content in content.contains("calyx-ipc") }
            ),
            DisablePreservesModeDescriptor(
                managerName: "CodexConfigManager",
                relativePath: "config.toml",
                unrelatedFixtureContent: "[other]\nzeta = 1\n",
                enable: { path in try CodexConfigManager.enableIPC(port: 41830, token: "contract-token", configPath: path) },
                disable: { path in try CodexConfigManager.disableIPC(configPath: path) },
                stillContainsCalyxEntry: { content in content.contains("mcp_servers.calyx-ipc") }
            ),
            DisablePreservesModeDescriptor(
                managerName: "GrokConfigManager",
                relativePath: "config.toml",
                unrelatedFixtureContent: "[other]\nzeta = 1\n",
                enable: { path in try GrokConfigManager.enableIPC(port: 41830, token: "contract-token", configPath: path) },
                disable: { path in try GrokConfigManager.disableIPC(configPath: path) },
                stillContainsCalyxEntry: { content in content.contains("mcp_servers.calyx-ipc") }
            ),
            DisablePreservesModeDescriptor(
                managerName: "HermesConfigManager",
                relativePath: "config.yaml",
                unrelatedFixtureContent: "other: true\n",
                enable: { path in try HermesConfigManager.enableIPC(port: 41830, token: "contract-token", configPath: path) },
                disable: { path in try HermesConfigManager.disableIPC(configPath: path) },
                stillContainsCalyxEntry: { content in content.contains("calyx-ipc") }
            ),
            DisablePreservesModeDescriptor(
                managerName: "OpenCodeConfigManager (opencode.json)",
                relativePath: "opencode.json",
                unrelatedFixtureContent: "{\n  \"other\": true\n}\n",
                enable: { path in
                    try OpenCodeConfigManager.enableIPC(port: 41830, token: "contract-token", configDir: (path as NSString).deletingLastPathComponent)
                },
                disable: { path in
                    try OpenCodeConfigManager.disableIPC(configDir: (path as NSString).deletingLastPathComponent)
                },
                stillContainsCalyxEntry: { content in content.contains("calyx-ipc") }
            ),
        ]

        for descriptor in descriptors {
            let root = tempDir + "/" + UUID().uuidString
            try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
            let path = root + "/" + descriptor.relativePath
            try Data(descriptor.unrelatedFixtureContent.utf8).write(to: URL(fileURLWithPath: path))

            try descriptor.enable(path)
            let contentAfterEnable = try String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)
            XCTAssertTrue(
                descriptor.stillContainsCalyxEntry(contentAfterEnable),
                "\(descriptor.managerName): precondition -- enable must have written Calyx's own entry"
            )
            XCTAssertEqual(chmod(path, 0o644), 0, "\(descriptor.managerName): test setup -- chmod to 0644 must succeed")

            try descriptor.disable(path)

            let contentAfterDisable = try String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)
            XCTAssertFalse(
                descriptor.stillContainsCalyxEntry(contentAfterDisable),
                "\(descriptor.managerName): disable must remove Calyx's own entry"
            )

            var statBuf = stat()
            XCTAssertEqual(stat(path, &statBuf), 0, "\(descriptor.managerName): file must still exist to check its mode")
            XCTAssertEqual(
                statBuf.st_mode & ~S_IFMT, 0o644,
                "\(descriptor.managerName): disable writes no secret, so it must preserve the file's mode " +
                "exactly as it found it, not force it back to 0600"
            )
        }
    }

    // MARK: - calyx-mcp: detection predicate agrees with disable-remove

    /// Each manager's `isIPCEnabled` detection predicate is keyed on the
    /// calyx-ipc entry alone (unchanged by this feature). This pins that
    /// `disableIPC` removes calyx-mcp in exact lockstep with calyx-ipc --
    /// `isIPCEnabled` never disagrees with what a fresh `enableIPC` +
    /// `disableIPC` cycle actually leaves behind for EITHER entry, across
    /// every manager that now owns a calyx-mcp entry.
    func test_calyxMCPEntry_disableIPC_agreesWithIsIPCEnabled_acrossAllManagers() throws {
        struct Descriptor {
            let managerName: String
            let relativePath: String
            /// Unrelated sibling content seeded before enable, so
            /// disable's removal never has to cross the "file became
            /// entirely Calyx's own region" cascade-delete boundary --
            /// this test has no reason to exercise that separate edge
            /// case (already covered by `jsonBoundaryChecks()` /
            /// `markerAbsentBecomesPresentButEmptyChecks()` above).
            let seedContent: String
            let enable: (String) throws -> Void
            let disable: (String) throws -> Void
            let isIPCEnabled: (String) -> Bool
            let containsCalyxMCP: (String) -> Bool
        }

        let descriptors: [Descriptor] = [
            Descriptor(
                managerName: "ClaudeConfigManager",
                relativePath: "claude.json",
                seedContent: "{\n  \"otherKey\": \"value\"\n}\n",
                enable: { path in try ClaudeConfigManager.enableIPC(port: 41830, token: "t", configPath: path) },
                disable: { path in try ClaudeConfigManager.disableIPC(configPath: path) },
                isIPCEnabled: { path in ClaudeConfigManager.isIPCEnabled(configPath: path) },
                containsCalyxMCP: { content in content.contains("calyx-mcp") }
            ),
            Descriptor(
                managerName: "CodexConfigManager",
                relativePath: "config.toml",
                seedContent: "[other]\nx = 1\n",
                enable: { path in try CodexConfigManager.enableIPC(port: 41830, token: "t", configPath: path) },
                disable: { path in try CodexConfigManager.disableIPC(configPath: path) },
                isIPCEnabled: { path in CodexConfigManager.isIPCEnabled(configPath: path) },
                containsCalyxMCP: { content in content.contains("[mcp_servers.calyx-mcp]") }
            ),
            Descriptor(
                managerName: "GrokConfigManager",
                relativePath: "config.toml",
                seedContent: "[other]\nx = 1\n",
                enable: { path in try GrokConfigManager.enableIPC(port: 41830, token: "t", configPath: path) },
                disable: { path in try GrokConfigManager.disableIPC(configPath: path) },
                isIPCEnabled: { path in GrokConfigManager.isIPCEnabled(configPath: path) },
                containsCalyxMCP: { content in content.contains("[mcp_servers.calyx-mcp") }
            ),
            Descriptor(
                managerName: "HermesConfigManager",
                relativePath: "config.yaml",
                seedContent: "other: 1\n",
                enable: { path in try HermesConfigManager.enableIPC(port: 41830, token: "t", configPath: path) },
                disable: { path in try HermesConfigManager.disableIPC(configPath: path) },
                isIPCEnabled: { path in HermesConfigManager.isIPCEnabled(configPath: path) },
                containsCalyxMCP: { content in content.contains("calyx-mcp:") }
            ),
        ]

        for descriptor in descriptors {
            let root = tempDir + "/" + UUID().uuidString
            try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
            let path = root + "/" + descriptor.relativePath

            XCTAssertFalse(descriptor.isIPCEnabled(path), "\(descriptor.managerName): absent file must report disabled")
            try Data(descriptor.seedContent.utf8).write(to: URL(fileURLWithPath: path))

            try descriptor.enable(path)
            XCTAssertTrue(descriptor.isIPCEnabled(path), "\(descriptor.managerName): isIPCEnabled must be true after enable")
            let afterEnable = try String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)
            XCTAssertTrue(
                descriptor.containsCalyxMCP(afterEnable),
                "\(descriptor.managerName): precondition -- enable must have written calyx-mcp"
            )

            try descriptor.disable(path)
            XCTAssertFalse(descriptor.isIPCEnabled(path), "\(descriptor.managerName): isIPCEnabled must be false after disable")
            let afterDisable = try String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)
            XCTAssertFalse(
                descriptor.containsCalyxMCP(afterDisable),
                "\(descriptor.managerName): disable must remove calyx-mcp in lockstep with calyx-ipc, " +
                "exactly when isIPCEnabled flips to false"
            )
        }

        // OpenCodeConfigManager: separate config-directory shape.
        let openCodeRoot = tempDir + "/" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: openCodeRoot, withIntermediateDirectories: true)
        XCTAssertFalse(OpenCodeConfigManager.isIPCEnabled(configDir: openCodeRoot))
        try Data("{\n  \"theme\": \"dark\"\n}\n".utf8).write(to: URL(fileURLWithPath: openCodeRoot + "/opencode.json"))
        try OpenCodeConfigManager.enableIPC(port: 41830, token: "t", configDir: openCodeRoot)
        XCTAssertTrue(OpenCodeConfigManager.isIPCEnabled(configDir: openCodeRoot))
        let openCodeJSON = try String(contentsOfFile: openCodeRoot + "/opencode.json", encoding: .utf8)
        XCTAssertTrue(openCodeJSON.contains("calyx-mcp"), "OpenCodeConfigManager: precondition -- enable must write calyx-mcp")
        try OpenCodeConfigManager.disableIPC(configDir: openCodeRoot)
        XCTAssertFalse(OpenCodeConfigManager.isIPCEnabled(configDir: openCodeRoot))
        let openCodeJSONAfter = try String(contentsOfFile: openCodeRoot + "/opencode.json", encoding: .utf8)
        XCTAssertFalse(openCodeJSONAfter.contains("calyx-mcp"), "OpenCodeConfigManager: disable must remove calyx-mcp")
    }
}
