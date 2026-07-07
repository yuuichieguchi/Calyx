//
//  CommandEventDecodeTests.swift
//  CalyxTests
//
//  TDD Red Phase for CommandEvent.decode(from:): the shell integration's
//  command-lifecycle JSON payload (snake_case, base64-encoded free-text
//  fields) decoding, mirroring AgentEventTests' coverage shape for
//  AgentEvent.decode(from:).
//
//  Coverage:
//  - start / end payloads populate the expected fields
//  - phase and cmd_id are mandatory; an unrecognized phase is rejected
//  - a start event without command_b64 is rejected
//  - invalid base64 in command_b64 / cwd_b64 rejects the whole event
//  - malformed / non-JSON input is rejected
//  - unknown/extra fields are tolerated
//  - base64 round-trip preserves multiline text, quotes, backslashes,
//    emoji, and Japanese text exactly
//

import XCTest
@testable import Calyx

final class CommandEventDecodeTests: XCTestCase {

    // MARK: - Helpers

    private func json(_ string: String) -> Data {
        Data(string.utf8)
    }

    private func b64(_ string: String) -> String {
        Data(string.utf8).base64EncodedString()
    }

    // MARK: - Happy path

    func test_decode_start_populatesCommandCwdAndTimestamp() throws {
        let data = json("""
        {
            "phase": "start",
            "cmd_id": "abc-123",
            "command_b64": "\(b64("ls -la"))",
            "cwd_b64": "\(b64("/Users/dev/repo"))",
            "ts": 1700000000000
        }
        """)

        let event = try XCTUnwrap(CommandEvent.decode(from: data))

        XCTAssertEqual(event.phase, .start)
        XCTAssertEqual(event.cmdID, "abc-123")
        XCTAssertEqual(event.command, "ls -la")
        XCTAssertEqual(event.cwd, "/Users/dev/repo")
        XCTAssertEqual(event.ts, Date(timeIntervalSince1970: 1_700_000_000),
                       "ts must decode as epoch milliseconds, not epoch seconds")
    }

    func test_decode_end_requiresOnlyCmdIDPlusOptionalExitCode() throws {
        let data = json("""
        { "phase": "end", "cmd_id": "abc-123" }
        """)

        let event = try XCTUnwrap(CommandEvent.decode(from: data))

        XCTAssertEqual(event.phase, .end)
        XCTAssertEqual(event.cmdID, "abc-123")
        XCTAssertNil(event.command, "An end event carries no command_b64")
        XCTAssertNil(event.cwd, "An end event carries no cwd_b64")
        XCTAssertNil(event.exitCode, "exit_code is optional on an end event")
    }

    func test_decode_end_withExitCode_populatesExitCode() throws {
        let data = json("""
        { "phase": "end", "cmd_id": "abc-123", "exit_code": 127 }
        """)

        let event = try XCTUnwrap(CommandEvent.decode(from: data))

        XCTAssertEqual(event.exitCode, 127)
    }

    func test_decode_extraFields_areTolerated() throws {
        let data = json("""
        {
            "phase": "start",
            "cmd_id": "abc-123",
            "command_b64": "\(b64("ls"))",
            "an_unknown_future_field": {"nested": [1, 2, 3]},
            "another_unknown_field": true
        }
        """)

        let event = try XCTUnwrap(CommandEvent.decode(from: data))

        XCTAssertEqual(event.cmdID, "abc-123")
    }

    // MARK: - Rejection

    func test_decode_missingPhase_returnsNil() {
        // Sanity: a well-formed payload for the same fields must decode,
        // proving the rejection below is caused by the missing key and
        // not some other defect.
        let validData = json("""
        { "phase": "end", "cmd_id": "abc-123" }
        """)
        XCTAssertNotNil(CommandEvent.decode(from: validData),
                        "Precondition: a well-formed payload must decode")

        let data = json("""
        { "cmd_id": "abc-123" }
        """)
        XCTAssertNil(CommandEvent.decode(from: data), "phase is mandatory")
    }

    func test_decode_unknownPhase_returnsNil() {
        let validData = json("""
        { "phase": "end", "cmd_id": "abc-123" }
        """)
        XCTAssertNotNil(CommandEvent.decode(from: validData),
                        "Precondition: a well-formed payload must decode")

        let data = json("""
        { "phase": "middle", "cmd_id": "abc-123" }
        """)
        XCTAssertNil(CommandEvent.decode(from: data), "An unrecognized phase value must be rejected")
    }

    func test_decode_missingCmdID_returnsNil() {
        let validData = json("""
        { "phase": "end", "cmd_id": "abc-123" }
        """)
        XCTAssertNotNil(CommandEvent.decode(from: validData),
                        "Precondition: a well-formed payload must decode")

        let data = json("""
        { "phase": "end" }
        """)
        XCTAssertNil(CommandEvent.decode(from: data), "cmd_id is mandatory")
    }

    func test_decode_startWithoutCommandB64_returnsNil() {
        let validData = json("""
        { "phase": "start", "cmd_id": "abc-123", "command_b64": "\(b64("ls"))" }
        """)
        XCTAssertNotNil(CommandEvent.decode(from: validData),
                        "Precondition: a well-formed start payload must decode")

        let data = json("""
        { "phase": "start", "cmd_id": "abc-123" }
        """)
        XCTAssertNil(CommandEvent.decode(from: data), "A start event without command_b64 must be rejected")
    }

