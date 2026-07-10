//
//  AgentHookPermissionResponseTests.swift
//  CalyxTests
//
//  TDD Red Phase for AgentHookPermissionResponse.body(kind:decision:):
//  the PreToolUse hook stdout body Calyx writes back to a CLI agent to
//  carry a human's approval decision into that CLI's own permission
//  gate -- shape and field names follow Claude Code's own hook-response
//  contract (hookSpecificOutput.permissionDecision), which Codex also
//  understands for allow/deny; Codex has no "ask" analog, so an expired
//  decision there prints nothing at all.
//
//  Coverage:
//  - claude-code: allowed/denied/expired each produce a
//    hookSpecificOutput.permissionDecision of "allow"/"deny"/"ask", with
//    hookEventName "PreToolUse" and a non-empty permissionDecisionReason
//  - codex: allowed/denied produce the same allow/deny shape; expired
//    produces nil (no hook stdout at all)
//  - any kind other than claude-code/codex produces nil for every
//    decision -- Calyx must never inject a decision into a CLI it
//    doesn't recognize
//
//  Bodies are re-parsed with JSONSerialization and asserted field by
//  field -- never by string equality, since key order in the serialized
//  JSON is unspecified.
//

import XCTest
@testable import Calyx

final class AgentHookPermissionResponseTests: XCTestCase {

    // MARK: - Helpers

    private func hookSpecificOutput(_ data: Data) throws -> [String: Any] {
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(object["hookSpecificOutput"] as? [String: Any])
    }

    private func assertPermissionDecision(
        kind: String,
        decision: ApprovalDecision,
        expectedPermissionDecision: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let data = try XCTUnwrap(
            AgentHookPermissionResponse.body(kind: kind, decision: decision),
            file: file, line: line
        )
        let output = try hookSpecificOutput(data)

        XCTAssertEqual(output["hookEventName"] as? String, "PreToolUse", file: file, line: line)
        XCTAssertEqual(output["permissionDecision"] as? String, expectedPermissionDecision, file: file, line: line)

        let reason = try XCTUnwrap(output["permissionDecisionReason"] as? String, file: file, line: line)
        XCTAssertFalse(reason.isEmpty, "permissionDecisionReason must be non-empty", file: file, line: line)
    }

    // MARK: - claude-code

    func test_body_claude_allowed_isAllowJSON() throws {
        try assertPermissionDecision(kind: AgentEntry.claudeCodeKind, decision: .allowed, expectedPermissionDecision: "allow")
    }

    func test_body_claude_denied_isDenyJSON() throws {
        try assertPermissionDecision(kind: AgentEntry.claudeCodeKind, decision: .denied, expectedPermissionDecision: "deny")
    }

    func test_body_claude_expired_isAskJSON() throws {
        try assertPermissionDecision(kind: AgentEntry.claudeCodeKind, decision: .expired, expectedPermissionDecision: "ask")
    }

    // MARK: - codex

    func test_body_codex_allowed_isAllowJSON() throws {
        try assertPermissionDecision(kind: AgentEntry.codexKind, decision: .allowed, expectedPermissionDecision: "allow")
    }

    func test_body_codex_denied_isDenyJSON() throws {
        try assertPermissionDecision(kind: AgentEntry.codexKind, decision: .denied, expectedPermissionDecision: "deny")
    }

    func test_body_codex_expired_isNil() {
        XCTAssertNil(AgentHookPermissionResponse.body(kind: AgentEntry.codexKind, decision: .expired),
                    "Codex has no 'ask' analog -- an expired decision must print nothing to its hook stdout")
    }

    // MARK: - unrecognized kind

    func test_body_unknownKind_isNilForAllDecisions() {
        let unknownKind = "some-unrecognized-cli"

        XCTAssertNil(AgentHookPermissionResponse.body(kind: unknownKind, decision: .allowed))
        XCTAssertNil(AgentHookPermissionResponse.body(kind: unknownKind, decision: .denied))
        XCTAssertNil(AgentHookPermissionResponse.body(kind: unknownKind, decision: .expired))
    }
}
