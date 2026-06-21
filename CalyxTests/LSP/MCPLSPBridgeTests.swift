//
//  MCPLSPBridgeTests.swift
//  Calyx
//
//  Tests for `MCPLSPBridge`, the `@MainActor` registry + dispatcher that
//  exposes LSP requests as MCP tools to the `CalyxMCPServer`.
//
//  Responsibilities exercised here:
//    - Tool catalogue: `MCPLSPBridge.tools` enumerates the 10 core
//      navigation/symbol/completion tools with correct names and
//      `inputSchema.required` keys.
//    - Dispatch: `handleToolCall(name:arguments:)` routes by tool name,
//      throwing for unknown tools and for missing required arguments.
//    - LSP request shape: each tool packs `arguments` into the right LSP
//      method + params (uri, position, context, query, etc).
//    - Response shaping: server results round-trip as JSON-encoded text
//      content; explicit `null` results are surfaced as `"null"`; LSP
//      `serverError` responses surface as an error content payload.
//    - Session caching: parallel tool calls against the same
//      (workspace, languageId) share a single `LSPSession` build (the
//      LSPService cache). Different workspaces produce different sessions.
//
//  TDD phase: RED. Neither `MCPLSPTool` nor `MCPLSPBridge` exist yet —
//  this file is expected to fail to compile (unresolved identifiers)
//  until the swift-specialist creates
//  `Calyx/Features/LSP/MCPLSPBridge.swift` (and likely a sibling file
//  declaring the individual `MCPLSPTool` types).
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

// MARK: - file-private fake LSP server driver

/// Tracks every `LSPClient` minted by `LSPService` and arranges for the
/// embedded `InMemoryLSPTransport` to auto-reply to `initialize`,
/// `shutdown`, and a configurable set of LSP request methods so the
/// surrounding `MCPLSPBridge` can complete a tool call without a real
/// language server.
///
/// Tests configure a `methodReplies` table keyed by LSP method name; the
/// driver will inject the matching JSON-RPC result for the next request
/// it sees with that method. Tests also receive a per-method record of
/// every payload the bridge sent, so they can assert on uri / position /
/// context / query / trigger arguments.
fileprivate actor MCPLSPBridgeServerDriver: LSPSessionFactory {

    // MARK: - Configuration

    /// JSON payload to return as the `result` for the first observed
    /// request matching the key. Set to `"null"` to emit a JSON `null`.
    /// Use `setMethodError` instead to surface a JSON-RPC error.
    private var methodReplies: [String: String] = [:]
    /// JSON-RPC error payload to return instead of a result, keyed by method.
    private var methodErrors: [String: (code: Int, message: String)] = [:]

    /// Captured `params` payloads keyed by method, in arrival order.
    private var paramsCaptured: [String: [[String: Any]]] = [:]
    /// Total number of `LSPClient` instances the bridge has caused
    /// `LSPService` to mint. Used to assert session-cache behaviour.
    private(set) var clientsMade: Int = 0
    /// Live transports kept alive for their sidecar Tasks.
    private var transports: [InMemoryLSPTransport] = []
    /// Sidecar Tasks driving fake server replies — retained so ARC does
    /// not cancel them when the local variable falls out of scope.
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
        // JSON-roundtrip the entire array through Sendable `Data` so the
        // returned region is disconnected from actor-isolated storage.
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

    func clientsMadeCount() -> Int { clientsMade }

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

        // Capture isolated-state references so the detached sidecar Task
        // can update them via dedicated actor-isolated mutators.
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
        // JSON-roundtrip to detach from caller's region before storing as actor state.
        guard let data = try? JSONSerialization.data(withJSONObject: params),
              let copy = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        paramsCaptured[method, default: []].append(copy)
    }

    // MARK: - Server simulator

    /// Poll `transport.sentMessages()` and inject responses for every
    /// JSON-RPC request the bridge dispatches. `initialize` and
    /// `shutdown` always reply with success; everything else consults
    /// `methodReplies` / `methodErrors` configured by the surrounding
    /// test. Unknown methods get a generic `null` result so callers see
    /// a deterministic shape.
    private static func driveServerReplies(
        on transport: InMemoryLSPTransport,
        driver: MCPLSPBridgeServerDriver
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

                // LSP request from the bridge — capture params, then
                // emit either a configured result or a JSON null.
                if let p = dict["params"] as? [String: Any] {
                    // Detach p from dict's region: serialize to Sendable Data,
                    // then deserialize via a top-level helper so the resulting
                    // dictionary is in a fresh region.
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
        if let n = any as? NSNumber { return n.intValue }
        if let s = any as? String { return Int(s) }
        return nil
    }
}

