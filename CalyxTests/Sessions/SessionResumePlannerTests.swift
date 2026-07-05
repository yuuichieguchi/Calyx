//
//  SessionResumePlannerTests.swift
//  CalyxTests
//
//  TDD Red Phase for `SessionResumePlanner`: the pure-function layer
//  that formats an agent CLI's resume command and the meta-key
//  convention `AgentSessionMetaBridge` stores an agent session ID
//  under. No I/O — matches `SessionCommandSynthesizerTests`'s
//  pure-function test style.
//
//  Coverage:
//  - resumeCommand: correct `claude --resume <id>` shape for Claude
//    Code; `nil` for an unrecognized agent kind
//  - resumeCommand: `nil` when agentSessionID is empty
//  - initialInput: no trailing newline in "propose" mode
//    (autoExecute: false); trailing newline in "auto-execute" mode
//    (autoExecute: true)
//  - initialInput: `nil` when the underlying resumeCommand is `nil`
//  - encodeMetaKey/decodeMetaKey round-trip; decodeMetaKey rejects a
//    key without the "agent." namespace
//

import XCTest
@testable import Calyx

final class SessionResumePlannerTests: XCTestCase {

    // MARK: - resumeCommand

    func test_resumeCommand_claudeCode_buildsExpectedShape() {
        let command = SessionResumePlanner.resumeCommand(
            agentKind: AgentEntry.claudeCodeKind,
            agentSessionID: "abc-123-session-id"
        )

        XCTAssertEqual(command, "claude --resume abc-123-session-id",
                       "resumeCommand for Claude Code must be exactly 'claude --resume <id>'")
    }

    func test_resumeCommand_unrecognizedAgentKind_returnsNil() {
        let command = SessionResumePlanner.resumeCommand(agentKind: "some-unknown-cli", agentSessionID: "abc-123")

        XCTAssertNil(command, "An agent kind with no known resume command must return nil")
    }

    func test_resumeCommand_emptyAgentSessionID_returnsNil() {
        let command = SessionResumePlanner.resumeCommand(agentKind: AgentEntry.claudeCodeKind, agentSessionID: "")

        XCTAssertNil(command, "An empty/invalid agentSessionID must return nil, never a malformed command")
    }

    // MARK: - initialInput

    func test_initialInput_proposeMode_hasNoTrailingNewline() {
        let input = SessionResumePlanner.initialInput(
            agentKind: AgentEntry.claudeCodeKind, agentSessionID: "abc-123", autoExecute: false
        )

        XCTAssertEqual(input, "claude --resume abc-123",
                       "Propose mode (autoExecute: false) must inject the command with no trailing newline, " +
                       "so the user presses Return themselves")
    }

    func test_initialInput_autoExecuteMode_hasTrailingNewline() {
        let input = SessionResumePlanner.initialInput(
            agentKind: AgentEntry.claudeCodeKind, agentSessionID: "abc-123", autoExecute: true
        )

        XCTAssertEqual(input, "claude --resume abc-123\n",
                       "Auto-execute mode (autoExecute: true) must inject the command with a trailing newline")
    }

    func test_initialInput_unresolvableResumeCommand_returnsNil() {
        let input = SessionResumePlanner.initialInput(agentKind: "unknown-cli", agentSessionID: "abc-123", autoExecute: false)

        XCTAssertNil(input, "initialInput must be nil whenever the underlying resumeCommand is nil")
    }

    // MARK: - encodeMetaKey / decodeMetaKey

    func test_encodeMetaKey_claudeCode_producesNamespacedKey() {
        XCTAssertEqual(SessionResumePlanner.encodeMetaKey(kind: AgentEntry.claudeCodeKind), "agent.claude-code")
    }

    func test_decodeMetaKey_roundTripsWithEncodeMetaKey() {
        let key = SessionResumePlanner.encodeMetaKey(kind: AgentEntry.codexKind)

        XCTAssertEqual(SessionResumePlanner.decodeMetaKey(key), AgentEntry.codexKind,
                       "decodeMetaKey must invert encodeMetaKey for every kind")
    }

    func test_decodeMetaKey_keyWithoutAgentNamespace_returnsNil() {
        XCTAssertNil(SessionResumePlanner.decodeMetaKey("some.other.key"),
                    "A meta key outside the 'agent.' namespace must not be misparsed as an agent kind")
    }
}
