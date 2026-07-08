//
//  CalyxMCPServerLSPIntegrationTests.swift
//  CalyxTests
//
//  Integration tests for the merge of the LSP tool surface (MCPLSPBridge)
//  into the existing IPC-flavoured MCP server (CalyxMCPServer / MCPRouter).
//
//  Scope:
//  - MCPRouter advertises both IPC tools (7) and LSP tools (54) via
//    `MCPRouter.allTools` (61 total), and exposes `lspTools` separately
//    for callers that only need the LSP catalogue.
//  - `MCPRouter.isLSPTool(name:)` correctly classifies tool names by the
//    `lsp_` prefix.
//  - `tools/list` responses include the LSP tools alongside the IPC tools.
//  - `MCPRouter.instructions` mentions the LSP tool surface so MCP clients
//    can discover the new capability.
//  - `CalyxMCPServer.lspBridge` is `nil` until `startLSP()` runs.
//  - After `startLSP()` the server holds a live `MCPLSPBridge`.
//  - `_testInjectLSPBridge(_:)` replaces the bridge for DI in tests.
//  - `handleJSONRPC(tools/call)` routes `lsp_*` calls to the injected
//    bridge, returning the bridge's `MCPContent` as the tool call result.
//  - Unknown `lsp_*` tools surface a structured `isError` response.
//  - Existing IPC tool calls (e.g. `register_peer`) continue to dispatch
//    against `IPCStore` after the bridge is wired in.
//  - Calling an LSP tool before `startLSP()` returns a structured error
//    instead of crashing.
//
//  TDD phase: RED. None of the symbols below
//  (`MCPRouter.lspTools`, `MCPRouter.allTools`, `MCPRouter.isLSPTool`,
//  `CalyxMCPServer.lspBridge`, `CalyxMCPServer.startLSP()`,
//  `CalyxMCPServer._testInjectLSPBridge(_:)`) exist yet. This file is
//  expected to fail compilation until swift-specialist adds them in
//  `Calyx/Features/IPC/MCPProtocol.swift` and
//  `Calyx/Features/IPC/CalyxMCPServer.swift`. Once implemented, every
//  test below must pass without touching the surrounding files in this
//  directory.
//

import XCTest
@testable import Calyx

// MARK: - file-private region-detaching helper

