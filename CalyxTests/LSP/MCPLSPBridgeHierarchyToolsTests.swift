//
//  MCPLSPBridgeHierarchyToolsTests.swift
//  Calyx
//
//  TDD red-phase tests for the seven additional MCP tools the LSP bridge
//  will ship on top of the 21 navigation / symbol / refactor / install
//  tools already wired through `MCPLSPBridge`.
//
//  Tools under test (and how they reach the language server):
//      lsp_call_hierarchy_prepare   -> textDocument/prepareCallHierarchy
//      lsp_call_hierarchy_incoming  -> callHierarchy/incomingCalls
//      lsp_call_hierarchy_outgoing  -> callHierarchy/outgoingCalls
//      lsp_type_hierarchy_prepare   -> textDocument/prepareTypeHierarchy
//      lsp_type_hierarchy_supertypes -> typeHierarchy/supertypes
//      lsp_type_hierarchy_subtypes  -> typeHierarchy/subtypes
//      lsp_moniker                  -> textDocument/moniker
//
//  Three of those are position-based (prepare* + moniker) and take the
//  usual `workspace_root` / `language_id` / `file` / `line` / `column`
//  argument bundle. The other four take a JSON `item` payload — the
//  `CallHierarchyItem` / `TypeHierarchyItem` returned by the matching
//  prepare call — and forward it verbatim to the language server.
//
//  TDD phase: RED. The bridge currently advertises 21 tools and only
//  routes those. These tests are expected to fail at runtime — the
//  catalogue assertion sees 21 names instead of 28, and every
//  `handleToolCall` for one of the new tools surfaces as
//  `MCPLSPBridgeError.unknownTool` (caught implicitly via the
//  propagating `try`).
//
//  Strategy notes:
//    - The fake LSP-server driver, region helpers, and `freshDict`
//      shim are file-private here to avoid colliding with the symbols
//      of the same name already defined in `MCPLSPBridgeTests.swift`
//      and `MCPLSPBridgeExtendedToolsTests.swift`. Each test file owns
//      its own driver instance.
//    - All tests run on `@MainActor` because `MCPLSPBridge` is
//      `@MainActor`-isolated.
//    - Swift 6.2 strict concurrency: any `[String: Any]` crossing an
//      actor boundary is re-deserialised through a Sendable `Data`
//      payload so the region is fresh on the receiving side.
//

import XCTest
@testable import Calyx

// MARK: - file-private region-detaching helper

