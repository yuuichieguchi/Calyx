//
//  CalyxMCPServerCockpitToolsTests.swift
//  CalyxTests
//
//  TDD Red Phase for the Cockpit MCP tool surface wired into
//  CalyxMCPServer: tools/list advertises the 3 Cockpit tools, and
//  tools/call dispatches them through MCPCockpitBridge via the
//  injected cockpitAccess -- mirroring CalyxMCPServerTerminalToolsTests'
//  structure at a small scale (direct handleJSONRPC calls, no real
//  NWConnection).
//
//  Coverage:
//  - tools/list includes pane_list / pane_split / tab_create and totals
//    82 (6 IPC + 70 LSP + 3 terminal_* + 3 Cockpit)
//  - tools/call pane_list dispatches through the injected FakeCockpitAccess
//    and returns the panes JSON MCPCockpitBridge builds
//  - a Cockpit tool call does not trigger syncBoundPeerInboxCounts (it's
//    not in inboxSyncToolNames), unlike a calyx-ipc messaging tool call,
//    mirroring CalyxMCPServerAgentEventTests' own lsp_hover exclusion test
//  - an unrecognized, cockpit-ish-looking tool name not yet in
//    MCPCockpitBridge.toolNames (pane_run, arriving in P5) falls through
//    to the server's own generic "Unknown tool" error, not a Cockpit-
//    bridge-specific one
//

import XCTest
@testable import Calyx

// MARK: - Fakes

@MainActor
private final class FakeCockpitAccess: CockpitAppAccessing {
    var panes: [CockpitPaneInfo] = []

    func listPanes() -> [CockpitPaneInfo] { panes }

    func paneExists(_ id: UUID) -> Bool { false }

    func sendCommand(surfaceID: UUID, command: String, doubleReturn: Bool) throws {}

    func sendKeys(surfaceID: UUID, text: String) throws {}

    func splitPane(surfaceID: UUID, direction: SplitDirection) throws -> UUID {
        throw CockpitAccessError.appUnavailable
    }

    func createTab(groupName: String?, cwd: String?) throws -> CockpitNewTab {
        throw CockpitAccessError.appUnavailable
    }

    func availablePaletteCommands() -> [CockpitPaletteCommand] { [] }

    func executePaletteCommand(id: String) throws -> CockpitPaletteCommand {
        throw CockpitAccessError.appUnavailable
    }
}

@MainActor
final class CalyxMCPServerCockpitToolsTests: XCTestCase {

    // MARK: - Properties

    private var server: CalyxMCPServer!
    private let testToken = "cockpit-tools-token"

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

    // MARK: - Helpers (mirroring CalyxMCPServerTerminalToolsTests)

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

    func test_toolsList_includesCockpitTools_totalsExpectedCount() async throws {
        let data = makeRequest(method: "tools/list")

        let (statusCode, body) = await server.handleJSONRPC(data: data, authToken: testToken)

        XCTAssertEqual(statusCode, 200)
        let result = try resultFromBody(body)
        let tools = try XCTUnwrap(result["tools"] as? [[String: Any]])
        let names = Set(tools.compactMap { $0["name"] as? String })
        XCTAssertTrue(names.contains("pane_list"), "tools/list must surface pane_list")
        XCTAssertTrue(names.contains("pane_split"), "tools/list must surface pane_split")
        XCTAssertTrue(names.contains("tab_create"), "tools/list must surface tab_create")
        XCTAssertEqual(tools.count, 82,
                       "tools/list must return 6 IPC + 70 LSP + 3 terminal_* + 3 Cockpit = 82 tools")
    }

    // MARK: - tools/call round trip

    func test_toolsCall_paneList_dispatchesToBridge_returnsPanesJSON() async throws {
        // Inject BEFORE the first dispatch -- lazyCockpitBridge is built
        // lazily from `cockpitAccess` on first actual Cockpit-tool
        // dispatch, so this must happen before that.
        let access = FakeCockpitAccess()
        let pane = CockpitPaneInfo(
            surfaceID: UUID(), windowID: UUID(), groupName: "Default", tabID: UUID(),
            tabTitle: "zsh", title: nil, cwd: nil, isFocused: true, agentKind: nil, calyxSessionID: nil
        )
        access.panes = [pane]
        server.cockpitAccess = access

        let data = makeToolCallRequest(toolName: "pane_list", arguments: [:])
        let (statusCode, body) = await server.handleJSONRPC(data: data, authToken: testToken)

        XCTAssertEqual(statusCode, 200)
        let (text, isError) = try toolCallText(body)
        XCTAssertFalse(isError, "pane_list must not be an error; got: \(text)")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let panes = try XCTUnwrap(json["panes"] as? [[String: Any]])
        XCTAssertEqual(panes.count, 1)
        XCTAssertEqual(panes.first?["surface_id"] as? String, pane.surfaceID.uuidString)
    }