// MARK: - MCPLSPBridgeTests

@MainActor
final class MCPLSPBridgeTests: XCTestCase {

    // MARK: - Constants

    private let workspaceA = URL(fileURLWithPath: "/tmp/calyx-mcp-lsp-bridge-A")
    private let workspaceB = URL(fileURLWithPath: "/tmp/calyx-mcp-lsp-bridge-B")
    private let fileA = "file:///tmp/calyx-mcp-lsp-bridge-A/main.ts"
    private let fileB = "file:///tmp/calyx-mcp-lsp-bridge-B/main.ts"

    // MARK: - Helpers

    /// Build an `LSPInstaller` whose runner reports the
    /// `typescript-language-server` and `npm` binaries as already on
    /// PATH — keeps the bridge's session build off the install path.
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

    /// Spin up an `LSPService`, a `WorkspaceResolver`, and the
    /// `MCPLSPBridge` under test, plus return the underlying driver so
    /// the test can configure replies and inspect captured params.
    private func makeBridge() async -> (bridge: MCPLSPBridge, driver: MCPLSPBridgeServerDriver) {
        let installer = await makeReadyInstaller()
        let driver = MCPLSPBridgeServerDriver()
        let service = LSPService(
            registry: .builtIn(),
            installer: installer,
            sessionFactory: driver,
            config: LSPServiceConfig()
        )
        let resolver = WorkspaceResolver(registry: .builtIn())
        let bridge = MCPLSPBridge(service: service, workspaceResolver: resolver)
        return (bridge, driver)
    }

    /// Standard `arguments` dictionary for the position-based tools.
    private func positionArguments(
        file: String,
        line: Int,
        column: Int,
        workspaceRoot: URL? = nil,
        languageId: String = "typescript"
    ) -> [String: AnyCodable] {
        var args: [String: AnyCodable] = [
            "file": AnyCodable(file),
            "line": AnyCodable(line),
            "column": AnyCodable(column),
            "language_id": AnyCodable(languageId),
        ]
        if let workspaceRoot {
            args["workspace_root"] = AnyCodable(workspaceRoot.path)
        }
        return args
    }

    // MARK: - 1. tools/list catalogue

    func test_tools_listContainsAll10CoreTools() throws {
        let names = MCPLSPBridge.tools.map { $0.name }
        let expected = [
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
        ]
        for name in expected {
            XCTAssertTrue(
                names.contains(name),
                "MCPLSPBridge.tools must expose \(name); got names=\(names)"
            )
        }

        // Spot-check each position-based tool's `required` keys.
        let positionalTools = [
            "lsp_hover",
            "lsp_definition",
            "lsp_declaration",
            "lsp_type_definition",
            "lsp_implementation",
            "lsp_references",
            "lsp_document_highlight",
            "lsp_completion",
        ]
        for toolName in positionalTools {
            let tool = MCPLSPBridge.tools.first(where: { $0.name == toolName })
            XCTAssertNotNil(tool, "missing tool \(toolName)")
            let required = try requiredKeys(of: tool!)
            XCTAssertTrue(required.contains("file"), "\(toolName) must require 'file'")
            XCTAssertTrue(required.contains("line"), "\(toolName) must require 'line'")
            XCTAssertTrue(required.contains("column"), "\(toolName) must require 'column'")
        }

        // documentSymbol takes a file only, no line/column.
        let docSymbol = MCPLSPBridge.tools.first(where: { $0.name == "lsp_document_symbol" })
        XCTAssertNotNil(docSymbol)
        let docSymbolRequired = try requiredKeys(of: docSymbol!)
        XCTAssertTrue(docSymbolRequired.contains("file"))

        // workspaceSymbol takes a `query` instead of a file/position.
        let workspaceSymbol = MCPLSPBridge.tools.first(where: { $0.name == "lsp_workspace_symbol" })
        XCTAssertNotNil(workspaceSymbol)
        let workspaceSymbolRequired = try requiredKeys(of: workspaceSymbol!)
        XCTAssertTrue(workspaceSymbolRequired.contains("query"))
    }

    /// Extract the `required` array from an `MCPTool.inputSchema`. The
    /// inputSchema is `[String: AnyCodable]` so we round-trip through
    /// JSON to inspect the array contents.
    private func requiredKeys(of tool: MCPTool) throws -> Set<String> {
        let data = try JSONEncoder().encode(tool.inputSchema)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let req = obj["required"] as? [String] else {
            return []
        }
        return Set(req)
    }

