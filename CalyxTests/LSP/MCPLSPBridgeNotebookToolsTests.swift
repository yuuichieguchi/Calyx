//
//  MCPLSPBridgeNotebookToolsTests.swift
//  Calyx
//
//  TDD red-phase tests for the three "notebook document synchronisation"
//  MCP tools the LSP bridge will ship on top of the 67 tools (10 core + 11
//  extended + 7 hierarchy/moniker + 7 information-cluster-A + 8
//  information-cluster-B + 11 edit/workspace cluster + 13 file-ops/AI)
//  already routed through `MCPLSPBridge`.
//
//  Tools under test (all LSP notifications — no response from the server):
//      lsp_notebook_did_open   -> notebookDocument/didOpen
//      lsp_notebook_did_change -> notebookDocument/didChange
//      lsp_notebook_did_close  -> notebookDocument/didClose
//
//  Argument-shape summary:
//      Each tool takes `workspace_root` + `language_id` + a single
//      `notebook: object` payload. The bridge decodes the `notebook` object
//      from `AnyCodable` into the typed `DidOpenNotebookDocumentParams` /
//      `DidChangeNotebookDocumentParams` / `DidCloseNotebookDocumentParams`
//      and forwards it via `LSPSession.sendGenericNotification`. The MCP
//      caller receives a tiny `{"success": true}` payload — notifications
//      have no response.
//
//  TDD phase: RED. The bridge currently advertises 67 tools and routes only
//  those. These tests are expected to fail at runtime — the catalogue
//  assertion sees 67 names instead of 70, and every `handleToolCall` for
//  one of the new tools surfaces as `MCPLSPBridgeError.unknownTool`.
//
//  Strategy notes:
//    - The fake LSP-server driver and helpers are file-private here to
//      avoid colliding with the symbols of the same name already defined
//      in the sibling bridge test files.
//    - All tests run on `@MainActor` because `MCPLSPBridge` is
//      `@MainActor`-isolated.
//    - Swift 6.2 strict concurrency: any `[String: Any]` crossing an actor
//      boundary is re-deserialised through a Sendable `Data` payload so the
//      region is fresh on the receiving side.
//    - The driver captures both request and notification params so the
//      did_open / did_change / did_close tests can assert that the
//      notification reached the server.
//

import XCTest
@testable import Calyx

// MARK: - file-private region-detaching helper