    // MARK: - Unknown tool fallthrough

    func test_toolsCall_paneRun_notYetWired_fallsThroughToStandardUnknownToolError() async throws {
        // pane_run (P5) is not yet in MCPCockpitBridge.toolNames, so
        // isCockpitTool must return false for it and the call must fall
        // all the way through to the server's own generic "Unknown tool"
        // error, not a Cockpit-bridge-specific unknownTool.
        let data = makeToolCallRequest(toolName: "pane_run", arguments: [:])

        let (statusCode, body) = await server.handleJSONRPC(data: data, authToken: testToken)

        XCTAssertEqual(statusCode, 200, "Tool errors are returned with HTTP 200 per MCP convention")
        let (text, isError) = try toolCallText(body)
        XCTAssertTrue(isError)
        XCTAssertTrue(text.localizedCaseInsensitiveContains("unknown tool"), "got: \(text)")
        XCTAssertTrue(text.contains("pane_run"), "got: \(text)")
    }

    // MARK: - Inbox sync exclusion

    /// Mirrors `CalyxMCPServerAgentEventTests
    /// .test_agentEventBinding_lspToolCall_doesNotRefreshInboxCounts_messagingToolDoes`'s
    /// technique: bind a surface to a peer, manufacture a stale
    /// unreadCount by delivering a message directly through the shared
    /// `IPCStore` (bypassing any tool call, and therefore
    /// `syncBoundPeerInboxCounts`), then prove a Cockpit tool call does
    /// NOT refresh it (unlike a calyx-ipc messaging tool call, which
    /// does) -- i.e. Cockpit tool names are not in `inboxSyncToolNames`.
    func test_toolsCall_cockpitTool_doesNotTriggerInboxSync() async throws {
        let registry = AgentRegistry()
        server.agentRegistry = registry
        server.cockpitAccess = FakeCockpitAccess()

        let p1 = try await registerPeerID(name: "P1")
        let p2 = try await registerPeerID(name: "P2")
        let p1ID = try XCTUnwrap(UUID(uuidString: p1))
        let p2ID = try XCTUnwrap(UUID(uuidString: p2))

        let boundSurface = UUID()
        let bindingRequest = agentEventRequest(
            surfaceIDHeader: boundSurface.uuidString,
            body: Data("""
            {"hook_event_name":"PreToolUse","session_id":"s1",
             "tool_name":"mcp__calyx-ipc__send_message",
             "tool_input":{"from":"\(p1)","to":"\(p2)","content":"hi"}}
            """.utf8)
        )
        let bindingResponse = await server.route(request: bindingRequest)
        XCTAssertEqual(bindingResponse.statusCode, 204)

        _ = try await server.store.sendMessage(from: p2ID, to: p1ID, content: "hello from P2")

        let paneListRequest = makeToolCallRequest(id: 10, toolName: "pane_list", arguments: [:])
        let (paneListStatus, _) = await server.handleJSONRPC(data: paneListRequest, authToken: testToken)
        XCTAssertEqual(paneListStatus, 200)
        XCTAssertEqual(registry.entries[boundSurface]?.unreadCount, 0,
                       "A Cockpit tools/call must never trigger syncBoundPeerInboxCounts, so the " +
                       "unreadCount left stale by the direct IPCStore delivery above must stay 0")

        let statusRequest = makeToolCallRequest(id: 11, toolName: "get_peer_status", arguments: ["peer_id": p1])
        let (statusStatus, _) = await server.handleJSONRPC(data: statusRequest, authToken: testToken)
        XCTAssertEqual(statusStatus, 200)
        XCTAssertEqual(registry.entries[boundSurface]?.unreadCount, 1,
                       "A calyx-ipc messaging tools/call (get_peer_status here) must still trigger " +
                       "syncBoundPeerInboxCounts and pick up the count left stale by the earlier pane_list call")
    }

    // MARK: - Peer-binding helpers (mirrors CalyxMCPServerAgentEventTests)

    private func agentEventRequest(surfaceIDHeader: String?, body: Data?) -> HTTPRequest {
        var headers: [String: String] = ["Authorization": "Bearer \(testToken)"]
        if let surfaceIDHeader { headers["X-Calyx-Surface-ID"] = surfaceIDHeader }
        return HTTPRequest(method: "POST", path: "/agent-event", headers: headers, body: body)
    }

    private func peerID(fromToolResultBody body: Data?) throws -> String {
        let (text, _) = try toolCallText(body)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        return try XCTUnwrap(json["peerId"] as? String)
    }

    private func registerPeerID(name: String) async throws -> String {
        let request = makeToolCallRequest(id: 1, toolName: "register_peer", arguments: ["name": name, "role": "terminal"])
        let (status, body) = await server.handleJSONRPC(data: request, authToken: testToken)
        XCTAssertEqual(status, 200)
        return try peerID(fromToolResultBody: body)
    }
}