    // MARK: - 2. Unknown tool throws

    func test_handleToolCall_unknownTool_throws() async {
        let (bridge, _) = await makeBridge()
        do {
            _ = try await bridge.handleToolCall(
                name: "lsp_does_not_exist",
                arguments: [:]
            )
            XCTFail("expected throw for unknown tool name")
        } catch {
            // OK — any error type is acceptable; the bridge just has to refuse.
        }
    }

    // MARK: - 3. lsp_hover dispatch

    func test_handleToolCall_lspHover_sendsCorrectLSPRequest() async throws {
        let (bridge, driver) = await makeBridge()
        let hoverJSON = #"{"contents":{"kind":"markdown","value":"docs"}}"#
        await driver.setReply(method: "textDocument/hover", jsonResult: hoverJSON)

        let args = positionArguments(
            file: fileA,
            line: 5,
            column: 12,
            workspaceRoot: workspaceA
        )
        let content = try await bridge.handleToolCall(name: "lsp_hover", arguments: args)
        XCTAssertEqual(content.type, "text")
        XCTAssertTrue(
            content.text.contains("\"kind\":\"markdown\"")
                && content.text.contains("\"value\":\"docs\""),
            "hover JSON must round-trip into MCPContent.text; got: \(content.text)"
        )

        let captured = await driver.capturedParams(forMethod: "textDocument/hover")
        XCTAssertEqual(captured.count, 1)
        let p = captured[0]
        let td = p["textDocument"] as? [String: Any]
        let tdUri: String? = td?["uri"] as? String
        XCTAssertEqual(tdUri, fileA)
        let pos = p["position"] as? [String: Any]
        let posLine: Int? = pos?["line"] as? Int
        let posChar: Int? = pos?["character"] as? Int
        XCTAssertEqual(posLine, 5)
        XCTAssertEqual(posChar, 12)
    }

    // MARK: - 4. lsp_definition dispatch

    func test_handleToolCall_lspDefinition_sendsCorrectLSPRequest() async throws {
        let (bridge, driver) = await makeBridge()
        let defJSON = """
        [{"uri":"\(fileA)","range":{"start":{"line":0,"character":0},"end":{"line":0,"character":4}}}]
        """
        await driver.setReply(method: "textDocument/definition", jsonResult: defJSON)

        let args = positionArguments(
            file: fileA,
            line: 3,
            column: 7,
            workspaceRoot: workspaceA
        )
        let content = try await bridge.handleToolCall(name: "lsp_definition", arguments: args)
        XCTAssertEqual(content.type, "text")
        XCTAssertTrue(content.text.contains(fileA))

        let captured = await driver.capturedParams(forMethod: "textDocument/definition")
        XCTAssertEqual(captured.count, 1)
        let p = captured[0]
        let td = p["textDocument"] as? [String: Any]
        let tdUri: String? = td?["uri"] as? String
        XCTAssertEqual(tdUri, fileA)
        let pos = p["position"] as? [String: Any]
        let posLine: Int? = pos?["line"] as? Int
        let posChar: Int? = pos?["character"] as? Int
        XCTAssertEqual(posLine, 3)
        XCTAssertEqual(posChar, 7)
    }

    // MARK: - 5. lsp_references includeDeclaration

    func test_handleToolCall_lspReferences_sendsContextIncludeDeclaration() async throws {
        let (bridge, driver) = await makeBridge()
        await driver.setReply(method: "textDocument/references", jsonResult: "[]")

        var args = positionArguments(
            file: fileA,
            line: 1,
            column: 2,
            workspaceRoot: workspaceA
        )
        args["include_declaration"] = AnyCodable(true)
        _ = try await bridge.handleToolCall(name: "lsp_references", arguments: args)

        let captured = await driver.capturedParams(forMethod: "textDocument/references")
        XCTAssertEqual(captured.count, 1)
        let ctx = captured[0]["context"] as? [String: Any]
        let includeDecl: Bool? = ctx?["includeDeclaration"] as? Bool
        XCTAssertEqual(includeDecl, true)
    }

    // MARK: - 6. lsp_workspace_symbol

    func test_handleToolCall_lspWorkspaceSymbol_sendsQuery() async throws {
        let (bridge, driver) = await makeBridge()
        await driver.setReply(method: "workspace/symbol", jsonResult: "[]")

        let args: [String: AnyCodable] = [
            "query": AnyCodable("MyClass"),
            "workspace_root": AnyCodable(workspaceA.path),
            "language_id": AnyCodable("typescript"),
        ]
        _ = try await bridge.handleToolCall(name: "lsp_workspace_symbol", arguments: args)

        let captured = await driver.capturedParams(forMethod: "workspace/symbol")
        XCTAssertEqual(captured.count, 1)
        let query: String? = captured[0]["query"] as? String
        XCTAssertEqual(query, "MyClass")
    }

