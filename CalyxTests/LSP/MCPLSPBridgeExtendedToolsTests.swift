//
//  MCPLSPBridgeExtendedToolsTests.swift
//  Calyx
//
//  TDD red-phase tests for the 11 additional MCP tools the LSP bridge will
//  ship on top of the 10 core navigation / symbol / completion tools
//  already exercised by `MCPLSPBridgeTests`.
//
//  Tools under test (and how they reach the language server):
//    Typed LSP requests
//      - lsp_signature_help    -> textDocument/signatureHelp
//      - lsp_prepare_rename    -> textDocument/prepareRename
//      - lsp_rename            -> textDocument/rename
//      - lsp_code_action       -> textDocument/codeAction
//      - lsp_diagnostics       -> textDocument/diagnostic (pull mode)
//    AI-only orchestration tools (no LSP request — they introspect /
//    drive Calyx-side state via LSPService and LSPInstaller)
//      - lsp_check_installation
//      - lsp_install
//      - lsp_install_status
//      - lsp_session_status
//      - lsp_session_warmup
//      - lsp_session_shutdown
//
//  TDD phase: RED. The bridge currently advertises 10 tools and only
//  routes those. This file is expected to fail to compile (no
//  `SignatureHelpTool`, etc.) and — once the new tool symbols exist —
//  to fail at runtime because the new `installer:` init parameter and
//  routing branches will not yet be in place.
//
//  Strategy notes:
//    - The fake LSP-server driver, `MockCommandRunner`, etc. are
//      file-private here to avoid colliding with the symbols of the
//      same name already defined in `MCPLSPBridgeTests.swift`. Each
//      test file owns its own driver instance.
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
/// of any caller-held value. Mirrors the helper in `MCPLSPBridgeTests` but
/// is file-private so the two test files don't fight over the symbol.
fileprivate func freshDictExt(fromJSON data: Data) -> sending [String: Any] {
    (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
}

// MARK: - file-private fake LSP server driver

/// Captures every request the bridge sends and emits a configurable
/// response. Lifted near-verbatim from `MCPLSPBridgeTests` and renamed
/// so the two files can compile side-by-side.
fileprivate actor ExtendedToolsServerDriver: LSPSessionFactory {

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
        driver: ExtendedToolsServerDriver
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
                            params: freshDictExt(fromJSON: data)
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

// MARK: - MCPLSPBridgeExtendedToolsTests

@MainActor
final class MCPLSPBridgeExtendedToolsTests: XCTestCase {

    // MARK: - Constants

    private let workspaceA = URL(fileURLWithPath: "/tmp/calyx-mcp-lsp-bridge-ext-A")
    private let workspaceB = URL(fileURLWithPath: "/tmp/calyx-mcp-lsp-bridge-ext-B")
    private let fileA = "file:///tmp/calyx-mcp-lsp-bridge-ext-A/main.ts"
    private let fileB = "file:///tmp/calyx-mcp-lsp-bridge-ext-B/main.ts"

    // MARK: - Lifecycle

    // `InstallTool.handle` now consults `LSPSettings` to decide the
    // installer's `ConfirmationMode`. The product defaults (auto-install on,
    // confirmation prompt on) would route the install through a rejecting
    // prompt handler — there is no UI bridge in this test process — and the
    // install would fail with "user declined: ...". For these unit tests we
    // pin the settings to "auto-install on, no confirmation" so the
    // installer runs straight through and the assertions on `.completed`
    // remain meaningful. `tearDown` restores the documented defaults so we
    // do not leak this state into sibling test classes.
    override func setUp() {
        super.setUp()
        LSPSettings.autoInstallEnabled = true
        LSPSettings.requireInstallConfirmation = false
    }

    override func tearDown() {
        LSPSettings.resetToDefaults()
        super.tearDown()
    }

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

    /// Build an `LSPInstaller` whose runner reports `npm` on PATH but
    /// `typescript-language-server` as MISSING — drives the "install"
    /// path through to a real (mocked) command invocation.
    private func makeMissingInstaller() async -> (LSPInstaller, MockCommandRunner) {
        let runner = MockCommandRunner()
        await runner.setLocateResult("typescript-language-server", url: nil)
        await runner.setLocateResult(
            "npm",
            url: URL(fileURLWithPath: "/usr/local/bin/npm")
        )
        return (LSPInstaller(registry: .builtIn(), runner: runner), runner)
    }

    /// Build the bridge under test + return the LSP-server driver and the
    /// installer mock so individual tests can configure them.
    private func makeBridge(installerOverride: LSPInstaller? = nil) async -> (
        bridge: MCPLSPBridge,
        driver: ExtendedToolsServerDriver,
        installer: LSPInstaller
    ) {
        let installer: LSPInstaller
        if let installerOverride {
            installer = installerOverride
        } else {
            installer = await makeReadyInstaller()
        }
        let driver = ExtendedToolsServerDriver()
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
        return (bridge, driver, installer)
    }

    /// Position-based argument dictionary shared by signature-help / rename
    /// / prepare-rename / etc.
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

    // MARK: - 1. tools catalogue (extended)

    func test_tools_listContainsAllExtendedTools() {
        let names = MCPLSPBridge.tools.map { $0.name }

        // The 10 core tools and the 44 extended tools must be advertised.
        let coreExpected = [
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
        let extendedExpected = [
            "lsp_signature_help",
            "lsp_prepare_rename",
            "lsp_rename",
            "lsp_code_action",
            "lsp_diagnostics",
            "lsp_check_installation",
            "lsp_install",
            "lsp_install_status",
            "lsp_session_status",
            "lsp_session_warmup",
            "lsp_session_shutdown",
            "lsp_call_hierarchy_prepare",
            "lsp_call_hierarchy_incoming",
            "lsp_call_hierarchy_outgoing",
            "lsp_type_hierarchy_prepare",
            "lsp_type_hierarchy_supertypes",
            "lsp_type_hierarchy_subtypes",
            "lsp_moniker",
            "lsp_code_lens",
            "lsp_code_lens_resolve",
            "lsp_inlay_hint",
            "lsp_inlay_hint_resolve",
            "lsp_inline_value",
            "lsp_folding_range",
            "lsp_selection_range",
            "lsp_semantic_tokens_full",
            "lsp_semantic_tokens_range",
            "lsp_semantic_tokens_delta",
            "lsp_linked_editing_range",
            "lsp_document_link",
            "lsp_document_link_resolve",
            "lsp_document_color",
            "lsp_color_presentation",
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
            "lsp_will_create_files",
            "lsp_did_create_files",
            "lsp_will_rename_files",
            "lsp_did_rename_files",
            "lsp_will_delete_files",
            "lsp_did_delete_files",
            "lsp_batch",
            "lsp_hover_bundle",
            "lsp_symbol_walk",
            "lsp_global_workspace_symbol",
            "lsp_cross_workspace_definition",
            "lsp_diagnostics_diff",
            "lsp_capabilities",
            "lsp_notebook_did_open",
            "lsp_notebook_did_change",
            "lsp_notebook_did_close",
        ]

        for name in coreExpected {
            XCTAssertTrue(
                names.contains(name),
                "MCPLSPBridge.tools must keep advertising core tool \(name); got names=\(names)"
            )
        }
        for name in extendedExpected {
            XCTAssertTrue(
                names.contains(name),
                "MCPLSPBridge.tools must advertise extended tool \(name); got names=\(names)"
            )
        }
        XCTAssertEqual(
            names.count,
            coreExpected.count + extendedExpected.count,
            "tools count must be 10 core + 60 extended = 70; got \(names.count) names=\(names)"
        )
    }

    // MARK: - 2. lsp_signature_help dispatch

    func test_lspSignatureHelp_sendsCorrectLSPRequest() async throws {
        let (bridge, driver, _) = await makeBridge()
        let sigJSON = """
        {
          "signatures": [
            {
              "label": "foo(a: Int, b: String)",
              "parameters": [
                {"label": "a: Int"},
                {"label": "b: String"}
              ]
            }
          ],
          "activeSignature": 0,
          "activeParameter": 1
        }
        """
        await driver.setReply(method: "textDocument/signatureHelp", jsonResult: sigJSON)

        let args = positionArguments(
            file: fileA,
            line: 4,
            column: 9,
            workspaceRoot: workspaceA
        )
        let content = try await bridge.handleToolCall(
            name: "lsp_signature_help",
            arguments: args
        )
        XCTAssertEqual(content.type, "text")
        XCTAssertTrue(
            content.text.contains("\"label\":\"foo(a: Int, b: String)\""),
            "signature label must round-trip; got: \(content.text)"
        )

        let captured = await driver.capturedParams(forMethod: "textDocument/signatureHelp")
        XCTAssertEqual(captured.count, 1)
        let td = captured[0]["textDocument"] as? [String: Any]
        let tdUri: String? = td?["uri"] as? String
        XCTAssertEqual(tdUri, fileA)
        let pos = captured[0]["position"] as? [String: Any]
        let line: Int? = pos?["line"] as? Int
        let character: Int? = pos?["character"] as? Int
        XCTAssertEqual(line, 4)
        XCTAssertEqual(character, 9)
    }

    // MARK: - 3. lsp_prepare_rename dispatch

    func test_lspPrepareRename_sendsCorrectLSPRequest() async throws {
        let (bridge, driver, _) = await makeBridge()
        let prepJSON = """
        {"range":{"start":{"line":2,"character":4},"end":{"line":2,"character":7}},
         "placeholder":"foo"}
        """
        await driver.setReply(method: "textDocument/prepareRename", jsonResult: prepJSON)

        let args = positionArguments(
            file: fileA,
            line: 2,
            column: 4,
            workspaceRoot: workspaceA
        )
        let content = try await bridge.handleToolCall(
            name: "lsp_prepare_rename",
            arguments: args
        )
        XCTAssertEqual(content.type, "text")
        XCTAssertTrue(
            content.text.contains("\"placeholder\":\"foo\""),
            "prepareRename placeholder must round-trip; got: \(content.text)"
        )

        let captured = await driver.capturedParams(forMethod: "textDocument/prepareRename")
        XCTAssertEqual(captured.count, 1)
        let td = captured[0]["textDocument"] as? [String: Any]
        XCTAssertEqual(td?["uri"] as? String, fileA)
    }

    // MARK: - 4. lsp_rename dispatch with new_name

    func test_lspRename_sendsCorrectLSPRequest_withNewName() async throws {
        let (bridge, driver, _) = await makeBridge()
        let renameJSON = """
        {"changes":{"\(fileA)":[
          {"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":3}},
           "newText":"bar"}
        ]}}
        """
        await driver.setReply(method: "textDocument/rename", jsonResult: renameJSON)

        var args = positionArguments(
            file: fileA,
            line: 0,
            column: 0,
            workspaceRoot: workspaceA
        )
        args["new_name"] = AnyCodable("bar")
        let content = try await bridge.handleToolCall(
            name: "lsp_rename",
            arguments: args
        )
        XCTAssertEqual(content.type, "text")
        XCTAssertTrue(
            content.text.contains("\"newText\":\"bar\""),
            "rename newText must round-trip; got: \(content.text)"
        )

        let captured = await driver.capturedParams(forMethod: "textDocument/rename")
        XCTAssertEqual(captured.count, 1)
        XCTAssertEqual(captured[0]["newName"] as? String, "bar")
    }

    // MARK: - 5. lsp_code_action dispatch with start/end range

    func test_lspCodeAction_sendsCorrectLSPRequest_withRange() async throws {
        let (bridge, driver, _) = await makeBridge()
        let actionJSON = """
        [
          {"title":"Add import","kind":"quickfix","isPreferred":true}
        ]
        """
        await driver.setReply(method: "textDocument/codeAction", jsonResult: actionJSON)

        let args: [String: AnyCodable] = [
            "workspace_root": AnyCodable(workspaceA.path),
            "language_id": AnyCodable("typescript"),
            "file": AnyCodable(fileA),
            "start_line": AnyCodable(1),
            "start_column": AnyCodable(0),
            "end_line": AnyCodable(1),
            "end_column": AnyCodable(10),
        ]
        let content = try await bridge.handleToolCall(
            name: "lsp_code_action",
            arguments: args
        )
        XCTAssertEqual(content.type, "text")
        XCTAssertTrue(
            content.text.contains("\"title\":\"Add import\""),
            "code action title must round-trip; got: \(content.text)"
        )

        let captured = await driver.capturedParams(forMethod: "textDocument/codeAction")
        XCTAssertEqual(captured.count, 1)
        let range = captured[0]["range"] as? [String: Any]
        let start = range?["start"] as? [String: Any]
        let end = range?["end"] as? [String: Any]
        XCTAssertEqual(start?["line"] as? Int, 1)
        XCTAssertEqual(start?["character"] as? Int, 0)
        XCTAssertEqual(end?["line"] as? Int, 1)
        XCTAssertEqual(end?["character"] as? Int, 10)
    }

    // MARK: - 6. lsp_diagnostics sends textDocument/diagnostic

    func test_lspDiagnostics_sendsTextDocumentDiagnostic() async throws {
        let (bridge, driver, _) = await makeBridge()
        let reportJSON = """
        {"kind":"full","items":[
          {"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":5}},
           "message":"Unused variable",
           "severity":2}
        ]}
        """
        await driver.setReply(method: "textDocument/diagnostic", jsonResult: reportJSON)

        let args: [String: AnyCodable] = [
            "workspace_root": AnyCodable(workspaceA.path),
            "language_id": AnyCodable("typescript"),
            "file": AnyCodable(fileA),
        ]
        let content = try await bridge.handleToolCall(
            name: "lsp_diagnostics",
            arguments: args
        )
        XCTAssertEqual(content.type, "text")
        XCTAssertTrue(
            content.text.contains("\"message\":\"Unused variable\""),
            "diagnostic message must round-trip; got: \(content.text)"
        )

        let captured = await driver.capturedParams(forMethod: "textDocument/diagnostic")
        XCTAssertEqual(captured.count, 1)
        let td = captured[0]["textDocument"] as? [String: Any]
        XCTAssertEqual(td?["uri"] as? String, fileA)
    }

    // MARK: - 7. lsp_check_installation for one language

    func test_lspCheckInstallation_specificLanguage() async throws {
        let (bridge, _, _) = await makeBridge()

        let args: [String: AnyCodable] = [
            "language_id": AnyCodable("typescript"),
        ]
        let content = try await bridge.handleToolCall(
            name: "lsp_check_installation",
            arguments: args
        )
        XCTAssertEqual(content.type, "text")
        XCTAssertTrue(
            content.text.contains("\"languageId\":\"typescript\""),
            "check_installation result must echo the requested languageId; got: \(content.text)"
        )
        XCTAssertTrue(
            content.text.contains("\"isInstalled\":true"),
            "with a ready installer, isInstalled must be true; got: \(content.text)"
        )
    }

    // MARK: - 8. lsp_check_installation for all languages

    func test_lspCheckInstallation_allLanguages() async throws {
        let (bridge, _, _) = await makeBridge()

        // No `language_id` → return a dictionary keyed by languageId
        // covering every registry entry (15 in the built-in table).
        let content = try await bridge.handleToolCall(
            name: "lsp_check_installation",
            arguments: [:]
        )
        XCTAssertEqual(content.type, "text")

        guard let data = content.text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            XCTFail("check_installation (no args) must return a JSON object; got: \(content.text)")
            return
        }
        // All 15 registry languages must appear as keys.
        let expectedLanguages = [
            "typescript", "python", "swift", "rust", "go",
            "ruby", "java", "kotlin", "php", "csharp",
            "lua", "elixir", "haskell", "zig", "ocaml",
        ]
        for lang in expectedLanguages {
            XCTAssertNotNil(
                obj[lang],
                "check_installation (no args) must include \(lang); got keys=\(Array(obj.keys))"
            )
        }
    }

    // MARK: - 9. lsp_install runs the install command

    func test_lspInstall_runsInstallCommand() async throws {
        let (installer, runner) = await makeMissingInstaller()
        // npm install -g typescript-language-server typescript — succeed.
        await runner.enqueueRunResult(
            "npm",
            result: .success(CommandResult(exitCode: 0, stdout: "", stderr: ""))
        )
        let (bridge, _, _) = await makeBridge(installerOverride: installer)

        let args: [String: AnyCodable] = [
            "language_id": AnyCodable("typescript"),
            "approve_prerequisites": AnyCodable(true),
        ]
        let content = try await bridge.handleToolCall(
            name: "lsp_install",
            arguments: args
        )
        XCTAssertEqual(content.type, "text")
        XCTAssertTrue(
            content.text.localizedCaseInsensitiveContains("completed"),
            "install must report .completed on success; got: \(content.text)"
        )

        let history = await runner.history()
        XCTAssertFalse(
            history.isEmpty,
            "install must invoke the runner at least once"
        )
        XCTAssertTrue(
            history.contains(where: { $0.executable == "npm" }),
            "install must shell out to npm for the typescript server; got history=\(history)"
        )
    }

    // MARK: - 10. lsp_install_status returns the current status

    func test_lspInstallStatus_returnsCurrentStatus() async throws {
        let (bridge, _, _) = await makeBridge()

        // Before any install, status is .notStarted.
        let args: [String: AnyCodable] = [
            "language_id": AnyCodable("typescript"),
        ]
        let content = try await bridge.handleToolCall(
            name: "lsp_install_status",
            arguments: args
        )
        XCTAssertEqual(content.type, "text")
        XCTAssertTrue(
            content.text.localizedCaseInsensitiveContains("notstarted")
                || content.text.localizedCaseInsensitiveContains("not_started")
                || content.text.localizedCaseInsensitiveContains("not started"),
            "install_status must report not-started for a fresh installer; got: \(content.text)"
        )
    }

    // MARK: - 11. lsp_session_status returns every cached session

    func test_lspSessionStatus_returnsAllSessions() async throws {
        let (bridge, driver, _) = await makeBridge()
        await driver.setReply(method: "textDocument/hover", jsonResult: "null")

        // Two distinct workspace roots → two distinct sessions.
        let argsA = positionArguments(
            file: fileA,
            line: 0,
            column: 0,
            workspaceRoot: workspaceA
        )
        _ = try await bridge.handleToolCall(name: "lsp_hover", arguments: argsA)

        await driver.setReply(method: "textDocument/hover", jsonResult: "null")
        let argsB = positionArguments(
            file: fileB,
            line: 0,
            column: 0,
            workspaceRoot: workspaceB
        )
        _ = try await bridge.handleToolCall(name: "lsp_hover", arguments: argsB)

        let content = try await bridge.handleToolCall(
            name: "lsp_session_status",
            arguments: [:]
        )
        XCTAssertEqual(content.type, "text")

        guard let data = content.text.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else {
            XCTFail("session_status must return a JSON array; got: \(content.text)")
            return
        }
        XCTAssertEqual(
            arr.count,
            2,
            "session_status must surface both cached sessions; got: \(arr)"
        )
    }

    // MARK: - 12. lsp_session_warmup initializes a session

    func test_lspSessionWarmup_initializesSession() async throws {
        let (bridge, driver, _) = await makeBridge()

        let args: [String: AnyCodable] = [
            "workspace_root": AnyCodable(workspaceA.path),
            "language_id": AnyCodable("typescript"),
        ]
        let content = try await bridge.handleToolCall(
            name: "lsp_session_warmup",
            arguments: args
        )
        XCTAssertEqual(content.type, "text")

        let madeBefore = await driver.clientsMadeCount()
        XCTAssertEqual(
            madeBefore,
            1,
            "warmup must build exactly one LSP client; got \(madeBefore)"
        )

        // Warmup is idempotent: a second call for the same key reuses the
        // cached session and does NOT build a second client.
        _ = try await bridge.handleToolCall(
            name: "lsp_session_warmup",
            arguments: args
        )
        let madeAfter = await driver.clientsMadeCount()
        XCTAssertEqual(
            madeAfter,
            1,
            "warmup must be idempotent — same (workspace, language) must reuse the session; got \(madeAfter)"
        )
    }

    // MARK: - 13. lsp_session_shutdown removes the cached session

    func test_lspSessionShutdown_removesSession() async throws {
        let (bridge, driver, _) = await makeBridge()
        await driver.setReply(method: "textDocument/hover", jsonResult: "null")

        let warmArgs: [String: AnyCodable] = [
            "workspace_root": AnyCodable(workspaceA.path),
            "language_id": AnyCodable("typescript"),
        ]
        _ = try await bridge.handleToolCall(
            name: "lsp_session_warmup",
            arguments: warmArgs
        )

        let shutdownContent = try await bridge.handleToolCall(
            name: "lsp_session_shutdown",
            arguments: warmArgs
        )
        XCTAssertEqual(shutdownContent.type, "text")
        XCTAssertTrue(
            shutdownContent.text.localizedCaseInsensitiveContains("shutdown")
                || shutdownContent.text.contains("\"shutdown\":true"),
            "session_shutdown must report success; got: \(shutdownContent.text)"
        )

        // After shutdown, session_status must show zero sessions.
        let statusContent = try await bridge.handleToolCall(
            name: "lsp_session_status",
            arguments: [:]
        )
        guard let data = statusContent.text.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else {
            XCTFail("session_status must return a JSON array; got: \(statusContent.text)")
            return
        }
        XCTAssertEqual(
            arr.count,
            0,
            "after shutdown, session_status must be empty; got: \(arr)"
        )
    }

    // MARK: - 14. lsp_install with missing language_id throws

    func test_lspInstall_missingLanguageId_throws() async {
        let (bridge, _, _) = await makeBridge()
        do {
            _ = try await bridge.handleToolCall(
                name: "lsp_install",
                arguments: [:]
            )
            XCTFail("expected throw for missing 'language_id' argument")
        } catch {
            // OK — any error type is acceptable; the bridge just has to refuse.
        }
    }

    // MARK: - 15. lsp_session_warmup with missing workspace_root throws

    func test_lspSessionWarmup_missingWorkspaceRoot_throws() async {
        let (bridge, _, _) = await makeBridge()
        let args: [String: AnyCodable] = [
            "language_id": AnyCodable("typescript"),
        ]
        do {
            _ = try await bridge.handleToolCall(
                name: "lsp_session_warmup",
                arguments: args
            )
            XCTFail("expected throw for missing 'workspace_root' argument")
        } catch {
            // OK
        }
    }
}
