//
//  MCPLSPBridgeEditWorkspaceToolsTests.swift
//  Calyx
//
//  TDD red-phase tests for the eleven "edit + workspace cluster" MCP tools the
//  LSP bridge will ship on top of the 43 tools (10 core + 11 extended +
//  7 hierarchy/moniker + 7 information-cluster-A + 8 information-cluster-B)
//  already routed through `MCPLSPBridge`.
//
//  Tools under test (and how they reach the language server):
//      Typed LSP requests
//        lsp_completion_resolve         -> completionItem/resolve
//        lsp_code_action_resolve        -> codeAction/resolve
//        lsp_formatting                 -> textDocument/formatting
//        lsp_range_formatting           -> textDocument/rangeFormatting
//        lsp_on_type_formatting         -> textDocument/onTypeFormatting
//        lsp_workspace_symbol_resolve   -> workspaceSymbol/resolve
//        lsp_workspace_diagnostic_pull  -> workspace/diagnostic
//        lsp_workspace_execute_command  -> workspace/executeCommand
//      Bridge-internal (no LSP request reaches the server)
//        lsp_workspace_apply_edit       -> Calyx applies the edit locally
//        lsp_workspace_configuration_get -> reads bridge-side configuration
//        lsp_workspace_configuration_set -> writes bridge-side configuration
//
//  Argument shape summary:
//    - lsp_completion_resolve       : workspace_root, language_id, completion_item
//    - lsp_code_action_resolve      : workspace_root, language_id, code_action
//    - lsp_formatting               : workspace_root, language_id, file, options
//    - lsp_range_formatting         : above + start/end_line/column
//    - lsp_on_type_formatting       : workspace_root, language_id, file,
//                                     line, column, ch, options
//    - lsp_workspace_symbol_resolve : workspace_root, language_id,
//                                     workspace_symbol
//    - lsp_workspace_diagnostic_pull: workspace_root, language_id,
//                                     identifier?, previous_result_ids?
//    - lsp_workspace_execute_command: workspace_root, language_id, command,
//                                     arguments?
//    - lsp_workspace_apply_edit     : workspace_root, language_id, edit,
//                                     commit, label?
//    - lsp_workspace_configuration_get: workspace_root, language_id, section
//    - lsp_workspace_configuration_set: workspace_root, language_id, section,
//                                       value
//
//  Special semantics:
//    - lsp_workspace_apply_edit must NOT send an LSP request. The bridge owns
//      the apply. With `commit: false` the call is a dry-run and returns
//      `{"applied":false,"failureReason":"dry-run"}`. With `commit: true` the
//      minimal stub returns `{"applied":true}` (FS write is deferred to a
//      later batch).
//    - lsp_workspace_configuration_get / set MUST NOT send an LSP request.
//      They operate on a bridge-internal `[String: AnyCodable]`-shaped
//      configuration store. Round-trip contract: a value written with `set`
//      under `(workspace_root, language_id, section)` must be returned by a
//      following `get` for the same triple.
//
//  TDD phase: RED. The bridge currently advertises 43 tools and routes only
//  those. These tests are expected to fail at runtime — the catalogue
//  assertion sees 43 names instead of 54, and every `handleToolCall` for one
//  of the new tools surfaces as `MCPLSPBridgeError.unknownTool`.
//
//  Strategy notes:
//    - The fake LSP-server driver and helpers are file-private here to avoid
//      colliding with the symbols of the same name already defined in
//      `MCPLSPBridgeTests.swift`, `MCPLSPBridgeExtendedToolsTests.swift`,
//      `MCPLSPBridgeHierarchyToolsTests.swift`,
//      `MCPLSPBridgeInfoClusterATests.swift` and
//      `MCPLSPBridgeInfoClusterBTests.swift`. Each test file owns its own
//      driver instance.
//    - All tests run on `@MainActor` because `MCPLSPBridge` is
//      `@MainActor`-isolated.
//    - Swift 6.2 strict concurrency: any `[String: Any]` crossing an actor
//      boundary is re-deserialised through a Sendable `Data` payload so the
//      region is fresh on the receiving side.
//

