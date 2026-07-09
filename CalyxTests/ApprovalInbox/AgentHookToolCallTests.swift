//
//  AgentHookToolCallTests.swift
//  CalyxTests
//
//  TDD Red Phase for AgentHookToolCall.decode(from:): parses a CLI
//  agent's PreToolUse hook stdin JSON (tool_name / tool_input) into the
//  toolName/payload/summary trio the approval inbox needs to render a
//  banner for a non-MCP agent hook call -- mirrors AgentEvent.decode's
//  JSONSerialization-based style (see AgentEventTests.swift).
//
//  Coverage:
//  - Bash/Write/Edit/Read/NotebookEdit/WebFetch each derive `summary`
//    from their own well-known tool_input key
//  - an unrecognized tool_name, or a recognized one missing its expected
//    key, falls back to the compact JSON of tool_input
//  - tool_name is mandatory; empty/non-string/missing values reject the
//    payload
//  - tool_input is optional; its absence yields an empty payload/summary
//  - payload is capped at maxPayloadBytes UTF-8 bytes, truncated on a
//    character boundary; summary is capped at maxSummaryLength characters
//  - unknown extra top-level fields are tolerated
//  - malformed JSON is rejected
//

import XCTest
@testable import Calyx

final class AgentHookToolCallTests: XCTestCase {

    // MARK: - Helpers

