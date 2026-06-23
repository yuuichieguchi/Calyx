//
//  MCPLSPBridgeHoverBundleBugSpecTests.swift
//  Calyx
//
//  TDD red-phase tests for the two remaining `lsp_hover_bundle` gaps
//  promised by the original plan but not yet wired into the handler:
//
//    1. `dependent_types` — the bundle must surface hover info for every
//       non-primitive type identifier referenced by the cursor symbol's
//       signature. e.g. hovering on `fn foo() -> Vec<KeyValue>` must also
//       resolve `Vec` and `KeyValue` (locations + hover) so the AI
//       consumer can grok the full type graph without an extra round-trip.
//       The bridge MUST issue `workspace/symbol` (one query per dependent
//       identifier) and the JSON envelope MUST include a
//       `dependent_types: [{ name, location, hover }, ...]` array. The
//       array MUST skip builtin primitives (`u32`, `bool`, …) and be
//       capped at 5 entries so the response stays bounded.
//
//    2. `doc_comment` — when the LSP hover content is a markdown payload
//       composed of a fenced code block followed by descriptive prose
//       (the conventional Rust-analyzer / rustdoc shape), the bundle must
//       expose the non-code-block prose verbatim under a `doc_comment`
//       string field. Today the field doesn't exist.
//
//  Driver pattern follows the sibling bridge tests (see
//  `MCPLSPBridgeBugSpecGroupBTests.swift` for `BugSpecBServerDriver`): a
//  file-private actor that conforms to `LSPSessionFactory`, drives an
//  `InMemoryLSPTransport` sidecar, captures every request + notification,
//  and emits a configurable reply per request. Replies are queued
//  per-method so the dependent-type test can serve a distinct
//  `workspace/symbol` payload for each identifier in arrival order.
//
//  TDD phase: RED. Every assertion below MUST FAIL against the current
//  bridge: the bundle envelope only contains
//  `hover` / `definition` / `surrounding_code` today, so `dependent_types`
//  / `doc_comment` parsing returns nil and `workspace/symbol` is never
//  issued from this code path.
//

import XCTest
@testable import Calyx

// MARK: - file-private region-detaching helper

