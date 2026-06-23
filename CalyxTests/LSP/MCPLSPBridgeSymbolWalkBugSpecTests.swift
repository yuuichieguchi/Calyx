//
//  MCPLSPBridgeSymbolWalkBugSpecTests.swift
//  Calyx
//
//  TDD red-phase tests for the `lsp_symbol_walk` MCP tool. The original
//  feature plan
//  (~/.claude/plans/claude-code-lsp-coding-agent-lsp-ai-nod-streamed-stroustrup.md,
//  line 98) requires `lsp_symbol_walk` to traverse BOTH the call hierarchy
//  AND the type hierarchy, in either direction:
//
//      kind: "call_incoming"    -> callHierarchy/incomingCalls   (today's only path)
//      kind: "call_outgoing"    -> callHierarchy/outgoingCalls   (missing)
//      kind: "type_supertypes"  -> textDocument/prepareTypeHierarchy
//                                  + typeHierarchy/supertypes    (missing)
//      kind: "type_subtypes"    -> textDocument/prepareTypeHierarchy
//                                  + typeHierarchy/subtypes      (missing)
//
//  Today the handler:
//    - exposes the parameter under the name `direction` instead of `kind`,
//    - rejects any value other than `"call_incoming"` with an
//      `invalidArgument` error,
//    - issues `callHierarchy/incomingCalls` only.
//
//  Because the `kind` argument is silently ignored by the current code, the
//  bridge falls back to its `call_incoming` default for tests 1-3, never
//  issues `callHierarchy/outgoingCalls`, never issues
//  `textDocument/prepareTypeHierarchy`, never issues
//  `typeHierarchy/{supertypes,subtypes}`, and never surfaces the deeper
//  hops the tests expect. Tests 1-3 therefore fail (RED). Test 4 confirms
//  the existing default behaviour (no `kind`) and is expected to PASS — it
//  is a regression guard for future implementations that swap `direction`
//  for `kind`.
//
//  Driver pattern mirrors `MCPLSPBridgeBugSpecGroupBTests.swift`: a
//  file-private actor that conforms to `LSPSessionFactory`, drives
//  `InMemoryLSPTransport` sidecars, queues per-method replies and captures
//  every request + notification.
//

import XCTest
@testable import Calyx

// MARK: - file-private region-detaching helper

