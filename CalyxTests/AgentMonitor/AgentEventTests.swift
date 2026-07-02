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

    // MARK: - displayName(forKind:) — Phase 2 (Codex / OpenCode)

    func test_displayName_codexKind_returnsCodex() {
        XCTAssertEqual(AgentEntry.displayName(forKind: "codex"), "Codex")
    }

    func test_displayName_openCodeKind_returnsOpenCode() {
        XCTAssertEqual(AgentEntry.displayName(forKind: "opencode"), "OpenCode")
    }

    // MARK: - ipcSelfPeerID extraction (Round 3: unread message badges)
    //
    // A PreToolUse for one of Calyx's own mcp__calyx-ipc__* tools carries
    // this surface's own peer ID in tool_input — AgentRegistry uses it to
    // learn the surface-to-peer binding that drives unread badges.

    func test_decode_preToolUse_sendMessage_extractsIpcSelfPeerIDFromFrom() throws {
        let data = json("""
        {
            "session_id": "abc-123",
            "hook_event_name": "PreToolUse",
            "tool_name": "mcp__calyx-ipc__send_message",
            "tool_input": {
                "from": "11111111-1111-1111-1111-111111111111",
                "to": "22222222-2222-2222-2222-222222222222",
                "content": "hi"
            }
        }
        """)

        let event = try XCTUnwrap(AgentEvent.decode(from: data))

        XCTAssertEqual(event.ipcSelfPeerID, "11111111-1111-1111-1111-111111111111",
                       "PreToolUse for send_message must extract the sender's own peer ID from tool_input.from")
    }

    func test_decode_preToolUse_broadcast_extractsIpcSelfPeerIDFromFrom() throws {
        let data = json("""
        {
            "session_id": "abc-123",
            "hook_event_name": "PreToolUse",
            "tool_name": "mcp__calyx-ipc__broadcast",
            "tool_input": {
                "from": "33333333-3333-3333-3333-333333333333",
                "content": "announcement"
            }
        }
        """)

        let event = try XCTUnwrap(AgentEvent.decode(from: data))

        XCTAssertEqual(event.ipcSelfPeerID, "33333333-3333-3333-3333-333333333333",
                       "PreToolUse for broadcast must extract the sender's own peer ID from tool_input.from")
    }

    func test_decode_preToolUse_receiveMessages_extractsIpcSelfPeerIDFromPeerID() throws {
        let data = json("""
        {
            "session_id": "abc-123",
            "hook_event_name": "PreToolUse",
            "tool_name": "mcp__calyx-ipc__receive_messages",
            "tool_input": {
                "peer_id": "44444444-4444-4444-4444-444444444444"
            }
        }
        """)

        let event = try XCTUnwrap(AgentEvent.decode(from: data))

        XCTAssertEqual(event.ipcSelfPeerID, "44444444-4444-4444-4444-444444444444",
                       "PreToolUse for receive_messages must extract this surface's own peer ID from tool_input.peer_id")
    }

    func test_decode_preToolUse_ackMessages_extractsIpcSelfPeerIDFromPeerID() throws {
        let data = json("""
        {
            "session_id": "abc-123",
            "hook_event_name": "PreToolUse",
            "tool_name": "mcp__calyx-ipc__ack_messages",
            "tool_input": {
                "peer_id": "55555555-5555-5555-5555-555555555555",
                "message_ids": ["m1", "m2"]
            }
        }
        """)

        let event = try XCTUnwrap(AgentEvent.decode(from: data))

        XCTAssertEqual(event.ipcSelfPeerID, "55555555-5555-5555-5555-555555555555",
                       "PreToolUse for ack_messages must extract this surface's own peer ID from tool_input.peer_id")
    }

    func test_decode_preToolUse_nonCalyxIPCToolAndMissingToolInput_ipcSelfPeerIDIsNil() throws {
        // Sanity: a calyx-ipc send_message PreToolUse must actually
        // extract a peer ID — otherwise the nil assertions below would be
        // indistinguishable from a decoder that never populates
        // ipcSelfPeerID at all.
        let calyxData = json("""
        {
            "hook_event_name": "PreToolUse",
            "tool_name": "mcp__calyx-ipc__send_message",
            "tool_input": {"from": "66666666-6666-6666-6666-666666666666", "to": "x", "content": "y"}
        }
        """)
        let calyxEvent = try XCTUnwrap(AgentEvent.decode(from: calyxData))
        XCTAssertEqual(calyxEvent.ipcSelfPeerID, "66666666-6666-6666-6666-666666666666",
                       "Precondition: a calyx-ipc PreToolUse must populate ipcSelfPeerID")

        let bashData = json("""
        { "hook_event_name": "PreToolUse", "tool_name": "Bash", "tool_input": {"command": "ls"} }
        """)
        let bashEvent = try XCTUnwrap(AgentEvent.decode(from: bashData))
        XCTAssertNil(bashEvent.ipcSelfPeerID,
                    "A non-calyx-ipc tool_name must never populate ipcSelfPeerID, even with an unrelated tool_input")

        let missingInputData = json("""
        { "hook_event_name": "PreToolUse", "tool_name": "mcp__calyx-ipc__send_message" }
        """)
        let missingInputEvent = try XCTUnwrap(AgentEvent.decode(from: missingInputData))
        XCTAssertNil(missingInputEvent.ipcSelfPeerID,
                    "A calyx-ipc tool_name with no tool_input at all must decode ipcSelfPeerID as nil, not crash")
    }
}
