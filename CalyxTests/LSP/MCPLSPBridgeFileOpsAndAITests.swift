//
//  MCPLSPBridgeFileOpsAndAITests.swift
//  Calyx
//
//  TDD red-phase tests for the thirteen "file operations + AI-specific" MCP
//  tools the LSP bridge will ship on top of the 54 tools (10 core + 11
//  extended + 7 hierarchy/moniker + 7 information-cluster-A + 8
//  information-cluster-B + 11 edit/workspace cluster) already routed through
//  `MCPLSPBridge`.
//
//  Tools under test (and how they reach the language server):
//      File-operations cluster (6 tools)
//        Requests (response = WorkspaceEdit?)
//          lsp_will_create_files  -> workspace/willCreateFiles
//          lsp_will_rename_files  -> workspace/willRenameFiles
//          lsp_will_delete_files  -> workspace/willDeleteFiles
//        Notifications (no response, captured via sendGenericNotification)
//          lsp_did_create_files   -> workspace/didCreateFiles
//          lsp_did_rename_files   -> workspace/didRenameFiles
//          lsp_did_delete_files   -> workspace/didDeleteFiles
//      AI-specific cluster (7 tools)
//        lsp_batch                      -> dispatches multiple bridge tools in
//                                          one round-trip
//        lsp_hover_bundle               -> textDocument/hover + textDocument/
//                                          definition + surrounding_code
//        lsp_symbol_walk                -> flattens call/type hierarchies
//                                          (stub: depth=1, call_incoming only)
//        lsp_global_workspace_symbol    -> workspace/symbol across every cached
//                                          LSPService session
//        lsp_cross_workspace_definition -> textDocument/definition (stub: same
//                                          as lsp_definition for now)
//        lsp_diagnostics_diff           -> DiagnosticsStore.diff
//        lsp_capabilities               -> CapabilityRegistry static + dynamic
//                                          snapshot
//
//  Argument-shape summary (see the JSON-schema comments in the implementation
//  for the full contract):
//    - lsp_will_create_files / lsp_did_create_files:
//        workspace_root, language_id, files: [{ uri: string }]
//    - lsp_will_rename_files / lsp_did_rename_files:
//        workspace_root, language_id, files: [{ oldUri: string, newUri: string }]
//    - lsp_will_delete_files / lsp_did_delete_files:
//        workspace_root, language_id, files: [{ uri: string }]
//    - lsp_batch:
//        requests: [{ tool: string, params: object }]
//    - lsp_hover_bundle / lsp_cross_workspace_definition:
//        positionRequestSchema (workspace_root, language_id, file, line, column)
//    - lsp_symbol_walk:
//        workspace_root, language_id, item: object,
//        direction: "call_incoming"|"call_outgoing"|"type_supertypes"|"type_subtypes",
//        depth?: int (default 3; stub honours depth=1 for call_incoming only)
//    - lsp_global_workspace_symbol:
//        query: string (workspace_root / language_id NOT required — the tool
//        iterates `LSPService.currentSessions()`)
//    - lsp_diagnostics_diff:
//        workspace_root, language_id, since_snapshot_id: int
//    - lsp_capabilities:
//        workspace_root, language_id
//
//  Special semantics:
//    - lsp_did_create_files / lsp_did_rename_files / lsp_did_delete_files MUST
//      be sent as LSP notifications (no response) via
//      `LSPSession.sendGenericNotification`. The bridge surfaces a tiny success
//      payload (e.g. `{"sent":true}`) but the test only requires that the
//      notification reach the server with the expected params.
//    - lsp_symbol_walk only supports `call_incoming` in the stub
//      implementation; the three other directions must throw
//      `MCPLSPBridgeError.invalidArgument`.
//    - lsp_capabilities MUST NOT issue any LSP request; it reads the
//      session-resident `CapabilityRegistry` directly. The driver therefore
//      sees zero method captures from this tool.
//
//  TDD phase: RED. The bridge currently advertises 54 tools and routes only
//  those. These tests are expected to fail at runtime — the catalogue
//  assertion sees 54 names instead of 67, and every `handleToolCall` for one
//  of the new tools surfaces as `MCPLSPBridgeError.unknownTool`.
//
//  Strategy notes:
//    - The fake LSP-server driver and helpers are file-private here to avoid
//      colliding with the symbols of the same name already defined in the
//      sibling bridge test files. Each test file owns its own driver
//      instance.
//    - All tests run on `@MainActor` because `MCPLSPBridge` is
//      `@MainActor`-isolated.
//    - Swift 6.2 strict concurrency: any `[String: Any]` crossing an actor
//      boundary is re-deserialised through a Sendable `Data` payload so the
//      region is fresh on the receiving side.
//    - Unlike the sibling driver, the one in this file captures both LSP
//      *requests* (id present) AND *notifications* (id absent) so the
//      did_create / did_rename / did_delete tests can assert that the
//      notification reached the server.
//

import XCTest
@testable import Calyx

// MARK: - file-private region-detaching helper