/// Deserialize JSON into a fresh `[String: Any]` whose region is
/// independent of any caller-held value. The "SymWalk" suffix avoids a
/// symbol collision with the same-named helper in the sibling bridge test
/// files under Swift 6.2 strict concurrency.
fileprivate func freshDictSymWalk(fromJSON data: Data) -> sending [String: Any] {
    (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
}

// MARK: - file-private fake LSP server driver

/// Per-method FIFO reply queue plus a captured-params recorder, wired into
/// `LSPClient` via an `InMemoryLSPTransport` sidecar. The driver is the
/// same shape as `BugSpecBServerDriver` in the sibling file — duplicated
/// here so both files can compile side-by-side and the two test suites
/// remain independently runnable.
fileprivate actor SymWalkServerDriver: LSPSessionFactory {

    // MARK: - Configuration

    private var methodReplyQueues: [String: [String]] = [:]
    private var methodErrors: [String: (code: Int, message: String)] = [:]

    private var paramsCaptured: [String: [[String: Any]]] = [:]
    private(set) var clientsMade: Int = 0
    private var transports: [InMemoryLSPTransport] = []
    private var sidecars: [Task<Void, Never>] = []

    init() {}

    // MARK: - Test configuration API

    func setReply(method: String, jsonResult: String) {
        methodReplyQueues[method, default: []].append(jsonResult)
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

    func capturedCount(forMethod method: String) -> Int {
        paramsCaptured[method]?.count ?? 0
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
        driver: SymWalkServerDriver
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
                                params: freshDictSymWalk(fromJSON: data)
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
                    if handledNotificationIndices.contains(idx) { continue }
                    handledNotificationIndices.insert(idx)
                    if let p = dict["params"] as? [String: Any] {
                        if let data = try? JSONSerialization.data(withJSONObject: p) {
                            await driver.recordParams(
                                method: method,
                                params: freshDictSymWalk(fromJSON: data)
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

// MARK: - MCPLSPBridgeSymbolWalkBugSpecTests

@MainActor
final class MCPLSPBridgeSymbolWalkBugSpecTests: XCTestCase {

    // MARK: - Constants

    private let workspace = URL(fileURLWithPath: "/tmp/calyx-mcp-bridge-symwalk-bug")

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

    private func makeBridge() async -> (bridge: MCPLSPBridge, driver: SymWalkServerDriver) {
        let installer = await makeReadyInstaller()
        let driver = SymWalkServerDriver()
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

    /// Build a hierarchy-item JSON literal — schemes for CallHierarchyItem
    /// and TypeHierarchyItem are structurally identical (same field set,
    /// same `kind` SymbolKind enum) so a single helper covers both.
    private func hierarchyItemJSON(name: String, uri: String) -> String {
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

    /// Build the seed-item argument payload (AnyCodable dict) for the
    /// MCP tool-call. Reused across the four tests so the seed shape stays
    /// in sync between every walk scenario.
    private func seedItem(name: String, uri: String) -> AnyCodable {
        AnyCodable([
            "name": AnyCodable(name),
            "kind": AnyCodable(12),
            "uri": AnyCodable(uri),
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
        ] as [String: AnyCodable])
    }

    // MARK: - Bug 1: kind="call_outgoing" must walk callHierarchy/outgoingCalls

    /// Seed `f1`. Script the outgoing-call chain `f1 -> f2 -> f3 -> []`
    /// across three `callHierarchy/outgoingCalls` replies. At `depth=2`
    /// the walk must surface both `f2` (hop 1) and `f3` (hop 2) AND must
    /// have actually invoked `callHierarchy/outgoingCalls` on the server.
    ///
    /// Today's handler ignores the `kind` argument entirely and falls
    /// back to its `call_incoming` default, so:
    ///   * no `callHierarchy/outgoingCalls` traffic is generated,
    ///   * the BFS finds neither f2 nor f3 in the result text.
    /// Hence this test is expected to FAIL against current code.
    func test_symbolWalk_kindCallOutgoing_walksOutgoingCalls() async throws {
        let (bridge, driver) = await makeBridge()

        let outgoingF2 = """
        [
          {"to": \(hierarchyItemJSON(name: "f2", uri: "file:///tmp/f2.ts")),
           "fromRanges":[{"start":{"line":1,"character":0},"end":{"line":1,"character":2}}]}
        ]
        """
        let outgoingF3 = """
        [
          {"to": \(hierarchyItemJSON(name: "f3", uri: "file:///tmp/f3.ts")),
           "fromRanges":[{"start":{"line":2,"character":0},"end":{"line":2,"character":2}}]}
        ]
        """
        await driver.setReply(method: "callHierarchy/outgoingCalls", jsonResult: outgoingF2)
        await driver.setReply(method: "callHierarchy/outgoingCalls", jsonResult: outgoingF3)
        await driver.setReply(method: "callHierarchy/outgoingCalls", jsonResult: "[]")

        // Defensive: if the bridge still walks incoming for some reason,
        // give it an empty reply rather than a `null` so the test focuses
        // on the directional assertions below.
        await driver.setReply(method: "callHierarchy/incomingCalls", jsonResult: "[]")

        let args: [String: AnyCodable] = [
            "workspace_root": AnyCodable(workspace.path),
            "language_id": AnyCodable("typescript"),
            "item": seedItem(name: "f1", uri: "file:///tmp/f1.ts"),
            "kind": AnyCodable("call_outgoing"),
            "depth": AnyCodable(2),
        ]
        let content = try await bridge.handleToolCall(
            name: "lsp_symbol_walk",
            arguments: args
        )
        XCTAssertEqual(content.type, "text")

        // The bridge must surface every reachable hop within depth=2.
        XCTAssertTrue(
            content.text.contains("f2"),
            "kind='call_outgoing' depth=2 must include hop-1 callee f2; got: \(content.text)"
        )
        XCTAssertTrue(
            content.text.contains("f3"),
            "kind='call_outgoing' depth=2 must include hop-2 callee f3; got: \(content.text)"
        )

        // Direction assertion: the bridge MUST have issued
        // callHierarchy/outgoingCalls (not incoming).
        let outgoingCaptured = await driver.capturedCount(
            forMethod: "callHierarchy/outgoingCalls"
        )
        XCTAssertGreaterThanOrEqual(
            outgoingCaptured, 1,
            "kind='call_outgoing' must issue callHierarchy/outgoingCalls; got \(outgoingCaptured) call(s)"
        )

        let incomingCaptured = await driver.capturedCount(
            forMethod: "callHierarchy/incomingCalls"
        )
        XCTAssertEqual(
            incomingCaptured, 0,
            "kind='call_outgoing' must NOT issue callHierarchy/incomingCalls; got \(incomingCaptured) call(s)"
        )
    }

    // MARK: - Bug 2: kind="type_supertypes" must walk typeHierarchy/supertypes

    /// Seed `Dog`. Script the supertype chain `Dog -> Mammal -> Animal -> []`
    /// across three `typeHierarchy/supertypes` replies. The bridge must
    /// first call `textDocument/prepareTypeHierarchy` (LSP requires a
    /// prepare step before any super/sub traversal) and then walk
    /// `typeHierarchy/supertypes`. At `depth=2` the result must surface
    /// `Mammal` (hop 1) and `Animal` (hop 2).
    ///
    /// Today's handler ignores `kind` and falls back to call_incoming, so
    /// neither `prepareTypeHierarchy` nor `typeHierarchy/supertypes` are
    /// ever issued — this test is expected to FAIL.
    func test_symbolWalk_kindTypeSupertypes_walksTypeHierarchy() async throws {
        let (bridge, driver) = await makeBridge()

        // The prepare step turns the (uri, position) of the seed into a
        // TypeHierarchyItem. We reply with a single Dog item so the
        // bridge can chain into typeHierarchy/supertypes from there.
        let prepareDog = """
        [\(hierarchyItemJSON(name: "Dog", uri: "file:///tmp/Dog.ts"))]
        """
        await driver.setReply(
            method: "textDocument/prepareTypeHierarchy",
            jsonResult: prepareDog
        )

        let supertypesMammal = """
        [\(hierarchyItemJSON(name: "Mammal", uri: "file:///tmp/Mammal.ts"))]
        """
        let supertypesAnimal = """
        [\(hierarchyItemJSON(name: "Animal", uri: "file:///tmp/Animal.ts"))]
        """
        await driver.setReply(method: "typeHierarchy/supertypes", jsonResult: supertypesMammal)
        await driver.setReply(method: "typeHierarchy/supertypes", jsonResult: supertypesAnimal)
        await driver.setReply(method: "typeHierarchy/supertypes", jsonResult: "[]")

        // Defensive: the current implementation will walk incoming-calls
        // instead. Queue an empty reply so the bridge does not block on
        // a missing response and the directional assertions stay precise.
        await driver.setReply(method: "callHierarchy/incomingCalls", jsonResult: "[]")

        let args: [String: AnyCodable] = [
            "workspace_root": AnyCodable(workspace.path),
            "language_id": AnyCodable("typescript"),
            "item": seedItem(name: "Dog", uri: "file:///tmp/Dog.ts"),
            "kind": AnyCodable("type_supertypes"),
            "depth": AnyCodable(2),
        ]
        let content = try await bridge.handleToolCall(
            name: "lsp_symbol_walk",
            arguments: args
        )
        XCTAssertEqual(content.type, "text")

        // Result must surface both supertypes within depth=2.
        XCTAssertTrue(
            content.text.contains("Mammal"),
            "kind='type_supertypes' depth=2 must include hop-1 supertype Mammal; got: \(content.text)"
        )
        XCTAssertTrue(
            content.text.contains("Animal"),
            "kind='type_supertypes' depth=2 must include hop-2 supertype Animal; got: \(content.text)"
        )

        // The bridge must issue prepareTypeHierarchy first and then
        // recursively walk supertypes (at least once for the seed Dog and
        // once for Mammal to reach depth=2).
        let prepareCount = await driver.capturedCount(
            forMethod: "textDocument/prepareTypeHierarchy"
        )
        XCTAssertGreaterThanOrEqual(
            prepareCount, 1,
            "kind='type_supertypes' must issue textDocument/prepareTypeHierarchy; got \(prepareCount) call(s)"
        )

        let supertypesCount = await driver.capturedCount(
            forMethod: "typeHierarchy/supertypes"
        )
        XCTAssertGreaterThanOrEqual(
            supertypesCount, 2,
            "kind='type_supertypes' depth=2 must issue typeHierarchy/supertypes at least twice (for Dog and Mammal); got \(supertypesCount) call(s)"
        )

        // Negative check — the call-hierarchy path must not be exercised.
        let incomingCount = await driver.capturedCount(
            forMethod: "callHierarchy/incomingCalls"
        )
        XCTAssertEqual(
            incomingCount, 0,
            "kind='type_supertypes' must NOT issue callHierarchy/incomingCalls; got \(incomingCount) call(s)"
        )
    }

    // MARK: - Bug 3: kind="type_subtypes" must walk typeHierarchy/subtypes

    /// Seed `Animal`. Script the subtype chain `Animal -> Mammal -> Dog -> []`
    /// across three `typeHierarchy/subtypes` replies. At `depth=2` the
    /// result must reach `Dog`.
    ///
    /// Today's handler issues neither `prepareTypeHierarchy` nor
    /// `typeHierarchy/subtypes` so this test is expected to FAIL.
    func test_symbolWalk_kindTypeSubtypes_walksSubtypes() async throws {
        let (bridge, driver) = await makeBridge()

        let prepareAnimal = """
        [\(hierarchyItemJSON(name: "Animal", uri: "file:///tmp/Animal.ts"))]
        """
        await driver.setReply(
            method: "textDocument/prepareTypeHierarchy",
            jsonResult: prepareAnimal
        )

        let subtypesMammal = """
        [\(hierarchyItemJSON(name: "Mammal", uri: "file:///tmp/Mammal.ts"))]
        """
        let subtypesDog = """
        [\(hierarchyItemJSON(name: "Dog", uri: "file:///tmp/Dog.ts"))]
        """
        await driver.setReply(method: "typeHierarchy/subtypes", jsonResult: subtypesMammal)
        await driver.setReply(method: "typeHierarchy/subtypes", jsonResult: subtypesDog)
        await driver.setReply(method: "typeHierarchy/subtypes", jsonResult: "[]")

        // Defensive empty reply for the call-hierarchy default path.
        await driver.setReply(method: "callHierarchy/incomingCalls", jsonResult: "[]")

        let args: [String: AnyCodable] = [
            "workspace_root": AnyCodable(workspace.path),
            "language_id": AnyCodable("typescript"),
            "item": seedItem(name: "Animal", uri: "file:///tmp/Animal.ts"),
            "kind": AnyCodable("type_subtypes"),
            "depth": AnyCodable(2),
        ]
        let content = try await bridge.handleToolCall(
            name: "lsp_symbol_walk",
            arguments: args
        )
        XCTAssertEqual(content.type, "text")

        // Result must reach Dog at hop 2.
        XCTAssertTrue(
            content.text.contains("Mammal"),
            "kind='type_subtypes' depth=2 must include hop-1 subtype Mammal; got: \(content.text)"
        )
        XCTAssertTrue(
            content.text.contains("Dog"),
            "kind='type_subtypes' depth=2 must include hop-2 subtype Dog; got: \(content.text)"
        )

        // The bridge must issue prepareTypeHierarchy and walk subtypes
        // recursively.
        let prepareCount = await driver.capturedCount(
            forMethod: "textDocument/prepareTypeHierarchy"
        )
        XCTAssertGreaterThanOrEqual(
            prepareCount, 1,
            "kind='type_subtypes' must issue textDocument/prepareTypeHierarchy; got \(prepareCount) call(s)"
        )

        let subtypesCount = await driver.capturedCount(
            forMethod: "typeHierarchy/subtypes"
        )
        XCTAssertGreaterThanOrEqual(
            subtypesCount, 2,
            "kind='type_subtypes' depth=2 must issue typeHierarchy/subtypes at least twice (for Animal and Mammal); got \(subtypesCount) call(s)"
        )

        // Negative: the supertypes endpoint must not be touched.
        let supertypesCount = await driver.capturedCount(
            forMethod: "typeHierarchy/supertypes"
        )
        XCTAssertEqual(
            supertypesCount, 0,
            "kind='type_subtypes' must NOT issue typeHierarchy/supertypes; got \(supertypesCount) call(s)"
        )
    }

    // MARK: - Bug 4: default kind preserves call_incoming behaviour (regression guard)

    /// No `kind` argument is supplied. The walk MUST keep the historical
    /// behaviour: issue `callHierarchy/incomingCalls`, not any of the new
    /// outgoing / supertype / subtype endpoints. This is a regression
    /// guard for a future implementation that swaps the `direction`
    /// parameter for `kind` — the default value must remain
    /// `call_incoming` so existing callers stay green.
    ///
    /// Expected status today: PASS (current default already walks
    /// incomingCalls).
    func test_symbolWalk_defaultKind_remainsCallIncoming() async throws {
        let (bridge, driver) = await makeBridge()

        let incomingF2 = """
        [
          {"from": \(hierarchyItemJSON(name: "f2", uri: "file:///tmp/f2.ts")),
           "fromRanges":[{"start":{"line":1,"character":0},"end":{"line":1,"character":2}}]}
        ]
        """
        await driver.setReply(method: "callHierarchy/incomingCalls", jsonResult: incomingF2)
        await driver.setReply(method: "callHierarchy/incomingCalls", jsonResult: "[]")

        let args: [String: AnyCodable] = [
            "workspace_root": AnyCodable(workspace.path),
            "language_id": AnyCodable("typescript"),
            "item": seedItem(name: "f1", uri: "file:///tmp/f1.ts"),
            // intentionally NO `kind` arg
            "depth": AnyCodable(1),
        ]
        let content = try await bridge.handleToolCall(
            name: "lsp_symbol_walk",
            arguments: args
        )
        XCTAssertEqual(content.type, "text")

        XCTAssertTrue(
            content.text.contains("f2"),
            "default kind (call_incoming) must surface the hop-1 caller f2; got: \(content.text)"
        )

        let incomingCount = await driver.capturedCount(
            forMethod: "callHierarchy/incomingCalls"
        )
        XCTAssertGreaterThanOrEqual(
            incomingCount, 1,
            "default kind must issue callHierarchy/incomingCalls at least once; got \(incomingCount) call(s)"
        )

        // None of the new endpoints may be touched when `kind` is unset.
        let outgoingCount = await driver.capturedCount(
            forMethod: "callHierarchy/outgoingCalls"
        )
        XCTAssertEqual(
            outgoingCount, 0,
            "default kind must NOT issue callHierarchy/outgoingCalls; got \(outgoingCount) call(s)"
        )

        let prepareTypeCount = await driver.capturedCount(
            forMethod: "textDocument/prepareTypeHierarchy"
        )
        XCTAssertEqual(
            prepareTypeCount, 0,
            "default kind must NOT issue textDocument/prepareTypeHierarchy; got \(prepareTypeCount) call(s)"
        )

        let supertypesCount = await driver.capturedCount(
            forMethod: "typeHierarchy/supertypes"
        )
        XCTAssertEqual(
            supertypesCount, 0,
            "default kind must NOT issue typeHierarchy/supertypes; got \(supertypesCount) call(s)"
        )

        let subtypesCount = await driver.capturedCount(
            forMethod: "typeHierarchy/subtypes"
        )
        XCTAssertEqual(
            subtypesCount, 0,
            "default kind must NOT issue typeHierarchy/subtypes; got \(subtypesCount) call(s)"
        )
    }
}