import XCTest
@testable import Calyx

// MARK: - file-private region-detaching helper

/// Deserialize JSON into a fresh `[String: Any]` whose region is independent
/// of any caller-held value. Mirrors the helpers in the sibling bridge test
/// files but is file-private so the six files can compile side-by-side.
fileprivate func freshDictEditWS(fromJSON data: Data) -> sending [String: Any] {
    (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
}

// MARK: - file-private fake LSP server driver

/// Captures every request the bridge sends and emits a configurable
/// response. Lifted near-verbatim from `MCPLSPBridgeInfoClusterBTests` and
/// renamed so the six files can compile side-by-side.
fileprivate actor EditWorkspaceToolsServerDriver: LSPSessionFactory {

    // MARK: - Configuration

    private var methodReplies: [String: String] = [:]
    private var methodErrors: [String: (code: Int, message: String)] = [:]

    /// Captured `params` payloads keyed by method, in arrival order.
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
        driver: EditWorkspaceToolsServerDriver
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
                            params: freshDictEditWS(fromJSON: data)
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

// MARK: - MCPLSPBridgeEditWorkspaceToolsTests

@MainActor
final class MCPLSPBridgeEditWorkspaceToolsTests: XCTestCase {

    // MARK: - Constants

    private let workspaceA = URL(fileURLWithPath: "/tmp/calyx-mcp-lsp-bridge-edit-ws-A")
    private let fileA = "file:///tmp/calyx-mcp-lsp-bridge-edit-ws-A/main.ts"

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
    private func makeBridge() async -> (bridge: MCPLSPBridge, driver: EditWorkspaceToolsServerDriver) {
        let installer = await makeReadyInstaller()
        let driver = EditWorkspaceToolsServerDriver()
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
            installer: installer
        )
        return (bridge, driver)
    }

    /// Standard `FormattingOptions`-shaped argument used by every formatting
    /// tool. Keys mirror the LSP wire format exactly; the bridge forwards
    /// the value verbatim.
    private func sampleFormattingOptions(
        tabSize: Int = 4,
        insertSpaces: Bool = true
    ) -> AnyCodable {
        AnyCodable([
            "tabSize": AnyCodable(tabSize),
            "insertSpaces": AnyCodable(insertSpaces),
        ] as [String: AnyCodable])
    }

    /// Minimal `CompletionItem`-shaped JSON payload for use as the
    /// `completion_item` argument of `lsp_completion_resolve`.
    private func sampleCompletionItem(
        label: String = "foo",
        kind: Int = 3,
        data: String = "opaque"
    ) -> AnyCodable {
        AnyCodable([
            "label": AnyCodable(label),
            "kind": AnyCodable(kind),
            "data": AnyCodable(["key": AnyCodable(data)] as [String: AnyCodable]),
        ] as [String: AnyCodable])
    }

    /// Minimal `CodeAction`-shaped JSON payload for use as the `code_action`
    /// argument of `lsp_code_action_resolve`.
    private func sampleCodeAction(
        title: String = "Add import",
        kind: String = "quickfix"
    ) -> AnyCodable {
        AnyCodable([
            "title": AnyCodable(title),
            "kind": AnyCodable(kind),
            "data": AnyCodable(["actionId": AnyCodable("act-1")] as [String: AnyCodable]),
        ] as [String: AnyCodable])
    }

    /// Minimal `WorkspaceSymbol`-shaped JSON payload for use as the
    /// `workspace_symbol` argument of `lsp_workspace_symbol_resolve`. Uses
    /// the lazy `{ uri }` location shape so the test exercises the case
    /// resolve is most useful for.
    private func sampleWorkspaceSymbol(
        name: String = "MyType",
        kind: Int = 5,
        uri: String = "file:///tmp/x.ts"
    ) -> AnyCodable {
        AnyCodable([
            "name": AnyCodable(name),
            "kind": AnyCodable(kind),
            "location": AnyCodable([
                "uri": AnyCodable(uri),
            ] as [String: AnyCodable]),
            "data": AnyCodable(["resolveKey": AnyCodable("sym-7")] as [String: AnyCodable]),
        ] as [String: AnyCodable])
    }

    /// Minimal `WorkspaceEdit`-shaped JSON payload for the `edit` argument
    /// of `lsp_workspace_apply_edit`. Carries a single `changes` map with one
    /// TextEdit.
    private func sampleWorkspaceEdit(
        uri: String = "file:///tmp/x.ts",
        newText: String = "bar"
    ) -> AnyCodable {
        let textEdit: [String: AnyCodable] = [
            "range": AnyCodable([
                "start": AnyCodable([
                    "line": AnyCodable(0),
                    "character": AnyCodable(0),
                ] as [String: AnyCodable]),
                "end": AnyCodable([
                    "line": AnyCodable(0),
                    "character": AnyCodable(3),
                ] as [String: AnyCodable]),
            ] as [String: AnyCodable]),
            "newText": AnyCodable(newText),
        ]
        return AnyCodable([
            "changes": AnyCodable([
                uri: AnyCodable([AnyCodable(textEdit)]),
            ] as [String: AnyCodable]),
        ] as [String: AnyCodable])
    }

    // MARK: - 1. tools/list catalogue (edit + workspace cluster)

    func test_tools_listIncludesEditWorkspaceTools() {
        let names = MCPLSPBridge.tools.map { $0.name }

        let expectedNew = [
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
        ]
        for name in expectedNew {
            XCTAssertTrue(
                names.contains(name),
                "MCPLSPBridge.tools must advertise edit+workspace tool \(name); got names=\(names)"
            )
        }

        XCTAssertEqual(
            names.count,
            54,
            "tools count must be 43 existing + 11 edit+workspace = 54; got \(names.count) names=\(names)"
        )
    }

    // MARK: - 2. lsp_completion_resolve forwards the completion item

    func test_lspCompletionResolve_sendsCompletionItem() async throws {
        let (bridge, driver) = await makeBridge()
        let resolvedJSON = """
        {
          "label":"foo",
          "kind":3,
          "detail":"foo(x: Int): String",
          "documentation":"Resolved docs"
        }
        """
        await driver.setReply(method: "completionItem/resolve", jsonResult: resolvedJSON)

        let args: [String: AnyCodable] = [
            "workspace_root": AnyCodable(workspaceA.path),
            "language_id": AnyCodable("typescript"),
            "completion_item": sampleCompletionItem(label: "foo", kind: 3),
        ]
        let content = try await bridge.handleToolCall(
            name: "lsp_completion_resolve",
            arguments: args
        )
        XCTAssertEqual(content.type, "text")
        XCTAssertTrue(
            content.text.contains("\"detail\":\"foo(x: Int): String\""),
            "completionItem/resolve detail must round-trip; got: \(content.text)"
        )

        let captured = await driver.capturedParams(forMethod: "completionItem/resolve")
        XCTAssertEqual(captured.count, 1)
        // The captured `params` for `completionItem/resolve` IS the
        // CompletionItem itself (no nested "completion_item" key). The bridge
        // forwards the value verbatim.
        XCTAssertEqual(captured[0]["label"] as? String, "foo")
        XCTAssertEqual(captured[0]["kind"] as? Int, 3)
    }

    // MARK: - 3. lsp_code_action_resolve forwards the code action

    func test_lspCodeActionResolve_sendsCodeAction() async throws {
        let (bridge, driver) = await makeBridge()
        let resolvedJSON = """
        {
          "title":"Add import",
          "kind":"quickfix",
          "edit":{
            "changes":{
              "file:///tmp/x.ts":[
                {"newText":"import x;","range":{"start":{"line":0,"character":0},"end":{"line":0,"character":0}}}
              ]
            }
          }
        }
        """
        await driver.setReply(method: "codeAction/resolve", jsonResult: resolvedJSON)

        let args: [String: AnyCodable] = [
            "workspace_root": AnyCodable(workspaceA.path),
            "language_id": AnyCodable("typescript"),
            "code_action": sampleCodeAction(title: "Add import", kind: "quickfix"),
        ]
        let content = try await bridge.handleToolCall(
            name: "lsp_code_action_resolve",
            arguments: args
        )
        XCTAssertEqual(content.type, "text")
        XCTAssertTrue(
            content.text.contains("\"newText\":\"import x;\""),
            "codeAction/resolve edit must round-trip; got: \(content.text)"
        )

        let captured = await driver.capturedParams(forMethod: "codeAction/resolve")
        XCTAssertEqual(captured.count, 1)
        // The captured `params` for `codeAction/resolve` IS the CodeAction
        // itself (no nested "code_action" key). The bridge forwards verbatim.
        XCTAssertEqual(captured[0]["title"] as? String, "Add import")
        XCTAssertEqual(captured[0]["kind"] as? String, "quickfix")
    }

    // MARK: - 4. lsp_formatting sends the whole-document formatting request

    func test_lspFormatting_sendsCorrectLSPRequest() async throws {
        let (bridge, driver) = await makeBridge()
        let editsJSON = """
        [
          {"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":5}},
           "newText":"hello"}
        ]
        """
        await driver.setReply(method: "textDocument/formatting", jsonResult: editsJSON)

        let args: [String: AnyCodable] = [
            "workspace_root": AnyCodable(workspaceA.path),
            "language_id": AnyCodable("typescript"),
            "file": AnyCodable(fileA),
            "options": sampleFormattingOptions(tabSize: 2, insertSpaces: true),
        ]
        let content = try await bridge.handleToolCall(
            name: "lsp_formatting",
            arguments: args
        )
        XCTAssertEqual(content.type, "text")
        XCTAssertTrue(
            content.text.contains("\"newText\":\"hello\""),
            "formatting result must round-trip; got: \(content.text)"
        )

        let captured = await driver.capturedParams(forMethod: "textDocument/formatting")
        XCTAssertEqual(captured.count, 1)
        let td = captured[0]["textDocument"] as? [String: Any]
        XCTAssertEqual(td?["uri"] as? String, fileA)
        let options = captured[0]["options"] as? [String: Any]
        XCTAssertNotNil(options, "formatting params must carry an 'options' object")
        XCTAssertEqual(options?["tabSize"] as? Int, 2)
        XCTAssertEqual(options?["insertSpaces"] as? Bool, true)
        XCTAssertNil(
            captured[0]["range"],
            "formatting params must NOT carry a range (this is a whole-document request)"
        )
    }

    // MARK: - 5. lsp_range_formatting sends the range-scoped formatting request

    func test_lspRangeFormatting_sendsCorrectLSPRequest() async throws {
        let (bridge, driver) = await makeBridge()
        let editsJSON = """
        [
          {"range":{"start":{"line":2,"character":0},"end":{"line":2,"character":3}},
           "newText":"FOO"}
        ]
        """
        await driver.setReply(method: "textDocument/rangeFormatting", jsonResult: editsJSON)

        let args: [String: AnyCodable] = [
            "workspace_root": AnyCodable(workspaceA.path),
            "language_id": AnyCodable("typescript"),
            "file": AnyCodable(fileA),
            "start_line": AnyCodable(2),
            "start_column": AnyCodable(0),
            "end_line": AnyCodable(5),
            "end_column": AnyCodable(0),
            "options": sampleFormattingOptions(tabSize: 4, insertSpaces: false),
        ]
        let content = try await bridge.handleToolCall(
            name: "lsp_range_formatting",
            arguments: args
        )
        XCTAssertEqual(content.type, "text")
        XCTAssertTrue(
            content.text.contains("\"newText\":\"FOO\""),
            "rangeFormatting result must round-trip; got: \(content.text)"
        )

        let captured = await driver.capturedParams(forMethod: "textDocument/rangeFormatting")
        XCTAssertEqual(captured.count, 1)
        let td = captured[0]["textDocument"] as? [String: Any]
        XCTAssertEqual(td?["uri"] as? String, fileA)
        let range = captured[0]["range"] as? [String: Any]
        let start = range?["start"] as? [String: Any]
        let end = range?["end"] as? [String: Any]
        XCTAssertEqual(start?["line"] as? Int, 2)
        XCTAssertEqual(start?["character"] as? Int, 0)
        XCTAssertEqual(end?["line"] as? Int, 5)
        XCTAssertEqual(end?["character"] as? Int, 0)
        let options = captured[0]["options"] as? [String: Any]
        XCTAssertEqual(options?["tabSize"] as? Int, 4)
        XCTAssertEqual(options?["insertSpaces"] as? Bool, false)
    }

    // MARK: - 6. lsp_on_type_formatting sends the on-type formatting request

    func test_lspOnTypeFormatting_sendsCorrectLSPRequest() async throws {
        let (bridge, driver) = await makeBridge()
        let editsJSON = """
        [
          {"range":{"start":{"line":12,"character":0},"end":{"line":12,"character":2}},
           "newText":"  "}
        ]
        """
        await driver.setReply(method: "textDocument/onTypeFormatting", jsonResult: editsJSON)

        let args: [String: AnyCodable] = [
            "workspace_root": AnyCodable(workspaceA.path),
            "language_id": AnyCodable("typescript"),
            "file": AnyCodable(fileA),
            "line": AnyCodable(12),
            "column": AnyCodable(1),
            "ch": AnyCodable("}"),
            "options": sampleFormattingOptions(tabSize: 2, insertSpaces: true),
        ]
        let content = try await bridge.handleToolCall(
            name: "lsp_on_type_formatting",
            arguments: args
        )
        XCTAssertEqual(content.type, "text")
        XCTAssertTrue(
            content.text.contains("\"newText\":\"  \""),
            "onTypeFormatting result must round-trip; got: \(content.text)"
        )

        let captured = await driver.capturedParams(forMethod: "textDocument/onTypeFormatting")
        XCTAssertEqual(captured.count, 1)
        let td = captured[0]["textDocument"] as? [String: Any]
        XCTAssertEqual(td?["uri"] as? String, fileA)
        let pos = captured[0]["position"] as? [String: Any]
        XCTAssertEqual(pos?["line"] as? Int, 12)
        XCTAssertEqual(pos?["character"] as? Int, 1)
        XCTAssertEqual(captured[0]["ch"] as? String, "}")
        let options = captured[0]["options"] as? [String: Any]
        XCTAssertEqual(options?["tabSize"] as? Int, 2)
        XCTAssertEqual(options?["insertSpaces"] as? Bool, true)
    }

    // MARK: - 7. lsp_workspace_symbol_resolve forwards the workspace symbol

    func test_lspWorkspaceSymbolResolve_sendsWorkspaceSymbol() async throws {
        let (bridge, driver) = await makeBridge()
        let resolvedJSON = """
        {
          "name":"MyType",
          "kind":5,
          "location":{
            "uri":"file:///tmp/x.ts",
            "range":{"start":{"line":3,"character":0},"end":{"line":3,"character":10}}
          }
        }
        """
        await driver.setReply(method: "workspaceSymbol/resolve", jsonResult: resolvedJSON)

        let args: [String: AnyCodable] = [
            "workspace_root": AnyCodable(workspaceA.path),
            "language_id": AnyCodable("typescript"),
            "workspace_symbol": sampleWorkspaceSymbol(
                name: "MyType",
                kind: 5,
                uri: "file:///tmp/x.ts"
            ),
        ]
        let content = try await bridge.handleToolCall(
            name: "lsp_workspace_symbol_resolve",
            arguments: args
        )
        XCTAssertEqual(content.type, "text")
        XCTAssertTrue(
            content.text.contains("\"name\":\"MyType\""),
            "workspaceSymbol/resolve name must round-trip; got: \(content.text)"
        )

        let captured = await driver.capturedParams(forMethod: "workspaceSymbol/resolve")
        XCTAssertEqual(captured.count, 1)
        // The captured `params` for `workspaceSymbol/resolve` IS the
        // WorkspaceSymbol itself (no nested "workspace_symbol" key). The
        // bridge forwards the value verbatim.
        XCTAssertEqual(captured[0]["name"] as? String, "MyType")
        XCTAssertEqual(captured[0]["kind"] as? Int, 5)
        let loc = captured[0]["location"] as? [String: Any]
        XCTAssertEqual(loc?["uri"] as? String, "file:///tmp/x.ts")
    }

    // MARK: - 8. lsp_workspace_diagnostic_pull sends workspace/diagnostic

    func test_lspWorkspaceDiagnosticPull_sendsCorrectLSPRequest() async throws {
        let (bridge, driver) = await makeBridge()
        let reportJSON = """
        {
          "items":[
            {"kind":"full","uri":"file:///tmp/x.ts","items":[
              {"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":5}},
               "message":"oops","severity":1}
            ]}
          ]
        }
        """
        await driver.setReply(method: "workspace/diagnostic", jsonResult: reportJSON)

        let previousResultIds: [AnyCodable] = [
            AnyCodable([
                "uri": AnyCodable("file:///tmp/x.ts"),
                "value": AnyCodable("x-prev-1"),
            ] as [String: AnyCodable]),
        ]
        let args: [String: AnyCodable] = [
            "workspace_root": AnyCodable(workspaceA.path),
            "language_id": AnyCodable("typescript"),
            "identifier": AnyCodable("global"),
            "previous_result_ids": AnyCodable(previousResultIds),
        ]
        let content = try await bridge.handleToolCall(
            name: "lsp_workspace_diagnostic_pull",
            arguments: args
        )
        XCTAssertEqual(content.type, "text")
        XCTAssertTrue(
            content.text.contains("\"message\":\"oops\""),
            "workspace/diagnostic message must round-trip; got: \(content.text)"
        )

        let captured = await driver.capturedParams(forMethod: "workspace/diagnostic")
        XCTAssertEqual(captured.count, 1)
        XCTAssertEqual(captured[0]["identifier"] as? String, "global")
        let prev = captured[0]["previousResultIds"] as? [[String: Any]]
        XCTAssertNotNil(
            prev,
            "workspace/diagnostic params must carry a 'previousResultIds' array"
        )
        XCTAssertEqual(prev?.count, 1)
        XCTAssertEqual(prev?[0]["uri"] as? String, "file:///tmp/x.ts")
        XCTAssertEqual(prev?[0]["value"] as? String, "x-prev-1")
    }

    // MARK: - 9. lsp_workspace_execute_command sends workspace/executeCommand

    func test_lspWorkspaceExecuteCommand_sendsCorrectLSPRequest() async throws {
        let (bridge, driver) = await makeBridge()
        let resultJSON = """
        {"ok":true,"changed":7}
        """
        await driver.setReply(method: "workspace/executeCommand", jsonResult: resultJSON)

        let args: [String: AnyCodable] = [
            "workspace_root": AnyCodable(workspaceA.path),
            "language_id": AnyCodable("typescript"),
            "command": AnyCodable("calyx.organizeImports"),
            "arguments": AnyCodable([
                AnyCodable("file:///tmp/x.ts"),
                AnyCodable(42),
            ]),
        ]
        let content = try await bridge.handleToolCall(
            name: "lsp_workspace_execute_command",
            arguments: args
        )
        XCTAssertEqual(content.type, "text")
        XCTAssertTrue(
            content.text.contains("\"changed\":7"),
            "executeCommand result must round-trip; got: \(content.text)"
        )

        let captured = await driver.capturedParams(forMethod: "workspace/executeCommand")
        XCTAssertEqual(captured.count, 1)
        XCTAssertEqual(captured[0]["command"] as? String, "calyx.organizeImports")
        let arguments = captured[0]["arguments"] as? [Any]
        XCTAssertNotNil(
            arguments,
            "executeCommand params must carry an 'arguments' array"
        )
        XCTAssertEqual(arguments?.count, 2)
        XCTAssertEqual(arguments?[0] as? String, "file:///tmp/x.ts")
        XCTAssertEqual(arguments?[1] as? Int, 42)
    }

    // MARK: - 10. lsp_workspace_apply_edit commit:true returns applied:true and sends NO LSP request

    func test_lspWorkspaceApplyEdit_commitTrue_returnsApplied_noLSPRequest() async throws {
        let (bridge, driver) = await makeBridge()

        let args: [String: AnyCodable] = [
            "workspace_root": AnyCodable(workspaceA.path),
            "language_id": AnyCodable("typescript"),
            "edit": sampleWorkspaceEdit(),
            "commit": AnyCodable(true),
            "label": AnyCodable("Rename foo to bar"),
        ]
        let content = try await bridge.handleToolCall(
            name: "lsp_workspace_apply_edit",
            arguments: args
        )
        XCTAssertEqual(content.type, "text")
        XCTAssertTrue(
            content.text.contains("\"applied\":true"),
            "apply_edit with commit:true must return applied:true; got: \(content.text)"
        )

        // No LSP request must have been routed to the server. workspace/applyEdit
        // is server -> client; the AI-facing tool is bridge-internal.
        let captured = await driver.capturedParams(forMethod: "workspace/applyEdit")
        XCTAssertEqual(
            captured.count,
            0,
            "apply_edit must NOT send a workspace/applyEdit LSP request; got captured=\(captured)"
        )
        let total = await driver.totalCapturedCount()
        XCTAssertEqual(
            total,
            0,
            "apply_edit must not route ANY LSP request through the session; got total=\(total)"
        )
    }

    // MARK: - 11. lsp_workspace_apply_edit commit:false returns dry-run failure

    func test_lspWorkspaceApplyEdit_commitFalse_returnsDryRun() async throws {
        let (bridge, driver) = await makeBridge()

        let args: [String: AnyCodable] = [
            "workspace_root": AnyCodable(workspaceA.path),
            "language_id": AnyCodable("typescript"),
            "edit": sampleWorkspaceEdit(),
            "commit": AnyCodable(false),
        ]
        let content = try await bridge.handleToolCall(
            name: "lsp_workspace_apply_edit",
            arguments: args
        )
        XCTAssertEqual(content.type, "text")
        XCTAssertTrue(
            content.text.contains("\"applied\":false"),
            "apply_edit dry-run must return applied:false; got: \(content.text)"
        )
        XCTAssertTrue(
            content.text.contains("\"failureReason\":\"dry-run\""),
            "apply_edit dry-run must surface failureReason 'dry-run'; got: \(content.text)"
        )

        let total = await driver.totalCapturedCount()
        XCTAssertEqual(
            total,
            0,
            "apply_edit dry-run must not route ANY LSP request; got total=\(total)"
        )
    }

    // MARK: - 12. lsp_workspace_configuration set + get round-trip

    func test_lspWorkspaceConfigurationSet_thenGet_roundtrips() async throws {
        let (bridge, driver) = await makeBridge()

        // Set the value first.
        let setArgs: [String: AnyCodable] = [
            "workspace_root": AnyCodable(workspaceA.path),
            "language_id": AnyCodable("typescript"),
            "section": AnyCodable("editor.tabSize"),
            "value": AnyCodable(4),
        ]
        let setContent = try await bridge.handleToolCall(
            name: "lsp_workspace_configuration_set",
            arguments: setArgs
        )
        XCTAssertEqual(setContent.type, "text")

        // Now read it back. The bridge MUST surface the same `4` for the same
        // (workspace, language, section) triple.
        let getArgs: [String: AnyCodable] = [
            "workspace_root": AnyCodable(workspaceA.path),
            "language_id": AnyCodable("typescript"),
            "section": AnyCodable("editor.tabSize"),
        ]
        let getContent = try await bridge.handleToolCall(
            name: "lsp_workspace_configuration_get",
            arguments: getArgs
        )
        XCTAssertEqual(getContent.type, "text")

        // The returned text is the JSON encoding of the stored value. For an
        // Int the value is `4` (possibly wrapped in a small object — both
        // shapes are acceptable so long as `4` is recoverable from the JSON).
        guard let data = getContent.text.data(using: .utf8) else {
            XCTFail("configuration_get text must be UTF-8 decodable")
            return
        }
        let parsed = try? JSONSerialization.jsonObject(
            with: data,
            options: [.fragmentsAllowed]
        )
        switch parsed {
        case let n as NSNumber:
            XCTAssertEqual(
                n.intValue,
                4,
                "configuration_get must return the integer 4 set via configuration_set"
            )
        case let dict as [String: Any]:
            // Accept either { "value": 4 } or { "<section>": 4 } as alternate
            // shapes. Whatever shape the implementer chooses, the integer 4
            // must be present somewhere in the JSON.
            XCTAssertTrue(
                getContent.text.contains("4"),
                "configuration_get must surface the integer 4 somewhere; got: \(getContent.text), parsed=\(dict)"
            )
        default:
            XCTFail("configuration_get result must be a JSON number or object; got: \(getContent.text)")
        }

        // Neither tool may reach the LSP server.
        let total = await driver.totalCapturedCount()
        XCTAssertEqual(
            total,
            0,
            "configuration_get / configuration_set must not route ANY LSP request; got total=\(total)"
        )
    }

    // MARK: - 13. lsp_workspace_configuration_get for an unset section returns null

    func test_lspWorkspaceConfigurationGet_unsetSection_returnsNullish() async throws {
        let (bridge, driver) = await makeBridge()

        // No prior `set` call: the section is unknown to the bridge.
        let getArgs: [String: AnyCodable] = [
            "workspace_root": AnyCodable(workspaceA.path),
            "language_id": AnyCodable("typescript"),
            "section": AnyCodable("never.set.before"),
        ]
        let content = try await bridge.handleToolCall(
            name: "lsp_workspace_configuration_get",
            arguments: getArgs
        )
        XCTAssertEqual(content.type, "text")

        // The exact shape of "no value" can be either the bare token `null`,
        // an empty JSON object `{}`, or a `{"value":null}` envelope. All
        // three communicate "section unset"; pick the one the implementer
        // ships. The single hard invariant is: the response MUST NOT carry
        // the integer 4 (i.e. no leakage from prior tests / no spurious
        // defaults).
        let text = content.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let acceptable: Set<String> = ["null", "{}", "{\"value\":null}"]
        XCTAssertTrue(
            acceptable.contains(text),
            "configuration_get for an unset section must return one of \(acceptable); got: \(text)"
        )

        let total = await driver.totalCapturedCount()
        XCTAssertEqual(
            total,
            0,
            "configuration_get must not route any LSP request; got total=\(total)"
        )
    }

    // MARK: - 14. lsp_completion_resolve missing completion_item throws

    func test_lspCompletionResolve_missingCompletionItem_throws() async {
        let (bridge, _) = await makeBridge()

        // `completion_item` is required; omit it to provoke a missing-arg error.
        let args: [String: AnyCodable] = [
            "workspace_root": AnyCodable(workspaceA.path),
            "language_id": AnyCodable("typescript"),
        ]
        do {
            _ = try await bridge.handleToolCall(
                name: "lsp_completion_resolve",
                arguments: args
            )
            XCTFail("expected throw for missing 'completion_item' argument")
        } catch {
            // OK — any error type is acceptable; the bridge just has to refuse.
        }
    }

    // MARK: - 15. lsp_workspace_apply_edit missing edit throws

    func test_lspWorkspaceApplyEdit_missingEdit_throws() async {
        let (bridge, _) = await makeBridge()

        // `edit` is required; omit it to provoke a missing-arg error.
        let args: [String: AnyCodable] = [
            "workspace_root": AnyCodable(workspaceA.path),
            "language_id": AnyCodable("typescript"),
            "commit": AnyCodable(true),
        ]
        do {
            _ = try await bridge.handleToolCall(
                name: "lsp_workspace_apply_edit",
                arguments: args
            )
            XCTFail("expected throw for missing 'edit' argument")
        } catch {
            // OK
        }
    }
}