/// Deserialize JSON into a fresh `[String: Any]` whose region is independent
/// of any caller-held value. Mirrors the helpers in the sibling bridge test
/// files but is file-private so the seven files can compile side-by-side.
fileprivate func freshDictFileOpsAI(fromJSON data: Data) -> sending [String: Any] {
    (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
}

// MARK: - file-private fake LSP server driver

/// Captures every request *and notification* the bridge sends and emits a
/// configurable response for each request. The notification branch is the
/// only structural difference from the drivers in the sibling test files —
/// it records the params payload but never writes a response back to the
/// transport.
fileprivate actor FileOpsAndAIServerDriver: LSPSessionFactory {

    // MARK: - Configuration

    private var methodReplies: [String: String] = [:]
    private var methodErrors: [String: (code: Int, message: String)] = [:]

    /// Captured `params` payloads keyed by method, in arrival order. Holds
    /// both request and notification params; the test inspects this map
    /// regardless of which JSON-RPC verb the bridge used.
    private var paramsCaptured: [String: [[String: Any]]] = [:]
    /// Number of `LSPClient` instances `LSPService` has built.
    private(set) var clientsMade: Int = 0
    /// Live transports kept alive for their sidecar Tasks.
    private var transports: [InMemoryLSPTransport] = []
    /// Sidecar Tasks driving fake server replies.
    private var sidecars: [Task<Void, Never>] = []

    init() {}

    // MARK: - Test configuration API

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

    /// Total number of method calls captured across every method. Used by
    /// "no LSP request must reach the server" assertions for the
    /// bridge-internal tools.
    func totalCapturedCount() -> Int {
        paramsCaptured.values.reduce(0) { $0 + $1.count }
    }

    func clientsMadeCount() -> Int { clientsMade }

    /// Poll `paramsCaptured` until at least `count` captures for `method`
    /// arrive or `timeoutMs` elapses. Used by the notification tests, where
    /// the bridge call returns immediately (no JSON-RPC response to wait on)
    /// and the test must give the driver's sidecar a chance to drain the
    /// transport.
    func waitForCapture(
        method: String,
        atLeast count: Int = 1,
        timeoutMs: Int = 2000
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000.0)
        while Date() < deadline {
            if (paramsCaptured[method]?.count ?? 0) >= count {
                return true
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return (paramsCaptured[method]?.count ?? 0) >= count
    }

    // MARK: - LSPSessionFactory

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

    // MARK: - Actor-isolated mutators called from the sidecar

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

    // MARK: - Server simulator

    private static func driveServerReplies(
        on transport: InMemoryLSPTransport,
        driver: FileOpsAndAIServerDriver
    ) async {
        var answeredIds: Set<Int> = []
        var handledNotificationIndices: Set<Int> = []

        for _ in 0..<4000 {
            let sent = await transport.sentMessages()
            for (idx, data) in sent.enumerated() {
                guard let dict = parseFramedJSON(data) else { continue }
                guard let method = dict["method"] as? String else { continue }

                if let id = extractId(dict["id"]) {
                    // Request branch.
                    if answeredIds.contains(id) { continue }

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
                                params: freshDictFileOpsAI(fromJSON: data)
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
                } else {
                    // Notification branch — capture params, no response.
                    if handledNotificationIndices.contains(idx) { continue }
                    handledNotificationIndices.insert(idx)
                    if let p = dict["params"] as? [String: Any] {
                        if let data = try? JSONSerialization.data(withJSONObject: p) {
                            await driver.recordParams(
                                method: method,
                                params: freshDictFileOpsAI(fromJSON: data)
                            )
                        } else {
                            await driver.recordParams(method: method, params: [:])
                        }
                    } else {
                        await driver.recordParams(method: method, params: [:])
                    }
                }
            }
            try? await Task.sleep(nanoseconds: 5_000_000) // 5ms
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
        if let n = any as? NSNumber {
            // JSON-RPC notifications omit "id"; JSONSerialization may parse a
            // missing key as nil OR an explicit null. NSNull falls through
            // the `as? NSNumber` check, so only real numbers reach here.
            return n.intValue
        }
        if let s = any as? String { return Int(s) }
        return nil
    }
}

// MARK: - MCPLSPBridgeFileOpsAndAITests

@MainActor
final class MCPLSPBridgeFileOpsAndAITests: XCTestCase {

    // MARK: - Constants

    private let workspaceA = URL(fileURLWithPath: "/tmp/calyx-mcp-lsp-bridge-fileops-ai-A")
    private let fileA = "file:///tmp/calyx-mcp-lsp-bridge-fileops-ai-A/main.ts"

    // MARK: - Helpers

    /// Build an `LSPInstaller` whose runner reports the
    /// `typescript-language-server` and `npm` binaries as already on PATH.
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

    /// Spin up the bridge under test plus the server driver so the test
    /// can configure replies and inspect captured params.
    private func makeBridge() async -> (bridge: MCPLSPBridge, driver: FileOpsAndAIServerDriver) {
        let installer = await makeReadyInstaller()
        let driver = FileOpsAndAIServerDriver()
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
            installer: installer,
            diagnosticsStore: DiagnosticsStore()
        )
        return (bridge, driver)
    }

    /// Build the standard `files: [{uri}]` argument for create / will_create
    /// / delete / will_delete.
    private func filesUriArray(_ uris: [String]) -> AnyCodable {
        AnyCodable(uris.map { uri in
            AnyCodable(["uri": AnyCodable(uri)] as [String: AnyCodable])
        })
    }

    /// Build the standard `files: [{oldUri, newUri}]` argument for rename /
    /// will_rename.
    private func filesRenameArray(_ pairs: [(String, String)]) -> AnyCodable {
        AnyCodable(pairs.map { (oldUri, newUri) in
            AnyCodable([
                "oldUri": AnyCodable(oldUri),
                "newUri": AnyCodable(newUri),
            ] as [String: AnyCodable])
        })
    }

    /// Warm one LSPService session for the bridge's workspace+language so
    /// session-iterating tools (lsp_global_workspace_symbol,
    /// lsp_capabilities, lsp_diagnostics_diff) have at least one entry in
    /// `currentSessions()` to act on. Issues a single `lsp_hover` whose LSP
    /// reply is configured to be `null` — cheap, deterministic, exercises
    /// the full handshake.
    private func warmDefaultSession(
        bridge: MCPLSPBridge,
        driver: FileOpsAndAIServerDriver
    ) async throws {
        await driver.setReply(method: "textDocument/hover", jsonResult: "null")
        let args: [String: AnyCodable] = [
            "workspace_root": AnyCodable(workspaceA.path),
            "language_id": AnyCodable("typescript"),
            "file": AnyCodable(fileA),
            "line": AnyCodable(0),
            "column": AnyCodable(0),
        ]
        _ = try await bridge.handleToolCall(name: "lsp_hover", arguments: args)
    }

    // MARK: - 1. tools/list catalogue (file-ops + AI cluster)

    func test_tools_listIncludesFileOpsAndAITools() {
        let names = MCPLSPBridge.tools.map { $0.name }

        let expectedNew = [
            // File-ops cluster
            "lsp_will_create_files",
            "lsp_did_create_files",
            "lsp_will_rename_files",
            "lsp_did_rename_files",
            "lsp_will_delete_files",
            "lsp_did_delete_files",
            // AI-specific cluster
            "lsp_batch",
            "lsp_hover_bundle",
            "lsp_symbol_walk",
            "lsp_global_workspace_symbol",
            "lsp_cross_workspace_definition",
            "lsp_diagnostics_diff",
            "lsp_capabilities",
        ]
        for name in expectedNew {
            XCTAssertTrue(
                names.contains(name),
                "MCPLSPBridge.tools must advertise file-ops/AI tool \(name); got names=\(names)"
            )
        }

        XCTAssertEqual(
            names.count,
            70,
            "tools count must be 54 existing + 13 file-ops/AI + 3 notebook = 70; got \(names.count) names=\(names)"
        )
    }

    // MARK: - 2. lsp_will_create_files sends workspace/willCreateFiles

    func test_lspWillCreateFiles_sendsCorrectLSPRequest() async throws {
        let (bridge, driver) = await makeBridge()
        let editJSON = """
        {"changes":{"file:///tmp/new.ts":[
          {"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":0}},
           "newText":"// generated\\n"}
        ]}}
        """
        await driver.setReply(method: "workspace/willCreateFiles", jsonResult: editJSON)

        let args: [String: AnyCodable] = [
            "workspace_root": AnyCodable(workspaceA.path),
            "language_id": AnyCodable("typescript"),
            "files": filesUriArray([
                "file:///tmp/calyx-mcp-lsp-bridge-fileops-ai-A/new.ts",
            ]),
        ]
        let content = try await bridge.handleToolCall(
            name: "lsp_will_create_files",
            arguments: args
        )
        XCTAssertEqual(content.type, "text")
        XCTAssertTrue(
            content.text.contains("\"newText\":\"// generated\\n\"")
                || content.text.contains("// generated"),
            "willCreateFiles result must round-trip; got: \(content.text)"
        )

        let captured = await driver.capturedParams(forMethod: "workspace/willCreateFiles")
        XCTAssertEqual(captured.count, 1)
        let files = captured[0]["files"] as? [[String: Any]]
        XCTAssertEqual(files?.count, 1)
        XCTAssertEqual(
            files?[0]["uri"] as? String,
            "file:///tmp/calyx-mcp-lsp-bridge-fileops-ai-A/new.ts"
        )
    }

    // MARK: - 3. lsp_did_create_files sends a notification (no response)

    func test_lspDidCreateFiles_sendsNotification() async throws {
        let (bridge, driver) = await makeBridge()

        // Warm the session via a hover round-trip so the subsequent
        // notification reaches a `.running` LSPSession (notifications are
        // refused before initialize completes).
        try await warmDefaultSession(bridge: bridge, driver: driver)

        let args: [String: AnyCodable] = [
            "workspace_root": AnyCodable(workspaceA.path),
            "language_id": AnyCodable("typescript"),
            "files": filesUriArray([
                "file:///tmp/calyx-mcp-lsp-bridge-fileops-ai-A/created.ts",
            ]),
        ]
        let content = try await bridge.handleToolCall(
            name: "lsp_did_create_files",
            arguments: args
        )
        XCTAssertEqual(content.type, "text")

        let arrived = await driver.waitForCapture(method: "workspace/didCreateFiles")
        XCTAssertTrue(arrived, "didCreateFiles notification must reach the server within 2s")

        let captured = await driver.capturedParams(forMethod: "workspace/didCreateFiles")
        XCTAssertEqual(captured.count, 1)
        let files = captured[0]["files"] as? [[String: Any]]
        XCTAssertEqual(files?.count, 1)
        XCTAssertEqual(
            files?[0]["uri"] as? String,
            "file:///tmp/calyx-mcp-lsp-bridge-fileops-ai-A/created.ts"
        )
    }

    // MARK: - 4. lsp_will_rename_files sends workspace/willRenameFiles

    func test_lspWillRenameFiles_sendsCorrectLSPRequest() async throws {
        let (bridge, driver) = await makeBridge()
        let editJSON = """
        {"changes":{}}
        """
        await driver.setReply(method: "workspace/willRenameFiles", jsonResult: editJSON)

        let args: [String: AnyCodable] = [
            "workspace_root": AnyCodable(workspaceA.path),
            "language_id": AnyCodable("typescript"),
            "files": filesRenameArray([
                (
                    "file:///tmp/calyx-mcp-lsp-bridge-fileops-ai-A/old.ts",
                    "file:///tmp/calyx-mcp-lsp-bridge-fileops-ai-A/new.ts"
                ),
            ]),
        ]
        let content = try await bridge.handleToolCall(
            name: "lsp_will_rename_files",
            arguments: args
        )
        XCTAssertEqual(content.type, "text")

        let captured = await driver.capturedParams(forMethod: "workspace/willRenameFiles")
        XCTAssertEqual(captured.count, 1)
        let files = captured[0]["files"] as? [[String: Any]]
        XCTAssertEqual(files?.count, 1)
        XCTAssertEqual(
            files?[0]["oldUri"] as? String,
            "file:///tmp/calyx-mcp-lsp-bridge-fileops-ai-A/old.ts"
        )
        XCTAssertEqual(
            files?[0]["newUri"] as? String,
            "file:///tmp/calyx-mcp-lsp-bridge-fileops-ai-A/new.ts"
        )
    }

    // MARK: - 5. lsp_did_rename_files sends a notification

    func test_lspDidRenameFiles_sendsNotification() async throws {
        let (bridge, driver) = await makeBridge()
        try await warmDefaultSession(bridge: bridge, driver: driver)

        let args: [String: AnyCodable] = [
            "workspace_root": AnyCodable(workspaceA.path),
            "language_id": AnyCodable("typescript"),
            "files": filesRenameArray([
                (
                    "file:///tmp/calyx-mcp-lsp-bridge-fileops-ai-A/old.ts",
                    "file:///tmp/calyx-mcp-lsp-bridge-fileops-ai-A/new.ts"
                ),
            ]),
        ]
        let content = try await bridge.handleToolCall(
            name: "lsp_did_rename_files",
            arguments: args
        )
        XCTAssertEqual(content.type, "text")

        let arrived = await driver.waitForCapture(method: "workspace/didRenameFiles")
        XCTAssertTrue(arrived, "didRenameFiles notification must reach the server within 2s")

        let captured = await driver.capturedParams(forMethod: "workspace/didRenameFiles")
        XCTAssertEqual(captured.count, 1)
        let files = captured[0]["files"] as? [[String: Any]]
        XCTAssertEqual(files?.count, 1)
        XCTAssertEqual(
            files?[0]["oldUri"] as? String,
            "file:///tmp/calyx-mcp-lsp-bridge-fileops-ai-A/old.ts"
        )
        XCTAssertEqual(
            files?[0]["newUri"] as? String,
            "file:///tmp/calyx-mcp-lsp-bridge-fileops-ai-A/new.ts"
        )
    }

    // MARK: - 6. lsp_will_delete_files sends workspace/willDeleteFiles

    func test_lspWillDeleteFiles_sendsCorrectLSPRequest() async throws {
        let (bridge, driver) = await makeBridge()
        let editJSON = """
        {"changes":{}}
        """
        await driver.setReply(method: "workspace/willDeleteFiles", jsonResult: editJSON)

        let args: [String: AnyCodable] = [
            "workspace_root": AnyCodable(workspaceA.path),
            "language_id": AnyCodable("typescript"),
            "files": filesUriArray([
                "file:///tmp/calyx-mcp-lsp-bridge-fileops-ai-A/gone.ts",
            ]),
        ]
        let content = try await bridge.handleToolCall(
            name: "lsp_will_delete_files",
            arguments: args
        )
        XCTAssertEqual(content.type, "text")

        let captured = await driver.capturedParams(forMethod: "workspace/willDeleteFiles")
        XCTAssertEqual(captured.count, 1)
        let files = captured[0]["files"] as? [[String: Any]]
        XCTAssertEqual(files?.count, 1)
        XCTAssertEqual(
            files?[0]["uri"] as? String,
            "file:///tmp/calyx-mcp-lsp-bridge-fileops-ai-A/gone.ts"
        )
    }

    // MARK: - 7. lsp_did_delete_files sends a notification

    func test_lspDidDeleteFiles_sendsNotification() async throws {
        let (bridge, driver) = await makeBridge()
        try await warmDefaultSession(bridge: bridge, driver: driver)

        let args: [String: AnyCodable] = [
            "workspace_root": AnyCodable(workspaceA.path),
            "language_id": AnyCodable("typescript"),
            "files": filesUriArray([
                "file:///tmp/calyx-mcp-lsp-bridge-fileops-ai-A/deleted.ts",
            ]),
        ]
        let content = try await bridge.handleToolCall(
            name: "lsp_did_delete_files",
            arguments: args
        )
        XCTAssertEqual(content.type, "text")

        let arrived = await driver.waitForCapture(method: "workspace/didDeleteFiles")
        XCTAssertTrue(arrived, "didDeleteFiles notification must reach the server within 2s")

        let captured = await driver.capturedParams(forMethod: "workspace/didDeleteFiles")
        XCTAssertEqual(captured.count, 1)
        let files = captured[0]["files"] as? [[String: Any]]
        XCTAssertEqual(files?.count, 1)
        XCTAssertEqual(
            files?[0]["uri"] as? String,
            "file:///tmp/calyx-mcp-lsp-bridge-fileops-ai-A/deleted.ts"
        )
    }

    // MARK: - 8. lsp_batch runs multiple tools in one round-trip

    func test_lspBatch_runsMultipleTools() async throws {
        let (bridge, driver) = await makeBridge()
        await driver.setReply(
            method: "textDocument/hover",
            jsonResult: #"{"contents":{"kind":"plaintext","value":"alpha"}}"#
        )
        await driver.setReply(
            method: "textDocument/definition",
            jsonResult: #"[{"uri":"file:///tmp/x.ts","range":{"start":{"line":1,"character":2},"end":{"line":1,"character":5}}}]"#
        )

        let hoverParams: [String: AnyCodable] = [
            "workspace_root": AnyCodable(workspaceA.path),
            "language_id": AnyCodable("typescript"),
            "file": AnyCodable(fileA),
            "line": AnyCodable(3),
            "column": AnyCodable(7),
        ]
        let defParams: [String: AnyCodable] = [
            "workspace_root": AnyCodable(workspaceA.path),
            "language_id": AnyCodable("typescript"),
            "file": AnyCodable(fileA),
            "line": AnyCodable(3),
            "column": AnyCodable(7),
        ]

        let requests = AnyCodable([
            AnyCodable([
                "tool": AnyCodable("lsp_hover"),
                "params": AnyCodable(hoverParams),
            ] as [String: AnyCodable]),
            AnyCodable([
                "tool": AnyCodable("lsp_definition"),
                "params": AnyCodable(defParams),
            ] as [String: AnyCodable]),
        ])
        let args: [String: AnyCodable] = ["requests": requests]

        let content = try await bridge.handleToolCall(
            name: "lsp_batch",
            arguments: args
        )
        XCTAssertEqual(content.type, "text")
        XCTAssertTrue(
            content.text.contains("alpha"),
            "lsp_batch result must surface the hover payload; got: \(content.text)"
        )
        XCTAssertTrue(
            content.text.contains("file:///tmp/x.ts"),
            "lsp_batch result must surface the definition payload; got: \(content.text)"
        )

        let hoverCaptures = await driver.capturedParams(forMethod: "textDocument/hover")
        let defCaptures = await driver.capturedParams(forMethod: "textDocument/definition")
        XCTAssertEqual(
            hoverCaptures.count, 1,
            "lsp_batch must dispatch the inner lsp_hover exactly once"
        )
        XCTAssertEqual(
            defCaptures.count, 1,
            "lsp_batch must dispatch the inner lsp_definition exactly once"
        )
    }

    // MARK: - 8b. lsp_batch rejects nested lsp_batch entries

    /// A `lsp_batch` whose inner entry targets `lsp_batch` itself must NOT
    /// recurse. Permitting recursion turns one outer call into an
    /// exponential fan-out (e.g. 100x100x100 = 1M dispatches) which pins the
    /// `@MainActor`-isolated bridge and is a trivial DoS vector. The bridge
    /// must surface the rejection as a per-entry `error` so peer entries
    /// still execute normally; the outer call MUST NOT throw.
    func test_lspBatch_nestedBatch_rejectedWithError() async throws {
        let (bridge, _) = await makeBridge()

        let innerParams: [String: AnyCodable] = [
            "requests": AnyCodable([AnyCodable]()),
        ]
        let requests = AnyCodable([
            AnyCodable([
                "tool": AnyCodable("lsp_batch"),
                "params": AnyCodable(innerParams),
            ] as [String: AnyCodable]),
        ])
        let args: [String: AnyCodable] = ["requests": requests]

        let content = try await bridge.handleToolCall(
            name: "lsp_batch",
            arguments: args
        )
        XCTAssertEqual(content.type, "text")

        guard let data = content.text.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else {
            XCTFail("lsp_batch text must be a JSON array; got: \(content.text)")
            return
        }
        XCTAssertEqual(arr.count, 1, "expected exactly one entry; got: \(arr)")
        guard let entry = arr.first else { return }
        XCTAssertEqual(
            entry["tool"] as? String, "lsp_batch",
            "entry must echo the inner tool name; got: \(entry)"
        )
        XCTAssertNil(
            entry["result"],
            "rejected nested batch entry must not carry a result; got: \(entry)"
        )
        let errorText = (entry["error"] as? String) ?? ""
        XCTAssertTrue(
            errorText.contains("nested") || errorText.contains("lsp_batch"),
            "rejected entry must explain the nested-batch rejection; got error=\(errorText)"
        )
    }

    // MARK: - 8c. lsp_batch caps requests.count to prevent DoS

    /// `requests.count` MUST be bounded so a single MCP round-trip cannot pin
    /// the bridge actor with an unbounded fan-out. The cap is encoded as
    /// `BatchTool.maxRequestsPerBatch` (64 in this build); exceeding it
    /// throws `MCPLSPBridgeError.invalidArgument(name: "requests", ...)`
    /// rather than per-entry failing so the client gets a single clear
    /// signal instead of N tiny errors.
    func test_lspBatch_tooManyRequests_throws() async throws {
        let (bridge, _) = await makeBridge()

        let manyRequests = AnyCodable(
            (0..<65).map { _ in
                AnyCodable([
                    "tool": AnyCodable("lsp_check_installation"),
                    "params": AnyCodable([String: AnyCodable]()),
                ] as [String: AnyCodable])
            }
        )
        let args: [String: AnyCodable] = ["requests": manyRequests]

        do {
            _ = try await bridge.handleToolCall(
                name: "lsp_batch",
                arguments: args
            )
            XCTFail("lsp_batch must reject a batch whose requests.count exceeds the per-batch cap")
        } catch let err as MCPLSPBridgeError {
            if case .invalidArgument(let name, let reason) = err {
                XCTAssertEqual(
                    name, "requests",
                    "invalidArgument must point at the 'requests' field; got: \(err)"
                )
                XCTAssertTrue(
                    reason.contains("65") || reason.contains("64") || reason.contains("max"),
                    "reason must mention the cap or observed count; got: \(reason)"
                )
            } else {
                XCTFail("expected MCPLSPBridgeError.invalidArgument, got: \(err)")
            }
        }
    }

    // MARK: - 9. lsp_hover_bundle returns hover + definition + surrounding_code

    func test_lspHoverBundle_returnsHoverAndDefinition() async throws {
        let (bridge, driver) = await makeBridge()
        await driver.setReply(
            method: "textDocument/hover",
            jsonResult: #"{"contents":{"kind":"plaintext","value":"hover-text"}}"#
        )
        await driver.setReply(
            method: "textDocument/definition",
            jsonResult: #"[{"uri":"file:///tmp/x.ts","range":{"start":{"line":1,"character":0},"end":{"line":1,"character":4}}}]"#
        )

        let args: [String: AnyCodable] = [
            "workspace_root": AnyCodable(workspaceA.path),
            "language_id": AnyCodable("typescript"),
            "file": AnyCodable(fileA),
            "line": AnyCodable(5),
            "column": AnyCodable(2),
        ]
        let content = try await bridge.handleToolCall(
            name: "lsp_hover_bundle",
            arguments: args
        )
        XCTAssertEqual(content.type, "text")

        guard let data = content.text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            XCTFail("lsp_hover_bundle text must be a JSON object; got: \(content.text)")
            return
        }
        XCTAssertNotNil(
            obj["hover"],
            "lsp_hover_bundle JSON must carry a 'hover' field; got: \(obj)"
        )
        XCTAssertNotNil(
            obj["definition"],
            "lsp_hover_bundle JSON must carry a 'definition' field; got: \(obj)"
        )
        XCTAssertTrue(
            obj.keys.contains("surrounding_code"),
            "lsp_hover_bundle JSON must carry a 'surrounding_code' field; got: \(obj)"
        )

        XCTAssertTrue(
            content.text.contains("hover-text"),
            "lsp_hover_bundle must surface the hover payload; got: \(content.text)"
        )
        XCTAssertTrue(
            content.text.contains("file:///tmp/x.ts"),
            "lsp_hover_bundle must surface the definition payload; got: \(content.text)"
        )

        let hoverCaptures = await driver.capturedParams(forMethod: "textDocument/hover")
        let defCaptures = await driver.capturedParams(forMethod: "textDocument/definition")
        XCTAssertEqual(hoverCaptures.count, 1)
        XCTAssertEqual(defCaptures.count, 1)
    }

    // MARK: - 10. lsp_symbol_walk (call_incoming, depth=1) flattens one step

    func test_lspSymbolWalk_callIncoming_depthOne_returnsFlatList() async throws {
        let (bridge, driver) = await makeBridge()
        // Server returns one incoming-call edge whose `from` item is named
        // "caller_one".
        let incomingJSON = """
        [
          {
            "from": {
              "name": "caller_one",
              "kind": 12,
              "uri": "file:///tmp/caller.ts",
              "range": {"start":{"line":0,"character":0},"end":{"line":0,"character":10}},
              "selectionRange": {"start":{"line":0,"character":0},"end":{"line":0,"character":10}}
            },
            "fromRanges": [
              {"start":{"line":3,"character":4},"end":{"line":3,"character":11}}
            ]
          }
        ]
        """
        await driver.setReply(method: "callHierarchy/incomingCalls", jsonResult: incomingJSON)

        let seedItem: [String: AnyCodable] = [
            "name": AnyCodable("target"),
            "kind": AnyCodable(12),
            "uri": AnyCodable("file:///tmp/target.ts"),
            "range": AnyCodable([
                "start": AnyCodable([
                    "line": AnyCodable(0), "character": AnyCodable(0),
                ] as [String: AnyCodable]),
                "end": AnyCodable([
                    "line": AnyCodable(0), "character": AnyCodable(6),
                ] as [String: AnyCodable]),
            ] as [String: AnyCodable]),
            "selectionRange": AnyCodable([
                "start": AnyCodable([
                    "line": AnyCodable(0), "character": AnyCodable(0),
                ] as [String: AnyCodable]),
                "end": AnyCodable([
                    "line": AnyCodable(0), "character": AnyCodable(6),
                ] as [String: AnyCodable]),
            ] as [String: AnyCodable]),
        ]

        let args: [String: AnyCodable] = [
            "workspace_root": AnyCodable(workspaceA.path),
            "language_id": AnyCodable("typescript"),
            "item": AnyCodable(seedItem),
            "direction": AnyCodable("call_incoming"),
            "depth": AnyCodable(1),
        ]
        let content = try await bridge.handleToolCall(
            name: "lsp_symbol_walk",
            arguments: args
        )
        XCTAssertEqual(content.type, "text")
        XCTAssertTrue(
            content.text.contains("caller_one"),
            "lsp_symbol_walk must surface the discovered caller; got: \(content.text)"
        )

        let captured = await driver.capturedParams(forMethod: "callHierarchy/incomingCalls")
        XCTAssertEqual(
            captured.count, 1,
            "lsp_symbol_walk with depth=1 must issue callHierarchy/incomingCalls exactly once"
        )
    }

    // MARK: - 11. lsp_symbol_walk unsupported direction throws

    func test_lspSymbolWalk_unsupportedDirection_throwsInvalidArgument() async throws {
        let (bridge, _) = await makeBridge()

        let seedItem: [String: AnyCodable] = [
            "name": AnyCodable("Whatever"),
            "kind": AnyCodable(5),
            "uri": AnyCodable("file:///tmp/t.ts"),
            "range": AnyCodable([
                "start": AnyCodable([
                    "line": AnyCodable(0), "character": AnyCodable(0),
                ] as [String: AnyCodable]),
                "end": AnyCodable([
                    "line": AnyCodable(0), "character": AnyCodable(8),
                ] as [String: AnyCodable]),
            ] as [String: AnyCodable]),
            "selectionRange": AnyCodable([
                "start": AnyCodable([
                    "line": AnyCodable(0), "character": AnyCodable(0),
                ] as [String: AnyCodable]),
                "end": AnyCodable([
                    "line": AnyCodable(0), "character": AnyCodable(8),
                ] as [String: AnyCodable]),
            ] as [String: AnyCodable]),
        ]

        let args: [String: AnyCodable] = [
            "workspace_root": AnyCodable(workspaceA.path),
            "language_id": AnyCodable("typescript"),
            "item": AnyCodable(seedItem),
            "direction": AnyCodable("type_supertypes"),
            "depth": AnyCodable(1),
        ]
        do {
            _ = try await bridge.handleToolCall(
                name: "lsp_symbol_walk",
                arguments: args
            )
            XCTFail("expected lsp_symbol_walk to throw for unsupported direction in stub impl")
        } catch let MCPLSPBridgeError.invalidArgument(name, _) {
            XCTAssertEqual(
                name, "direction",
                "invalidArgument must point at the 'direction' key; got: \(name)"
            )
        } catch {
            XCTFail("expected MCPLSPBridgeError.invalidArgument for direction; got: \(error)")
        }
    }

    // MARK: - 12. lsp_global_workspace_symbol aggregates across sessions

    func test_lspGlobalWorkspaceSymbol_aggregatesAcrossSessions() async throws {
        let (bridge, driver) = await makeBridge()
        try await warmDefaultSession(bridge: bridge, driver: driver)

        let symbolsJSON = """
        [
          {
            "name": "Aggregated",
            "kind": 5,
            "location": {
              "uri": "file:///tmp/agg.ts",
              "range": {"start":{"line":0,"character":0},"end":{"line":0,"character":10}}
            }
          }
        ]
        """
        await driver.setReply(method: "workspace/symbol", jsonResult: symbolsJSON)

        let args: [String: AnyCodable] = [
            "query": AnyCodable("Agg"),
        ]
        let content = try await bridge.handleToolCall(
            name: "lsp_global_workspace_symbol",
            arguments: args
        )
        XCTAssertEqual(content.type, "text")
        XCTAssertTrue(
            content.text.contains("Aggregated"),
            "lsp_global_workspace_symbol must aggregate symbols across cached sessions; got: \(content.text)"
        )

        let captured = await driver.capturedParams(forMethod: "workspace/symbol")
        XCTAssertEqual(
            captured.count, 1,
            "lsp_global_workspace_symbol must dispatch workspace/symbol against each cached session"
        )
        XCTAssertEqual(captured[0]["query"] as? String, "Agg")
    }

    // MARK: - 13. lsp_cross_workspace_definition resolves a normal definition (stub)

    func test_lspCrossWorkspaceDefinition_returnsDefinition() async throws {
        let (bridge, driver) = await makeBridge()
        let defJSON = """
        [{"uri":"file:///tmp/other.ts","range":{"start":{"line":4,"character":1},"end":{"line":4,"character":7}}}]
        """
        await driver.setReply(method: "textDocument/definition", jsonResult: defJSON)

        let args: [String: AnyCodable] = [
            "workspace_root": AnyCodable(workspaceA.path),
            "language_id": AnyCodable("typescript"),
            "file": AnyCodable(fileA),
            "line": AnyCodable(9),
            "column": AnyCodable(0),
        ]
        let content = try await bridge.handleToolCall(
            name: "lsp_cross_workspace_definition",
            arguments: args
        )
        XCTAssertEqual(content.type, "text")
        XCTAssertTrue(
            content.text.contains("file:///tmp/other.ts"),
            "lsp_cross_workspace_definition must surface the definition payload; got: \(content.text)"
        )

        let captured = await driver.capturedParams(forMethod: "textDocument/definition")
        XCTAssertEqual(
            captured.count, 1,
            "lsp_cross_workspace_definition stub must issue textDocument/definition exactly once"
        )
    }

    // MARK: - 14. lsp_diagnostics_diff returns a DiagnosticsDiff-shaped payload

    func test_lspDiagnosticsDiff_returnsDiagnosticsDiffShape() async throws {
        let (bridge, driver) = await makeBridge()

        // The bridge owns its DiagnosticsStore — we can't pre-populate it
        // from the outside in the stub phase. The hard invariant we test
        // is the *contract*: the bridge dispatches the tool, returns a
        // single text content block, and routes no LSP request to the
        // server (the diff is read from the local store, not the LSP).
        let args: [String: AnyCodable] = [
            "workspace_root": AnyCodable(workspaceA.path),
            "language_id": AnyCodable("typescript"),
            "since_snapshot_id": AnyCodable(1),
        ]
        let content = try await bridge.handleToolCall(
            name: "lsp_diagnostics_diff",
            arguments: args
        )
        XCTAssertEqual(content.type, "text")
        XCTAssertFalse(
            content.text.isEmpty,
            "lsp_diagnostics_diff must return a non-empty text payload"
        )

        // The text must parse as JSON (either a structured error envelope
        // surfaced via `makeErrorContent` for unknownSnapshot, or the
        // serialised `DiagnosticsDiff` itself). We don't pin the exact
        // shape here — the stub is allowed to either return the
        // DiagnosticsDiff JSON or an "LSP error: ..." text envelope.
        let trimmed = content.text.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(
            trimmed.hasPrefix("{") || trimmed.hasPrefix("LSP error:"),
            "lsp_diagnostics_diff text must be JSON or an LSP-error envelope; got: \(trimmed)"
        )

        // No LSP-side method should be invoked — the diff is local.
        let total = await driver.totalCapturedCount()
        XCTAssertEqual(
            total,
            0,
            "lsp_diagnostics_diff must not route any LSP request through the session; got total=\(total)"
        )
    }

    // MARK: - 15. lsp_capabilities returns static + dynamic snapshot, no LSP request

    func test_lspCapabilities_returnsStaticAndDynamicSnapshot() async throws {
        let (bridge, driver) = await makeBridge()
        // Warm the session so CapabilityRegistry has at least an
        // initialize-derived static snapshot.
        try await warmDefaultSession(bridge: bridge, driver: driver)

        // Reset captures from the warmup so the post-warmup assertion below
        // is meaningful — only the lsp_capabilities call should be measured.
        let baseline = await driver.totalCapturedCount()

        let args: [String: AnyCodable] = [
            "workspace_root": AnyCodable(workspaceA.path),
            "language_id": AnyCodable("typescript"),
        ]
        let content = try await bridge.handleToolCall(
            name: "lsp_capabilities",
            arguments: args
        )
        XCTAssertEqual(content.type, "text")

        guard let data = content.text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            XCTFail("lsp_capabilities text must be a JSON object; got: \(content.text)")
            return
        }
        XCTAssertTrue(
            obj.keys.contains("static"),
            "lsp_capabilities JSON must carry a 'static' field; got: \(obj)"
        )
        XCTAssertTrue(
            obj.keys.contains("dynamic"),
            "lsp_capabilities JSON must carry a 'dynamic' field; got: \(obj)"
        )
        XCTAssertTrue(
            obj["dynamic"] is [Any],
            "lsp_capabilities 'dynamic' must be an array; got: \(String(describing: obj["dynamic"]))"
        )

        // lsp_capabilities is bridge-internal — no LSP request must reach
        // the server.
        let after = await driver.totalCapturedCount()
        XCTAssertEqual(
            after,
            baseline,
            "lsp_capabilities must not route any LSP request through the session; baseline=\(baseline), after=\(after)"
        )
    }

    // MARK: - 16. lsp_will_create_files missing 'files' throws

    func test_lspWillCreateFiles_missingFiles_throws() async {
        let (bridge, _) = await makeBridge()

        // `files` is required; omit it to provoke a missing-arg error.
        let args: [String: AnyCodable] = [
            "workspace_root": AnyCodable(workspaceA.path),
            "language_id": AnyCodable("typescript"),
        ]
        do {
            _ = try await bridge.handleToolCall(
                name: "lsp_will_create_files",
                arguments: args
            )
            XCTFail("expected throw for missing 'files' argument")
        } catch let MCPLSPBridgeError.missingArgument(name) {
            XCTAssertEqual(
                name, "files",
                "missingArgument must point at the 'files' key; got: \(name)"
            )
        } catch let MCPLSPBridgeError.unknownTool(name) {
            // Force a RED-phase failure: the bridge must already know about
            // 'lsp_will_create_files' and reject the call because the
            // required `files` argument is missing. A bare unknownTool
            // means the tool itself hasn't been registered yet.
            XCTFail(
                "expected the bridge to advertise 'lsp_will_create_files' and reject"
                + " for missing 'files'; got unknownTool(\(name))"
            )
        } catch {
            // Any other error type is acceptable so long as it isn't
            // unknownTool — the bridge just has to refuse the call for the
            // right reason.
        }
    }
}
