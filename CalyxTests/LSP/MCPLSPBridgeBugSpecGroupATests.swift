//
//  MCPLSPBridgeBugSpecGroupATests.swift
//  Calyx
//
//  RED-phase TDD spec for MCPLSPBridge "Group A" defects:
//    URI normalization, argument validation, encoding handling.
//
//  This file is intentionally hostile to current behaviour: every test
//  asserts the BUG-FREE contract, not what the bridge does today. Run as
//  RED before any fix lands. The matching GREEN pass belongs to the
//  Swift specialist.
//
//  Bugs covered (see PR description for citations):
//    1. documentUri(fromPathOrUri:) does not percent-encode file:// URIs
//       containing spaces; absolute-path and file:// inputs for the same
//       logical file diverge.
//    2. fileURL(fromPathOrUri:) on a file:// URI containing a space falls
//       through to URL(fileURLWithPath:), producing a .path beginning
//       with "/file:".
//    3. ensureFileOpen is a silent no-op on unparseable URIs, so the
//       tool returns "no language service" instead of a URI error.
//    4. ensureFileOpen silently skips non-UTF-8 files; downstream errors
//       look like "no language service" instead of an encoding error.
//    5. InstallationCheckDTO.prerequisiteStatuses uses [String: String?];
//       JSON encoding drops the nil entries, hiding missing prereqs.
//    6. requireInt truncates 3.9 to 3; optionalBool accepts arbitrary
//       NSNumbers via NSNumber.boolValue.
//    7. CompletionTool accepts trigger_kind=2 (TriggerCharacter) without
//       trigger_character.
//    8. CodeActionTool always sends diagnostics: []; the schema does not
//       accept a diagnostics argument so quickfix flows never round-trip.
//    9. WorkspaceApplyEditTool declares commit as required in the schema
//       but reads it via optionalBool, silently defaulting to false.
//

import XCTest
@testable import Calyx

// MARK: - file-private region-detaching helper

