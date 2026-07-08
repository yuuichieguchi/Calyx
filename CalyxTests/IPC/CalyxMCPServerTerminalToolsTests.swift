//
//  CalyxMCPServerTerminalToolsTests.swift
//  CalyxTests
//
//  TDD Red Phase for the terminal_* MCP tool surface wired into
//  CalyxMCPServer: tools/list advertises the 3 terminal_* tools, and
//  tools/call dispatches them through MCPCommandLogBridge via the
//  injected commandLogStore -- mirroring CalyxMCPServerLSPIntegrationTests'
//  structure at a small scale (direct handleJSONRPC calls, no HTTP
//  layer).
//
//  Coverage:
//  - tools/list includes terminal_list_commands / terminal_read_output /
//    terminal_await_command
//  - tools/call terminal_list_commands round-trips through the server
//    against the injected CommandLogStore
//  - tools/call terminal_list_commands with a missing surface_id returns
//    a structured error whose text names the missing argument (proves
//    the call actually reached MCPCommandLogBridge's own validation,
//    not just the generic "Unknown tool" fallback every unrecognized
//    tool name already falls through to)
//

import XCTest
@testable import Calyx

@MainActor
final class CalyxMCPServerTerminalToolsTests: XCTestCase {

    // MARK: - Properties

    private var server: CalyxMCPServer!
    private let testToken = "terminal-tools-token"

    // MARK: - Lifecycle

    override func setUp() {
        super.setUp()
        server = CalyxMCPServer()
        server._testSetToken(testToken)
    }

    override func tearDown() {
        server.stop()
        server = nil
        super.tearDown()
    }

    // MARK: - Helpers (mirroring CalyxMCPServerLSPIntegrationTests)

    private func makeRequest(id: Int? = 1, method: String, params: [String: Any]? = nil) -> Data {
        var dict: [String: Any] = ["jsonrpc": "2.0", "method": method]
        if let id { dict["id"] = id }
        if let params { dict["params"] = params }
        return try! JSONSerialization.data(withJSONObject: dict)
    }

    private func makeToolCallRequest(id: Int = 1, toolName: String, arguments: [String: Any]) -> Data {
        makeRequest(id: id, method: "tools/call", params: ["name": toolName, "arguments": arguments])
    }

    private func responseJSON(_ body: Data?) throws -> [String: Any] {
        let data = try XCTUnwrap(body, "Response body must not be nil")
        let obj = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(obj as? [String: Any], "Response body must be a JSON object")
    }

    private func resultFromBody(_ body: Data?) throws -> [String: Any] {
        let json = try responseJSON(body)
        return try XCTUnwrap(json["result"] as? [String: Any], "Response must contain a 'result' object")
    }

    private func toolCallText(_ body: Data?) throws -> (text: String, isError: Bool) {
        let result = try resultFromBody(body)
        let content = try XCTUnwrap(result["content"] as? [[String: Any]], "Tool call result must have 'content' array")
        XCTAssertFalse(content.isEmpty, "content array must not be empty")
        let text = try XCTUnwrap(content[0]["text"] as? String, "First content item must have 'text' string")
        let isError = result["isError"] as? Bool ?? false
        return (text, isError)
    }

    // MARK: - tools/list

    func test_toolsList_includesTerminalTools() async throws {
        let data = makeRequest(method: "tools/list")

        let (statusCode, body) = await server.handleJSONRPC(data: data, authToken: testToken)

        XCTAssertEqual(statusCode, 200)
        let result = try resultFromBody(body)
        let tools = try XCTUnwrap(result["tools"] as? [[String: Any]])
        let names = Set(tools.compactMap { $0["name"] as? String })
        XCTAssertTrue(names.contains("terminal_list_commands"), "tools/list must surface terminal_list_commands")
        XCTAssertTrue(names.contains("terminal_read_output"), "tools/list must surface terminal_read_output")
        XCTAssertTrue(names.contains("terminal_await_command"), "tools/list must surface terminal_await_command")
    }

    // MARK: - tools/call round trip

    func test_toolsCall_terminalListCommands_roundTripsThroughInjectedStore() async throws {
        let store = CommandLogStore()
        server.commandLogStore = store
        let surfaceID = UUID()
        store.ingest(
            CommandEvent(phase: .start, cmdID: "cmd-1", command: "echo hi", cwd: "/tmp", exitCode: nil, ts: nil),
            surfaceID: surfaceID
        )

        let data = makeToolCallRequest(
            toolName: "terminal_list_commands", arguments: ["surface_id": surfaceID.uuidString]
        )
        let (statusCode, body) = await server.handleJSONRPC(data: data, authToken: testToken)

        XCTAssertEqual(statusCode, 200)
        let (text, isError) = try toolCallText(body)
        XCTAssertFalse(isError, "terminal_list_commands for a resolvable surface must not be an error; got: \(text)")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let commands = try XCTUnwrap(json["commands"] as? [[String: Any]])
        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(commands.first?["cmd_id"] as? String, "cmd-1")
    }

    func test_toolsCall_terminalListCommands_missingSurfaceID_returnsErrorMentioningIt() async throws {
        let data = makeToolCallRequest(toolName: "terminal_list_commands", arguments: [:])

        let (statusCode, body) = await server.handleJSONRPC(data: data, authToken: testToken)

        XCTAssertEqual(statusCode, 200, "Tool errors are returned with HTTP 200 per MCP convention")
        let (text, isError) = try toolCallText(body)
        XCTAssertTrue(isError, "A missing surface_id must surface as isError=true; got text=\(text)")
        XCTAssertTrue(text.localizedCaseInsensitiveContains("surface_id"),
                      "The error text must name the missing argument (proves the call reached " +
                      "MCPCommandLogBridge's own validation, not just the generic 'Unknown tool' " +
                      "fallback every unrecognized name already falls through to); got: \(text)")
    }
}
