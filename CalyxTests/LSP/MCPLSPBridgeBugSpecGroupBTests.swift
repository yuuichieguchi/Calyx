//
//  MCPLSPBridgeBugSpecGroupBTests.swift
//  Calyx
//
//  TDD red-phase tests for three stubbed AI tools advertised by
//  `MCPLSPBridge` whose handlers currently fall short of the schema /
//  description they publish to MCP callers.
//
//  Bugs under test:
//    1. lsp_symbol_walk
//         Schema advertises `depth` (default 3) but the handler only honours
//         depth=1: it issues `callHierarchy/incomingCalls` exactly once on
//         the seed item and returns whatever the server replies. The fix is
//         to BFS the call graph up to `depth` levels, expanding each
//         frontier node by re-issuing `callHierarchy/incomingCalls`.
//    2. lsp_hover_bundle
//         JSON envelope already exposes a `surrounding_code` field but the
//         handler hard-codes it to "". The fix is to read the target file
//         from disk and slice ±`context_lines` (default 10) around the
//         requested position, returning the snippet with line-number
//         markers.
//    3. lsp_cross_workspace_definition
//         Today a thin pass-through to `DefinitionTool`. The fix is to:
//           (a) call `textDocument/moniker` on the requested position to
//               obtain a portable identifier,
//           (b) fan `workspace/symbol` for that identifier out across every
//               warm `LSPService` session (each treated as a candidate
//               sibling workspace),
//           (c) aggregate the resulting locations with a `resolved_in:
//               <workspace>` annotation per entry.
//
//  TDD phase: RED. Every assertion below MUST FAIL against current code:
//    - symbol_walk's deeper-than-1 BFS expectations cannot pass while only
//      one round-trip is issued.
//    - hover_bundle's non-empty `surrounding_code` expectation cannot pass
//      while the field is hard-coded to "".
//    - cross_workspace_definition's moniker + workspace/symbol fan-out
//      expectations cannot pass while the handler simply delegates to
//      `DefinitionTool`.
//
//  Driver pattern follows the sibling bridge tests: a file-private actor
//  that conforms to `LSPSessionFactory`, drives `InMemoryLSPTransport`
//  sidecars, captures every request + notification, and queues replies per
//  method (so the BFS test can hand back different `incomingCalls`
//  responses on successive hops). All replies / captures are file-private
//  so this driver does not collide with the same-named symbols in the
//  sibling bridge test files.
//

import XCTest
@testable import Calyx

// MARK: - file-private region-detaching helper

/// Deserialize JSON into a fresh `[String: Any]` whose region is
/// independent of any caller-held value. Mirrors the helpers in the
/// sibling bridge test files but is file-private so the files can compile
/// side-by-side under Swift 6.2 strict concurrency.
fileprivate func freshDictBugSpecB(fromJSON data: Data) -> sending [String: Any] {
    (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
}

// MARK: - file-private fake LSP server driver

/// Captures every request *and notification* the bridge sends and emits a
/// configurable reply for each request. Replies are queued per-method:
/// `setReply(method: ..., jsonResult: ...)` called N times queues N
/// responses, which are consumed in FIFO order. This lets the symbol-walk
/// BFS test return a different `callHierarchy/incomingCalls` payload for
/// each hop without needing per-transport routing.
fileprivate actor BugSpecBServerDriver: LSPSessionFactory {

    // MARK: - Configuration

    private var methodReplyQueues: [String: [String]] = [:]
    private var methodErrors: [String: (code: Int, message: String)] = [:]

    private var paramsCaptured: [String: [[String: Any]]] = [:]
    private(set) var clientsMade: Int = 0
    private var transports: [InMemoryLSPTransport] = []
    private var sidecars: [Task<Void, Never>] = []

    init() {}

    // MARK: - Test configuration API

    /// Queue a reply for `method`. Successive calls append; a call that has
    /// no remaining queued reply gets `null` from `consumeReply`.
    func setReply(method: String, jsonResult: String) {
        methodReplyQueues[method, default: []].append(jsonResult)
    }

    func setError(method: String, code: Int, message: String) {
        methodErrors[method] = (code, message)
    }

    /// Snapshot of every params payload the bridge sent for `method`, in
    /// arrival order. Round-trips through `JSONSerialization` so the
    /// returned region is fresh for the caller.
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
        guard var queue = methodReplyQueues[method], !queue.isEmpty else { return nil }
        let next = queue.removeFirst()
        methodReplyQueues[method] = queue.isEmpty ? nil : queue
        return next
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
        driver: BugSpecBServerDriver
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
                                params: freshDictBugSpecB(fromJSON: data)
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
                                params: freshDictBugSpecB(fromJSON: data)
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
        if let n = any as? NSNumber { return n.intValue }
        if let s = any as? String { return Int(s) }
        return nil
    }
}