fileprivate func freshDictGroupA(fromJSON data: Data) -> sending [String: Any] {
    (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
}

// MARK: - Driver: requests + notifications

/// Trimmed-down clone of `MCPLSPBridgeServerDriver` that ALSO captures
/// JSON-RPC notifications (no `id`), required to assert whether the
/// bridge sent a `textDocument/didOpen` for the URI under test.
fileprivate actor BugSpecGroupADriver: LSPSessionFactory {

    // Per-method auto-replies for requests.
    private var methodReplies: [String: String] = [:]
    private var methodErrors: [String: (code: Int, message: String)] = [:]

    // Captured params, keyed by method, in arrival order.
    private var requestParams: [String: [[String: Any]]] = [:]
    private var notificationParams: [String: [[String: Any]]] = [:]

    private(set) var clientsMade: Int = 0

    private var transports: [InMemoryLSPTransport] = []
    private var sidecars: [Task<Void, Never>] = []

    init() {}

    // MARK: Test configuration

    func setReply(method: String, jsonResult: String) {
        methodReplies[method] = jsonResult
    }

    func setError(method: String, code: Int, message: String) {
        methodErrors[method] = (code, message)
    }

    func capturedRequestParams(forMethod method: String) -> sending [[String: Any]] {
        roundtrip(requestParams[method] ?? [])
    }

    func capturedNotificationParams(forMethod method: String) -> sending [[String: Any]] {
        roundtrip(notificationParams[method] ?? [])
    }

    private func roundtrip(_ arr: [[String: Any]]) -> sending [[String: Any]] {
        guard let data = try? JSONSerialization.data(withJSONObject: arr) else { return [] }
        let bytes: [UInt8] = Array(data)
        let fresh = Data(bytes)
        return (try? JSONSerialization.jsonObject(with: fresh) as? [[String: Any]]) ?? []
    }

    // MARK: LSPSessionFactory

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
            await Self.drive(on: transport, driver: self)
        }
        sidecars.append(sidecar)
        return client
    }

    // MARK: Mutators (isolated)

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

    fileprivate func recordRequest(method: String, params: sending [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: params),
              let copy = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        requestParams[method, default: []].append(copy)
    }

    fileprivate func recordNotification(method: String, params: sending [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: params),
              let copy = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        notificationParams[method, default: []].append(copy)
    }

    // MARK: Server simulator

    private static func drive(
        on transport: InMemoryLSPTransport,
        driver: BugSpecGroupADriver
    ) async {
        var answeredIds: Set<Int> = []

        for _ in 0..<4000 {
            let sent = await transport.sentMessages()
            for data in sent {
                guard let dict = parseFramedJSON(data) else { continue }
                guard let method = dict["method"] as? String else { continue }

                // Notifications: no "id" field. Capture and move on.
                if extractId(dict["id"]) == nil {
                    if let p = dict["params"] as? [String: Any],
                       let payload = try? JSONSerialization.data(withJSONObject: p) {
                        await driver.recordNotification(
                            method: method,
                            params: freshDictGroupA(fromJSON: payload)
                        )
                    } else {
                        await driver.recordNotification(method: method, params: [:])
                    }
                    continue
                }

                guard let id = extractId(dict["id"]) else { continue }
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

                if let p = dict["params"] as? [String: Any],
                   let payload = try? JSONSerialization.data(withJSONObject: p) {
                    await driver.recordRequest(
                        method: method,
                        params: freshDictGroupA(fromJSON: payload)
                    )
                } else {
                    await driver.recordRequest(method: method, params: [:])
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
            try? await Task.sleep(nanoseconds: 5_000_000)
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

// MARK: - Tests

@MainActor
final class MCPLSPBridgeBugSpecGroupATests: XCTestCase {

    private let workspaceA = URL(fileURLWithPath: "/tmp/calyx-mcp-lsp-bridge-bugA")
    private let fileA = "file:///tmp/calyx-mcp-lsp-bridge-bugA/main.ts"

    // MARK: Helpers

    /// Build an installer where `typescript-language-server` is found and
    /// `npm` is REPORTED MISSING. The missing-prereq case is what bug 5
    /// needs to expose.
    private func makeInstallerWithMissingNpm() async -> LSPInstaller {
        let runner = MockCommandRunner()
        await runner.setLocateResult(
            "typescript-language-server",
            url: URL(fileURLWithPath: "/usr/local/bin/typescript-language-server")
        )
        await runner.setLocateResult("npm", url: nil)
        return LSPInstaller(registry: .builtIn(), runner: runner)
    }

    /// Build an installer with all binaries present — used by tool calls
    /// that need the session to spin up without an install-side branch.
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

    private func makeBridge(
        installer providedInstaller: LSPInstaller? = nil
    ) async -> (bridge: MCPLSPBridge, driver: BugSpecGroupADriver) {
        let installer: LSPInstaller
        if let providedInstaller {
            installer = providedInstaller
        } else {
            installer = await makeReadyInstaller()
        }
        let driver = BugSpecGroupADriver()
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

    private func positionArguments(
        file: String,
        line: Int,
        column: Int,
        workspaceRoot: URL,
        languageId: String = "typescript"
    ) -> [String: AnyCodable] {
        [
            "file": AnyCodable(file),
            "line": AnyCodable(line),
            "column": AnyCodable(column),
            "language_id": AnyCodable(languageId),
            "workspace_root": AnyCodable(workspaceRoot.path),
        ]
    }

    private func rangeArguments(
        file: String,
        startLine: Int,
        startColumn: Int,
        endLine: Int,
        endColumn: Int,
        workspaceRoot: URL,
        languageId: String = "typescript"
    ) -> [String: AnyCodable] {
        [
            "file": AnyCodable(file),
            "language_id": AnyCodable(languageId),
            "workspace_root": AnyCodable(workspaceRoot.path),
            "start_line": AnyCodable(startLine),
            "start_column": AnyCodable(startColumn),
            "end_line": AnyCodable(endLine),
            "end_column": AnyCodable(endColumn),
        ]
    }

    private func sampleWorkspaceEdit(uri: String, newText: String) -> AnyCodable {
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

    // MARK: - Bug 1: documentUri must percent-encode file:// URIs containing spaces

    /// Two inputs for the SAME logical file must converge on a single LSP
    /// `DocumentUri`. The absolute-path form goes through
    /// `URL(fileURLWithPath:)` which percent-encodes the space; the
    /// `file://` form is returned verbatim today, so they diverge.
    /// Contract: both forms must produce `file:///tmp/my%20project/main.ts`.
    func test_bug1_documentUri_spaceInPath_pathAndFileURIConverge() {
        let asPath = MCPLSPBridge.documentUri(fromPathOrUri: "/tmp/my project/main.ts")
        let asFileURI = MCPLSPBridge.documentUri(fromPathOrUri: "file:///tmp/my project/main.ts")

        XCTAssertEqual(
            asPath,
            "file:///tmp/my%20project/main.ts",
            "documentUri must percent-encode spaces when starting from a raw path"
        )
        XCTAssertEqual(
            asFileURI,
            "file:///tmp/my%20project/main.ts",
            "documentUri must percent-encode spaces in already-file:// URIs"
        )
        XCTAssertEqual(
            asPath,
            asFileURI,
            "documentUri(path) and documentUri(file://path) for the SAME logical file must converge"
        )
    }

    // MARK: - Bug 2: fileURL must produce a single normalized URL for one logical file

    /// Two `fileURL(_:)` inputs that name the SAME logical file (raw
    /// absolute path vs `file://` URI) must produce identical URLs so the
    /// session-cache key in `LSPService.session(for:)` does not split.
    ///
    /// We exercise this with a `?` in the filename — a perfectly legal
    /// POSIX path character, but one that the `URL(string:)` branch in
    /// `fileURL` treats as a query delimiter:
    ///
    ///   fileURL("/tmp/my?file.ts")
    ///     → URL(fileURLWithPath:) → .path="/tmp/my?file.ts"
    ///                                .absoluteString="file:///tmp/my%3Ffile.ts"
    ///
    ///   fileURL("file:///tmp/my?file.ts")
    ///     → URL(string:) → .path="/tmp/my" (!), .query="file.ts" (!),
    ///                       .absoluteString="file:///tmp/my?file.ts"
    ///
    /// The session key derived from these two URLs diverges, so a caller
    /// that hands `workspace_root` as a raw path and a later caller that
    /// hands the equivalent `file://` URI mint two separate LSP sessions
    /// for one workspace.
    ///
    /// A space-only regression guard is also kept here so any future
    /// Foundation regression that resurrects the `.path` starting-with-
    /// `/file:` shape is caught.
    func test_bug2_fileURL_pathAndFileURI_normalizeToSameURL() {
        // Part 1: regression guard against the `/file:`-prefixed-.path
        // shape called out in the bug report. Currently a no-op on
        // Foundation Darwin 25.x but kept as a guard.
        let spaceFromFileURI = MCPLSPBridge.fileURL(fromPathOrUri: "file:///tmp/my project/main.ts")
        XCTAssertFalse(
            spaceFromFileURI.path.hasPrefix("/file:"),
            "fileURL must NOT yield a .path beginning with '/file:' (regression guard for older Foundation)"
        )

        // Part 2: the real divergence. A filename with `?` exposes the
        // mismatch between the two parser branches in `fileURL`.
        let urlFromPath = MCPLSPBridge.fileURL(fromPathOrUri: "/tmp/my?file.ts")
        let urlFromFileURI = MCPLSPBridge.fileURL(fromPathOrUri: "file:///tmp/my?file.ts")

        XCTAssertEqual(
            urlFromPath.path,
            "/tmp/my?file.ts",
            "fileURL(path).path must preserve '?' as a filename character (URL(fileURLWithPath:) does this)"
        )
        XCTAssertEqual(
            urlFromFileURI.path,
            "/tmp/my?file.ts",
            "fileURL(file:// + '?').path must preserve the '?'; URL(string:) currently truncates to '/tmp/my' and drops 'file.ts' into the query"
        )
        XCTAssertEqual(
            urlFromPath.absoluteString,
            urlFromFileURI.absoluteString,
            "fileURL(path) and fileURL(file://path) for the same logical file MUST converge on a single absoluteString — divergent .absoluteString splits the session-cache key in LSPService.session(for:). got path=\(urlFromPath.absoluteString) file=\(urlFromFileURI.absoluteString)"
        )
    }

    // MARK: - Bug 3: ensureFileOpen must surface unparseable URIs as a structured error

    /// A deliberately-malformed URI (e.g. `file://[bad]/foo bar`) currently
    /// short-circuits `ensureFileOpen` silently; the bridge then forwards
    /// the broken URI to the server, which answers "no language service".
    /// Contract: the tool must surface a structured error whose text
    /// mentions "uri" (case-insensitive) instead of swallowing the failure.
    func test_bug3_unparseableUri_isStructuredError_notSilent() async throws {
        let (bridge, driver) = await makeBridge()
        await driver.setReply(method: "textDocument/hover", jsonResult: "null")

        let badUri = "file://[bad]/foo bar baz"
        let args = positionArguments(
            file: badUri,
            line: 0,
            column: 0,
            workspaceRoot: workspaceA
        )

        let content: MCPContent
        do {
            content = try await bridge.handleToolCall(name: "lsp_hover", arguments: args)
        } catch {
            // Throwing is an acceptable "structured error" surface; either
            // path satisfies the contract. Fall through with a sentinel.
            content = MCPContent(type: "text", text: "thrown: \(error)")
            let lowered = content.text.lowercased()
            XCTAssertTrue(
                lowered.contains("uri") || lowered.contains("invalid") || lowered.contains("malformed"),
                "thrown error must mention 'uri' or 'invalid'/'malformed'; got: \(content.text)"
            )
            return
        }

        let text = content.text.lowercased()
        XCTAssertTrue(
            text.contains("uri") && (text.contains("error") || text.contains("invalid") || text.contains("malformed")),
            "unparseable URI must surface a structured error mentioning 'uri'; got: \(content.text)"
        )
    }

    // MARK: - Bug 4: ensureFileOpen must not silently skip non-UTF-8 files

    /// Write a Latin-1 file with bytes that are invalid UTF-8, then call
    /// `lsp_hover` for it. The bridge currently fails `String(contentsOf:
    /// encoding: .utf8)`, returns early, and never sends `didOpen` — the
    /// downstream `hover` then reaches a server that has never seen the
    /// file. Contract: either a `didOpen` is dispatched (the bridge falls
    /// back to a tolerant decoder) or the tool returns an error that
    /// mentions encoding / UTF-8.
    func test_bug4_nonUTF8File_didOpenDispatchedOrEncodingError() async throws {
        let (bridge, driver) = await makeBridge()
        await driver.setReply(method: "textDocument/hover", jsonResult: "null")

        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("calyx-bugA-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let filePath = tmpDir.appendingPathComponent("main.ts")
        // Latin-1 'é', 'à', 'ñ' — invalid as standalone UTF-8 bytes.
        let bytes: [UInt8] = [0xE9, 0xE0, 0xF1]
        try Data(bytes).write(to: filePath)

        let fileUri = filePath.absoluteString
        let args = positionArguments(
            file: fileUri,
            line: 0,
            column: 0,
            workspaceRoot: tmpDir
        )

        let content = try await bridge.handleToolCall(name: "lsp_hover", arguments: args)

        let didOpenSeen = await driver
            .capturedNotificationParams(forMethod: "textDocument/didOpen").count > 0
        let lowered = content.text.lowercased()
        let encodingMentioned = lowered.contains("encoding")
            || lowered.contains("utf-8")
            || lowered.contains("utf8")
            || lowered.contains("decode")

        XCTAssertTrue(
            didOpenSeen || encodingMentioned,
            "non-UTF-8 file: the bridge must either dispatch textDocument/didOpen (via a tolerant decoder fallback) OR surface an encoding-related error. Got didOpenSeen=\(didOpenSeen), text=\(content.text)"
        )
    }

    // MARK: - Bug 5: InstallationCheckDTO.prerequisiteStatuses must encode missing prereqs

    /// With `npm` missing on PATH, `lsp_check_installation` for typescript
    /// today returns a JSON object whose `prerequisiteStatuses` map has
    /// dropped the `"npm"` key entirely (Swift's default `[String: String?]`
    /// encoding skips nil values). Contract: the missing prereq must be
    /// represented — either as JSON null or as a sentinel string — so
    /// MCP callers can render "missing".
    func test_bug5_checkInstallation_missingPrereq_keptInJSON() async throws {
        let installer = await makeInstallerWithMissingNpm()
        let (bridge, _) = await makeBridge(installer: installer)

        let args: [String: AnyCodable] = [
            "language_id": AnyCodable("typescript"),
        ]
        let content = try await bridge.handleToolCall(
            name: "lsp_check_installation",
            arguments: args
        )
        XCTAssertEqual(content.type, "text")

        let data = Data(content.text.utf8)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNotNil(obj, "response must be valid JSON; got: \(content.text)")

        let prereqs = obj?["prerequisiteStatuses"] as? [String: Any]
        XCTAssertNotNil(
            prereqs,
            "response must carry a 'prerequisiteStatuses' object; got: \(content.text)"
        )

        // The crux: with npm missing, the dict must STILL contain the
        // "npm" key. Today JSONEncoder drops it.
        let allKeys = Set(prereqs?.keys ?? Dictionary<String, Any>().keys)
        XCTAssertTrue(
            allKeys.contains("npm"),
            "prerequisiteStatuses must retain the 'npm' key even when the prereq is missing; got keys=\(allKeys) payload=\(content.text)"
        )
    }

    // MARK: - Bug 6a: requireInt must reject fractional doubles

    /// `line: 3.9` is not an integer. Today `requireInt` round-trips through
    /// `JSONEncoder` → `JSONSerialization` (which produces an `NSNumber`),
    /// then `Int(truncating:)` returns `3` and the tool silently accepts.
    /// Contract: a fractional double must throw `invalidArgument`.
    func test_bug6a_requireInt_rejectsFractionalDouble() async throws {
        let (bridge, driver) = await makeBridge()
        await driver.setReply(method: "textDocument/hover", jsonResult: "null")

        var args = positionArguments(
            file: fileA,
            line: 0,
            column: 0,
            workspaceRoot: workspaceA
        )
        args["line"] = AnyCodable(3.9)

        do {
            _ = try await bridge.handleToolCall(name: "lsp_hover", arguments: args)
            XCTFail("line=3.9 must throw 'expected integer'; truncating to 3 silently is the bug")
        } catch let MCPLSPBridgeError.invalidArgument(name, reason) {
            XCTAssertEqual(name, "line")
            XCTAssertTrue(
                reason.lowercased().contains("integer"),
                "reason must mention 'integer'; got: \(reason)"
            )
        } catch {
            // Any error is acceptable so long as the bridge refuses.
        }
    }

    // MARK: - Bug 6b: optionalBool must reject non-bool NSNumbers

    /// `include_declaration: 42` is not a boolean. Today `optionalBool`
    /// happily coerces via `NSNumber.boolValue`, treating any non-zero
    /// number as `true`. Contract: a non-bool numeric value must throw
    /// `invalidArgument`.
    func test_bug6b_optionalBool_rejectsArbitraryNumber() async throws {
        let (bridge, driver) = await makeBridge()
        await driver.setReply(method: "textDocument/references", jsonResult: "[]")

        var args = positionArguments(
            file: fileA,
            line: 0,
            column: 0,
            workspaceRoot: workspaceA
        )
        args["include_declaration"] = AnyCodable(42)

        do {
            _ = try await bridge.handleToolCall(name: "lsp_references", arguments: args)
            XCTFail("include_declaration=42 must throw 'expected boolean'; coercing via boolValue is the bug")
        } catch let MCPLSPBridgeError.invalidArgument(name, reason) {
            XCTAssertEqual(name, "include_declaration")
            XCTAssertTrue(
                reason.lowercased().contains("bool"),
                "reason must mention 'bool'; got: \(reason)"
            )
        } catch {
            // Any error is acceptable so long as the bridge refuses.
        }
    }

    // MARK: - Bug 7: CompletionTool must require trigger_character when trigger_kind == 2

    /// `trigger_kind: 2` is `TriggerCharacter`. With no `trigger_character`,
    /// the request makes no semantic sense — yet the bridge accepts it
    /// today and dispatches a request with `triggerCharacter: nil`.
    /// Contract: trigger_kind=2 without trigger_character must error.
    func test_bug7_completion_triggerKind2_withoutTriggerCharacter_errors() async throws {
        let (bridge, driver) = await makeBridge()
        await driver.setReply(method: "textDocument/completion", jsonResult: "[]")

        var args = positionArguments(
            file: fileA,
            line: 0,
            column: 0,
            workspaceRoot: workspaceA
        )
        args["trigger_kind"] = AnyCodable(2)
        // intentionally NOT setting trigger_character

        do {
            _ = try await bridge.handleToolCall(name: "lsp_completion", arguments: args)
            XCTFail("trigger_kind=2 with no trigger_character must error; silent dispatch is the bug")
        } catch let MCPLSPBridgeError.missingArgument(name) {
            XCTAssertEqual(name, "trigger_character")
        } catch let MCPLSPBridgeError.invalidArgument(name, _) {
            XCTAssertTrue(
                name == "trigger_character" || name == "trigger_kind",
                "structured error must target trigger_character / trigger_kind; got: \(name)"
            )
        } catch {
            // Any error type is acceptable so long as the bridge refuses.
        }
    }

    // MARK: - Bug 8: CodeActionTool must forward the supplied diagnostics

    /// Quickfix-style consumers filter on `context.diagnostics`. Today
    /// `CodeActionTool` hardcodes `CodeActionContext(diagnostics: [])`
    /// AND the schema does not accept a `diagnostics` argument, so the
    /// payload either drops on the floor (no schema slot) or is silently
    /// ignored. Contract: a supplied `diagnostics` array must arrive in
    /// the LSP request body.
    func test_bug8_codeAction_forwardsDiagnostics() async throws {
        let (bridge, driver) = await makeBridge()
        await driver.setReply(method: "textDocument/codeAction", jsonResult: "[]")

        let diagnostic: [String: AnyCodable] = [
            "range": AnyCodable([
                "start": AnyCodable([
                    "line": AnyCodable(0),
                    "character": AnyCodable(0),
                ] as [String: AnyCodable]),
                "end": AnyCodable([
                    "line": AnyCodable(0),
                    "character": AnyCodable(5),
                ] as [String: AnyCodable]),
            ] as [String: AnyCodable]),
            "message": AnyCodable("foo is undefined"),
            "severity": AnyCodable(1),
            "source": AnyCodable("typescript"),
            "code": AnyCodable("TS2304"),
        ]
        var args = rangeArguments(
            file: fileA,
            startLine: 0,
            startColumn: 0,
            endLine: 0,
            endColumn: 5,
            workspaceRoot: workspaceA
        )
        args["diagnostics"] = AnyCodable([AnyCodable(diagnostic)])

        _ = try await bridge.handleToolCall(name: "lsp_code_action", arguments: args)

        let captured = await driver.capturedRequestParams(forMethod: "textDocument/codeAction")
        XCTAssertEqual(captured.count, 1, "code_action must dispatch exactly one request")
        let context = captured.first?["context"] as? [String: Any]
        XCTAssertNotNil(context, "code_action params must carry a context object; got: \(captured)")
        let diagnostics = context?["diagnostics"] as? [[String: Any]]
        XCTAssertEqual(
            diagnostics?.count,
            1,
            "context.diagnostics must contain the supplied diagnostic — hardcoded [] is the bug; got: \(String(describing: context))"
        )
        let firstMessage = diagnostics?.first?["message"] as? String
        XCTAssertEqual(
            firstMessage,
            "foo is undefined",
            "the diagnostic must round-trip verbatim into the LSP request; got: \(String(describing: diagnostics))"
        )
    }

    // MARK: - Bug 9: WorkspaceApplyEditTool must enforce `commit` as required

    /// The tool's input schema declares `commit` as required. The handler
    /// reads it via `optionalBool` and silently defaults to `false`, so a
    /// strict MCP caller (running the call without supplying `commit`)
    /// gets a "successful dry-run" instead of the validation error the
    /// schema implies. Contract: omitting `commit` must throw
    /// `missingArgument("commit")`.
    func test_bug9_workspaceApplyEdit_missingCommit_throws() async throws {
        let (bridge, _) = await makeBridge()

        let edit = sampleWorkspaceEdit(uri: fileA, newText: "bar")
        let args: [String: AnyCodable] = [
            "workspace_root": AnyCodable(workspaceA.path),
            "language_id": AnyCodable("typescript"),
            "edit": edit,
            // intentionally NOT setting commit
        ]

        do {
            _ = try await bridge.handleToolCall(
                name: "lsp_workspace_apply_edit",
                arguments: args
            )
            XCTFail("apply_edit without 'commit' must throw missingArgument — silently treating absent as false is the schema/runtime mismatch")
        } catch let MCPLSPBridgeError.missingArgument(name) {
            XCTAssertEqual(name, "commit")
        } catch {
            // Any error type is acceptable so long as the bridge refuses.
        }
    }
}
