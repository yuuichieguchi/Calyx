//
//  MCPLSPBridgeInfoClusterATests.swift
//  Calyx
//
//  TDD red-phase tests for the seven "information cluster A" MCP tools the
//  LSP bridge will ship on top of the 28 tools (10 core + 11 extended +
//  7 hierarchy/moniker) already routed through `MCPLSPBridge`.
//
//  Tools under test (and how they reach the language server):
//      lsp_code_lens             -> textDocument/codeLens
//      lsp_code_lens_resolve     -> codeLens/resolve
//      lsp_inlay_hint            -> textDocument/inlayHint
//      lsp_inlay_hint_resolve    -> inlayHint/resolve
//      lsp_inline_value          -> textDocument/inlineValue
//      lsp_folding_range         -> textDocument/foldingRange
//      lsp_selection_range       -> textDocument/selectionRange
//
//  Argument shape summary:
//    - lsp_code_lens, lsp_folding_range : workspace_root, language_id, file
//    - lsp_code_lens_resolve            : workspace_root, language_id,
//                                         code_lens  (a CodeLens object)
//    - lsp_inlay_hint_resolve           : workspace_root, language_id,
//                                         inlay_hint (an InlayHint object)
//    - lsp_inlay_hint, lsp_inline_value : workspace_root, language_id, file,
//                                         start_line, start_column,
//                                         end_line, end_column
//                                         (lsp_inline_value also accepts an
//                                          optional frame_id [default 0] and
//                                          stopped_* range [defaults to the
//                                          target range])
//    - lsp_selection_range              : workspace_root, language_id, file,
//                                         positions: [{line, column}]
//
//  TDD phase: RED. The bridge currently advertises 28 tools and routes only
//  those. These tests are expected to fail at runtime — the catalogue
//  assertion sees 28 names instead of 35, and every `handleToolCall` for one
//  of the new tools surfaces as `MCPLSPBridgeError.unknownTool`.
//
//  Strategy notes:
//    - The fake LSP-server driver and helpers are file-private here to avoid
//      colliding with the symbols of the same name already defined in
//      `MCPLSPBridgeTests.swift`, `MCPLSPBridgeExtendedToolsTests.swift`, and
//      `MCPLSPBridgeHierarchyToolsTests.swift`. Each test file owns its own
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
/// files but is file-private so the four files can compile side-by-side.
fileprivate func freshDictInfoA(fromJSON data: Data) -> sending [String: Any] {
    (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
}

// MARK: - file-private fake LSP server driver

/// Captures every request the bridge sends and emits a configurable
/// response. Lifted near-verbatim from `MCPLSPBridgeHierarchyToolsTests` and
/// renamed so the four files can compile side-by-side.
fileprivate actor InfoClusterAServerDriver: LSPSessionFactory {

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
        driver: InfoClusterAServerDriver
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
                            params: freshDictInfoA(fromJSON: data)
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

// MARK: - MCPLSPBridgeInfoClusterATests

@MainActor
final class MCPLSPBridgeInfoClusterATests: XCTestCase {

    // MARK: - Constants

    private let workspaceA = URL(fileURLWithPath: "/tmp/calyx-mcp-lsp-bridge-info-A")
    private let fileA = "file:///tmp/calyx-mcp-lsp-bridge-info-A/main.ts"

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
    private func makeBridge() async -> (bridge: MCPLSPBridge, driver: InfoClusterAServerDriver) {
        let installer = await makeReadyInstaller()
        let driver = InfoClusterAServerDriver()
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

    /// File-only argument dictionary used by `lsp_code_lens` and
    /// `lsp_folding_range`.
    private func fileArguments(
        file: String,
        workspaceRoot: URL? = nil,
        languageId: String = "typescript"
    ) -> [String: AnyCodable] {
        var args: [String: AnyCodable] = [
            "file": AnyCodable(file),
            "language_id": AnyCodable(languageId),
        ]
        if let workspaceRoot {
            args["workspace_root"] = AnyCodable(workspaceRoot.path)
        }
        return args
    }

    /// Range-style argument dictionary used by `lsp_inlay_hint` and
    /// `lsp_inline_value`.
    private func rangeArguments(
        file: String,
        startLine: Int,
        startColumn: Int,
        endLine: Int,
        endColumn: Int,
        workspaceRoot: URL? = nil,
        languageId: String = "typescript"
    ) -> [String: AnyCodable] {
        var args: [String: AnyCodable] = [
            "file": AnyCodable(file),
            "language_id": AnyCodable(languageId),
            "start_line": AnyCodable(startLine),
            "start_column": AnyCodable(startColumn),
            "end_line": AnyCodable(endLine),
            "end_column": AnyCodable(endColumn),
        ]
        if let workspaceRoot {
            args["workspace_root"] = AnyCodable(workspaceRoot.path)
        }
        return args
    }

    /// Build a minimal `CodeLens`-shaped JSON payload as an `AnyCodable`
    /// suitable for use as the `code_lens` argument of `lsp_code_lens_resolve`.
    private func sampleCodeLens(
        title: String = "Run test",
        commandId: String = "test.run"
    ) -> AnyCodable {
        let lens: [String: AnyCodable] = [
            "range": AnyCodable([
                "start": AnyCodable(["line": AnyCodable(1), "character": AnyCodable(0)]),
                "end":   AnyCodable(["line": AnyCodable(1), "character": AnyCodable(10)]),
            ] as [String: AnyCodable]),
            "command": AnyCodable([
                "title": AnyCodable(title),
                "command": AnyCodable(commandId),
            ] as [String: AnyCodable]),
            "data": AnyCodable(["key": AnyCodable("opaque")] as [String: AnyCodable]),
        ]
        return AnyCodable(lens)
    }

    /// Build a minimal `InlayHint`-shaped JSON payload as an `AnyCodable`
    /// suitable for use as the `inlay_hint` argument of
    /// `lsp_inlay_hint_resolve`. The label is encoded as a plain string —
    /// the most common server output.
    private func sampleInlayHint(
        line: Int = 2,
        character: Int = 5,
        label: String = "T"
    ) -> AnyCodable {
        let hint: [String: AnyCodable] = [
            "position": AnyCodable([
                "line": AnyCodable(line),
                "character": AnyCodable(character),
            ] as [String: AnyCodable]),
            "label": AnyCodable(label),
            "kind": AnyCodable(1),
        ]
        return AnyCodable(hint)
    }

    // MARK: - 1. tools/list catalogue (information cluster A)

    func test_tools_listIncludesInfoClusterA() {
        let names = MCPLSPBridge.tools.map { $0.name }

        let expectedNew = [
            "lsp_code_lens",
            "lsp_code_lens_resolve",
            "lsp_inlay_hint",
            "lsp_inlay_hint_resolve",
            "lsp_inline_value",
            "lsp_folding_range",
            "lsp_selection_range",
        ]
        for name in expectedNew {
            XCTAssertTrue(
                names.contains(name),
                "MCPLSPBridge.tools must advertise information-cluster-A tool \(name); got names=\(names)"
            )
        }

        XCTAssertGreaterThanOrEqual(
            names.count,
            35,
            "tools count must be at least 28 existing + 7 information-cluster-A = 35; got \(names.count) names=\(names)"
        )
    }

    // MARK: - 2. lsp_code_lens dispatch

    func test_lspCodeLens_sendsCorrectLSPRequest() async throws {
        let (bridge, driver) = await makeBridge()
        let lensJSON = """
        [
          {
            "range":{"start":{"line":1,"character":0},"end":{"line":1,"character":10}},
            "command":{"title":"Run test","command":"test.run"}
          }
        ]
        """
        await driver.setReply(method: "textDocument/codeLens", jsonResult: lensJSON)

        let args = fileArguments(file: fileA, workspaceRoot: workspaceA)
        let content = try await bridge.handleToolCall(
            name: "lsp_code_lens",
            arguments: args
        )
        XCTAssertEqual(content.type, "text")
        XCTAssertTrue(
            content.text.contains("\"title\":\"Run test\""),
            "codeLens command must round-trip into MCPContent.text; got: \(content.text)"
        )

        let captured = await driver.capturedParams(forMethod: "textDocument/codeLens")
        XCTAssertEqual(captured.count, 1)
        let td = captured[0]["textDocument"] as? [String: Any]
        XCTAssertEqual(td?["uri"] as? String, fileA)
        XCTAssertNil(
            captured[0]["position"],
            "codeLens params must NOT carry a position (this is a file-scoped request)"
        )
    }

    // MARK: - 3. lsp_code_lens_resolve forwards the code lens

    func test_lspCodeLensResolve_sendsCodeLens() async throws {
        let (bridge, driver) = await makeBridge()
        let resolvedJSON = """
        {
          "range":{"start":{"line":1,"character":0},"end":{"line":1,"character":10}},
          "command":{"title":"Run test","command":"test.run","arguments":[42]}
        }
        """
        await driver.setReply(method: "codeLens/resolve", jsonResult: resolvedJSON)

        let args: [String: AnyCodable] = [
            "workspace_root": AnyCodable(workspaceA.path),
            "language_id": AnyCodable("typescript"),
            "code_lens": sampleCodeLens(title: "Run test", commandId: "test.run"),
        ]
        let content = try await bridge.handleToolCall(
            name: "lsp_code_lens_resolve",
            arguments: args
        )
        XCTAssertEqual(content.type, "text")
        XCTAssertTrue(
            content.text.contains("\"title\":\"Run test\""),
            "codeLens/resolve result must round-trip; got: \(content.text)"
        )

        let captured = await driver.capturedParams(forMethod: "codeLens/resolve")
        XCTAssertEqual(captured.count, 1)
        // The captured `params` for `codeLens/resolve` IS the CodeLens itself
        // (no nested "code_lens" key). The bridge forwards the value verbatim.
        let command = captured[0]["command"] as? [String: Any]
        XCTAssertEqual(command?["title"] as? String, "Run test")
        XCTAssertEqual(command?["command"] as? String, "test.run")
        let range = captured[0]["range"] as? [String: Any]
        let start = range?["start"] as? [String: Any]
        XCTAssertEqual(start?["line"] as? Int, 1)
        XCTAssertEqual(start?["character"] as? Int, 0)
    }

    // MARK: - 4. lsp_inlay_hint sends the visible range

    func test_lspInlayHint_sendsRange() async throws {
        let (bridge, driver) = await makeBridge()
        let hintsJSON = """
        [
          {"position":{"line":2,"character":5},"label":"T","kind":1}
        ]
        """
        await driver.setReply(method: "textDocument/inlayHint", jsonResult: hintsJSON)

        let args = rangeArguments(
            file: fileA,
            startLine: 0,
            startColumn: 0,
            endLine: 10,
            endColumn: 0,
            workspaceRoot: workspaceA
        )
        let content = try await bridge.handleToolCall(
            name: "lsp_inlay_hint",
            arguments: args
        )
        XCTAssertEqual(content.type, "text")
        XCTAssertTrue(
            content.text.contains("\"label\":\"T\""),
            "inlayHint label must round-trip; got: \(content.text)"
        )

        let captured = await driver.capturedParams(forMethod: "textDocument/inlayHint")
        XCTAssertEqual(captured.count, 1)
        let td = captured[0]["textDocument"] as? [String: Any]
        XCTAssertEqual(td?["uri"] as? String, fileA)
        let range = captured[0]["range"] as? [String: Any]
        let start = range?["start"] as? [String: Any]
        let end = range?["end"] as? [String: Any]
        XCTAssertEqual(start?["line"] as? Int, 0)
        XCTAssertEqual(start?["character"] as? Int, 0)
        XCTAssertEqual(end?["line"] as? Int, 10)
        XCTAssertEqual(end?["character"] as? Int, 0)
    }

    // MARK: - 5. lsp_inlay_hint_resolve forwards the inlay hint

    func test_lspInlayHintResolve_sendsInlayHint() async throws {
        let (bridge, driver) = await makeBridge()
        let resolvedJSON = """
        {
          "position":{"line":2,"character":5},
          "label":"T",
          "kind":1,
          "tooltip":"resolved tooltip"
        }
        """
        await driver.setReply(method: "inlayHint/resolve", jsonResult: resolvedJSON)

        let args: [String: AnyCodable] = [
            "workspace_root": AnyCodable(workspaceA.path),
            "language_id": AnyCodable("typescript"),
            "inlay_hint": sampleInlayHint(line: 2, character: 5, label: "T"),
        ]
        let content = try await bridge.handleToolCall(
            name: "lsp_inlay_hint_resolve",
            arguments: args
        )
        XCTAssertEqual(content.type, "text")
        XCTAssertTrue(
            content.text.contains("\"tooltip\":\"resolved tooltip\""),
            "inlayHint/resolve tooltip must round-trip; got: \(content.text)"
        )

        let captured = await driver.capturedParams(forMethod: "inlayHint/resolve")
        XCTAssertEqual(captured.count, 1)
        // The captured `params` for `inlayHint/resolve` IS the InlayHint itself
        // (no nested "inlay_hint" key). The bridge forwards the value verbatim.
        XCTAssertEqual(captured[0]["label"] as? String, "T")
        XCTAssertEqual(captured[0]["kind"] as? Int, 1)
        let position = captured[0]["position"] as? [String: Any]
        XCTAssertEqual(position?["line"] as? Int, 2)
        XCTAssertEqual(position?["character"] as? Int, 5)
    }

    // MARK: - 6. lsp_inline_value dispatch

    func test_lspInlineValue_sendsParams() async throws {
        let (bridge, driver) = await makeBridge()
        let valuesJSON = """
        [
          {"range":{"start":{"line":3,"character":0},"end":{"line":3,"character":4}},
           "text":"x = 42"}
        ]
        """
        await driver.setReply(method: "textDocument/inlineValue", jsonResult: valuesJSON)

        // frame_id and stopped_* are omitted: the bridge defaults frame_id to 0
        // and the stopped_location to the requested target range.
        let args = rangeArguments(
            file: fileA,
            startLine: 2,
            startColumn: 0,
            endLine: 5,
            endColumn: 0,
            workspaceRoot: workspaceA
        )
        let content = try await bridge.handleToolCall(
            name: "lsp_inline_value",
            arguments: args
        )
        XCTAssertEqual(content.type, "text")
        XCTAssertTrue(
            content.text.contains("\"text\":\"x = 42\""),
            "inlineValue text must round-trip; got: \(content.text)"
        )

        let captured = await driver.capturedParams(forMethod: "textDocument/inlineValue")
        XCTAssertEqual(captured.count, 1)
        let td = captured[0]["textDocument"] as? [String: Any]
        XCTAssertEqual(td?["uri"] as? String, fileA)

        let range = captured[0]["range"] as? [String: Any]
        let rStart = range?["start"] as? [String: Any]
        let rEnd = range?["end"] as? [String: Any]
        XCTAssertEqual(rStart?["line"] as? Int, 2)
        XCTAssertEqual(rStart?["character"] as? Int, 0)
        XCTAssertEqual(rEnd?["line"] as? Int, 5)
        XCTAssertEqual(rEnd?["character"] as? Int, 0)

        // Spec-required `context`: frameId defaults to 0, stoppedLocation
        // defaults to the requested range.
        let context = captured[0]["context"] as? [String: Any]
        XCTAssertNotNil(context, "inlineValue params must carry a 'context' object")
        XCTAssertEqual(context?["frameId"] as? Int, 0)
        let stopped = context?["stoppedLocation"] as? [String: Any]
        let sStart = stopped?["start"] as? [String: Any]
        let sEnd = stopped?["end"] as? [String: Any]
        XCTAssertEqual(sStart?["line"] as? Int, 2)
        XCTAssertEqual(sStart?["character"] as? Int, 0)
        XCTAssertEqual(sEnd?["line"] as? Int, 5)
        XCTAssertEqual(sEnd?["character"] as? Int, 0)
    }

    // MARK: - 7. lsp_folding_range dispatch

    func test_lspFoldingRange_sendsCorrectLSPRequest() async throws {
        let (bridge, driver) = await makeBridge()
        let rangesJSON = """
        [
          {"startLine":0,"endLine":4,"kind":"region"},
          {"startLine":6,"endLine":9,"kind":"comment"}
        ]
        """
        await driver.setReply(method: "textDocument/foldingRange", jsonResult: rangesJSON)

        let args = fileArguments(file: fileA, workspaceRoot: workspaceA)
        let content = try await bridge.handleToolCall(
            name: "lsp_folding_range",
            arguments: args
        )
        XCTAssertEqual(content.type, "text")
        XCTAssertTrue(
            content.text.contains("\"kind\":\"region\""),
            "foldingRange kind must round-trip; got: \(content.text)"
        )

        let captured = await driver.capturedParams(forMethod: "textDocument/foldingRange")
        XCTAssertEqual(captured.count, 1)
        let td = captured[0]["textDocument"] as? [String: Any]
        XCTAssertEqual(td?["uri"] as? String, fileA)
        XCTAssertNil(
            captured[0]["position"],
            "foldingRange params must NOT carry a position"
        )
        XCTAssertNil(
            captured[0]["range"],
            "foldingRange params must NOT carry a range"
        )
    }

    // MARK: - 8. lsp_selection_range forwards the positions array

    func test_lspSelectionRange_sendsPositions() async throws {
        let (bridge, driver) = await makeBridge()
        let rangesJSON = """
        [
          {"range":{"start":{"line":3,"character":5},"end":{"line":3,"character":8}}},
          {"range":{"start":{"line":7,"character":2},"end":{"line":7,"character":6}}}
        ]
        """
        await driver.setReply(method: "textDocument/selectionRange", jsonResult: rangesJSON)

        let positions: [AnyCodable] = [
            AnyCodable([
                "line": AnyCodable(3),
                "column": AnyCodable(5),
            ] as [String: AnyCodable]),
            AnyCodable([
                "line": AnyCodable(7),
                "column": AnyCodable(2),
            ] as [String: AnyCodable]),
        ]
        let args: [String: AnyCodable] = [
            "workspace_root": AnyCodable(workspaceA.path),
            "language_id": AnyCodable("typescript"),
            "file": AnyCodable(fileA),
            "positions": AnyCodable(positions),
        ]
        let content = try await bridge.handleToolCall(
            name: "lsp_selection_range",
            arguments: args
        )
        XCTAssertEqual(content.type, "text")
        XCTAssertTrue(
            content.text.contains("\"character\":5"),
            "selectionRange result must round-trip; got: \(content.text)"
        )

        let captured = await driver.capturedParams(forMethod: "textDocument/selectionRange")
        XCTAssertEqual(captured.count, 1)
        let td = captured[0]["textDocument"] as? [String: Any]
        XCTAssertEqual(td?["uri"] as? String, fileA)

        let positionsCaptured = captured[0]["positions"] as? [[String: Any]]
        XCTAssertNotNil(
            positionsCaptured,
            "selectionRange params must carry a 'positions' array"
        )
        XCTAssertEqual(positionsCaptured?.count, 2)
        // Spec uses `character`, not `column`. The bridge must translate
        // the MCP-facing `column` key to the LSP `character` key.
        XCTAssertEqual(positionsCaptured?[0]["line"] as? Int, 3)
        XCTAssertEqual(positionsCaptured?[0]["character"] as? Int, 5)
        XCTAssertEqual(positionsCaptured?[1]["line"] as? Int, 7)
        XCTAssertEqual(positionsCaptured?[1]["character"] as? Int, 2)
    }

    // MARK: - 9. lsp_code_lens_resolve missing code_lens throws

    func test_lspCodeLensResolve_missingCodeLens_throws() async {
        let (bridge, _) = await makeBridge()

        // `code_lens` is required; supply only workspace/language to provoke
        // a missing-argument error.
        let args: [String: AnyCodable] = [
            "workspace_root": AnyCodable(workspaceA.path),
            "language_id": AnyCodable("typescript"),
        ]
        do {
            _ = try await bridge.handleToolCall(
                name: "lsp_code_lens_resolve",
                arguments: args
            )
            XCTFail("expected throw for missing 'code_lens' argument")
        } catch {
            // OK — any error type is acceptable; the bridge just has to refuse.
        }
    }

    // MARK: - 10. lsp_inlay_hint_resolve missing inlay_hint throws

    func test_lspInlayHintResolve_missingInlayHint_throws() async {
        let (bridge, _) = await makeBridge()

        // `inlay_hint` is required; supply only workspace/language to provoke
        // a missing-argument error.
        let args: [String: AnyCodable] = [
            "workspace_root": AnyCodable(workspaceA.path),
            "language_id": AnyCodable("typescript"),
        ]
        do {
            _ = try await bridge.handleToolCall(
                name: "lsp_inlay_hint_resolve",
                arguments: args
            )
            XCTFail("expected throw for missing 'inlay_hint' argument")
        } catch {
            // OK
        }
    }

    // MARK: - 11. lsp_selection_range missing positions throws

    func test_lspSelectionRange_missingPositions_throws() async {
        let (bridge, _) = await makeBridge()

        // `positions` is required; the bridge cannot guess them.
        let args: [String: AnyCodable] = [
            "workspace_root": AnyCodable(workspaceA.path),
            "language_id": AnyCodable("typescript"),
            "file": AnyCodable(fileA),
        ]
        do {
            _ = try await bridge.handleToolCall(
                name: "lsp_selection_range",
                arguments: args
            )
            XCTFail("expected throw for missing 'positions' argument")
        } catch {
            // OK
        }
    }

    // MARK: - 12. lsp_inline_value missing range throws

    func test_lspInlineValue_missingRange_throws() async {
        let (bridge, _) = await makeBridge()

        // start_line / start_column / end_line / end_column are all required
        // by the range-based schema. Omit them entirely to confirm the bridge
        // refuses rather than fabricating a default range.
        let args: [String: AnyCodable] = [
            "workspace_root": AnyCodable(workspaceA.path),
            "language_id": AnyCodable("typescript"),
            "file": AnyCodable(fileA),
        ]
        do {
            _ = try await bridge.handleToolCall(
                name: "lsp_inline_value",
                arguments: args
            )
            XCTFail("expected throw for missing range arguments")
        } catch {
            // OK
        }
    }
}