    private func json(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    private func compactJSON(_ object: [String: Any]) throws -> String {
        try XCTUnwrap(String(data: try JSONSerialization.data(withJSONObject: object), encoding: .utf8))
    }

    /// Truncates `text` to at most `cap` UTF-8 bytes without ever
    /// splitting a `Character` -- the same "character boundary" contract
    /// AgentHookToolCall.payload is specced to uphold, computed here
    /// independently of the decoder under test.
    private func truncatedToByteCap(_ text: String, cap: Int) -> String {
        var result = ""
        var byteCount = 0
        for character in text {
            let characterByteCount = String(character).utf8.count
            guard byteCount + characterByteCount <= cap else { break }
            result.append(character)
            byteCount += characterByteCount
        }
        return result
    }

    // MARK: - summary derivation per tool_name

    func test_decode_bashTool_summaryIsCommandString() throws {
        let data = json(["tool_name": "Bash", "tool_input": ["command": "ls -la /tmp"]])

        let call = try XCTUnwrap(AgentHookToolCall.decode(from: data))

        XCTAssertEqual(call.toolName, "Bash")
        XCTAssertEqual(call.summary, "ls -la /tmp")
    }

    func test_decode_writeTool_summaryIsFilePath() throws {
        for toolName in ["Write", "Edit", "Read", "NotebookEdit"] {
            let data = json(["tool_name": toolName, "tool_input": ["file_path": "/Users/dev/repo/file.swift"]])

            let call = try XCTUnwrap(AgentHookToolCall.decode(from: data), "tool_name=\(toolName)")

            XCTAssertEqual(call.toolName, toolName, "tool_name=\(toolName)")
            XCTAssertEqual(call.summary, "/Users/dev/repo/file.swift", "tool_name=\(toolName)")
        }
    }

    func test_decode_webFetchTool_summaryIsURL() throws {
        let data = json(["tool_name": "WebFetch", "tool_input": ["url": "https://example.com/docs"]])

        let call = try XCTUnwrap(AgentHookToolCall.decode(from: data))

        XCTAssertEqual(call.summary, "https://example.com/docs")
    }

    // MARK: - fallback to compact JSON of tool_input

    func test_decode_unknownTool_summaryIsCompactJSONOfToolInput() throws {
        let toolInput: [String: Any] = ["foo": "bar"]
        let data = json(["tool_name": "SomeFutureUnknownTool", "tool_input": toolInput])

        let call = try XCTUnwrap(AgentHookToolCall.decode(from: data))

        let expected = try compactJSON(toolInput)
        XCTAssertEqual(call.summary, expected)
        XCTAssertFalse(call.summary.contains("\n"), "summary must be compact JSON, never pretty-printed")
        XCTAssertEqual(call.payload, expected, "payload is also the compact JSON of tool_input")
    }

    func test_decode_bashMissingCommandKey_fallsBackToCompactJSON() throws {
        let toolInput: [String: Any] = ["foo": "bar"]
        let data = json(["tool_name": "Bash", "tool_input": toolInput])

        let call = try XCTUnwrap(AgentHookToolCall.decode(from: data))

        let expected = try compactJSON(toolInput)
        XCTAssertEqual(call.summary, expected,
                       "Bash without a tool_input.command key must fall back to compact JSON, same as an unknown tool")
    }

    // MARK: - tool_name rejection

    func test_decode_missingToolName_returnsNil() {
        let validData = json(["tool_name": "Bash", "tool_input": ["command": "ls"]])
        XCTAssertNotNil(AgentHookToolCall.decode(from: validData), "Precondition: a well-formed payload must decode")

        let data = json(["tool_input": ["command": "ls"]])
        XCTAssertNil(AgentHookToolCall.decode(from: data), "tool_name is mandatory")
    }

    func test_decode_emptyOrNonStringToolName_returnsNil() {
        let validData = json(["tool_name": "Bash", "tool_input": ["command": "ls"]])
        XCTAssertNotNil(AgentHookToolCall.decode(from: validData), "Precondition: a well-formed payload must decode")

        let emptyData = json(["tool_name": "", "tool_input": ["command": "ls"]])
        XCTAssertNil(AgentHookToolCall.decode(from: emptyData), "an empty tool_name must be rejected")

        let numericData = json(["tool_name": 42, "tool_input": ["command": "ls"]])
        XCTAssertNil(AgentHookToolCall.decode(from: numericData), "a non-string tool_name must be rejected")
    }

    // MARK: - tool_input absence

    func test_decode_missingToolInput_payloadEmpty_summaryEmpty() throws {
        let data = json(["tool_name": "Bash"])

        let call = try XCTUnwrap(AgentHookToolCall.decode(from: data))

        XCTAssertEqual(call.payload, "", "tool_input absent must yield an empty payload")
        XCTAssertEqual(call.summary, "", "tool_input absent must yield an empty summary")
    }

    // MARK: - capping

    func test_decode_payloadOverCap_truncatedAtCharacterBoundary() throws {
        // "あ" is 3 UTF-8 bytes; {"data":"<N x あ>"} makes the raw
        // byte-16384 cut point land mid-character, since 16384 minus the
        // 9-byte `{"data":"` prefix (16375) is not a multiple of 3 --
        // proving the cap backs off to a whole character instead of
        // splitting one.
        let repeatCount = 6_000
        let bigValue = String(repeating: "あ", count: repeatCount)
        let toolInput: [String: Any] = ["data": bigValue]
        let data = json(["tool_name": "SomeFutureUnknownTool", "tool_input": toolInput])

        let fullJSON = try compactJSON(toolInput)
        XCTAssertGreaterThan(fullJSON.utf8.count, AgentHookToolCall.maxPayloadBytes,
                            "Precondition: the fixture must actually exceed maxPayloadBytes")

        let call = try XCTUnwrap(AgentHookToolCall.decode(from: data))

        XCTAssertLessThanOrEqual(call.payload.utf8.count, AgentHookToolCall.maxPayloadBytes,
                                "payload must never exceed maxPayloadBytes")

        let expected = truncatedToByteCap(fullJSON, cap: AgentHookToolCall.maxPayloadBytes)
        XCTAssertEqual(call.payload, expected,
                       "payload must be the full compact JSON truncated to the byte cap on a character boundary")
    }

    func test_decode_summaryOverCap_truncatedTo500Chars() throws {
        let longCommand = String(repeating: "a", count: AgentHookToolCall.maxSummaryLength + 100)
        let data = json(["tool_name": "Bash", "tool_input": ["command": longCommand]])

        let call = try XCTUnwrap(AgentHookToolCall.decode(from: data))

        XCTAssertEqual(call.summary.count, AgentHookToolCall.maxSummaryLength)
        XCTAssertEqual(call.summary, String(longCommand.prefix(AgentHookToolCall.maxSummaryLength)))
    }

    // MARK: - tolerance / malformed input

    func test_decode_toleratesUnknownFields() throws {
        let data = json([
            "tool_name": "Bash",
            "tool_input": ["command": "pwd"],
            "hook_event_name": "PreToolUse",
            "an_unknown_future_field": ["nested": [1, 2, 3]],
        ])

        let call = try XCTUnwrap(AgentHookToolCall.decode(from: data))

        XCTAssertEqual(call.toolName, "Bash")
        XCTAssertEqual(call.summary, "pwd")
    }

    func test_decode_malformedJSON_returnsNil() {
        let validData = json(["tool_name": "Bash", "tool_input": ["command": "ls"]])
        XCTAssertNotNil(AgentHookToolCall.decode(from: validData), "Precondition: a well-formed payload must decode")

        let data = Data("this is not { json".utf8)
        XCTAssertNil(AgentHookToolCall.decode(from: data))
    }
}
