//
//  MCPLSPBridgeInfoClusterBTests.swift
//  Calyx
//
//  TDD red-phase tests for the eight "information cluster B" MCP tools the
//  LSP bridge will ship on top of the 35 tools (10 core + 11 extended +
//  7 hierarchy/moniker + 7 information-cluster-A) already routed through
//  `MCPLSPBridge`.
//
//  Tools under test (and how they reach the language server):
//      lsp_semantic_tokens_full   -> textDocument/semanticTokens/full
//      lsp_semantic_tokens_range  -> textDocument/semanticTokens/range
//      lsp_semantic_tokens_delta  -> textDocument/semanticTokens/full/delta
//      lsp_linked_editing_range   -> textDocument/linkedEditingRange
//      lsp_document_link          -> textDocument/documentLink
//      lsp_document_link_resolve  -> documentLink/resolve
//      lsp_document_color         -> textDocument/documentColor
//      lsp_color_presentation     -> textDocument/colorPresentation
//
//  Argument shape summary:
//    - lsp_semantic_tokens_full, lsp_document_link, lsp_document_color :
//          workspace_root, language_id, file                  (file-only)
//    - lsp_semantic_tokens_range :
//          workspace_root, language_id, file,
//          start_line, start_column, end_line, end_column     (file + range)
//    - lsp_semantic_tokens_delta :
//          workspace_root, language_id, file,
//          previous_result_id                                  (file + token)
//    - lsp_linked_editing_range :
//          workspace_root, language_id, file, line, column    (position)
//    - lsp_document_link_resolve :
//          workspace_root, language_id, document_link         (item-based)
//    - lsp_color_presentation :
//          workspace_root, language_id, file,
//          start_line, start_column, end_line, end_column,
//          color: { red, green, blue, alpha }                 (range + color)
//
//  TDD phase: RED. The bridge currently advertises 35 tools and routes only
//  those. These tests are expected to fail at runtime — the catalogue
//  assertion sees 35 names instead of 43, and every `handleToolCall` for one
//  of the new tools surfaces as `MCPLSPBridgeError.unknownTool`.
//
//  Strategy notes:
//    - The fake LSP-server driver and helpers are file-private here to avoid
//      colliding with the symbols of the same name already defined in the
//      five sibling bridge test files. Each test file owns its own driver
//      instance.
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
fileprivate func freshDictInfoB(fromJSON data: Data) -> sending [String: Any] {
    (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
}

// MARK: - file-private fake LSP server driver

/// Captures every request the bridge sends and emits a configurable
/// response. Lifted near-verbatim from `MCPLSPBridgeInfoClusterATests` and
/// renamed so the six files can compile side-by-side.
fileprivate actor InfoClusterBServerDriver: LSPSessionFactory {

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
        driver: InfoClusterBServerDriver
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
                            params: freshDictInfoB(fromJSON: data)
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

// MARK: - MCPLSPBridgeInfoClusterBTests

@MainActor
final class MCPLSPBridgeInfoClusterBTests: XCTestCase {

    // MARK: - Constants

    private let workspaceA = URL(fileURLWithPath: "/tmp/calyx-mcp-lsp-bridge-info-B")
    private let fileA = "file:///tmp/calyx-mcp-lsp-bridge-info-B/main.ts"

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
    private func makeBridge() async -> (bridge: MCPLSPBridge, driver: InfoClusterBServerDriver) {
        let installer = await makeReadyInstaller()
        let driver = InfoClusterBServerDriver()
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

    /// File-only argument dictionary used by `lsp_semantic_tokens_full`,
    /// `lsp_document_link`, `lsp_document_color`.
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

    /// Position-style argument dictionary used by `lsp_linked_editing_range`.
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

    /// Range-style argument dictionary used by `lsp_semantic_tokens_range`
    /// (and the range portion of `lsp_color_presentation`).
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

    /// Build a `{ red, green, blue, alpha }` `LSPColor` payload as an
    /// `AnyCodable` suitable for use as the `color` argument of
    /// `lsp_color_presentation`.
    private func sampleColor(
        red: Double = 0.5,
        green: Double = 0.25,
        blue: Double = 0.75,
        alpha: Double = 1.0
    ) -> AnyCodable {
        AnyCodable([
            "red": AnyCodable(red),
            "green": AnyCodable(green),
            "blue": AnyCodable(blue),
            "alpha": AnyCodable(alpha),
        ] as [String: AnyCodable])
    }

    /// Build a minimal `DocumentLink`-shaped JSON payload as an `AnyCodable`
    /// suitable for use as the `document_link` argument of
    /// `lsp_document_link_resolve`. Only `range` is populated; the bridge
    /// must forward the value verbatim to `documentLink/resolve`.
    private func sampleDocumentLink(
        startLine: Int = 3,
        startCharacter: Int = 0,
        endLine: Int = 3,
        endCharacter: Int = 20,
        data: String = "opaque"
    ) -> AnyCodable {
        let link: [String: AnyCodable] = [
            "range": AnyCodable([
                "start": AnyCodable([
                    "line": AnyCodable(startLine),
                    "character": AnyCodable(startCharacter),
                ] as [String: AnyCodable]),
                "end": AnyCodable([
                    "line": AnyCodable(endLine),
                    "character": AnyCodable(endCharacter),
                ] as [String: AnyCodable]),
            ] as [String: AnyCodable]),
            "data": AnyCodable(["key": AnyCodable(data)] as [String: AnyCodable]),
        ]
        return AnyCodable(link)
    }

    // MARK: - 1. tools/list catalogue (information cluster B)

    func test_tools_listIncludesInfoClusterB() {
        let names = MCPLSPBridge.tools.map { $0.name }

        let expectedNew = [
            "lsp_semantic_tokens_full",
            "lsp_semantic_tokens_range",
            "lsp_semantic_tokens_delta",
            "lsp_linked_editing_range",
            "lsp_document_link",
            "lsp_document_link_resolve",
            "lsp_document_color",
            "lsp_color_presentation",
        ]
        for name in expectedNew {
            XCTAssertTrue(
                names.contains(name),
                "MCPLSPBridge.tools must advertise information-cluster-B tool \(name); got names=\(names)"
            )
        }

        XCTAssertGreaterThanOrEqual(
            names.count,
            43,
            "tools count must be at least 35 existing + 8 information-cluster-B = 43; got \(names.count) names=\(names)"
        )
    }

    // MARK: - 2. lsp_semantic_tokens_full dispatch

    func test_lspSemanticTokensFull_sendsCorrectLSPRequest() async throws {
        let (bridge, driver) = await makeBridge()
        let tokensJSON = """
        {"resultId":"snap-1","data":[0,0,3,1,0,1,2,4,2,0]}
        """
        await driver.setReply(
            method: "textDocument/semanticTokens/full",
            jsonResult: tokensJSON
        )

        let args = fileArguments(file: fileA, workspaceRoot: workspaceA)
        let content = try await bridge.handleToolCall(
            name: "lsp_semantic_tokens_full",
            arguments: args
        )
        XCTAssertEqual(content.type, "text")
        XCTAssertTrue(
            content.text.contains("\"resultId\":\"snap-1\""),
            "semanticTokens/full resultId must round-trip; got: \(content.text)"
        )

        let captured = await driver.capturedParams(
            forMethod: "textDocument/semanticTokens/full"
        )
        XCTAssertEqual(captured.count, 1)
        let td = captured[0]["textDocument"] as? [String: Any]
        XCTAssertEqual(td?["uri"] as? String, fileA)
        XCTAssertNil(
            captured[0]["position"],
            "semanticTokens/full params must NOT carry a position (file-scoped)"
        )
        XCTAssertNil(
            captured[0]["range"],
            "semanticTokens/full params must NOT carry a range"
        )
    }

    // MARK: - 3. lsp_semantic_tokens_range dispatch

    func test_lspSemanticTokensRange_sendsRange() async throws {
        let (bridge, driver) = await makeBridge()
        let tokensJSON = """
        {"resultId":"snap-r1","data":[3,0,5,2,0]}
        """
        await driver.setReply(
            method: "textDocument/semanticTokens/range",
            jsonResult: tokensJSON
        )

        let args = rangeArguments(
            file: fileA,
            startLine: 2,
            startColumn: 0,
            endLine: 8,
            endColumn: 0,
            workspaceRoot: workspaceA
        )
        let content = try await bridge.handleToolCall(
            name: "lsp_semantic_tokens_range",
            arguments: args
        )
        XCTAssertEqual(content.type, "text")
        XCTAssertTrue(
            content.text.contains("\"resultId\":\"snap-r1\""),
            "semanticTokens/range resultId must round-trip; got: \(content.text)"
        )

        let captured = await driver.capturedParams(
            forMethod: "textDocument/semanticTokens/range"
        )
        XCTAssertEqual(captured.count, 1)
        let td = captured[0]["textDocument"] as? [String: Any]
        XCTAssertEqual(td?["uri"] as? String, fileA)
        let range = captured[0]["range"] as? [String: Any]
        let start = range?["start"] as? [String: Any]
        let end = range?["end"] as? [String: Any]
        XCTAssertEqual(start?["line"] as? Int, 2)
        XCTAssertEqual(start?["character"] as? Int, 0)
        XCTAssertEqual(end?["line"] as? Int, 8)
        XCTAssertEqual(end?["character"] as? Int, 0)
    }

    // MARK: - 4. lsp_semantic_tokens_delta dispatch

    func test_lspSemanticTokensDelta_sendsPreviousResultId() async throws {
        let (bridge, driver) = await makeBridge()
        // Server may answer with either full tokens or a delta — use the
        // delta variant so the discriminator (`edits`) is observable in
        // the round-tripped JSON.
        let deltaJSON = """
        {"resultId":"snap-2","edits":[{"start":0,"deleteCount":2,"data":[0,1,3,1,0]}]}
        """
        await driver.setReply(
            method: "textDocument/semanticTokens/full/delta",
            jsonResult: deltaJSON
        )

        var args = fileArguments(file: fileA, workspaceRoot: workspaceA)
        args["previous_result_id"] = AnyCodable("snap-1")
        let content = try await bridge.handleToolCall(
            name: "lsp_semantic_tokens_delta",
            arguments: args
        )
        XCTAssertEqual(content.type, "text")
        XCTAssertTrue(
            content.text.contains("\"resultId\":\"snap-2\""),
            "semanticTokens/full/delta resultId must round-trip; got: \(content.text)"
        )
        XCTAssertTrue(
            content.text.contains("\"edits\""),
            "delta variant 'edits' key must round-trip; got: \(content.text)"
        )

        let captured = await driver.capturedParams(
            forMethod: "textDocument/semanticTokens/full/delta"
        )
        XCTAssertEqual(captured.count, 1)
        let td = captured[0]["textDocument"] as? [String: Any]
        XCTAssertEqual(td?["uri"] as? String, fileA)
        XCTAssertEqual(
            captured[0]["previousResultId"] as? String,
            "snap-1",
            "delta params must carry previousResultId (spec key, not previous_result_id)"
        )
    }

    // MARK: - 5. lsp_linked_editing_range dispatch

    func test_lspLinkedEditingRange_sendsPosition() async throws {
        let (bridge, driver) = await makeBridge()
        let rangesJSON = """
        {
          "ranges":[
            {"start":{"line":4,"character":0},"end":{"line":4,"character":3}},
            {"start":{"line":7,"character":12},"end":{"line":7,"character":15}}
          ],
          "wordPattern":"[A-Za-z_][A-Za-z0-9_]*"
        }
        """
        await driver.setReply(
            method: "textDocument/linkedEditingRange",
            jsonResult: rangesJSON
        )

        let args = positionArguments(
            file: fileA,
            line: 4,
            column: 1,
            workspaceRoot: workspaceA
        )
        let content = try await bridge.handleToolCall(
            name: "lsp_linked_editing_range",
            arguments: args
        )
        XCTAssertEqual(content.type, "text")
        XCTAssertTrue(
            content.text.contains("\"wordPattern\""),
            "linkedEditingRange wordPattern must round-trip; got: \(content.text)"
        )

        let captured = await driver.capturedParams(
            forMethod: "textDocument/linkedEditingRange"
        )
        XCTAssertEqual(captured.count, 1)
        let td = captured[0]["textDocument"] as? [String: Any]
        XCTAssertEqual(td?["uri"] as? String, fileA)
        let pos = captured[0]["position"] as? [String: Any]
        XCTAssertEqual(pos?["line"] as? Int, 4)
        XCTAssertEqual(pos?["character"] as? Int, 1)
    }

    // MARK: - 6. lsp_document_link dispatch

    func test_lspDocumentLink_sendsCorrectLSPRequest() async throws {
        let (bridge, driver) = await makeBridge()
        let linksJSON = """
        [
          {
            "range":{"start":{"line":3,"character":0},"end":{"line":3,"character":20}},
            "target":"https://example.com/",
            "tooltip":"Visit example"
          }
        ]
        """
        await driver.setReply(method: "textDocument/documentLink", jsonResult: linksJSON)

        let args = fileArguments(file: fileA, workspaceRoot: workspaceA)
        let content = try await bridge.handleToolCall(
            name: "lsp_document_link",
            arguments: args
        )
        XCTAssertEqual(content.type, "text")
        XCTAssertTrue(
            content.text.contains("\"target\":\"https:\\/\\/example.com\\/\"")
                || content.text.contains("\"target\":\"https://example.com/\""),
            "documentLink target must round-trip; got: \(content.text)"
        )

        let captured = await driver.capturedParams(
            forMethod: "textDocument/documentLink"
        )
        XCTAssertEqual(captured.count, 1)
        let td = captured[0]["textDocument"] as? [String: Any]
        XCTAssertEqual(td?["uri"] as? String, fileA)
        XCTAssertNil(
            captured[0]["position"],
            "documentLink params must NOT carry a position"
        )
        XCTAssertNil(
            captured[0]["range"],
            "documentLink params must NOT carry a range"
        )
    }

    // MARK: - 7. lsp_document_link_resolve forwards the document link

    func test_lspDocumentLinkResolve_sendsDocumentLink() async throws {
        let (bridge, driver) = await makeBridge()
        let resolvedJSON = """
        {
          "range":{"start":{"line":3,"character":0},"end":{"line":3,"character":20}},
          "target":"https://example.com/resolved",
          "tooltip":"Resolved tooltip"
        }
        """
        await driver.setReply(method: "documentLink/resolve", jsonResult: resolvedJSON)

        let args: [String: AnyCodable] = [
            "workspace_root": AnyCodable(workspaceA.path),
            "language_id": AnyCodable("typescript"),
            "document_link": sampleDocumentLink(),
        ]
        let content = try await bridge.handleToolCall(
            name: "lsp_document_link_resolve",
            arguments: args
        )
        XCTAssertEqual(content.type, "text")
        XCTAssertTrue(
            content.text.contains("Resolved tooltip"),
            "documentLink/resolve tooltip must round-trip; got: \(content.text)"
        )

        let captured = await driver.capturedParams(
            forMethod: "documentLink/resolve"
        )
        XCTAssertEqual(captured.count, 1)
        // The captured `params` for `documentLink/resolve` IS the DocumentLink
        // itself (no nested "document_link" key). The bridge forwards verbatim.
        let range = captured[0]["range"] as? [String: Any]
        let start = range?["start"] as? [String: Any]
        let end = range?["end"] as? [String: Any]
        XCTAssertEqual(start?["line"] as? Int, 3)
        XCTAssertEqual(start?["character"] as? Int, 0)
        XCTAssertEqual(end?["line"] as? Int, 3)
        XCTAssertEqual(end?["character"] as? Int, 20)
        // `data` is preserved for the server (LSP spec requirement).
        let data = captured[0]["data"] as? [String: Any]
        XCTAssertEqual(data?["key"] as? String, "opaque")
    }

    // MARK: - 8. lsp_document_color dispatch

    func test_lspDocumentColor_sendsCorrectLSPRequest() async throws {
        let (bridge, driver) = await makeBridge()
        let colorsJSON = """
        [
          {
            "range":{"start":{"line":5,"character":4},"end":{"line":5,"character":11}},
            "color":{"red":0.5,"green":0.25,"blue":0.75,"alpha":1.0}
          }
        ]
        """
        await driver.setReply(method: "textDocument/documentColor", jsonResult: colorsJSON)

        let args = fileArguments(file: fileA, workspaceRoot: workspaceA)
        let content = try await bridge.handleToolCall(
            name: "lsp_document_color",
            arguments: args
        )
        XCTAssertEqual(content.type, "text")
        XCTAssertTrue(
            content.text.contains("\"red\":0.5"),
            "documentColor red must round-trip; got: \(content.text)"
        )

        let captured = await driver.capturedParams(
            forMethod: "textDocument/documentColor"
        )
        XCTAssertEqual(captured.count, 1)
        let td = captured[0]["textDocument"] as? [String: Any]
        XCTAssertEqual(td?["uri"] as? String, fileA)
        XCTAssertNil(
            captured[0]["position"],
            "documentColor params must NOT carry a position"
        )
        XCTAssertNil(
            captured[0]["range"],
            "documentColor params must NOT carry a range"
        )
    }

    // MARK: - 9. lsp_color_presentation dispatch

    func test_lspColorPresentation_sendsColorAndRange() async throws {
        let (bridge, driver) = await makeBridge()
        let presentationsJSON = """
        [
          {"label":"#7f4040bf"},
          {"label":"rgba(127, 64, 191, 1.0)"}
        ]
        """
        await driver.setReply(
            method: "textDocument/colorPresentation",
            jsonResult: presentationsJSON
        )

        var args = rangeArguments(
            file: fileA,
            startLine: 5,
            startColumn: 4,
            endLine: 5,
            endColumn: 11,
            workspaceRoot: workspaceA
        )
        args["color"] = sampleColor(red: 0.5, green: 0.25, blue: 0.75, alpha: 1.0)
        let content = try await bridge.handleToolCall(
            name: "lsp_color_presentation",
            arguments: args
        )
        XCTAssertEqual(content.type, "text")
        XCTAssertTrue(
            content.text.contains("\"label\":\"#7f4040bf\""),
            "colorPresentation label must round-trip; got: \(content.text)"
        )

        let captured = await driver.capturedParams(
            forMethod: "textDocument/colorPresentation"
        )
        XCTAssertEqual(captured.count, 1)
        let td = captured[0]["textDocument"] as? [String: Any]
        XCTAssertEqual(td?["uri"] as? String, fileA)

        let color = captured[0]["color"] as? [String: Any]
        XCTAssertNotNil(color, "colorPresentation params must carry 'color'")
        XCTAssertEqual(color?["red"] as? Double, 0.5)
        XCTAssertEqual(color?["green"] as? Double, 0.25)
        XCTAssertEqual(color?["blue"] as? Double, 0.75)
        XCTAssertEqual(color?["alpha"] as? Double, 1.0)

        let range = captured[0]["range"] as? [String: Any]
        let start = range?["start"] as? [String: Any]
        let end = range?["end"] as? [String: Any]
        XCTAssertEqual(start?["line"] as? Int, 5)
        XCTAssertEqual(start?["character"] as? Int, 4)
        XCTAssertEqual(end?["line"] as? Int, 5)
        XCTAssertEqual(end?["character"] as? Int, 11)
    }

    // MARK: - 10. lsp_semantic_tokens_delta missing previous_result_id throws

    func test_lspSemanticTokensDelta_missingPreviousResultId_throws() async {
        let (bridge, _) = await makeBridge()

        // `previous_result_id` is required by spec — there is no sensible
        // default for "the previous response's id".
        let args = fileArguments(file: fileA, workspaceRoot: workspaceA)
        do {
            _ = try await bridge.handleToolCall(
                name: "lsp_semantic_tokens_delta",
                arguments: args
            )
            XCTFail("expected throw for missing 'previous_result_id' argument")
        } catch {
            // OK — any error type is acceptable; the bridge just has to refuse.
        }
    }

    // MARK: - 11. lsp_color_presentation missing color throws

    func test_lspColorPresentation_missingColor_throws() async {
        let (bridge, _) = await makeBridge()

        // `color` is required — without it the bridge cannot construct
        // a `colorPresentation` request body.
        let args = rangeArguments(
            file: fileA,
            startLine: 5,
            startColumn: 4,
            endLine: 5,
            endColumn: 11,
            workspaceRoot: workspaceA
        )
        do {
            _ = try await bridge.handleToolCall(
                name: "lsp_color_presentation",
                arguments: args
            )
            XCTFail("expected throw for missing 'color' argument")
        } catch {
            // OK
        }
    }

    // MARK: - 12. lsp_document_link_resolve missing document_link throws

    func test_lspDocumentLinkResolve_missingDocumentLink_throws() async {
        let (bridge, _) = await makeBridge()

        // `document_link` is required; supply only workspace/language to
        // provoke a missing-argument error.
        let args: [String: AnyCodable] = [
            "workspace_root": AnyCodable(workspaceA.path),
            "language_id": AnyCodable("typescript"),
        ]
        do {
            _ = try await bridge.handleToolCall(
                name: "lsp_document_link_resolve",
                arguments: args
            )
            XCTFail("expected throw for missing 'document_link' argument")
        } catch {
            // OK
        }
    }

    // MARK: - 13. lsp_semantic_tokens_range missing range throws

    func test_lspSemanticTokensRange_missingRange_throws() async {
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
                name: "lsp_semantic_tokens_range",
                arguments: args
            )
            XCTFail("expected throw for missing range arguments")
        } catch {
            // OK
        }
    }
}