// MARK: - MCPLSPBridgeBugSpecGroupBTests

@MainActor
final class MCPLSPBridgeBugSpecGroupBTests: XCTestCase {

    // MARK: - Constants

    private let workspaceA = URL(fileURLWithPath: "/tmp/calyx-mcp-bridge-bug-grp-b-A")
    private let workspaceB = URL(fileURLWithPath: "/tmp/calyx-mcp-bridge-bug-grp-b-B")
    private let fileAUri = "file:///tmp/calyx-mcp-bridge-bug-grp-b-A/main.ts"
    private let fileBUri = "file:///tmp/calyx-mcp-bridge-bug-grp-b-B/main.ts"

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

    /// Spin up the bridge under test plus the driver so the test can
    /// configure replies and inspect captured params.
    private func makeBridge() async -> (bridge: MCPLSPBridge, driver: BugSpecBServerDriver) {
        let installer = await makeReadyInstaller()
        let driver = BugSpecBServerDriver()
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

    /// Warm a `(workspace, typescript)` session via a single `lsp_hover`
    /// round-trip with a `null` hover reply. Cheap, deterministic, drives
    /// the full handshake so subsequent tools see a `.running` session.
    private func warmSession(
        bridge: MCPLSPBridge,
        driver: BugSpecBServerDriver,
        workspace: URL,
        file: String
    ) async throws {
        await driver.setReply(method: "textDocument/hover", jsonResult: "null")
        let args: [String: AnyCodable] = [
            "workspace_root": AnyCodable(workspace.path),
            "language_id": AnyCodable("typescript"),
            "file": AnyCodable(file),
            "line": AnyCodable(0),
            "column": AnyCodable(0),
        ]
        _ = try await bridge.handleToolCall(name: "lsp_hover", arguments: args)
    }

    /// Render a minimal `CallHierarchyItem` JSON literal that decodes
    /// cleanly with the LSP types. Used to compose `incomingCalls` replies
    /// for the BFS test.
    private func callHierarchyItemJSON(name: String, uri: String) -> String {
        """
        {
          "name": "\(name)",
          "kind": 12,
          "uri": "\(uri)",
          "range": {"start":{"line":0,"character":0},"end":{"line":0,"character":10}},
          "selectionRange": {"start":{"line":0,"character":0},"end":{"line":0,"character":10}}
        }
        """
    }

    // MARK: - Bug 1: lsp_symbol_walk depth=3 must BFS all four nodes

    /// The seed is `f1`. We script `callHierarchy/incomingCalls` to return:
    ///   - hop 1 (for f1) → caller f2
    ///   - hop 2 (for f2) → caller f3
    ///   - hop 3 (for f3) → caller f4
    ///   - hop 4 (for f4) → []   (BFS terminator if the impl ever asks)
    /// The bridge under test today only issues one `incomingCalls` request
    /// (depth=1) so f3 / f4 are unreachable and the assertions below fail.
    func test_symbolWalk_depthThree_walksAllFourNodes() async throws {
        let (bridge, driver) = await makeBridge()

        let incomingF2 = """
        [
          {"from": \(callHierarchyItemJSON(name: "f2", uri: "file:///tmp/f2.ts")),
           "fromRanges":[{"start":{"line":1,"character":0},"end":{"line":1,"character":2}}]}
        ]
        """
        let incomingF3 = """
        [
          {"from": \(callHierarchyItemJSON(name: "f3", uri: "file:///tmp/f3.ts")),
           "fromRanges":[{"start":{"line":2,"character":0},"end":{"line":2,"character":2}}]}
        ]
        """
        let incomingF4 = """
        [
          {"from": \(callHierarchyItemJSON(name: "f4", uri: "file:///tmp/f4.ts")),
           "fromRanges":[{"start":{"line":3,"character":0},"end":{"line":3,"character":2}}]}
        ]
        """
        await driver.setReply(method: "callHierarchy/incomingCalls", jsonResult: incomingF2)
        await driver.setReply(method: "callHierarchy/incomingCalls", jsonResult: incomingF3)
        await driver.setReply(method: "callHierarchy/incomingCalls", jsonResult: incomingF4)
        await driver.setReply(method: "callHierarchy/incomingCalls", jsonResult: "[]")

        let seedItem: [String: AnyCodable] = [
            "name": AnyCodable("f1"),
            "kind": AnyCodable(12),
            "uri": AnyCodable("file:///tmp/f1.ts"),
            "range": AnyCodable([
                "start": AnyCodable([
                    "line": AnyCodable(0), "character": AnyCodable(0),
                ] as [String: AnyCodable]),
                "end": AnyCodable([
                    "line": AnyCodable(0), "character": AnyCodable(2),
                ] as [String: AnyCodable]),
            ] as [String: AnyCodable]),
            "selectionRange": AnyCodable([
                "start": AnyCodable([
                    "line": AnyCodable(0), "character": AnyCodable(0),
                ] as [String: AnyCodable]),
                "end": AnyCodable([
                    "line": AnyCodable(0), "character": AnyCodable(2),
                ] as [String: AnyCodable]),
            ] as [String: AnyCodable]),
        ]

        let args: [String: AnyCodable] = [
            "workspace_root": AnyCodable(workspaceA.path),
            "language_id": AnyCodable("typescript"),
            "item": AnyCodable(seedItem),
            "direction": AnyCodable("call_incoming"),
            "depth": AnyCodable(3),
        ]
        let content = try await bridge.handleToolCall(
            name: "lsp_symbol_walk",
            arguments: args
        )
        XCTAssertEqual(content.type, "text")

        // The BFS must surface every hop in the chain. Today only the
        // direct hop-1 caller (f2) ever appears because the handler stops
        // after one `incomingCalls` round-trip.
        XCTAssertTrue(
            content.text.contains("f2"),
            "lsp_symbol_walk depth=3 must include hop-1 caller f2; got: \(content.text)"
        )
        XCTAssertTrue(
            content.text.contains("f3"),
            "lsp_symbol_walk depth=3 must include hop-2 caller f3 (BFS); got: \(content.text)"
        )
        XCTAssertTrue(
            content.text.contains("f4"),
            "lsp_symbol_walk depth=3 must include hop-3 caller f4 (BFS); got: \(content.text)"
        )

        // The bridge must issue `callHierarchy/incomingCalls` once per
        // frontier node — for f1, f2, and f3 — to reach depth 3. The
        // current implementation issues exactly one round-trip.
        let captured = await driver.capturedParams(forMethod: "callHierarchy/incomingCalls")
        XCTAssertGreaterThanOrEqual(
            captured.count, 3,
            "BFS at depth=3 must issue callHierarchy/incomingCalls at least 3 times (for f1, f2, f3); got \(captured.count) call(s)"
        )
    }

    // MARK: - Bug 2: lsp_hover_bundle must populate surrounding_code

    /// Writes a 30-line file with distinctive line tokens (`LINE_00` …
    /// `LINE_29`), asks the bridge for a hover bundle centred on line 15
    /// with `context_lines=3`, and asserts that `surrounding_code`:
    ///   - is non-empty,
    ///   - includes the seven lines 12..18,
    ///   - excludes lines 11 and 19 (the just-outside-window neighbours),
    ///   - carries some kind of line-number marker so the AI consumer can
    ///     map back to absolute line numbers.
    /// Today's handler hard-codes `surrounding_code` to "" so every
    /// assertion below fails.
    func test_hoverBundle_includesSurroundingCodeAroundPosition() async throws {
        let (bridge, driver) = await makeBridge()

        // Build the on-disk 30-line file in a fresh workspace-isolated dir.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("calyx-bridge-bug-grp-b-hover-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let filePath = dir.appendingPathComponent("subject.ts")
        let lines = (0..<30).map { "LINE_\(String(format: "%02d", $0))" }
        let text = lines.joined(separator: "\n") + "\n"
        try text.write(to: filePath, atomically: true, encoding: .utf8)

        // hover + definition replies — present so the bundle handler can
        // still surface its non-context fields and the test isolates the
        // `surrounding_code` regression cleanly.
        await driver.setReply(
            method: "textDocument/hover",
            jsonResult: #"{"contents":{"kind":"plaintext","value":"hover-text"}}"#
        )
        await driver.setReply(
            method: "textDocument/definition",
            jsonResult: "null"
        )

        let args: [String: AnyCodable] = [
            "workspace_root": AnyCodable(dir.path),
            "language_id": AnyCodable("typescript"),
            "file": AnyCodable(filePath.absoluteString),
            "line": AnyCodable(15),
            "column": AnyCodable(0),
            "context_lines": AnyCodable(3),
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
        guard let surrounding = obj["surrounding_code"] as? String else {
            XCTFail("lsp_hover_bundle JSON must carry a string 'surrounding_code'; got: \(obj)")
            return
        }

        XCTAssertFalse(
            surrounding.isEmpty,
            "surrounding_code must be populated when the file is on disk and context_lines=3; got empty string"
        )

        for keep in 12...18 {
            let token = "LINE_\(String(format: "%02d", keep))"
            XCTAssertTrue(
                surrounding.contains(token),
                "surrounding_code must include \(token) (line \(keep) is inside ±3 window); got: \(surrounding)"
            )
        }
        for drop in [11, 19] {
            let token = "LINE_\(String(format: "%02d", drop))"
            XCTAssertFalse(
                surrounding.contains(token),
                "surrounding_code must NOT include \(token) (line \(drop) is outside the ±3 window); got: \(surrounding)"
            )
        }

        // Line-number markers: the snippet must carry the absolute 0-based
        // line numbers for the window edges and the centre so the AI
        // consumer can correlate snippet rows with the file.
        XCTAssertTrue(
            surrounding.contains("12") && surrounding.contains("15") && surrounding.contains("18"),
            "surrounding_code must carry line-number markers for 12 / 15 / 18; got: \(surrounding)"
        )

        // Cleanup — best-effort.
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - Bug 3: lsp_cross_workspace_definition must moniker + fan out

    /// Warms two distinct `(workspace, typescript)` sessions (A and B),
    /// scripts `textDocument/moniker` to return identifier `X.foo`, scripts
    /// `workspace/symbol` to return two locations under `file:///tmp/wsB`,
    /// and asks the bridge to resolve a cross-workspace definition rooted
    /// in workspace A. The handler must:
    ///   1. issue `textDocument/moniker` on the origin position,
    ///   2. issue `workspace/symbol` against every warm session with the
    ///      moniker identifier as the query,
    ///   3. annotate each resolved entry with `resolved_in: <workspace>`,
    ///   4. surface the B-locations in the aggregated result.
    /// Today's handler simply delegates to `DefinitionTool`, so the
    /// moniker / workspace-symbol captures stay at zero and the `resolved_in`
    /// annotation never appears.
    func test_crossWorkspaceDefinition_usesMonikerAndFanOutWorkspaceSymbol() async throws {
        let (bridge, driver) = await makeBridge()

        // Warm both workspaces so the bridge has two live sessions to fan
        // out across.
        try await warmSession(
            bridge: bridge,
            driver: driver,
            workspace: workspaceA,
            file: fileAUri
        )
        try await warmSession(
            bridge: bridge,
            driver: driver,
            workspace: workspaceB,
            file: fileBUri
        )

        let monikerJSON = #"[{"scheme":"tsc","identifier":"X.foo","kind":"export"}]"#
        await driver.setReply(method: "textDocument/moniker", jsonResult: monikerJSON)

        // Queue the same workspace/symbol payload twice so each warm
        // session that the bridge fans out to gets a deterministic reply.
        let wsBSymbolJSON = """
        [
          {
            "name": "X.foo",
            "kind": 12,
            "location": {
              "uri": "file:///tmp/wsB/foo.ts",
              "range": {"start":{"line":0,"character":0},"end":{"line":0,"character":6}}
            }
          },
          {
            "name": "X.foo",
            "kind": 12,
            "location": {
              "uri": "file:///tmp/wsB/bar.ts",
              "range": {"start":{"line":1,"character":0},"end":{"line":1,"character":6}}
            }
          }
        ]
        """
        await driver.setReply(method: "workspace/symbol", jsonResult: wsBSymbolJSON)
        await driver.setReply(method: "workspace/symbol", jsonResult: wsBSymbolJSON)

        // Also configure an empty definition reply in case the new
        // implementation still asks the origin workspace for
        // textDocument/definition as a fallback. The test does not depend
        // on its shape.
        await driver.setReply(method: "textDocument/definition", jsonResult: "[]")

        let args: [String: AnyCodable] = [
            "workspace_root": AnyCodable(workspaceA.path),
            "language_id": AnyCodable("typescript"),
            "file": AnyCodable(fileAUri),
            "line": AnyCodable(9),
            "column": AnyCodable(0),
        ]
        let content = try await bridge.handleToolCall(
            name: "lsp_cross_workspace_definition",
            arguments: args
        )
        XCTAssertEqual(content.type, "text")

        // 1. textDocument/moniker must be queried on the origin session.
        let monikerCalls = await driver.capturedParams(forMethod: "textDocument/moniker")
        XCTAssertGreaterThanOrEqual(
            monikerCalls.count, 1,
            "lsp_cross_workspace_definition must call textDocument/moniker on the origin session; got \(monikerCalls.count) call(s)"
        )

        // 2. workspace/symbol must be fanned across warm sessions, using
        //    the moniker identifier as the query.
        let symbolCalls = await driver.capturedParams(forMethod: "workspace/symbol")
        XCTAssertGreaterThanOrEqual(
            symbolCalls.count, 1,
            "lsp_cross_workspace_definition must fan workspace/symbol across warm sessions; got \(symbolCalls.count) call(s)"
        )
        if let first = symbolCalls.first {
            XCTAssertEqual(
                first["query"] as? String, "X.foo",
                "workspace/symbol must use the moniker identifier as query; got params=\(first)"
            )
        }

        // 3. Aggregated result must surface the B-side locations.
        XCTAssertTrue(
            content.text.contains("file:///tmp/wsB/foo.ts"),
            "result must surface a workspace-B location resolved via moniker; got: \(content.text)"
        )

        // 4. Each resolved entry must be annotated with the workspace it
        //    came from (the plan calls the field `resolved_in`).
        XCTAssertTrue(
            content.text.contains("resolved_in"),
            "result must annotate each location with a 'resolved_in: <workspace>' field; got: \(content.text)"
        )
    }
}