    func test_decode_invalidBase64InCommandB64_returnsNil() {
        let validData = json("""
        { "phase": "start", "cmd_id": "abc-123", "command_b64": "\(b64("ls"))" }
        """)
        XCTAssertNotNil(CommandEvent.decode(from: validData),
                        "Precondition: a well-formed start payload must decode")

        let data = json("""
        { "phase": "start", "cmd_id": "abc-123", "command_b64": "not-valid-base64!!!" }
        """)
        XCTAssertNil(CommandEvent.decode(from: data), "Invalid base64 in command_b64 must reject the whole event")
    }

    func test_decode_invalidBase64InCwdB64_returnsNil() {
        let validData = json("""
        {
            "phase": "start",
            "cmd_id": "abc-123",
            "command_b64": "\(b64("ls"))",
            "cwd_b64": "\(b64("/tmp"))"
        }
        """)
        XCTAssertNotNil(CommandEvent.decode(from: validData),
                        "Precondition: a well-formed start payload with cwd_b64 must decode")

        let data = json("""
        {
            "phase": "start",
            "cmd_id": "abc-123",
            "command_b64": "\(b64("ls"))",
            "cwd_b64": "not-valid-base64!!!"
        }
        """)
        XCTAssertNil(CommandEvent.decode(from: data), "Invalid base64 in cwd_b64 must reject the whole event")
    }

    func test_decode_malformedJSON_returnsNil() {
        let validData = json("""
        { "phase": "end", "cmd_id": "abc-123" }
        """)
        XCTAssertNotNil(CommandEvent.decode(from: validData),
                        "Precondition: a well-formed payload must decode")

        let data = json("this is not { json")
        XCTAssertNil(CommandEvent.decode(from: data), "Malformed / non-JSON input must be rejected")
    }

    // MARK: - Base64 round-trip

    func test_decode_base64RoundTrip_multilineCommandPreserved() throws {
        let command = "echo hello\ndone\nexit 0"
        let data = json("""
        { "phase": "start", "cmd_id": "abc-123", "command_b64": "\(b64(command))" }
        """)

        let event = try XCTUnwrap(CommandEvent.decode(from: data))

        XCTAssertEqual(event.command, command, "A multiline command must round-trip through base64 exactly")
    }

    func test_decode_base64RoundTrip_quotesAndBackslashesPreserved() throws {
        let command = #"echo "hello" 'world' C:\Users\dev\repo \\ done"#
        let data = json("""
        { "phase": "start", "cmd_id": "abc-123", "command_b64": "\(b64(command))" }
        """)

        let event = try XCTUnwrap(CommandEvent.decode(from: data))

        XCTAssertEqual(event.command, command,
                       "Single/double quotes and backslashes must round-trip through base64 exactly")
    }

    func test_decode_base64RoundTrip_emojiAndJapaneseTextPreserved() throws {
        let command = "echo 日本語テスト 🎉🚀 完了"
        let cwd = "/Users/開発者/プロジェクト"
        let data = json("""
        {
            "phase": "start",
            "cmd_id": "abc-123",
            "command_b64": "\(b64(command))",
            "cwd_b64": "\(b64(cwd))"
        }
        """)

        let event = try XCTUnwrap(CommandEvent.decode(from: data))

        XCTAssertEqual(event.command, command, "Emoji and Japanese text in command_b64 must round-trip exactly")
        XCTAssertEqual(event.cwd, cwd, "Japanese text in cwd_b64 must round-trip exactly")
    }

    // MARK: - ts plausibility

    func test_decode_tsBelowPlausibleMillisThreshold_treatedAsAbsent() throws {
        // 1700000000 looks like an epoch-SECONDS value (a plausible
        // off-by-1000 shell-integration bug), not milliseconds -- far
        // below the plausible-epoch-milliseconds threshold, and would
        // otherwise decode into a bogus early-1970s Date.
        let data = json("""
        { "phase": "end", "cmd_id": "abc-123", "ts": 1700000000 }
        """)

        let event = try XCTUnwrap(CommandEvent.decode(from: data))

        XCTAssertNil(event.ts, "A ts value implausibly small to be epoch milliseconds must decode as absent")
    }

    // MARK: - Type confusion

    func test_decode_phaseAsNumber_returnsNil() {
        let data = json("""
        { "phase": 133, "cmd_id": "abc-123" }
        """)
        XCTAssertNil(CommandEvent.decode(from: data), "A non-string phase must be rejected, not crash")
    }

    func test_decode_cmdIDAsObject_returnsNil() {
        let data = json("""
        { "phase": "end", "cmd_id": {"a": 1} }
        """)
        XCTAssertNil(CommandEvent.decode(from: data), "A non-string cmd_id must be rejected, not crash")
    }

    func test_decode_exitCodeAsString_decodesWithExitCodeAbsent() throws {
        let data = json("""
        { "phase": "end", "cmd_id": "abc-123", "exit_code": "0" }
        """)

        let event = try XCTUnwrap(CommandEvent.decode(from: data),
                                  "exit_code is optional -- a wrong-typed value must not fail the whole decode")

        XCTAssertNil(event.exitCode, "A string exit_code must not be coerced -- it decodes as absent")
    }

    func test_decode_tsAsString_decodesWithTsAbsent() throws {
        let data = json("""
        { "phase": "end", "cmd_id": "abc-123", "ts": "1700000000000" }
        """)

        let event = try XCTUnwrap(CommandEvent.decode(from: data),
                                  "ts is optional -- a wrong-typed value must not fail the whole decode")

        XCTAssertNil(event.ts, "A string ts must not be coerced -- it decodes as absent")
    }
}
