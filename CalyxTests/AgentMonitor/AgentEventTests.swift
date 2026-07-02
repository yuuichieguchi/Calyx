//
//  AgentEventTests.swift
//  CalyxTests
//
//  TDD Red Phase for AgentEvent.decode(from:): Claude Code hook stdin JSON
//  (snake_case) decoding for each hook_event_name Calyx observes.
//
//  Coverage:
//  - Real stdin JSON for each observed hook_event_name
//  - hook_event_name is mandatory; its absence rejects the payload
//  - Unknown/extra fields are tolerated
//  - Optional fields (session_id / cwd / message) may be entirely absent
//  - Malformed JSON is rejected
//

import XCTest
@testable import Calyx

final class AgentEventTests: XCTestCase {

    // MARK: - Helpers

    private func json(_ string: String) -> Data {
        Data(string.utf8)
    }

    // MARK: - Per-event decoding

    func test_decode_sessionStart_populatesFields() throws {
        let data = json("""
        {
            "session_id": "abc-123",
            "transcript_path": "/Users/dev/.claude/projects/x/abc-123.jsonl",
            "cwd": "/Users/dev/repo",
            "hook_event_name": "SessionStart",
            "source": "startup"
        }
        """)

        let event = try XCTUnwrap(AgentEvent.decode(from: data))

        XCTAssertEqual(event.hookEventName, "SessionStart")
        XCTAssertEqual(event.sessionID, "abc-123")
        XCTAssertEqual(event.cwd, "/Users/dev/repo")
    }

    func test_decode_userPromptSubmit_populatesFields() throws {
        let data = json("""
        {
            "session_id": "abc-123",
            "cwd": "/Users/dev/repo",
            "hook_event_name": "UserPromptSubmit",
            "prompt": "fix the bug"
        }
        """)

        let event = try XCTUnwrap(AgentEvent.decode(from: data))

        XCTAssertEqual(event.hookEventName, "UserPromptSubmit")
        XCTAssertEqual(event.sessionID, "abc-123")
        XCTAssertEqual(event.cwd, "/Users/dev/repo")
    }

    func test_decode_preToolUse_populatesFields() throws {
        let data = json("""
        {
            "session_id": "abc-123",
            "cwd": "/Users/dev/repo",
            "hook_event_name": "PreToolUse",
            "tool_name": "Bash",
            "tool_input": {"command": "ls"}
        }
        """)

        let event = try XCTUnwrap(AgentEvent.decode(from: data))

        XCTAssertEqual(event.hookEventName, "PreToolUse")
        XCTAssertEqual(event.sessionID, "abc-123")
    }

    func test_decode_postToolUse_populatesFields() throws {
        let data = json("""
        {
            "session_id": "abc-123",
            "cwd": "/Users/dev/repo",
            "hook_event_name": "PostToolUse",
            "tool_name": "Bash",
            "tool_response": {"stdout": "ok"}
        }
        """)

        let event = try XCTUnwrap(AgentEvent.decode(from: data))

        XCTAssertEqual(event.hookEventName, "PostToolUse")
        XCTAssertEqual(event.sessionID, "abc-123")
    }

    func test_decode_notification_populatesMessage() throws {
        let data = json("""
        {
            "session_id": "abc-123",
            "cwd": "/Users/dev/repo",
            "hook_event_name": "Notification",
            "message": "Claude needs your permission to use Bash"
        }
        """)

        let event = try XCTUnwrap(AgentEvent.decode(from: data))

        XCTAssertEqual(event.hookEventName, "Notification")
        XCTAssertEqual(event.message, "Claude needs your permission to use Bash")
    }

    func test_decode_stop_populatesFields() throws {
        let data = json("""
        {
            "session_id": "abc-123",
            "cwd": "/Users/dev/repo",
            "hook_event_name": "Stop",
            "stop_hook_active": false
        }
        """)

        let event = try XCTUnwrap(AgentEvent.decode(from: data))

        XCTAssertEqual(event.hookEventName, "Stop")
        XCTAssertEqual(event.sessionID, "abc-123")
    }

    func test_decode_sessionEnd_populatesFields() throws {
        let data = json("""
        {
            "session_id": "abc-123",
            "cwd": "/Users/dev/repo",
            "hook_event_name": "SessionEnd",
            "reason": "exit"
        }
        """)

        let event = try XCTUnwrap(AgentEvent.decode(from: data))

        XCTAssertEqual(event.hookEventName, "SessionEnd")
        XCTAssertEqual(event.sessionID, "abc-123")
    }

    func test_decode_subagentStop_populatesFields() throws {
        let data = json("""
        {
            "session_id": "abc-123",
            "cwd": "/Users/dev/repo",
            "hook_event_name": "SubagentStop",
            "stop_hook_active": false
        }
        """)

        let event = try XCTUnwrap(AgentEvent.decode(from: data))

        XCTAssertEqual(event.hookEventName, "SubagentStop")
    }

    // MARK: - Rejection / tolerance

    func test_decode_missingHookEventName_returnsNil() {
        // Sanity: a well-formed payload for the same fields must decode,
        // proving the rejection below is caused by the missing key and not
        // some other defect.
        let validData = json("""
        { "session_id": "abc-123", "cwd": "/Users/dev/repo", "hook_event_name": "UserPromptSubmit" }
        """)
        XCTAssertNotNil(AgentEvent.decode(from: validData),
                        "Precondition: a well-formed payload must decode")

        let data = json("""
        { "session_id": "abc-123", "cwd": "/Users/dev/repo" }
        """)
        XCTAssertNil(AgentEvent.decode(from: data), "hook_event_name is mandatory")
    }

    func test_decode_extraFields_areTolerated() throws {
        let data = json("""
        {
            "session_id": "abc-123",
            "cwd": "/Users/dev/repo",
            "hook_event_name": "UserPromptSubmit",
            "an_unknown_future_field": {"nested": [1, 2, 3]},
            "another_unknown_field": true
        }
        """)

        let event = try XCTUnwrap(AgentEvent.decode(from: data))

        XCTAssertEqual(event.hookEventName, "UserPromptSubmit")
    }

    func test_decode_missingOptionalFields_stillDecodes() throws {
        let data = json("""
        { "hook_event_name": "SessionStart" }
        """)

        let event = try XCTUnwrap(AgentEvent.decode(from: data))

        XCTAssertEqual(event.hookEventName, "SessionStart")
        XCTAssertNil(event.sessionID)
        XCTAssertNil(event.cwd)
        XCTAssertNil(event.message)
    }

    func test_decode_malformedJSON_returnsNil() {
        // Sanity: a well-formed payload must decode, proving the rejection
        // below is caused by the malformed JSON and not some other defect.
        let validData = json("""
        { "hook_event_name": "Stop" }
        """)
        XCTAssertNotNil(AgentEvent.decode(from: validData),
                        "Precondition: a well-formed payload must decode")

        let data = json("this is not { json")
        XCTAssertNil(AgentEvent.decode(from: data))
    }
}