/// Deserialize JSON into a fresh `[String: Any]` whose memory region is
/// independent of any caller-held value. Matches the helper used in the
/// sibling bridge test files but is file-private so this file can compile
/// side-by-side without symbol collisions under Swift 6.2 strict
/// concurrency.
fileprivate func freshDictHoverBundleBugSpec(fromJSON data: Data) -> sending [String: Any] {
    (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
}

// MARK: - file-private fake LSP server driver

/// Captures every request and notification the bridge sends and emits a
/// configurable reply for each request. Replies are queued per-method:
/// `setReply(method: ..., jsonResult: ...)` called N times queues N
/// responses, consumed in FIFO order. This lets the dependent-type test
/// hand back distinct `workspace/symbol` payloads for `Vec` vs
/// `KeyValue` without per-transport routing.
fileprivate actor HoverBundleBugSpecDriver: LSPSessionFactory {

    // MARK: - Configuration

    private var methodReplyQueues: [String: [String]] = [:]

    private var paramsCaptured: [String: [[String: Any]]] = [:]
    private(set) var clientsMade: Int = 0
    private var transports: [InMemoryLSPTransport] = []
    private var sidecars: [Task<Void, Never>] = []

    init() {}

    // MARK: - Test configuration API

    /// Queue a reply for `method`. Successive calls append; a call that
    /// has no remaining queued reply falls back to `null` in
    /// `consumeReply`.
    func setReply(method: String, jsonResult: String) {
        methodReplyQueues[method, default: []].append(jsonResult)
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

    fileprivate func recordParams(method: String, params: sending [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: params),
              let copy = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        paramsCaptured[method, default: []].append(copy)
    }

    // MARK: - Server simulator

    private static func driveServerReplies(
        on transport: InMemoryLSPTransport,
        driver: HoverBundleBugSpecDriver
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
                                params: freshDictHoverBundleBugSpec(fromJSON: data)
                            )
                        } else {
                            await driver.recordParams(method: method, params: [:])
                        }
                    } else {
                        await driver.recordParams(method: method, params: [:])
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
                                params: freshDictHoverBundleBugSpec(fromJSON: data)
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

// MARK: - MCPLSPBridgeHoverBundleBugSpecTests

@MainActor
final class MCPLSPBridgeHoverBundleBugSpecTests: XCTestCase {

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

    /// Spin up the bridge under test plus the driver so each test can
    /// configure replies and inspect captured params.
    private func makeBridge() async -> (bridge: MCPLSPBridge, driver: HoverBundleBugSpecDriver) {
        let installer = await makeReadyInstaller()
        let driver = HoverBundleBugSpecDriver()
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

    /// Create a one-line on-disk subject file so `ensureFileOpen` has a
    /// readable source and the bridge can compute `surrounding_code`
    /// without the test having to care about its contents.
    private func makeTempSubject() throws -> (dir: URL, file: URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("calyx-hover-bundle-bug-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("subject.ts")
        try "// placeholder\n".write(to: file, atomically: true, encoding: .utf8)
        return (dir, file)
    }

    /// JSON-escape a Swift string for embedding inside a JSON string
    /// literal. Order matters: backslash first, then double quote, then
    /// newline (and carriage return) so the replacements compose
    /// idempotently.
    private func jsonEscape(_ s: String) -> String {
        s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    // MARK: - Test 1: dependent_types must be resolved + surfaced

    /// Mocks an LSP hover that returns `"fn foo() -> Vec<KeyValue>"` for
    /// the cursor. Expects the bundle handler to:
    ///   1. parse `Vec` and `KeyValue` out of the hover text,
    ///   2. issue `workspace/symbol` once per identifier to resolve the
    ///      type's home location,
    ///   3. issue follow-up `textDocument/hover` calls at the resolved
    ///      locations to enrich each entry,
    ///   4. expose the aggregated result under
    ///      `dependent_types: [{ name, location, hover }, ...]`.
    ///
    /// Today the bundle envelope omits `dependent_types` entirely and the
    /// handler never calls `workspace/symbol`, so every assertion below
    /// fails.
    func test_hoverBundle_includesDependentTypes() async throws {
        let (bridge, driver) = await makeBridge()
        let (dir, file) = try makeTempSubject()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Cursor hover — references two non-primitive type identifiers.
        await driver.setReply(
            method: "textDocument/hover",
            jsonResult: #"{"contents":{"kind":"plaintext","value":"fn foo() -> Vec<KeyValue>"}}"#
        )
        await driver.setReply(method: "textDocument/definition", jsonResult: "null")

        // workspace/symbol fan-out: one reply per dependent identifier,
        // consumed in arrival order.
        let vecSymbolJSON = """
        [
          {
            "name": "Vec",
            "kind": 23,
            "location": {
              "uri": "file:///tmp/std/vec.rs",
              "range": {"start":{"line":0,"character":0},"end":{"line":0,"character":3}}
            }
          }
        ]
        """
        let kvSymbolJSON = """
        [
          {
            "name": "KeyValue",
            "kind": 23,
            "location": {
              "uri": "file:///tmp/app/key_value.rs",
              "range": {"start":{"line":4,"character":0},"end":{"line":4,"character":8}}
            }
          }
        ]
        """
        await driver.setReply(method: "workspace/symbol", jsonResult: vecSymbolJSON)
        await driver.setReply(method: "workspace/symbol", jsonResult: kvSymbolJSON)

        // Follow-up hovers at the resolved sites — the implementation may
        // or may not enrich the entries with a second hover round-trip,
        // but queuing these makes the test deterministic either way.
        await driver.setReply(
            method: "textDocument/hover",
            jsonResult: #"{"contents":{"kind":"plaintext","value":"struct Vec<T>"}}"#
        )
        await driver.setReply(
            method: "textDocument/hover",
            jsonResult: #"{"contents":{"kind":"plaintext","value":"struct KeyValue { key: String, value: String }"}}"#
        )

        let args: [String: AnyCodable] = [
            "workspace_root": AnyCodable(dir.path),
            "language_id": AnyCodable("typescript"),
            "file": AnyCodable(file.absoluteString),
            "line": AnyCodable(0),
            "column": AnyCodable(0),
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

        // ---- shape assertion: dependent_types must be present ----
        guard let deps = obj["dependent_types"] as? [[String: Any]] else {
            XCTFail(
                "lsp_hover_bundle JSON must include a 'dependent_types' array; got keys: \(Array(obj.keys))"
            )
            return
        }
        XCTAssertGreaterThanOrEqual(
            deps.count, 1,
            "dependent_types must surface at least one entry for hover 'fn foo() -> Vec<KeyValue>'; got 0"
        )

        // Each entry must carry { name, location, hover }.
        let depNames = deps.compactMap { $0["name"] as? String }
        XCTAssertTrue(
            depNames.contains("Vec"),
            "dependent_types must include 'Vec'; got names=\(depNames)"
        )
        XCTAssertTrue(
            depNames.contains("KeyValue"),
            "dependent_types must include 'KeyValue'; got names=\(depNames)"
        )
        for entry in deps {
            XCTAssertNotNil(
                entry["location"],
                "each dependent_types entry must carry a 'location' field; got entry=\(entry)"
            )
            XCTAssertNotNil(
                entry["hover"],
                "each dependent_types entry must carry a 'hover' field; got entry=\(entry)"
            )
        }

        // ---- behaviour assertion: workspace/symbol fan-out ----
        let symbolCalls = await driver.capturedParams(forMethod: "workspace/symbol")
        XCTAssertGreaterThanOrEqual(
            symbolCalls.count, 2,
            "lsp_hover_bundle must issue workspace/symbol for each dependent type identifier (Vec, KeyValue); got \(symbolCalls.count) call(s)"
        )
        let queries = symbolCalls.compactMap { $0["query"] as? String }
        XCTAssertTrue(
            queries.contains("Vec"),
            "workspace/symbol must be issued for 'Vec'; got queries=\(queries)"
        )
        XCTAssertTrue(
            queries.contains("KeyValue"),
            "workspace/symbol must be issued for 'KeyValue'; got queries=\(queries)"
        )
    }

    // MARK: - Test 2: doc_comment extracted from markdown hover

    /// Mocks an LSP hover whose markdown payload is a fenced Rust code
    /// block followed by a single descriptive sentence (the conventional
    /// rust-analyzer / rustdoc shape). Expects the bundle envelope to
    /// expose the descriptive sentence verbatim under `doc_comment`.
    ///
    /// Today the bundle envelope has no `doc_comment` field, so the
    /// downcast returns nil and the test fails.
    func test_hoverBundle_extractsDocCommentField() async throws {
        let (bridge, driver) = await makeBridge()
        let (dir, file) = try makeTempSubject()
        defer { try? FileManager.default.removeItem(at: dir) }

        let docComment = "Maps a key-value input to a list of output key-value pairs."
        let markdown = "```rust\npub fn foo() -> Vec<KeyValue>\n```\n\(docComment)"
        let escaped = jsonEscape(markdown)
        let hoverJSON = #"{"contents":{"kind":"markdown","value":"\#(escaped)"}}"#
        await driver.setReply(method: "textDocument/hover", jsonResult: hoverJSON)
        await driver.setReply(method: "textDocument/definition", jsonResult: "null")

        // Drain any opportunistic dependent-type lookups so the
        // implementation never deadlocks waiting for a reply.
        for _ in 0..<4 {
            await driver.setReply(method: "workspace/symbol", jsonResult: "[]")
            await driver.setReply(method: "textDocument/hover", jsonResult: "null")
        }

        let args: [String: AnyCodable] = [
            "workspace_root": AnyCodable(dir.path),
            "language_id": AnyCodable("typescript"),
            "file": AnyCodable(file.absoluteString),
            "line": AnyCodable(0),
            "column": AnyCodable(0),
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
        guard let docField = obj["doc_comment"] as? String else {
            XCTFail(
                "lsp_hover_bundle JSON must include a 'doc_comment' string; got keys: \(Array(obj.keys))"
            )
            return
        }
        XCTAssertEqual(
            docField.trimmingCharacters(in: .whitespacesAndNewlines),
            docComment,
            "doc_comment must hold the non-code-block markdown portion verbatim; got: '\(docField)'"
        )
        XCTAssertFalse(
            docField.contains("```"),
            "doc_comment must strip the code-fence markup; got: '\(docField)'"
        )
        XCTAssertFalse(
            docField.contains("pub fn foo"),
            "doc_comment must not include the code-block body; got: '\(docField)'"
        )
    }

    // MARK: - Test 3: dependent_types skips builtin primitives

    /// Mocks a hover that references only primitive identifiers (`u32`,
    /// `bool`). The bundle's `dependent_types` array must exist but be
    /// empty (or at least exclude primitives) so the AI consumer isn't
    /// spammed with noise for which there is no meaningful definition
    /// site.
    ///
    /// Today the field doesn't exist, so the downcast to `[[String:
    /// Any]]` returns nil and the test fails at the shape assertion.
    func test_hoverBundle_dependent_types_skipsBuiltinPrimitives() async throws {
        let (bridge, driver) = await makeBridge()
        let (dir, file) = try makeTempSubject()
        defer { try? FileManager.default.removeItem(at: dir) }

        await driver.setReply(
            method: "textDocument/hover",
            jsonResult: #"{"contents":{"kind":"plaintext","value":"fn bar(x: u32) -> bool"}}"#
        )
        await driver.setReply(method: "textDocument/definition", jsonResult: "null")

        // Drain opportunistic fan-out so the impl never blocks on a reply.
        for _ in 0..<4 {
            await driver.setReply(method: "workspace/symbol", jsonResult: "[]")
            await driver.setReply(method: "textDocument/hover", jsonResult: "null")
        }

        let args: [String: AnyCodable] = [
            "workspace_root": AnyCodable(dir.path),
            "language_id": AnyCodable("typescript"),
            "file": AnyCodable(file.absoluteString),
            "line": AnyCodable(0),
            "column": AnyCodable(0),
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
        guard let deps = obj["dependent_types"] as? [[String: Any]] else {
            XCTFail(
                "lsp_hover_bundle JSON must include a 'dependent_types' array (even if empty); got keys: \(Array(obj.keys))"
            )
            return
        }
        let depNames = deps.compactMap { $0["name"] as? String }
        XCTAssertFalse(
            depNames.contains("u32"),
            "dependent_types must skip primitive 'u32'; got names=\(depNames)"
        )
        XCTAssertFalse(
            depNames.contains("bool"),
            "dependent_types must skip primitive 'bool'; got names=\(depNames)"
        )
    }

    // MARK: - Test 4: dependent_types is capped at 5

    /// Mocks a hover whose signature references 10 distinct non-primitive
    /// identifiers. The bundle MUST cap `dependent_types` at 5 entries so
    /// the response payload stays bounded for the AI consumer.
    ///
    /// Today the field doesn't exist at all, so the cap test fails at the
    /// shape assertion before reaching the count assertion.
    func test_hoverBundle_capsDependentTypes_at5() async throws {
        let (bridge, driver) = await makeBridge()
        let (dir, file) = try makeTempSubject()
        defer { try? FileManager.default.removeItem(at: dir) }

        // 10 distinct identifiers (T1..T10) — all start with a capital
        // letter so any reasonable parser treats them as user types
        // rather than primitives.
        let value = "fn z(a: T1, b: T2, c: T3, d: T4, e: T5, f: T6, g: T7, h: T8, i: T9, j: T10)"
        let hoverJSON = #"{"contents":{"kind":"plaintext","value":"\#(value)"}}"#
        await driver.setReply(method: "textDocument/hover", jsonResult: hoverJSON)
        await driver.setReply(method: "textDocument/definition", jsonResult: "null")

        // Provide a generous reply queue so the implementation can issue
        // up to 10 workspace/symbol + 10 follow-up hover round-trips
        // without deadlocking while still being capped to 5 on the
        // output side.
        for _ in 0..<15 {
            await driver.setReply(method: "workspace/symbol", jsonResult: "[]")
            await driver.setReply(method: "textDocument/hover", jsonResult: "null")
        }

        let args: [String: AnyCodable] = [
            "workspace_root": AnyCodable(dir.path),
            "language_id": AnyCodable("typescript"),
            "file": AnyCodable(file.absoluteString),
            "line": AnyCodable(0),
            "column": AnyCodable(0),
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
        guard let deps = obj["dependent_types"] as? [[String: Any]] else {
            XCTFail(
                "lsp_hover_bundle JSON must include a 'dependent_types' array; got keys: \(Array(obj.keys))"
            )
            return
        }
        XCTAssertLessThanOrEqual(
            deps.count, 5,
            "dependent_types must be capped at 5 to bound response size; got count=\(deps.count)"
        )
    }
}