/// Deserialize JSON into a fresh `[String: Any]` whose region is independent
/// of any caller-held value. Used to bridge non-`Sendable` `[String: Any]`
/// values across actor boundaries in tests by way of a `Sendable` `Data`
/// payload.
fileprivate func freshDict(fromJSON data: Data) -> sending [String: Any] {
    (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
}

// MARK: - fake LSP server driver (cloned from MCPLSPBridgeTests pattern)

/// Stand-in `LSPSessionFactory` that auto-replies to `initialize`,
/// `shutdown`, and a configurable set of LSP request methods. The
/// surrounding test injects this driver into an `LSPService` instance,
/// then constructs an `MCPLSPBridge` around the service so the
/// `CalyxMCPServer` can dispatch real `lsp_*` tool calls without a
/// running language server.
fileprivate actor LSPIntegrationServerDriver: LSPSessionFactory {

    private var methodReplies: [String: String] = [:]
    private var methodErrors: [String: (code: Int, message: String)] = [:]
    private var paramsCaptured: [String: [[String: Any]]] = [:]
    private(set) var clientsMade: Int = 0
    private var transports: [InMemoryLSPTransport] = []
    private var sidecars: [Task<Void, Never>] = []

    init() {}

    func setReply(method: String, jsonResult: String) {
        methodReplies[method] = jsonResult
    }

    func setError(method: String, code: Int, message: String) {
        methodErrors[method] = (code, message)
    }

    func capturedParams(forMethod method: String) -> sending [[String: Any]] {
        let captured = paramsCaptured[method] ?? []
        guard let data = try? JSONSerialization.data(withJSONObject: captured) else {
            return []
        }
        let bytes: [UInt8] = Array(data)
        let fresh = Data(bytes)
        guard let arr = try? JSONSerialization.jsonObject(with: fresh) as? [[String: Any]] else {
            return []
        }
        return arr
    }

    func makeClient(
        executable: String,
        arguments: [String],
        environment: [String: String]?,
        workingDirectory: URL?
    ) async throws -> LSPClient {
        clientsMade += 1
        let transport = InMemoryLSPTransport()
        transports.append(transport)
        let client = LSPClient(transport: transport)
        let sidecar = Task { [weak self] in
            guard let self else { return }
            await Self.driveServerReplies(on: transport, driver: self)
        }
        sidecars.append(sidecar)
        return client
    }

    fileprivate func consumeReply(forMethod method: String) -> String? {
        guard let json = methodReplies[method] else { return nil }
        methodReplies[method] = nil
        return json
    }

    fileprivate func consumeError(forMethod method: String) -> (code: Int, message: String)? {
        guard let err = methodErrors[method] else { return nil }
        methodErrors[method] = nil
        return err
    }

    fileprivate func recordParams(method: String, params: sending [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: params),
              let copy = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        paramsCaptured[method, default: []].append(copy)
    }

    private static func driveServerReplies(
        on transport: InMemoryLSPTransport,
        driver: LSPIntegrationServerDriver
    ) async {
        var answeredIds: Set<Int> = []

        for _ in 0..<4000 {
            let sent = await transport.sentMessages()
            for data in sent {
                guard let dict = parseFramedJSON(data) else { continue }
                guard let id = extractId(dict["id"]) else { continue }
                if answeredIds.contains(id) { continue }
                guard let method = dict["method"] as? String else { continue }

                if method == "initialize" {
                    let resp = #"{"jsonrpc":"2.0","id":\#(id),"result":{"capabilities":{},"serverInfo":{"name":"mock-lsp"}}}"#
                    await transport.simulateServerMessage(lspFrame(resp))
                    answeredIds.insert(id)
                    continue
                }
                if method == "shutdown" {
                    let resp = #"{"jsonrpc":"2.0","id":\#(id),"result":null}"#
                    await transport.simulateServerMessage(lspFrame(resp))
                    answeredIds.insert(id)
                    continue
                }

                if let p = dict["params"] as? [String: Any] {
                    if let data = try? JSONSerialization.data(withJSONObject: p) {
                        await driver.recordParams(
                            method: method,
                            params: freshDict(fromJSON: data)
                        )
                    } else {
                        await driver.recordParams(method: method, params: [:])
                    }
                } else {
                    await driver.recordParams(method: method, params: [:])
                }

                if let err = await driver.consumeError(forMethod: method) {
                    let escaped = err.message.replacingOccurrences(of: "\"", with: "\\\"")
                    let resp = #"{"jsonrpc":"2.0","id":\#(id),"error":{"code":\#(err.code),"message":"\#(escaped)"}}"#
                    await transport.simulateServerMessage(lspFrame(resp))
                    answeredIds.insert(id)
                    continue
                }

                let resultJSON = await driver.consumeReply(forMethod: method) ?? "null"
                let resp = #"{"jsonrpc":"2.0","id":\#(id),"result":\#(resultJSON)}"#
                await transport.simulateServerMessage(lspFrame(resp))
                answeredIds.insert(id)
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private static func lspFrame(_ json: String) -> Data {
        let body = Data(json.utf8)
        var out = Data("Content-Length: \(body.count)\r\n\r\n".utf8)
        out.append(body)
        return out
    }

    private static func parseFramedJSON(_ data: Data) -> [String: Any]? {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let body = data.subdata(in: headerEnd.upperBound..<data.endIndex)
        return try? JSONSerialization.jsonObject(with: body) as? [String: Any]
    }

    private static func extractId(_ any: Any?) -> Int? {
        if let i = any as? Int { return i }
        if let n = any as? NSNumber { return n.intValue }
        if let s = any as? String { return Int(s) }
        return nil
    }
}

// MARK: - CalyxMCPServerLSPIntegrationTests

@MainActor
final class CalyxMCPServerLSPIntegrationTests: XCTestCase {

    // MARK: - Properties

    private var server: CalyxMCPServer!
    private let testToken = "lsp-integration-token"
    private let workspace = URL(fileURLWithPath: "/tmp/calyx-lsp-integration")
    private let fileURI = "file:///tmp/calyx-lsp-integration/main.ts"

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

    // MARK: - Helpers

    private func makeRequest(
        id: Int? = 1,
        method: String,
        params: [String: Any]? = nil
    ) -> Data {
        var dict: [String: Any] = ["jsonrpc": "2.0", "method": method]
        if let id { dict["id"] = id }
        if let params { dict["params"] = params }
        return try! JSONSerialization.data(withJSONObject: dict)
    }

    private func makeToolCallRequest(
        id: Int = 1,
        toolName: String,
        arguments: [String: Any]
    ) -> Data {
        return makeRequest(id: id, method: "tools/call", params: [
            "name": toolName,
            "arguments": arguments,
        ])
    }

    private func responseJSON(_ body: Data?) throws -> [String: Any] {
        let data = try XCTUnwrap(body, "Response body must not be nil")
        let obj = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(obj as? [String: Any], "Response body must be a JSON object")
    }

    private func resultFromBody(_ body: Data?) throws -> [String: Any] {
        let json = try responseJSON(body)
        return try XCTUnwrap(json["result"] as? [String: Any],
                             "Response must contain a 'result' object")
    }

    private func toolCallText(_ body: Data?) throws -> (text: String, isError: Bool) {
        let result = try resultFromBody(body)
        let content = try XCTUnwrap(result["content"] as? [[String: Any]],
                                    "Tool call result must have 'content' array")
        XCTAssertFalse(content.isEmpty, "content array must not be empty")
        let text = try XCTUnwrap(content[0]["text"] as? String,
                                 "First content item must have 'text' string")
        let isError = result["isError"] as? Bool ?? false
        return (text, isError)
    }

    private func toolCallJSON(_ body: Data?) throws -> (json: [String: Any], isError: Bool) {
        let (text, isError) = try toolCallText(body)
        let data = Data(text.utf8)
        let obj = try JSONSerialization.jsonObject(with: data)
        let dict = try XCTUnwrap(obj as? [String: Any],
                                 "Tool call text should be parseable JSON object")
        return (dict, isError)
    }

    /// Build an `LSPInstaller` whose runner reports the
    /// `typescript-language-server` and `npm` binaries as already on
    /// PATH so the bridge's session build does not hit the install path.
    private func makeReadyInstaller() async -> LSPInstaller {
        let runner = MockCommandRunner()
        await runner.setLocateResult(
            "typescript-language-server",
            url: URL(fileURLWithPath: "/usr/local/bin/typescript-language-server")
        )
        await runner.setLocateResult(
            "npm",
            url: URL(fileURLWithPath: "/usr/local/bin/npm")
        )
        return LSPInstaller(registry: .builtIn(), runner: runner)
    }

    /// Build a real `MCPLSPBridge` whose underlying language server is a
    /// fake driver. Returns the bridge and the driver so the test can
    /// configure replies and inspect captured params.
    private func makeBridge() async -> (bridge: MCPLSPBridge, driver: LSPIntegrationServerDriver) {
        let installer = await makeReadyInstaller()
        let driver = LSPIntegrationServerDriver()
        let service = LSPService(
            registry: .builtIn(),
            installer: installer,
            sessionFactory: driver,
            config: LSPServiceConfig()
        )
        let resolver = WorkspaceResolver(registry: .builtIn())
        let bridge = MCPLSPBridge(
            service: service,
            workspaceResolver: resolver,
            diagnosticsStore: DiagnosticsStore()
        )
        return (bridge, driver)
    }

    /// Register a peer via tools/call and return the peer ID.
    @discardableResult
    private func registerPeer(name: String, role: String = "terminal") async throws -> String {
        let data = makeToolCallRequest(toolName: "register_peer", arguments: [
            "name": name,
            "role": role,
        ])
        let (statusCode, body) = await server.handleJSONRPC(data: data, authToken: testToken)
        XCTAssertEqual(statusCode, 200, "register_peer should return 200")
        let (json, isError) = try toolCallJSON(body)
        XCTAssertFalse(isError, "register_peer should not be an error")
        let peerId = try XCTUnwrap(json["peerId"] as? String,
                                   "register_peer result must contain peerId")
        XCTAssertFalse(peerId.isEmpty, "peerId must not be empty")
        return peerId
    }

    // ==================== MCPRouter Catalogue Tests ====================

    // 1. allTools combines IPC (6) + LSP (70) + terminal_* (3) + Cockpit (3) = 82
    //    (Round 7 removed ack_messages, P3 added the terminal_* surface, P4 added the Cockpit surface).
    func test_mcpRouter_allTools_includesIPCAndLSPTools() {
        let all = MCPRouter.allTools
        XCTAssertEqual(all.count, 82,
                       "allTools must enumerate 6 IPC + 70 LSP + 3 terminal_* + 3 Cockpit = 82 tools")
        let names = Set(all.map { $0.name })
        XCTAssertTrue(names.contains("register_peer"),
                      "allTools must include the IPC tool 'register_peer'")
        XCTAssertTrue(names.contains("send_message"),
                      "allTools must include the IPC tool 'send_message'")
        XCTAssertTrue(names.contains("lsp_hover"),
                      "allTools must include the LSP tool 'lsp_hover'")
        XCTAssertTrue(names.contains("lsp_completion"),
                      "allTools must include the LSP tool 'lsp_completion'")
    }

    // 2. lspTools is the 70-tool LSP catalogue.
    func test_mcpRouter_lspTools_count_is10() {
        let lsp = MCPRouter.lspTools
        XCTAssertEqual(lsp.count, 70,
                       "MCPRouter.lspTools must expose exactly 70 LSP tools")
        let names = Set(lsp.map { $0.name })
        let expected: Set<String> = [
            "lsp_hover",
            "lsp_definition",
            "lsp_declaration",
            "lsp_type_definition",
            "lsp_implementation",
            "lsp_references",
            "lsp_document_highlight",
            "lsp_document_symbol",
            "lsp_workspace_symbol",
            "lsp_completion",
            "lsp_signature_help",
            "lsp_prepare_rename",
            "lsp_rename",
            "lsp_code_action",
            "lsp_diagnostics",
            "lsp_check_installation",
            "lsp_install",
            "lsp_install_status",
            "lsp_session_status",
            "lsp_session_warmup",
            "lsp_session_shutdown",
            "lsp_call_hierarchy_prepare",
            "lsp_call_hierarchy_incoming",
            "lsp_call_hierarchy_outgoing",
            "lsp_type_hierarchy_prepare",
            "lsp_type_hierarchy_supertypes",
            "lsp_type_hierarchy_subtypes",
            "lsp_moniker",
            "lsp_code_lens",
            "lsp_code_lens_resolve",
            "lsp_inlay_hint",
            "lsp_inlay_hint_resolve",
            "lsp_inline_value",
            "lsp_folding_range",
            "lsp_selection_range",
            "lsp_semantic_tokens_full",
            "lsp_semantic_tokens_range",
            "lsp_semantic_tokens_delta",
            "lsp_linked_editing_range",
            "lsp_document_link",
            "lsp_document_link_resolve",
            "lsp_document_color",
            "lsp_color_presentation",
            "lsp_completion_resolve",
            "lsp_code_action_resolve",
            "lsp_formatting",
            "lsp_range_formatting",
            "lsp_on_type_formatting",
            "lsp_workspace_symbol_resolve",
            "lsp_workspace_diagnostic_pull",
            "lsp_workspace_execute_command",
            "lsp_workspace_apply_edit",
            "lsp_workspace_configuration_get",
            "lsp_workspace_configuration_set",
            "lsp_will_create_files",
            "lsp_did_create_files",
            "lsp_will_rename_files",
            "lsp_did_rename_files",
            "lsp_will_delete_files",
            "lsp_did_delete_files",
            "lsp_batch",
            "lsp_hover_bundle",
            "lsp_symbol_walk",
            "lsp_global_workspace_symbol",
            "lsp_cross_workspace_definition",
            "lsp_diagnostics_diff",
            "lsp_capabilities",
            "lsp_notebook_did_open",
            "lsp_notebook_did_change",
            "lsp_notebook_did_close",
        ]
        XCTAssertEqual(names, expected,
                       "MCPRouter.lspTools must enumerate the 70 expected LSP tool names")
    }

    // 3. isLSPTool prefix classifier.
    func test_mcpRouter_isLSPTool_returnsTrueForLSPPrefix() {
        XCTAssertTrue(MCPRouter.isLSPTool(name: "lsp_hover"),
                      "isLSPTool must return true for 'lsp_hover'")
        XCTAssertTrue(MCPRouter.isLSPTool(name: "lsp_completion"),
                      "isLSPTool must return true for 'lsp_completion'")
        XCTAssertFalse(MCPRouter.isLSPTool(name: "register_peer"),
                       "isLSPTool must return false for the IPC tool 'register_peer'")
        XCTAssertFalse(MCPRouter.isLSPTool(name: "send_message"),
                       "isLSPTool must return false for the IPC tool 'send_message'")
        XCTAssertFalse(MCPRouter.isLSPTool(name: ""),
                       "isLSPTool must return false for an empty name")
    }

    // 4. tools/list response surfaces the LSP tools.
    func test_mcpRouter_buildToolsListResponse_includesLSPTools() async throws {
        let data = makeRequest(method: "tools/list")
        let (statusCode, body) = await server.handleJSONRPC(data: data, authToken: testToken)
        XCTAssertEqual(statusCode, 200)
        let result = try resultFromBody(body)
        let tools = try XCTUnwrap(result["tools"] as? [[String: Any]],
                                  "tools/list result must contain 'tools' array")
        let names = Set(tools.compactMap { $0["name"] as? String })
        XCTAssertTrue(names.contains("lsp_hover"),
                      "tools/list must surface 'lsp_hover'")
        XCTAssertTrue(names.contains("lsp_workspace_symbol"),
                      "tools/list must surface 'lsp_workspace_symbol'")
        XCTAssertTrue(names.contains("register_peer"),
                      "tools/list must still surface the IPC tools alongside LSP tools")
        XCTAssertEqual(tools.count, 82,
                       "tools/list must enumerate all 82 (6 IPC + 70 LSP + 3 terminal_* + 3 Cockpit) tools")
    }

    // 5. instructions text mentions LSP tooling so MCP clients can discover it.
    func test_mcpProtocol_instructions_mentionsLSPTools() {
        let text = MCPRouter.instructions
        XCTAssertTrue(text.localizedCaseInsensitiveContains("lsp"),
                      "instructions must mention LSP in some form; got: \(text)")
        // At least one specific tool name should be referenced so callers
        // know which surface to invoke.
        let mentionsAnyTool = text.contains("lsp_hover")
            || text.contains("lsp_definition")
            || text.contains("lsp_completion")
            || text.contains("lsp_workspace_symbol")
        XCTAssertTrue(mentionsAnyTool,
                      "instructions must reference at least one lsp_* tool name; got: \(text)")
    }

    // ==================== Bridge Lifecycle Tests ====================

    // 6. Before startLSP(), lspBridge is nil.
    func test_calyxMCPServer_lspBridge_isNilBeforeStartLSP() {
        XCTAssertNil(server.lspBridge,
                     "lspBridge must be nil before startLSP() is called")
    }

    // 7. After startLSP(), lspBridge is non-nil.
    func test_calyxMCPServer_startLSP_initializesBridge() async {
        await server.startLSP()
        XCTAssertNotNil(server.lspBridge,
                        "startLSP() must initialise a live MCPLSPBridge")
    }

    // 8. _testInjectLSPBridge swaps the bridge for DI.
    func test_calyxMCPServer_testInjectLSPBridge_replacesBridge() async {
        let (bridge, _) = await makeBridge()
        server._testInjectLSPBridge(bridge)
        XCTAssertNotNil(server.lspBridge,
                        "_testInjectLSPBridge must populate lspBridge")
        // Identity check: the injected bridge should be the same object.
        XCTAssertTrue(server.lspBridge === bridge,
                      "_testInjectLSPBridge must store the exact instance passed in")
    }

    // ==================== Tool Dispatch Tests ====================

    // 9. tools/call with an lsp_* name routes to the injected bridge,
    //    and the bridge's MCPContent.text bubbles up as the result.
    func test_calyxMCPServer_handleConnection_lspToolCall_routesToBridge() async throws {
        // Arrange — inject a bridge with a fake driver that replies to hover.
        let (bridge, driver) = await makeBridge()
        server._testInjectLSPBridge(bridge)

        let hoverJSON = #"{"contents":{"kind":"markdown","value":"docs from bridge"}}"#
        await driver.setReply(method: "textDocument/hover", jsonResult: hoverJSON)

        let data = makeToolCallRequest(toolName: "lsp_hover", arguments: [
            "workspace_root": workspace.path,
            "language_id": "typescript",
            "file": fileURI,
            "line": 4,
            "column": 9,
        ])

        // Act
        let (statusCode, body) = await server.handleJSONRPC(data: data, authToken: testToken)

        // Assert
        XCTAssertEqual(statusCode, 200, "lsp_hover tool call must return HTTP 200")
        let (text, isError) = try toolCallText(body)
        XCTAssertFalse(isError, "lsp_hover should not be an error; got: \(text)")
        XCTAssertTrue(
            text.contains("\"kind\":\"markdown\"") && text.contains("\"value\":\"docs from bridge\""),
            "bridge result JSON must round-trip into the MCP tool call text; got: \(text)"
        )

        // Verify the bridge actually saw the request (uri + position).
        let captured = await driver.capturedParams(forMethod: "textDocument/hover")
        XCTAssertEqual(captured.count, 1,
                       "bridge must have dispatched exactly one hover request")
        let td = captured[0]["textDocument"] as? [String: Any]
        XCTAssertEqual(td?["uri"] as? String, fileURI,
                       "hover request must carry the file URI from the MCP arguments")
        let pos = captured[0]["position"] as? [String: Any]
        XCTAssertEqual(pos?["line"] as? Int, 4)
        XCTAssertEqual(pos?["character"] as? Int, 9)
    }

    // 10. Unknown lsp_* tool surfaces a structured error response.
    func test_calyxMCPServer_handleConnection_unknownLSPTool_returnsError() async throws {
        // Arrange
        let (bridge, _) = await makeBridge()
        server._testInjectLSPBridge(bridge)

        let data = makeToolCallRequest(toolName: "lsp_does_not_exist", arguments: [
            "workspace_root": workspace.path,
            "language_id": "typescript",
            "file": fileURI,
            "line": 0,
            "column": 0,
        ])

        // Act
        let (statusCode, body) = await server.handleJSONRPC(data: data, authToken: testToken)

        // Assert
        XCTAssertEqual(statusCode, 200,
                       "Tool errors are returned with HTTP 200 per MCP convention")
        let (text, isError) = try toolCallText(body)
        XCTAssertTrue(isError,
                      "Unknown lsp_* tool must surface as isError=true; got text=\(text)")
        XCTAssertTrue(
            text.localizedCaseInsensitiveContains("lsp_does_not_exist")
                || text.localizedCaseInsensitiveContains("unknown"),
            "Error text should identify the unknown tool; got: \(text)"
        )
    }

    // 11. Existing IPC tools continue to dispatch against IPCStore even
    //     after the LSP bridge is wired in.
    func test_calyxMCPServer_handleConnection_ipcToolCall_stillWorks() async throws {
        // Arrange — wire in a bridge.
        let (bridge, _) = await makeBridge()
        server._testInjectLSPBridge(bridge)

        // Act — register a peer via the existing IPC tool path.
        let peerId = try await registerPeer(name: "ipc-still-works")

        // Assert — list_peers should see the registered peer, proving the
        // IPC dispatch path is intact alongside the LSP dispatch path.
        let listData = makeToolCallRequest(toolName: "list_peers", arguments: [:])
        let (statusCode, body) = await server.handleJSONRPC(data: listData, authToken: testToken)
        XCTAssertEqual(statusCode, 200)
        let (json, isError) = try toolCallJSON(body)
        XCTAssertFalse(isError, "list_peers must still succeed after LSP bridge wiring")
        let peers = try XCTUnwrap(json["peers"] as? [[String: Any]],
                                  "list_peers result must contain a 'peers' array")
        let ids = Set(peers.compactMap { $0["id"] as? String })
        XCTAssertTrue(ids.contains(peerId),
                      "list_peers must surface the freshly registered peer")
    }

    /// Poll `predicate` until it returns true or `timeout` expires.
    @discardableResult
    private func waitUntil(
        timeout: TimeInterval = 3.0,
        pollInterval: TimeInterval = 0.01,
        _ predicate: () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await predicate() { return true }
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }
        return await predicate()
    }

    // 13. `stop()` tears down the injected LSP bridge: every cached
    //     session is shut down, and `server.lspBridge` is cleared so
    //     no stale reference survives the toggle. Guards against the
    //     leak where Disable AI Agent IPC left child language-server
    //     processes and FSEvents streams alive.
    func test_stop_tearsDownLSPBridge() async throws {
        // Arrange — inject a bridge wired to a fake driver and warm up a
        // session so there is something to shut down.
        let (bridge, _) = await makeBridge()
        server._testInjectLSPBridge(bridge)
        let session = try await bridge.service.session(
            for: workspace,
            languageId: "typescript"
        )
        XCTAssertEqual(session.workspaceRoot, workspace,
                       "precondition: session must be built for the test workspace")
        let before = await bridge.service.currentSessions()
        XCTAssertEqual(before.count, 1,
                       "precondition: bridge must hold exactly one cached session")

        // Act — synchronous stop schedules an async LSP teardown.
        server.stop()

        // Assert — the server clears its bridge reference immediately,
        // and the async teardown eventually drains the bridge's
        // session cache.
        XCTAssertNil(
            server.lspBridge,
            "stop() must clear server.lspBridge so a subsequent disable cannot reach a stale bridge"
        )
        let drained = await waitUntil(timeout: 3.0) {
            let infos = await bridge.service.currentSessions()
            return infos.isEmpty
        }
        XCTAssertTrue(
            drained,
            "stop() must asynchronously shut down every session previously held by the LSP bridge"
        )
    }

    // 14. `start()` immediately followed by `stop()` does not leak the
    //     LSP bridge installed by the racing `startLSP()` Task.
    //
    //     Before the post-drain re-read in `stop()`, the cleanup
    //     captured `lspBridge` synchronously (which was nil because
    //     `startLSP()` had not yet populated it) and then the racing
    //     `startLSP()` installed a brand-new `MCPLSPBridge` *after* the
    //     sync clear. The cleanup Task awaited the startup but never
    //     looked at the freshly-installed bridge — every `LSPService`,
    //     child language-server process, and FSEvents watch leaked.
    //
    //     This test drives the race directly by calling
    //     `startLSP()` and `stop()` back-to-back on `@MainActor`, then
    //     waits for the post-drain teardown to clear the cache.
    func test_stop_racingStartLSP_tearsDownBridgeBuiltAfterClear() async throws {
        // Pre-condition — fresh server, no bridge yet.
        XCTAssertNil(server.lspBridge,
                     "precondition: lspBridge must be nil before this test")

        // Act 1 — kick startLSP as an unstructured Task so it races
        // with the immediately-following stop(). Mirrors what the
        // real `start()` path does internally: it schedules
        // `Task { await startLSP() }` and returns.
        let startTask = Task { @MainActor in
            await self.server.startLSP()
        }

        // Give the Task a tiny chance to suspend on the async work
        // inside `startLSP()` (LSPInstaller actor hops, etc.). The
        // race we want is `stop()` landing *before* `startLSP()` has
        // executed `self.lspBridge = MCPLSPBridge(...)`. Without a
        // sleep here the runtime may or may not have entered the
        // startup body yet — both windows exercise the race-safety
        // contract.
        await Task.yield()

        // Act 2 — stop() while startLSP() is still in flight (or
        // about to be). The sync clear inside stop() nils any
        // currently-set bridge; the cleanup Task must re-read
        // `self.lspBridge` after the startup drains so the
        // freshly-installed bridge is also torn down.
        server.stop()

        // Sync invariant: lspBridge cleared.
        XCTAssertNil(
            server.lspBridge,
            "stop() must clear lspBridge synchronously regardless of startLSP() racing"
        )

        // Wait for the startup task to finish so we are sure
        // `self.lspBridge` has had a chance to be set by the race.
        await startTask.value

        // The cleanup Task scheduled inside stop() will eventually
        // re-read lspBridge, clear it, and shut down every session.
        // Poll until both invariants hold.
        let finalCleared = await waitUntil(timeout: 5.0) {
            let bridge = await MainActor.run { self.server.lspBridge }
            return bridge == nil
        }
        XCTAssertTrue(
            finalCleared,
            "post-drain re-read in stop() must clear lspBridge even after startLSP() raced past the sync clear"
        )
    }

    // 15. `stop()` followed by an immediate `start(B)` must NOT let the
    //     first stop's teardown Task tear down `start(B)`'s freshly
    //     installed bridge.
    //
    //     Previously the post-drain re-read inside `stop()` was
    //     identity-agnostic: after `await pendingStartup?.value` it would
    //     read whatever was in `self.lspBridge`. With this sequence:
    //
    //       1. start(A) — installs startup_A in `lspStartTask` and
    //          (eventually) bridge_A in `lspBridge`.
    //       2. stop() — snapshots pendingStartup=startup_A,
    //          pendingBridge=bridge_A, schedules teardown_1, returns.
    //       3. start(B) — installs startup_B in `lspStartTask`. Its
    //          `startLSP()` later installs bridge_B in `lspBridge`.
    //       4. teardown_1 wakes up, re-reads `self.lspBridge`, sees
    //          bridge_B, and calls `shutdownAll()` on it. start(B)'s
    //          bridge dies; `isRunning == true` but every `lsp_*` tool
    //          returns "LSP bridge is not started".
    //
    //     The fix uses `self.lspStartTask` as the identity gate. If a
    //     follow-up `start(B)` set `lspStartTask` after the sync clear,
    //     teardown_1 bails out without touching `self.lspBridge`. Only
    //     the snapshotted `preStartupBridge` (= bridge_A) is shut down.
    //
    //     This test reproduces the race directly with the
    //     `_testInjectLSPBridge` / `_testInjectLSPStartTask` hooks
    //     instead of binding a real `NWListener` port.
    func test_stopThenStart_doesNotTearDownNewBridge() async throws {
        // ---- Phase 1: build BOTH bridges up front so no `await` sits
        //               between `stop()` and the `_testInjectLSPBridge(bridgeB)`
        //               call. With awaits in that window the MainActor
        //               could yield to teardown_1 before bridge_B is
        //               injected, which would make the regression test
        //               pass for the wrong reason (teardown_1 reads nil
        //               and bails harmlessly). Pre-building keeps the
        //               race window deterministic. ----
        let (bridgeA, _) = await makeBridge()
        let (bridgeB, _) = await makeBridge()
        // Long-running startTaskB so `self.lspStartTask` is non-nil when
        // teardown_1's identity guard executes. Cancelled at the end of
        // the test so tearDown can exit cleanly. Building it pre-stop is
        // fine; the Task itself only runs once it gets scheduled.
        let startTaskB = Task<Void, Never> {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
        }

        // Warm a session on bridge_A so the preStartupBridge cleanup has
        // something observable to drain.
        let warmedA = try await bridgeA.service.session(
            for: workspace,
            languageId: "typescript"
        )
        XCTAssertEqual(warmedA.workspaceRoot, workspace,
                       "precondition: bridge_A must hold a session for the workspace")
        let bridgeABefore = await bridgeA.service.currentSessions()
        XCTAssertEqual(bridgeABefore.count, 1,
                       "precondition: bridge_A must own exactly one cached session")
        server._testInjectLSPBridge(bridgeA)
        let startTaskA = Task<Void, Never> {}
        await startTaskA.value
        server._testInjectLSPStartTask(startTaskA)

        // ---- Phase 2: stop() schedules teardown_1, then we immediately
        //               (no `await` in between) simulate start(B) by
        //               injecting startup_B + bridge_B. The order matches
        //               a real `start(token:)`: lspStartTask first, then
        //               the body installs the bridge. ----
        server.stop()
        XCTAssertNil(
            server.lspBridge,
            "sync stop() must clear lspBridge before teardown_1 fires"
        )
        server._testInjectLSPStartTask(startTaskB)
        server._testInjectLSPBridge(bridgeB)

        // ---- Phase 4: wait for teardown_1 to actually run its
        //               preStartupBridge cleanup. Observing bridge_A's
        //               session cache drain proves teardown_1 has
        //               progressed past `shutdownAll(preStartupBridge)`
        //               and is now at (or past) the identity guard.
        let drained = await waitUntil(timeout: 5.0) {
            let infos = await bridgeA.service.currentSessions()
            return infos.isEmpty
        }
        XCTAssertTrue(
            drained,
            "preStartupBridge cleanup inside teardown_1 must shut down bridge_A's session"
        )

        // Yield briefly so the synchronous guard + early-return after
        // the async `shutdownAll` has finished executing on @MainActor.
        try await Task.sleep(nanoseconds: 100_000_000)

        // ---- Phase 5: bridge_B must survive. ----
        XCTAssertNotNil(
            server.lspBridge,
            "teardown_1 from the prior stop() must not clobber the bridge installed by the racing start(B)"
        )
        XCTAssertTrue(
            server.lspBridge === bridgeB,
            "lspBridge must still be exactly bridge_B; teardown_1 should have bailed at the identity guard"
        )
        let bridgeBSessions = await bridgeB.service.currentSessions()
        XCTAssertTrue(
            bridgeBSessions.isEmpty,
            "bridge_B was freshly built so its session cache should still be empty (no spurious shutdown happened either)"
        )

        // ---- Cleanup: release startTaskB so tearDown's server.stop()
        //               does not block on a still-sleeping task. The
        //               cancel propagates through the `try?` inside the
        //               task body.
        startTaskB.cancel()
        server._testInjectLSPStartTask(nil)
    }

    // 12. Calling an lsp_* tool before startLSP() / _testInjectLSPBridge
    //     surfaces a structured error rather than crashing.
    func test_calyxMCPServer_handleConnection_lspBridgeNotStarted_returnsError() async throws {
        // Pre-condition — bridge is nil.
        XCTAssertNil(server.lspBridge,
                     "lspBridge must be nil at the start of this test")

        // Act
        let data = makeToolCallRequest(toolName: "lsp_hover", arguments: [
            "workspace_root": workspace.path,
            "language_id": "typescript",
            "file": fileURI,
            "line": 0,
            "column": 0,
        ])
        let (statusCode, body) = await server.handleJSONRPC(data: data, authToken: testToken)

        // Assert
        XCTAssertEqual(statusCode, 200,
                       "Bridge-not-started errors must follow MCP HTTP 200 convention")
        let (text, isError) = try toolCallText(body)
        XCTAssertTrue(isError,
                      "lsp_* call without bridge must surface as isError=true; got text=\(text)")
        XCTAssertFalse(text.isEmpty,
                       "Error response must carry a non-empty diagnostic text")
    }
}