/// Deserialize JSON into a fresh `[String: Any]` whose region is independent
/// of any caller-held value. Mirrors the helpers in the other bridge test
/// files but is file-private so the three files can compile side-by-side.
fileprivate func freshDictHier(fromJSON data: Data) -> sending [String: Any] {
    (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
}

// MARK: - file-private fake LSP server driver

/// Captures every request the bridge sends and emits a configurable
/// response. Lifted near-verbatim from `MCPLSPBridgeTests` and renamed
/// so the two files can compile side-by-side.
fileprivate actor HierarchyToolsServerDriver: LSPSessionFactory {

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
        driver: HierarchyToolsServerDriver
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
                            params: freshDictHier(fromJSON: data)
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

// MARK: - MCPLSPBridgeHierarchyToolsTests

@MainActor
final class MCPLSPBridgeHierarchyToolsTests: XCTestCase {

    // MARK: - Constants

    private let workspaceA = URL(fileURLWithPath: "/tmp/calyx-mcp-lsp-bridge-hier-A")
    private let fileA = "file:///tmp/calyx-mcp-lsp-bridge-hier-A/main.ts"

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
    private func makeBridge() async -> (bridge: MCPLSPBridge, driver: HierarchyToolsServerDriver) {
        let installer = await makeReadyInstaller()
        let driver = HierarchyToolsServerDriver()
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

    /// Standard position-based argument dictionary shared by the
    /// `prepare*` and `moniker` tools.
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

    /// Build a minimal `CallHierarchyItem`-shaped JSON payload as an
    /// `AnyCodable` suitable for use as the `item` argument of the
    /// `lsp_call_hierarchy_incoming` / `lsp_call_hierarchy_outgoing`
    /// tools. The payload mirrors what a real `prepareCallHierarchy`
    /// response would return.
    private func sampleCallHierarchyItem(
        name: String = "foo",
        uri: String? = nil
    ) -> AnyCodable {
        let targetUri = uri ?? fileA
        let item: [String: AnyCodable] = [
            "name": AnyCodable(name),
            "kind": AnyCodable(12), // SymbolKind.function
            "uri": AnyCodable(targetUri),
            "range": AnyCodable([
                "start": AnyCodable(["line": AnyCodable(2), "character": AnyCodable(0)]),
                "end":   AnyCodable(["line": AnyCodable(2), "character": AnyCodable(3)]),
            ] as [String: AnyCodable]),
            "selectionRange": AnyCodable([
                "start": AnyCodable(["line": AnyCodable(2), "character": AnyCodable(0)]),
                "end":   AnyCodable(["line": AnyCodable(2), "character": AnyCodable(3)]),
            ] as [String: AnyCodable]),
        ]
        return AnyCodable(item)
    }

    /// Build a minimal `TypeHierarchyItem`-shaped JSON payload as an
    /// `AnyCodable` suitable for use as the `item` argument of the
    /// `lsp_type_hierarchy_supertypes` / `lsp_type_hierarchy_subtypes`
    /// tools.
    private func sampleTypeHierarchyItem(
        name: String = "Foo",
        uri: String? = nil
    ) -> AnyCodable {
        let targetUri = uri ?? fileA
        let item: [String: AnyCodable] = [
            "name": AnyCodable(name),
            "kind": AnyCodable(5), // SymbolKind.class
            "uri": AnyCodable(targetUri),
            "range": AnyCodable([
                "start": AnyCodable(["line": AnyCodable(1), "character": AnyCodable(0)]),
                "end":   AnyCodable(["line": AnyCodable(1), "character": AnyCodable(3)]),
            ] as [String: AnyCodable]),
            "selectionRange": AnyCodable([
                "start": AnyCodable(["line": AnyCodable(1), "character": AnyCodable(0)]),
                "end":   AnyCodable(["line": AnyCodable(1), "character": AnyCodable(3)]),
            ] as [String: AnyCodable]),
        ]
        return AnyCodable(item)
    }

    // MARK: - 1. tools/list catalogue (hierarchy + moniker)

    func test_tools_listContainsHierarchyAndMonikerTools() {
        let names = MCPLSPBridge.tools.map { $0.name }

        let expectedNew = [
            "lsp_call_hierarchy_prepare",
            "lsp_call_hierarchy_incoming",
            "lsp_call_hierarchy_outgoing",
            "lsp_type_hierarchy_prepare",
            "lsp_type_hierarchy_supertypes",
            "lsp_type_hierarchy_subtypes",
            "lsp_moniker",
        ]
        for name in expectedNew {
            XCTAssertTrue(
                names.contains(name),
                "MCPLSPBridge.tools must advertise hierarchy/moniker tool \(name); got names=\(names)"
            )
        }

        XCTAssertGreaterThanOrEqual(
            names.count,
            28,
            "tools count must be at least 21 existing + 7 hierarchy/moniker = 28; got \(names.count) names=\(names)"
        )
    }

    // MARK: - 2. lsp_call_hierarchy_prepare dispatch

    func test_lspCallHierarchyPrepare_sendsCorrectLSPRequest() async throws {
        let (bridge, driver) = await makeBridge()
        let prepJSON = """
        [
          {
            "kind": 12,
            "name": "foo",
            "range":{"start":{"line":2,"character":0},"end":{"line":2,"character":3}},
            "selectionRange":{"start":{"line":2,"character":0},"end":{"line":2,"character":3}},
            "uri": "\(fileA)"
          }
        ]
        """
        await driver.setReply(
            method: "textDocument/prepareCallHierarchy",
            jsonResult: prepJSON
        )

        let args = positionArguments(
            file: fileA,
            line: 2,
            column: 0,
            workspaceRoot: workspaceA
        )
        let content = try await bridge.handleToolCall(
            name: "lsp_call_hierarchy_prepare",
            arguments: args
        )
        XCTAssertEqual(content.type, "text")
        XCTAssertTrue(
            content.text.contains("\"name\":\"foo\""),
            "prepareCallHierarchy item must round-trip into MCPContent.text; got: \(content.text)"
        )

        let captured = await driver.capturedParams(
            forMethod: "textDocument/prepareCallHierarchy"
        )
        XCTAssertEqual(captured.count, 1)
        let td = captured[0]["textDocument"] as? [String: Any]
        XCTAssertEqual(td?["uri"] as? String, fileA)
        let pos = captured[0]["position"] as? [String: Any]
        XCTAssertEqual(pos?["line"] as? Int, 2)
        XCTAssertEqual(pos?["character"] as? Int, 0)
    }

    // MARK: - 3. lsp_call_hierarchy_incoming forwards the item

    func test_lspCallHierarchyIncoming_sendsItem() async throws {
        let (bridge, driver) = await makeBridge()
        let incomingJSON = """
        [
          {
            "from": {
              "kind": 12,
              "name": "caller",
              "range":{"start":{"line":5,"character":0},"end":{"line":9,"character":1}},
              "selectionRange":{"start":{"line":5,"character":0},"end":{"line":5,"character":6}},
              "uri":"\(fileA)"
            },
            "fromRanges":[
              {"start":{"line":7,"character":4},"end":{"line":7,"character":7}}
            ]
          }
        ]
        """
        await driver.setReply(
            method: "callHierarchy/incomingCalls",
            jsonResult: incomingJSON
        )

        let args: [String: AnyCodable] = [
            "workspace_root": AnyCodable(workspaceA.path),
            "language_id": AnyCodable("typescript"),
            "item": sampleCallHierarchyItem(name: "foo"),
        ]
        let content = try await bridge.handleToolCall(
            name: "lsp_call_hierarchy_incoming",
            arguments: args
        )
        XCTAssertEqual(content.type, "text")
        XCTAssertTrue(
            content.text.contains("\"name\":\"caller\""),
            "incomingCalls result must round-trip into MCPContent.text; got: \(content.text)"
        )

        let captured = await driver.capturedParams(
            forMethod: "callHierarchy/incomingCalls"
        )
        XCTAssertEqual(captured.count, 1)
        let item = captured[0]["item"] as? [String: Any]
        XCTAssertNotNil(item, "incomingCalls params must carry an 'item' object")
        XCTAssertEqual(item?["name"] as? String, "foo")
        XCTAssertEqual(item?["uri"] as? String, fileA)
    }

    // MARK: - 4. lsp_call_hierarchy_outgoing forwards the item

    func test_lspCallHierarchyOutgoing_sendsItem() async throws {
        let (bridge, driver) = await makeBridge()
        let outgoingJSON = """
        [
          {
            "to": {
              "kind": 12,
              "name": "callee",
              "range":{"start":{"line":2,"character":0},"end":{"line":2,"character":3}},
              "selectionRange":{"start":{"line":2,"character":0},"end":{"line":2,"character":3}},
              "uri":"\(fileA)"
            },
            "fromRanges":[
              {"start":{"line":3,"character":8},"end":{"line":3,"character":12}}
            ]
          }
        ]
        """
        await driver.setReply(
            method: "callHierarchy/outgoingCalls",
            jsonResult: outgoingJSON
        )

        let args: [String: AnyCodable] = [
            "workspace_root": AnyCodable(workspaceA.path),
            "language_id": AnyCodable("typescript"),
            "item": sampleCallHierarchyItem(name: "foo"),
        ]
        let content = try await bridge.handleToolCall(
            name: "lsp_call_hierarchy_outgoing",
            arguments: args
        )
        XCTAssertEqual(content.type, "text")
        XCTAssertTrue(
            content.text.contains("\"name\":\"callee\""),
            "outgoingCalls result must round-trip into MCPContent.text; got: \(content.text)"
        )

        let captured = await driver.capturedParams(
            forMethod: "callHierarchy/outgoingCalls"
        )
        XCTAssertEqual(captured.count, 1)
        let item = captured[0]["item"] as? [String: Any]
        XCTAssertNotNil(item, "outgoingCalls params must carry an 'item' object")
        XCTAssertEqual(item?["name"] as? String, "foo")
    }

    // MARK: - 5. lsp_type_hierarchy_prepare dispatch

    func test_lspTypeHierarchyPrepare_sendsCorrectLSPRequest() async throws {
        let (bridge, driver) = await makeBridge()
        let prepJSON = """
        [
          {
            "kind": 5,
            "name": "Foo",
            "range":{"start":{"line":1,"character":0},"end":{"line":1,"character":3}},
            "selectionRange":{"start":{"line":1,"character":0},"end":{"line":1,"character":3}},
            "uri": "\(fileA)"
          }
        ]
        """
        await driver.setReply(
            method: "textDocument/prepareTypeHierarchy",
            jsonResult: prepJSON
        )

        let args = positionArguments(
            file: fileA,
            line: 1,
            column: 0,
            workspaceRoot: workspaceA
        )
        let content = try await bridge.handleToolCall(
            name: "lsp_type_hierarchy_prepare",
            arguments: args
        )
        XCTAssertEqual(content.type, "text")
        XCTAssertTrue(
            content.text.contains("\"name\":\"Foo\""),
            "prepareTypeHierarchy item must round-trip into MCPContent.text; got: \(content.text)"
        )

        let captured = await driver.capturedParams(
            forMethod: "textDocument/prepareTypeHierarchy"
        )
        XCTAssertEqual(captured.count, 1)
        let td = captured[0]["textDocument"] as? [String: Any]
        XCTAssertEqual(td?["uri"] as? String, fileA)
        let pos = captured[0]["position"] as? [String: Any]
        XCTAssertEqual(pos?["line"] as? Int, 1)
        XCTAssertEqual(pos?["character"] as? Int, 0)
    }

    // MARK: - 6. lsp_type_hierarchy_supertypes forwards the item

    func test_lspTypeHierarchySupertypes_sendsItem() async throws {
        let (bridge, driver) = await makeBridge()
        let superJSON = """
        [
          {
            "kind": 5,
            "name": "Bar",
            "range":{"start":{"line":4,"character":0},"end":{"line":4,"character":3}},
            "selectionRange":{"start":{"line":4,"character":0},"end":{"line":4,"character":3}},
            "uri":"\(fileA)"
          }
        ]
        """
        await driver.setReply(
            method: "typeHierarchy/supertypes",
            jsonResult: superJSON
        )

        let args: [String: AnyCodable] = [
            "workspace_root": AnyCodable(workspaceA.path),
            "language_id": AnyCodable("typescript"),
            "item": sampleTypeHierarchyItem(name: "Foo"),
        ]
        let content = try await bridge.handleToolCall(
            name: "lsp_type_hierarchy_supertypes",
            arguments: args
        )
        XCTAssertEqual(content.type, "text")
        XCTAssertTrue(
            content.text.contains("\"name\":\"Bar\""),
            "supertypes result must round-trip into MCPContent.text; got: \(content.text)"
        )

        let captured = await driver.capturedParams(
            forMethod: "typeHierarchy/supertypes"
        )
        XCTAssertEqual(captured.count, 1)
        let item = captured[0]["item"] as? [String: Any]
        XCTAssertNotNil(item, "supertypes params must carry an 'item' object")
        XCTAssertEqual(item?["name"] as? String, "Foo")
        XCTAssertEqual(item?["kind"] as? Int, 5)
    }

    // MARK: - 7. lsp_type_hierarchy_subtypes forwards the item

    func test_lspTypeHierarchySubtypes_sendsItem() async throws {
        let (bridge, driver) = await makeBridge()
        let subJSON = """
        [
          {
            "kind": 5,
            "name": "Baz",
            "range":{"start":{"line":6,"character":0},"end":{"line":6,"character":3}},
            "selectionRange":{"start":{"line":6,"character":0},"end":{"line":6,"character":3}},
            "uri":"\(fileA)"
          }
        ]
        """
        await driver.setReply(
            method: "typeHierarchy/subtypes",
            jsonResult: subJSON
        )

        let args: [String: AnyCodable] = [
            "workspace_root": AnyCodable(workspaceA.path),
            "language_id": AnyCodable("typescript"),
            "item": sampleTypeHierarchyItem(name: "Foo"),
        ]
        let content = try await bridge.handleToolCall(
            name: "lsp_type_hierarchy_subtypes",
            arguments: args
        )
        XCTAssertEqual(content.type, "text")
        XCTAssertTrue(
            content.text.contains("\"name\":\"Baz\""),
            "subtypes result must round-trip into MCPContent.text; got: \(content.text)"
        )

        let captured = await driver.capturedParams(
            forMethod: "typeHierarchy/subtypes"
        )
        XCTAssertEqual(captured.count, 1)
        let item = captured[0]["item"] as? [String: Any]
        XCTAssertNotNil(item, "subtypes params must carry an 'item' object")
        XCTAssertEqual(item?["name"] as? String, "Foo")
    }

    // MARK: - 8. lsp_moniker dispatch

    func test_lspMoniker_sendsCorrectLSPRequest() async throws {
        let (bridge, driver) = await makeBridge()
        await driver.setReply(method: "textDocument/moniker", jsonResult: "[]")

        let args = positionArguments(
            file: fileA,
            line: 3,
            column: 7,
            workspaceRoot: workspaceA
        )
        _ = try await bridge.handleToolCall(
            name: "lsp_moniker",
            arguments: args
        )

        let captured = await driver.capturedParams(forMethod: "textDocument/moniker")
        XCTAssertEqual(captured.count, 1)
        let td = captured[0]["textDocument"] as? [String: Any]
        XCTAssertEqual(td?["uri"] as? String, fileA)
        let pos = captured[0]["position"] as? [String: Any]
        XCTAssertEqual(pos?["line"] as? Int, 3)
        XCTAssertEqual(pos?["character"] as? Int, 7)
    }

    // MARK: - 9. lsp_moniker returns array of Monikers

    func test_lspMoniker_returnsArrayOfMonikers() async throws {
        let (bridge, driver) = await makeBridge()
        let monikersJSON = """
        [
          {"scheme":"tsc","identifier":"calyx::foo","unique":"document"},
          {"scheme":"npm","identifier":"@calyx/util::bar","unique":"global","kind":"export"}
        ]
        """
        await driver.setReply(method: "textDocument/moniker", jsonResult: monikersJSON)

        let args = positionArguments(
            file: fileA,
            line: 0,
            column: 0,
            workspaceRoot: workspaceA
        )
        let content = try await bridge.handleToolCall(
            name: "lsp_moniker",
            arguments: args
        )
        XCTAssertEqual(content.type, "text")

        guard let data = content.text.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else {
            XCTFail("moniker must return a JSON array; got: \(content.text)")
            return
        }
        XCTAssertEqual(arr.count, 2, "expected two monikers; got: \(arr)")
        XCTAssertEqual(arr[0]["scheme"] as? String, "tsc")
        XCTAssertEqual(arr[0]["identifier"] as? String, "calyx::foo")
        XCTAssertEqual(arr[1]["scheme"] as? String, "npm")
    }

    // MARK: - 10. lsp_call_hierarchy_incoming missing item throws

    func test_lspCallHierarchyIncoming_missingItem_throws() async {
        let (bridge, _) = await makeBridge()

        // `item` is required; supply only workspace/language to provoke
        // a missing-argument error.
        let args: [String: AnyCodable] = [
            "workspace_root": AnyCodable(workspaceA.path),
            "language_id": AnyCodable("typescript"),
        ]
        do {
            _ = try await bridge.handleToolCall(
                name: "lsp_call_hierarchy_incoming",
                arguments: args
            )
            XCTFail("expected throw for missing 'item' argument")
        } catch {
            // OK — any error type is acceptable; the bridge just has to refuse.
        }
    }

    // MARK: - 11. lsp_type_hierarchy_prepare missing file throws

    func test_lspTypeHierarchyPrepare_missingFile_throws() async {
        let (bridge, _) = await makeBridge()

        // `file` is required by every position-based tool. Omit it to
        // confirm prepareTypeHierarchy validates its arguments.
        let args: [String: AnyCodable] = [
            "workspace_root": AnyCodable(workspaceA.path),
            "language_id": AnyCodable("typescript"),
            "line": AnyCodable(0),
            "column": AnyCodable(0),
        ]
        do {
            _ = try await bridge.handleToolCall(
                name: "lsp_type_hierarchy_prepare",
                arguments: args
            )
            XCTFail("expected throw for missing 'file' argument")
        } catch {
            // OK
        }
    }

    // MARK: - 12. lsp_moniker valid response includes uniqueness and kind

    func test_lspMoniker_validResponse_includesUniquenessAndKind() async throws {
        let (bridge, driver) = await makeBridge()
        let monikersJSON = """
        [
          {"scheme":"calyx","identifier":"calyx::Bar","unique":"global","kind":"import"}
        ]
        """
        await driver.setReply(method: "textDocument/moniker", jsonResult: monikersJSON)

        let args = positionArguments(
            file: fileA,
            line: 0,
            column: 0,
            workspaceRoot: workspaceA
        )
        let content = try await bridge.handleToolCall(
            name: "lsp_moniker",
            arguments: args
        )
        XCTAssertEqual(content.type, "text")
        XCTAssertTrue(
            content.text.contains("\"unique\":\"global\""),
            "moniker text must carry the UniquenessLevel; got: \(content.text)"
        )
        XCTAssertTrue(
            content.text.contains("\"kind\":\"import\""),
            "moniker text must carry the MonikerKind; got: \(content.text)"
        )
        XCTAssertTrue(
            content.text.contains("\"identifier\":\"calyx::Bar\""),
            "moniker text must carry the identifier; got: \(content.text)"
        )
    }
}
