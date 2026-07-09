//
//  CalyxMCPServerCockpitToolsTests.swift
//  CalyxTests
//
//  Covers the Cockpit MCP tool surface wired into CalyxMCPServer:
//  tools/list advertises all 6 Cockpit tools, and tools/call dispatches
//  them through MCPCockpitBridge via the injected cockpitAccess --
//  mirroring CalyxMCPServerTerminalToolsTests' structure at a small
//  scale (direct handleJSONRPC calls, no real NWConnection).
//
//  Coverage:
//  - tools/list includes pane_list/pane_split/tab_create (ungated, P4)
//    and pane_run/pane_send_keys/palette_execute (human-approval gated,
//    P5), totaling 85 (6 IPC + 70 LSP + 3 terminal_* + 6 Cockpit)
//  - tools/call pane_list dispatches through the injected FakeCockpitAccess
//    and returns the panes JSON MCPCockpitBridge builds
//  - a Cockpit tool call does not trigger syncBoundPeerInboxCounts (it's
//    not in inboxSyncToolNames), unlike a calyx-ipc messaging tool call,
//    mirroring CalyxMCPServerAgentEventTests' own lsp_hover exclusion test
//  - a Cockpit-like tool name absent from MCPCockpitBridge.toolNames
//    falls through to the server's own generic "Unknown tool" error, not
//    a Cockpit-bridge-specific one
//  - server.stop() expires every pending Cockpit approval request (drains
//    approvalInbox.pending, resumes any in-flight waiter .expired)
//    rather than stranding it. Driven at the approvalInbox level
//    directly (not through a real gated tool call), so this test
//    exercises stop()'s drain behavior in isolation, independent of
//    which specific gated tool submitted the request.
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
        XCTAssertEqual(tools.count, 85,
                       "tools/list must return 6 IPC + 70 LSP + 3 terminal_* + 6 Cockpit = 85 tools")
    }

    func test_toolsList_advertises85_includesGatedTools() async throws {
        let data = makeRequest(method: "tools/list")

        let (statusCode, body) = await server.handleJSONRPC(data: data, authToken: testToken)

        XCTAssertEqual(statusCode, 200)
        let result = try resultFromBody(body)
        let tools = try XCTUnwrap(result["tools"] as? [[String: Any]])
        let names = Set(tools.compactMap { $0["name"] as? String })
        XCTAssertTrue(names.contains("pane_run"), "tools/list must surface pane_run")
        XCTAssertTrue(names.contains("pane_send_keys"), "tools/list must surface pane_send_keys")
        XCTAssertTrue(names.contains("palette_execute"), "tools/list must surface palette_execute")
        XCTAssertEqual(tools.count, 85,
                       "tools/list must return 6 IPC + 70 LSP + 3 terminal_* + 6 Cockpit = 85 tools")
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

    func test_toolsCall_unknownCockpitLikeName_fallsThroughToStandardUnknownToolError() async throws {
        // A name that looks like it could be a Cockpit tool but isn't in
        // MCPCockpitBridge.toolNames must have isCockpitTool return false
        // for it, so the call falls all the way through to the server's
        // own generic "Unknown tool" error, not a Cockpit-bridge-specific
        // unknownTool.
        let data = makeToolCallRequest(toolName: "pane_nonexistent", arguments: [:])

        let (statusCode, body) = await server.handleJSONRPC(data: data, authToken: testToken)

        XCTAssertEqual(statusCode, 200, "Tool errors are returned with HTTP 200 per MCP convention")
        let (text, isError) = try toolCallText(body)
        XCTAssertTrue(isError)
        XCTAssertTrue(text.localizedCaseInsensitiveContains("unknown tool"), "got: \(text)")
        XCTAssertTrue(text.contains("pane_nonexistent"), "got: \(text)")
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

    // MARK: - stop() drains pending approvals

    /// Driven directly at the `approvalInbox` level (see this file's
    /// header for why a route-level `pane_run` call can't exercise this
    /// meaningfully yet). `timeoutMs: 60_000` on the awaiter is
    /// deliberately far longer than this test's own runtime -- if
    /// `stop()` genuinely drains synchronously, `pending` is empty
    /// immediately after it returns, with no waiting; if it does NOT
    /// (today's stub), `pending` is still guaranteed non-empty at that
    /// same instant, since nothing else could have resolved it that
    /// fast. This avoids the alternative (asserting only the final
    /// `.expired` value after awaiting the full timeout), which would
    /// let the request's own eventual timeout accidentally produce the
    /// same end state `stop()` is supposed to produce, on a 60s delay.
    func test_serverStop_expiresPendingApprovals() async throws {
        let approvalInbox = ApprovalInboxStore()
        server.approvalInbox = approvalInbox
        let request = ApprovalRequest(
            id: UUID(), source: .mcpTool(name: "pane_run"), targetSurfaceID: UUID(),
            payload: "ls", createdAt: Date()
        )
        approvalInbox.submit(request)

        let waiter = Task { @MainActor in
            await approvalInbox.awaitDecision(id: request.id, timeoutMs: 60_000)
        }
        for _ in 0..<50 {
            await Task.yield()
        }

        server.stop()
        for _ in 0..<50 {
            await Task.yield()
        }

        XCTAssertTrue(approvalInbox.pending.isEmpty,
                      "server.stop() must synchronously drain approvalInbox.pending, not rely on the request's own 60s timeout")

        waiter.cancel()
        let result = await waiter.value
        XCTAssertEqual(result, .expired)
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