/// Deserialize JSON into a fresh `[String: Any]` whose region is independent
/// of any caller-held value. Mirrors the helpers in the sibling bridge test
/// files but is file-private so the files can compile side-by-side.
fileprivate func freshDictNotebook(fromJSON data: Data) -> sending [String: Any] {
    (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
}

// MARK: - file-private fake LSP server driver

/// Captures every request *and notification* the bridge sends and emits a
/// configurable response for each request. The notification branch is the
/// only structural difference from the drivers in the sibling test files —
/// it records the params payload but never writes a response back to the
/// transport.
fileprivate actor NotebookToolsServerDriver: LSPSessionFactory {

    // MARK: - Configuration

    private var methodReplies: [String: String] = [:]
    private var methodErrors: [String: (code: Int, message: String)] = [:]

    /// Captured `params` payloads keyed by method, in arrival order. Holds
    /// both request and notification params; the test inspects this map
    /// regardless of which JSON-RPC verb the bridge used.
    private var paramsCaptured: [String: [[String: Any]]] = [:]
    private(set) var clientsMade: Int = 0
    private var transports: [InMemoryLSPTransport] = []
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

    func totalCapturedCount() -> Int {
        paramsCaptured.values.reduce(0) { $0 + $1.count }
    }

    func clientsMadeCount() -> Int { clientsMade }

    /// Poll `paramsCaptured` until at least `count` captures for `method`
    /// arrive or `timeoutMs` elapses.
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
        driver: NotebookToolsServerDriver
    ) async {
        var answeredIds: Set<Int> = []
        var handledNotificationIndices: Set<Int> = []

        for _ in 0..<4000 {
            let sent = await transport.sentMessages()
            for (idx, data) in sent.enumerated() {
                guard let dict = parseFramedJSON(data) else { continue }
                guard let method = dict["method"] as? String else { continue }

                if let id = extractId(dict["id"]) {
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
                                params: freshDictNotebook(fromJSON: data)
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
                                params: freshDictNotebook(fromJSON: data)
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
            return n.intValue
        }
        if let s = any as? String { return Int(s) }
        return nil
    }
}

// MARK: - MCPLSPBridgeNotebookToolsTests

@MainActor
final class MCPLSPBridgeNotebookToolsTests: XCTestCase {

    // MARK: - Constants

    private let workspaceA = URL(fileURLWithPath: "/tmp/calyx-mcp-lsp-bridge-notebook-A")
    private let fileA = "file:///tmp/calyx-mcp-lsp-bridge-notebook-A/main.ts"
    private let notebookUri = "file:///tmp/calyx-mcp-lsp-bridge-notebook-A/example.ipynb"
    private let cellOneUri = "file:///tmp/calyx-mcp-lsp-bridge-notebook-A/cell-1.py"
    private let cellTwoUri = "file:///tmp/calyx-mcp-lsp-bridge-notebook-A/cell-2.py"

    // MARK: - Helpers

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

    private func makeBridge() async -> (bridge: MCPLSPBridge, driver: NotebookToolsServerDriver) {
        let installer = await makeReadyInstaller()
        let driver = NotebookToolsServerDriver()
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

    /// Warm one LSPService session for the bridge's workspace+language so
    /// the subsequent notification reaches a `.running` LSPSession
    /// (notifications are refused before initialize completes).
    private func warmDefaultSession(
        bridge: MCPLSPBridge,
        driver: NotebookToolsServerDriver
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

    /// Build the `notebook` AnyCodable argument for `lsp_notebook_did_open`.
    /// Matches the wire shape of `DidOpenNotebookDocumentParams`.
    private func didOpenNotebookAny() -> AnyCodable {
        let cell: [String: AnyCodable] = [
            "document": AnyCodable(cellOneUri),
            "kind": AnyCodable(2),
        ]
        let notebookDoc: [String: AnyCodable] = [
            "uri": AnyCodable(notebookUri),
            "notebookType": AnyCodable("jupyter-notebook"),
            "version": AnyCodable(1),
            "cells": AnyCodable([AnyCodable(cell)]),
        ]
        let cellTextDoc: [String: AnyCodable] = [
            "uri": AnyCodable(cellOneUri),
            "languageId": AnyCodable("python"),
            "version": AnyCodable(1),
            "text": AnyCodable("print(1)"),
        ]
        return AnyCodable([
            "notebookDocument": AnyCodable(notebookDoc),
            "cellTextDocuments": AnyCodable([AnyCodable(cellTextDoc)]),
        ] as [String: AnyCodable])
    }

    /// Build the `notebook` AnyCodable argument for `lsp_notebook_did_change`.
    /// Matches the wire shape of `DidChangeNotebookDocumentParams`.
    private func didChangeNotebookAny() -> AnyCodable {
        let versioned: [String: AnyCodable] = [
            "uri": AnyCodable(notebookUri),
            "version": AnyCodable(2),
        ]
        let textChange: [String: AnyCodable] = [
            "text": AnyCodable("y = 2"),
        ]
        let textContentEntry: [String: AnyCodable] = [
            "document": AnyCodable([
                "uri": AnyCodable(cellOneUri),
                "version": AnyCodable(2),
            ] as [String: AnyCodable]),
            "changes": AnyCodable([AnyCodable(textChange)]),
        ]
        let cells: [String: AnyCodable] = [
            "textContent": AnyCodable([AnyCodable(textContentEntry)]),
        ]
        let change: [String: AnyCodable] = [
            "cells": AnyCodable(cells),
        ]
        return AnyCodable([
            "notebookDocument": AnyCodable(versioned),
            "change": AnyCodable(change),
        ] as [String: AnyCodable])
    }

    /// Build the `notebook` AnyCodable argument for `lsp_notebook_did_close`.
    /// Matches the wire shape of `DidCloseNotebookDocumentParams`.
    private func didCloseNotebookAny() -> AnyCodable {
        let identifier: [String: AnyCodable] = [
            "uri": AnyCodable(notebookUri),
        ]
        let cellId1: [String: AnyCodable] = ["uri": AnyCodable(cellOneUri)]
        let cellId2: [String: AnyCodable] = ["uri": AnyCodable(cellTwoUri)]
        return AnyCodable([
            "notebookDocument": AnyCodable(identifier),
            "cellTextDocuments": AnyCodable([AnyCodable(cellId1), AnyCodable(cellId2)]),
        ] as [String: AnyCodable])
    }

    // MARK: - 1. tools/list catalogue (notebook cluster)

    func test_tools_listIncludesNotebookTools() {
        let names = MCPLSPBridge.tools.map { $0.name }

        let expectedNew = [
            "lsp_notebook_did_open",
            "lsp_notebook_did_change",
            "lsp_notebook_did_close",
        ]
        for name in expectedNew {
            XCTAssertTrue(
                names.contains(name),
                "MCPLSPBridge.tools must advertise notebook tool \(name); got names=\(names)"
            )
        }

        XCTAssertEqual(
            names.count,
            70,
            "tools count must be 67 existing + 3 notebook = 70; got \(names.count) names=\(names)"
        )
    }

    // MARK: - 2. lsp_notebook_did_open sends notebookDocument/didOpen

    func test_lspNotebookDidOpen_sendsNotification() async throws {
        let (bridge, driver) = await makeBridge()
        try await warmDefaultSession(bridge: bridge, driver: driver)

        let args: [String: AnyCodable] = [
            "workspace_root": AnyCodable(workspaceA.path),
            "language_id": AnyCodable("typescript"),
            "notebook": didOpenNotebookAny(),
        ]
        let content = try await bridge.handleToolCall(
            name: "lsp_notebook_did_open",
            arguments: args
        )
        XCTAssertEqual(content.type, "text")
        // Notification — bridge surfaces a tiny success payload.
        XCTAssertTrue(
            content.text.contains("\"success\":true")
                || content.text.contains("\"success\": true"),
            "lsp_notebook_did_open must return a success payload; got: \(content.text)"
        )

        let arrived = await driver.waitForCapture(method: "notebookDocument/didOpen")
        XCTAssertTrue(arrived, "notebookDocument/didOpen notification must reach the server within 2s")

        let captured = await driver.capturedParams(forMethod: "notebookDocument/didOpen")
        XCTAssertEqual(captured.count, 1)
        let notebookDoc = captured[0]["notebookDocument"] as? [String: Any]
        XCTAssertEqual(notebookDoc?["uri"] as? String, notebookUri)
        XCTAssertEqual(notebookDoc?["notebookType"] as? String, "jupyter-notebook")
        XCTAssertEqual(notebookDoc?["version"] as? Int, 1)
        let cells = notebookDoc?["cells"] as? [[String: Any]]
        XCTAssertEqual(cells?.count, 1)
        XCTAssertEqual(cells?[0]["document"] as? String, cellOneUri)
        XCTAssertEqual(cells?[0]["kind"] as? Int, 2)
        let cellTextDocs = captured[0]["cellTextDocuments"] as? [[String: Any]]
        XCTAssertEqual(cellTextDocs?.count, 1)
        XCTAssertEqual(cellTextDocs?[0]["uri"] as? String, cellOneUri)
        XCTAssertEqual(cellTextDocs?[0]["languageId"] as? String, "python")
        XCTAssertEqual(cellTextDocs?[0]["text"] as? String, "print(1)")
    }

    // MARK: - 3. lsp_notebook_did_change sends notebookDocument/didChange

    func test_lspNotebookDidChange_sendsNotification() async throws {
        let (bridge, driver) = await makeBridge()
        try await warmDefaultSession(bridge: bridge, driver: driver)

        let args: [String: AnyCodable] = [
            "workspace_root": AnyCodable(workspaceA.path),
            "language_id": AnyCodable("typescript"),
            "notebook": didChangeNotebookAny(),
        ]
        let content = try await bridge.handleToolCall(
            name: "lsp_notebook_did_change",
            arguments: args
        )
        XCTAssertEqual(content.type, "text")
        XCTAssertTrue(
            content.text.contains("\"success\":true")
                || content.text.contains("\"success\": true"),
            "lsp_notebook_did_change must return a success payload; got: \(content.text)"
        )

        let arrived = await driver.waitForCapture(method: "notebookDocument/didChange")
        XCTAssertTrue(arrived, "notebookDocument/didChange notification must reach the server within 2s")

        let captured = await driver.capturedParams(forMethod: "notebookDocument/didChange")
        XCTAssertEqual(captured.count, 1)
        let versioned = captured[0]["notebookDocument"] as? [String: Any]
        XCTAssertEqual(versioned?["uri"] as? String, notebookUri)
        XCTAssertEqual(versioned?["version"] as? Int, 2)
        let change = captured[0]["change"] as? [String: Any]
        let cells = change?["cells"] as? [String: Any]
        let textContent = cells?["textContent"] as? [[String: Any]]
        XCTAssertEqual(textContent?.count, 1)
        let doc = textContent?[0]["document"] as? [String: Any]
        XCTAssertEqual(doc?["uri"] as? String, cellOneUri)
        XCTAssertEqual(doc?["version"] as? Int, 2)
        let textChanges = textContent?[0]["changes"] as? [[String: Any]]
        XCTAssertEqual(textChanges?.count, 1)
        XCTAssertEqual(textChanges?[0]["text"] as? String, "y = 2")
    }

    // MARK: - 4. lsp_notebook_did_close sends notebookDocument/didClose

    func test_lspNotebookDidClose_sendsNotification() async throws {
        let (bridge, driver) = await makeBridge()
        try await warmDefaultSession(bridge: bridge, driver: driver)

        let args: [String: AnyCodable] = [
            "workspace_root": AnyCodable(workspaceA.path),
            "language_id": AnyCodable("typescript"),
            "notebook": didCloseNotebookAny(),
        ]
        let content = try await bridge.handleToolCall(
            name: "lsp_notebook_did_close",
            arguments: args
        )
        XCTAssertEqual(content.type, "text")
        XCTAssertTrue(
            content.text.contains("\"success\":true")
                || content.text.contains("\"success\": true"),
            "lsp_notebook_did_close must return a success payload; got: \(content.text)"
        )

        let arrived = await driver.waitForCapture(method: "notebookDocument/didClose")
        XCTAssertTrue(arrived, "notebookDocument/didClose notification must reach the server within 2s")

        let captured = await driver.capturedParams(forMethod: "notebookDocument/didClose")
        XCTAssertEqual(captured.count, 1)
        let identifier = captured[0]["notebookDocument"] as? [String: Any]
        XCTAssertEqual(identifier?["uri"] as? String, notebookUri)
        let cellTextDocs = captured[0]["cellTextDocuments"] as? [[String: Any]]
        XCTAssertEqual(cellTextDocs?.count, 2)
        XCTAssertEqual(cellTextDocs?[0]["uri"] as? String, cellOneUri)
        XCTAssertEqual(cellTextDocs?[1]["uri"] as? String, cellTwoUri)
    }

    // MARK: - 5. lsp_notebook_did_open missing 'notebook' throws

    func test_lspNotebookDidOpen_missingNotebook_throws() async {
        let (bridge, _) = await makeBridge()

        // `notebook` is required; omit it to provoke a missing-arg error.
        let args: [String: AnyCodable] = [
            "workspace_root": AnyCodable(workspaceA.path),
            "language_id": AnyCodable("typescript"),
        ]
        do {
            _ = try await bridge.handleToolCall(
                name: "lsp_notebook_did_open",
                arguments: args
            )
            XCTFail("expected throw for missing 'notebook' argument")
        } catch let MCPLSPBridgeError.missingArgument(name) {
            XCTAssertEqual(
                name, "notebook",
                "missingArgument must point at the 'notebook' key; got: \(name)"
            )
        } catch let MCPLSPBridgeError.unknownTool(name) {
            // RED-phase guard: the bridge must already register the tool and
            // refuse the call because the required `notebook` argument is
            // missing. A bare unknownTool means the tool isn't wired up yet.
            XCTFail(
                "expected the bridge to advertise 'lsp_notebook_did_open' and reject"
                + " for missing 'notebook'; got unknownTool(\(name))"
            )
        } catch {
            // Any other error type is acceptable so long as it isn't
            // unknownTool — the bridge just has to refuse the call for the
            // right reason.
        }
    }

    // MARK: - 6. lsp_notebook_did_change missing 'workspace_root' throws

    func test_lspNotebookDidChange_missingWorkspaceRoot_throws() async {
        let (bridge, _) = await makeBridge()

        let args: [String: AnyCodable] = [
            "language_id": AnyCodable("typescript"),
            "notebook": didChangeNotebookAny(),
        ]
        do {
            _ = try await bridge.handleToolCall(
                name: "lsp_notebook_did_change",
                arguments: args
            )
            XCTFail("expected throw for missing 'workspace_root' argument")
        } catch let MCPLSPBridgeError.missingArgument(name) {
            XCTAssertEqual(
                name, "workspace_root",
                "missingArgument must point at the 'workspace_root' key; got: \(name)"
            )
        } catch let MCPLSPBridgeError.unknownTool(name) {
            XCTFail(
                "expected the bridge to advertise 'lsp_notebook_did_change' and reject"
                + " for missing 'workspace_root'; got unknownTool(\(name))"
            )
        } catch {
            // Acceptable.
        }
    }
}