    // MARK: - 7. lsp_completion with trigger context

    func test_handleToolCall_lspCompletion_sendsContextIfProvided() async throws {
        let (bridge, driver) = await makeBridge()
        await driver.setReply(method: "textDocument/completion", jsonResult: "[]")

        var args = positionArguments(
            file: fileA,
            line: 0,
            column: 0,
            workspaceRoot: workspaceA
        )
        args["trigger_kind"] = AnyCodable(2)
        args["trigger_character"] = AnyCodable(".")
        _ = try await bridge.handleToolCall(name: "lsp_completion", arguments: args)

        let captured = await driver.capturedParams(forMethod: "textDocument/completion")
        XCTAssertEqual(captured.count, 1)
        let ctx = captured[0]["context"] as? [String: Any]
        let triggerKind: Int? = ctx?["triggerKind"] as? Int
        let triggerChar: String? = ctx?["triggerCharacter"] as? String
        XCTAssertEqual(triggerKind, 2)
        XCTAssertEqual(triggerChar, ".")
    }

    // MARK: - 8. Null hover result

    func test_handleToolCall_lspHover_serverReturnsNull_responseIsNull() async throws {
        let (bridge, driver) = await makeBridge()
        await driver.setReply(method: "textDocument/hover", jsonResult: "null")

        let args = positionArguments(
            file: fileA,
            line: 0,
            column: 0,
            workspaceRoot: workspaceA
        )
        let content = try await bridge.handleToolCall(name: "lsp_hover", arguments: args)
        XCTAssertEqual(content.type, "text")
        let trimmed = content.text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        XCTAssertEqual(
            trimmed,
            "null",
            "null result must surface as the JSON string \"null\""
        )
    }

    // MARK: - 9. Error response

    func test_handleToolCall_lspHover_serverReturnsError_responseIsError() async throws {
        let (bridge, driver) = await makeBridge()
        await driver.setError(
            method: "textDocument/hover",
            code: -32603,
            message: "internal error"
        )

        let args = positionArguments(
            file: fileA,
            line: 0,
            column: 0,
            workspaceRoot: workspaceA
        )
        let content = try await bridge.handleToolCall(name: "lsp_hover", arguments: args)
        XCTAssertEqual(content.type, "text")
        XCTAssertTrue(
            content.text.localizedCaseInsensitiveContains("error")
                || content.text.contains("internal error"),
            "error result must carry the server error message; got: \(content.text)"
        )
    }

    // MARK: - 10. Missing required argument

    func test_handleToolCall_missingRequiredArgument_throws() async {
        let (bridge, _) = await makeBridge()

        // `file` is required by every position-based tool. Omit it.
        let args: [String: AnyCodable] = [
            "line": AnyCodable(0),
            "column": AnyCodable(0),
            "workspace_root": AnyCodable(workspaceA.path),
            "language_id": AnyCodable("typescript"),
        ]
        do {
            _ = try await bridge.handleToolCall(name: "lsp_hover", arguments: args)
            XCTFail("expected throw for missing 'file' argument")
        } catch {
            // OK
        }
    }

    // MARK: - 11. documentSymbol (hierarchical)

    func test_handleToolCall_lspDocumentSymbol_returnsHierarchical() async throws {
        let (bridge, driver) = await makeBridge()
        let symJSON = """
        [
          {
            "name": "Foo",
            "kind": 5,
            "range": {"start":{"line":0,"character":0},"end":{"line":10,"character":0}},
            "selectionRange": {"start":{"line":0,"character":6},"end":{"line":0,"character":9}},
            "children": [
              {
                "name": "bar",
                "kind": 6,
                "range": {"start":{"line":1,"character":2},"end":{"line":3,"character":3}},
                "selectionRange": {"start":{"line":1,"character":6},"end":{"line":1,"character":9}}
              }
            ]
          }
        ]
        """
        await driver.setReply(method: "textDocument/documentSymbol", jsonResult: symJSON)

        let args: [String: AnyCodable] = [
            "file": AnyCodable(fileA),
            "workspace_root": AnyCodable(workspaceA.path),
            "language_id": AnyCodable("typescript"),
        ]
        let content = try await bridge.handleToolCall(name: "lsp_document_symbol", arguments: args)
        XCTAssertEqual(content.type, "text")
        XCTAssertTrue(content.text.contains("\"name\":\"Foo\""))
        XCTAssertTrue(content.text.contains("\"name\":\"bar\""), "children must round-trip")

        let captured = await driver.capturedParams(forMethod: "textDocument/documentSymbol")
        XCTAssertEqual(captured.count, 1)
        let td = captured[0]["textDocument"] as? [String: Any]
        let tdUri: String? = td?["uri"] as? String
        XCTAssertEqual(tdUri, fileA)
    }

    // MARK: - 12. documentHighlight returns array

    func test_handleToolCall_lspDocumentHighlight_returnsArray() async throws {
        let (bridge, driver) = await makeBridge()
        let highlightsJSON = """
        [
          {"range":{"start":{"line":1,"character":2},"end":{"line":1,"character":5}},"kind":2},
          {"range":{"start":{"line":3,"character":4},"end":{"line":3,"character":7}},"kind":3}
        ]
        """
        await driver.setReply(method: "textDocument/documentHighlight", jsonResult: highlightsJSON)

        let args = positionArguments(
            file: fileA,
            line: 1,
            column: 2,
            workspaceRoot: workspaceA
        )
        let content = try await bridge.handleToolCall(
            name: "lsp_document_highlight",
            arguments: args
        )
        XCTAssertEqual(content.type, "text")
        XCTAssertTrue(content.text.contains("\"kind\":2"))
        XCTAssertTrue(content.text.contains("\"kind\":3"))
    }

    // MARK: - 13. typeDefinition

    func test_handleToolCall_lspTypeDefinition_returnsLocation() async throws {
        let (bridge, driver) = await makeBridge()
        let locJSON = """
        {"uri":"\(fileA)","range":{"start":{"line":7,"character":0},"end":{"line":7,"character":4}}}
        """
        await driver.setReply(method: "textDocument/typeDefinition", jsonResult: locJSON)

        let args = positionArguments(
            file: fileA,
            line: 1,
            column: 1,
            workspaceRoot: workspaceA
        )
        let content = try await bridge.handleToolCall(
            name: "lsp_type_definition",
            arguments: args
        )
        XCTAssertEqual(content.type, "text")
        XCTAssertTrue(content.text.contains("\"uri\":\"\(fileA)\""))
    }

    // MARK: - 14. Concurrent tool calls share session

    func test_handleToolCall_concurrentToolCalls_shareSession() async throws {
        let (bridge, driver) = await makeBridge()
        // The driver pre-configures replies for two different methods so
        // both branches succeed.
        await driver.setReply(method: "textDocument/hover", jsonResult: "null")
        await driver.setReply(method: "textDocument/definition", jsonResult: "null")

        // Hoist MainActor properties out of `async let` (Swift 6 strict
        // concurrency: do not touch MainActor-isolated `self` inside the
        // structured child).
        let argsA = positionArguments(
            file: fileA,
            line: 1,
            column: 1,
            workspaceRoot: workspaceA
        )
        let argsB = positionArguments(
            file: fileA,
            line: 2,
            column: 2,
            workspaceRoot: workspaceA
        )

        async let a = bridge.handleToolCall(name: "lsp_hover", arguments: argsA)
        async let b = bridge.handleToolCall(name: "lsp_definition", arguments: argsB)
        _ = try await a
        _ = try await b

        let made = await driver.clientsMadeCount()
        XCTAssertEqual(
            made,
            1,
            "concurrent tool calls to the same (workspace, languageId) must share one LSPSession"
        )
    }

    // MARK: - 15. Different workspaces use different sessions

    func test_handleToolCall_differentWorkspaces_useDifferentSessions() async throws {
        let (bridge, driver) = await makeBridge()
        await driver.setReply(method: "textDocument/hover", jsonResult: "null")

        let argsA = positionArguments(
            file: fileA,
            line: 0,
            column: 0,
            workspaceRoot: workspaceA
        )
        _ = try await bridge.handleToolCall(name: "lsp_hover", arguments: argsA)

        // Second workspace; pre-load another reply for the second hover.
        await driver.setReply(method: "textDocument/hover", jsonResult: "null")
        let argsB = positionArguments(
            file: fileB,
            line: 0,
            column: 0,
            workspaceRoot: workspaceB
        )
        _ = try await bridge.handleToolCall(name: "lsp_hover", arguments: argsB)

        let made = await driver.clientsMadeCount()
        XCTAssertEqual(
            made,
            2,
            "distinct workspace_root values must produce distinct LSP sessions"
        )
    }
}
