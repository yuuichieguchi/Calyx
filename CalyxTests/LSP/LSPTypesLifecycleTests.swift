//
//  LSPTypesLifecycleTests.swift
//  Calyx
//
//  Round-trip Codable tests for the LSP 3.18 lifecycle + capabilities outer
//  shell type batch.
//
//  Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/
//
//  Coverage (this batch — lifecycle + capabilities outer shell only):
//    - TraceValue (enum: "off" | "messages" | "verbose")
//    - WorkspaceFolder
//    - ClientInfo / ServerInfo
//    - InitializeError (a.k.a. InitializeErrorData)
//    - InitializeParams (incl. nullable processId/rootUri/rootPath/workspaceFolders)
//    - InitializeResult
//    - InitializedParams (empty object)
//    - Registration / RegistrationParams
//    - Unregistration / UnregistrationParams (spec keeps the "unregisterations" typo)
//    - SetTraceParams / LogTraceParams
//    - PositionEncodingKind (enum: "utf-8" | "utf-16" | "utf-32")
//    - ClientCapabilities outer shell (sub-capabilities still AnyCodable)
//    - ServerCapabilities outer shell (sub-capabilities still AnyCodable)
//
//  TDD phase: RED. None of these types exist yet. This file is expected to
//  fail to compile until the swift-specialist implements them under
//  `Calyx/Features/LSP/LSPTypes/`.
//

import XCTest
@testable import Calyx

final class LSPTypesLifecycleTests: XCTestCase {

    // MARK: - Helpers

    private let decoder = JSONDecoder()
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    /// Parse a JSON string literal into a Foundation object for semantic comparison.
    private func parse(_ json: String) throws -> Any {
        let data = Data(json.utf8)
        return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    /// Encode an Encodable value to a Foundation object (dict / array / scalar).
    private func toJSONObject<T: Encodable>(_ value: T) throws -> Any {
        let data = try encoder.encode(value)
        return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    /// Assert that decoding `json` into `T` and re-encoding produces semantically
    /// equivalent JSON (NSObject equality on the parsed Foundation graph).
    private func assertRoundtrip<T: Codable>(
        _ type: T.Type,
        json: String,
        file: StaticString = #file,
        line: UInt = #line
    ) throws {
        let data = Data(json.utf8)
        let decoded = try decoder.decode(T.self, from: data)
        let reencoded = try toJSONObject(decoded) as AnyObject
        let original = try parse(json) as AnyObject
        XCTAssertTrue(
            reencoded.isEqual(original),
            "Round-trip mismatch for \(T.self):\n  reencoded=\(reencoded)\n  original=\(original)",
            file: file, line: line
        )
    }

    // ====================================================================
    // MARK: - TraceValue
    // Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#traceValue
    // ====================================================================

    func test_traceValue_off_roundtrip() throws {
        // TraceValue is a string enum: "off" | "messages" | "verbose".
        let json = #""off""#
        let decoded = try decoder.decode(TraceValue.self, from: Data(json.utf8))
        XCTAssertEqual(decoded, TraceValue.off)
        let reencoded = try encoder.encode(decoded)
        XCTAssertEqual(String(data: reencoded, encoding: .utf8), json)
    }

    func test_traceValue_messages_roundtrip() throws {
        let json = #""messages""#
        let decoded = try decoder.decode(TraceValue.self, from: Data(json.utf8))
        XCTAssertEqual(decoded, TraceValue.messages)
        let reencoded = try encoder.encode(decoded)
        XCTAssertEqual(String(data: reencoded, encoding: .utf8), json)
    }

    func test_traceValue_verbose_roundtrip() throws {
        let json = #""verbose""#
        let decoded = try decoder.decode(TraceValue.self, from: Data(json.utf8))
        XCTAssertEqual(decoded, TraceValue.verbose)
        let reencoded = try encoder.encode(decoded)
        XCTAssertEqual(String(data: reencoded, encoding: .utf8), json)
    }

    func test_traceValue_invalidString_decodingFails() throws {
        // Any string outside the closed set must fail to decode.
        let json = #""shout""#
        XCTAssertThrowsError(try decoder.decode(TraceValue.self, from: Data(json.utf8)))
    }

    // ====================================================================
    // MARK: - WorkspaceFolder
    // Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#workspaceFolder
    // ====================================================================

    func test_workspaceFolder_roundtrip() throws {
        // { uri: DocumentUri, name: String }
        let json = #"{"name":"calyx","uri":"file:///Users/example/calyx"}"#
        try assertRoundtrip(WorkspaceFolder.self, json: json)

        // Direct construction sanity check (ensures memberwise initializer exists).
        let wf = WorkspaceFolder(uri: "file:///Users/example/calyx", name: "calyx")
        XCTAssertEqual(wf.uri, "file:///Users/example/calyx")
        XCTAssertEqual(wf.name, "calyx")
    }

    // ====================================================================
    // MARK: - ClientInfo / ServerInfo
    // Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#initialize
    // ====================================================================

    func test_clientInfo_withVersion_roundtrip() throws {
        let json = #"{"name":"Calyx","version":"0.26.1"}"#
        try assertRoundtrip(ClientInfo.self, json: json)
    }

    func test_clientInfo_withoutVersion_roundtrip() throws {
        // version is optional and must be omitted (not encoded as null) when absent.
        let json = #"{"name":"Calyx"}"#
        try assertRoundtrip(ClientInfo.self, json: json)
    }

    func test_serverInfo_withVersion_roundtrip() throws {
        let json = #"{"name":"sourcekit-lsp","version":"6.0"}"#
        try assertRoundtrip(ServerInfo.self, json: json)
    }

    func test_serverInfo_withoutVersion_roundtrip() throws {
        let json = #"{"name":"sourcekit-lsp"}"#
        try assertRoundtrip(ServerInfo.self, json: json)
    }

    // ====================================================================
    // MARK: - InitializeError
    // Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#initializeError
    // ====================================================================

    func test_initializeError_retryTrue_roundtrip() throws {
        // Spec wire shape: { retry: boolean }. Modeled as `InitializeError`
        // (a.k.a. InitializeErrorData) on the Swift side.
        let json = #"{"retry":true}"#
        try assertRoundtrip(InitializeError.self, json: json)
    }

    func test_initializeError_retryFalse_roundtrip() throws {
        let json = #"{"retry":false}"#
        try assertRoundtrip(InitializeError.self, json: json)
    }

    // ====================================================================
    // MARK: - InitializeParams
    // Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#initializeParams
    // ====================================================================

    func test_initializeParams_processIdInt_roundtrip() throws {
        // processId: integer — client PID is sent during normal startup.
        let json = #"""
        {"capabilities":{},"processId":12345}
        """#
        try assertRoundtrip(InitializeParams.self, json: json)
    }

    func test_initializeParams_processIdNull_roundtrip() throws {
        // processId: null — explicit `null` must round-trip (spec marks the
        // field as `integer | null`; null indicates "no parent process").
        let json = #"""
        {"capabilities":{},"processId":null}
        """#
        try assertRoundtrip(InitializeParams.self, json: json)
    }

    func test_initializeParams_rootUriString_roundtrip() throws {
        // rootUri: DocumentUri — deprecated in 3.18 but still accepted.
        let json = #"""
        {"capabilities":{},"processId":1,"rootUri":"file:///workspace"}
        """#
        try assertRoundtrip(InitializeParams.self, json: json)
    }

    func test_initializeParams_rootUriNull_roundtrip() throws {
        // rootUri: null — explicit null must round-trip.
        let json = #"""
        {"capabilities":{},"processId":1,"rootUri":null}
        """#
        try assertRoundtrip(InitializeParams.self, json: json)
    }

    func test_initializeParams_rootUriOmitted_roundtrip() throws {
        // rootUri omitted — encoding must not emit the key.
        let json = #"""
        {"capabilities":{},"processId":1}
        """#
        try assertRoundtrip(InitializeParams.self, json: json)
    }

    func test_initializeParams_rootPathDeprecatedField_decodes() throws {
        // rootPath is deprecated but historically still sent by some clients.
        // Decoding must succeed; re-encoded JSON must preserve the value.
        let json = #"""
        {"capabilities":{},"processId":1,"rootPath":"/legacy/workspace"}
        """#
        try assertRoundtrip(InitializeParams.self, json: json)
    }

    func test_initializeParams_workspaceFoldersArray_roundtrip() throws {
        let json = #"""
        {
          "capabilities":{},
          "processId":1,
          "workspaceFolders":[
            {"name":"a","uri":"file:///a"},
            {"name":"b","uri":"file:///b"}
          ]
        }
        """#
        try assertRoundtrip(InitializeParams.self, json: json)
    }

    func test_initializeParams_workspaceFoldersNull_roundtrip() throws {
        // workspaceFolders: WorkspaceFolder[] | null — null signals "no folders".
        let json = #"""
        {"capabilities":{},"processId":1,"workspaceFolders":null}
        """#
        try assertRoundtrip(InitializeParams.self, json: json)
    }

    func test_initializeParams_workspaceFoldersOmitted_roundtrip() throws {
        // workspaceFolders absent — encoding must not emit the key.
        let json = #"""
        {"capabilities":{},"processId":1}
        """#
        try assertRoundtrip(InitializeParams.self, json: json)
    }

    func test_initializeParams_locale_roundtrip() throws {
        // locale is a BCP 47 tag, surfaced verbatim.
        let json = #"""
        {"capabilities":{},"locale":"en-US","processId":1}
        """#
        try assertRoundtrip(InitializeParams.self, json: json)
    }

    func test_initializeParams_clientInfoAndTrace_roundtrip() throws {
        let json = #"""
        {
          "capabilities":{},
          "clientInfo":{"name":"Calyx","version":"0.26.1"},
          "processId":12345,
          "trace":"verbose"
        }
        """#
        try assertRoundtrip(InitializeParams.self, json: json)
    }

    func test_initializeParams_initializationOptionsArbitrary_roundtrip() throws {
        // initializationOptions: LSPAny — arbitrary JSON value; AnyCodable.
        let json = #"""
        {
          "capabilities":{},
          "initializationOptions":{"buildSystem":"swiftpm","extraArgs":["-warnings-as-errors"]},
          "processId":1
        }
        """#
        try assertRoundtrip(InitializeParams.self, json: json)
    }

    func test_initializeParams_fullPayload_roundtrip() throws {
        // Realistic InitializeParams payload from a Swift host. Exercises
        // every optional field in a single call.
        let json = #"""
        {
          "capabilities":{
            "experimental":{"calyx":{"version":1}},
            "workspace":{"applyEdit":true},
            "textDocument":{"hover":{"contentFormat":["markdown","plaintext"]}}
          },
          "clientInfo":{"name":"Calyx","version":"0.26.1"},
          "initializationOptions":{"key":"value"},
          "locale":"en-US",
          "processId":4242,
          "rootPath":"/workspace",
          "rootUri":"file:///workspace",
          "trace":"messages",
          "workspaceFolders":[{"name":"root","uri":"file:///workspace"}]
        }
        """#
        try assertRoundtrip(InitializeParams.self, json: json)
    }

    // ====================================================================
    // MARK: - InitializeResult
    // Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#initializeResult
    // ====================================================================

    func test_initializeResult_minimal_roundtrip() throws {
        let json = #"{"capabilities":{}}"#
        try assertRoundtrip(InitializeResult.self, json: json)
    }

    func test_initializeResult_withServerInfo_roundtrip() throws {
        let json = #"""
        {
          "capabilities":{"positionEncoding":"utf-16"},
          "serverInfo":{"name":"sourcekit-lsp","version":"6.0"}
        }
        """#
        try assertRoundtrip(InitializeResult.self, json: json)
    }

    // ====================================================================
    // MARK: - InitializedParams
    // Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#initialized
    // ====================================================================

    func test_initializedParams_emptyObject_roundtrip() throws {
        // `initialized` carries an empty object as params.
        let json = "{}"
        try assertRoundtrip(InitializedParams.self, json: json)

        // Direct construction sanity check (parameterless initializer).
        _ = InitializedParams()
    }

    // ====================================================================
    // MARK: - Registration / RegistrationParams
    // Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#registration
    // ====================================================================

    func test_registration_withoutRegisterOptions_roundtrip() throws {
        let json = #"{"id":"reg-1","method":"textDocument/didChange"}"#
        try assertRoundtrip(Registration.self, json: json)
    }

    func test_registration_withRegisterOptions_roundtrip() throws {
        // registerOptions is method-specific arbitrary JSON.
        let json = #"""
        {
          "id":"reg-1",
          "method":"textDocument/didChange",
          "registerOptions":{"documentSelector":[{"language":"swift"}],"syncKind":2}
        }
        """#
        try assertRoundtrip(Registration.self, json: json)
    }

    func test_registrationParams_roundtrip() throws {
        let json = #"""
        {
          "registrations":[
            {"id":"reg-1","method":"textDocument/didChange"},
            {"id":"reg-2","method":"textDocument/willSave","registerOptions":{"documentSelector":[{"language":"swift"}]}}
          ]
        }
        """#
        try assertRoundtrip(RegistrationParams.self, json: json)
    }

    // ====================================================================
    // MARK: - Unregistration / UnregistrationParams
    // Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#unregistration
    // Note: spec uses the typo "unregisterations" (with an extra "er").
    //       We preserve it verbatim on the wire via CodingKeys.
    // ====================================================================

    func test_unregistration_roundtrip() throws {
        let json = #"{"id":"reg-1","method":"textDocument/didChange"}"#
        try assertRoundtrip(Unregistration.self, json: json)
    }

    func test_unregistrationParams_preservesSpecTypo_roundtrip() throws {
        // The wire JSON key is "unregisterations" (per LSP 3.18 spec, kept for
        // historical compatibility). The Swift property name may differ, but
        // the encoded/decoded key MUST be exactly "unregisterations".
        let json = #"""
        {
          "unregisterations":[
            {"id":"reg-1","method":"textDocument/didChange"},
            {"id":"reg-2","method":"textDocument/willSave"}
          ]
        }
        """#
        try assertRoundtrip(UnregistrationParams.self, json: json)

        // Explicit guard: encoded JSON must contain the typo'd key.
        let value = try decoder.decode(UnregistrationParams.self, from: Data(json.utf8))
        let encoded = try encoder.encode(value)
        let encodedString = String(data: encoded, encoding: .utf8) ?? ""
        XCTAssertTrue(
            encodedString.contains("\"unregisterations\""),
            "UnregistrationParams must serialize the spec-typo key 'unregisterations'; got: \(encodedString)"
        )
        XCTAssertFalse(
            encodedString.contains("\"unregistrations\""),
            "UnregistrationParams must NOT correct the typo to 'unregistrations'; got: \(encodedString)"
        )
    }

    // ====================================================================
    // MARK: - SetTraceParams
    // Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#setTrace
    // ====================================================================

    func test_setTraceParams_off_roundtrip() throws {
        let json = #"{"value":"off"}"#
        try assertRoundtrip(SetTraceParams.self, json: json)
    }

    func test_setTraceParams_verbose_roundtrip() throws {
        let json = #"{"value":"verbose"}"#
        try assertRoundtrip(SetTraceParams.self, json: json)
    }

    // ====================================================================
    // MARK: - LogTraceParams
    // Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#logTrace
    // ====================================================================

    func test_logTraceParams_withoutVerbose_roundtrip() throws {
        // verbose is optional; absent when trace level is "messages".
        let json = #"{"message":"compiling module A"}"#
        try assertRoundtrip(LogTraceParams.self, json: json)
    }

    func test_logTraceParams_withVerbose_roundtrip() throws {
        // verbose carries the extra detail when trace level is "verbose".
        let json = #"""
        {"message":"compiling module A","verbose":"dep graph: A -> B -> C"}
        """#
        try assertRoundtrip(LogTraceParams.self, json: json)
    }

    // ====================================================================
    // MARK: - PositionEncodingKind
    // Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#positionEncodingKind
    // ====================================================================

    func test_positionEncodingKind_utf8_roundtrip() throws {
        let json = #""utf-8""#
        let decoded = try decoder.decode(PositionEncodingKind.self, from: Data(json.utf8))
        XCTAssertEqual(decoded, PositionEncodingKind.utf8)
        let reencoded = try encoder.encode(decoded)
        XCTAssertEqual(String(data: reencoded, encoding: .utf8), json)
    }

    func test_positionEncodingKind_utf16_roundtrip() throws {
        // utf-16 is the LSP default and must round-trip.
        let json = #""utf-16""#
        let decoded = try decoder.decode(PositionEncodingKind.self, from: Data(json.utf8))
        XCTAssertEqual(decoded, PositionEncodingKind.utf16)
        let reencoded = try encoder.encode(decoded)
        XCTAssertEqual(String(data: reencoded, encoding: .utf8), json)
    }

    func test_positionEncodingKind_utf32_roundtrip() throws {
        let json = #""utf-32""#
        let decoded = try decoder.decode(PositionEncodingKind.self, from: Data(json.utf8))
        XCTAssertEqual(decoded, PositionEncodingKind.utf32)
        let reencoded = try encoder.encode(decoded)
        XCTAssertEqual(String(data: reencoded, encoding: .utf8), json)
    }

    func test_positionEncodingKind_invalidString_decodingFails() throws {
        // Anything outside { utf-8, utf-16, utf-32 } must fail to decode.
        let json = #""ucs-2""#
        XCTAssertThrowsError(
            try decoder.decode(PositionEncodingKind.self, from: Data(json.utf8))
        )
    }

    // ====================================================================
    // MARK: - ClientCapabilities (outer shell only)
    // Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#clientCapabilities
    //
    // In this batch the sub-capabilities (workspace, textDocument, etc.) are
    // typed as AnyCodable so they round-trip as arbitrary JSON. They will be
    // promoted to typed structs in subsequent batches (B2 / B3).
    // ====================================================================

    func test_clientCapabilities_empty_roundtrip() throws {
        let json = "{}"
        try assertRoundtrip(ClientCapabilities.self, json: json)
    }

    func test_clientCapabilities_workspaceField_roundtrip() throws {
        let json = #"""
        {"workspace":{"applyEdit":true,"workspaceEdit":{"documentChanges":true}}}
        """#
        try assertRoundtrip(ClientCapabilities.self, json: json)
    }

    func test_clientCapabilities_textDocumentField_roundtrip() throws {
        let json = #"""
        {"textDocument":{"hover":{"contentFormat":["markdown","plaintext"]}}}
        """#
        try assertRoundtrip(ClientCapabilities.self, json: json)
    }

    func test_clientCapabilities_notebookDocumentField_roundtrip() throws {
        let json = #"""
        {"notebookDocument":{"synchronization":{"dynamicRegistration":true}}}
        """#
        try assertRoundtrip(ClientCapabilities.self, json: json)
    }

    func test_clientCapabilities_windowField_roundtrip() throws {
        let json = #"""
        {"window":{"showMessage":{"messageActionItem":{"additionalPropertiesSupport":true}},"workDoneProgress":true}}
        """#
        try assertRoundtrip(ClientCapabilities.self, json: json)
    }

    func test_clientCapabilities_generalField_roundtrip() throws {
        let json = #"""
        {"general":{"positionEncodings":["utf-16","utf-8"],"staleRequestSupport":{"cancel":true,"retryOnContentModified":["textDocument/semanticTokens/full"]}}}
        """#
        try assertRoundtrip(ClientCapabilities.self, json: json)
    }

    func test_clientCapabilities_experimentalField_roundtrip() throws {
        let json = #"""
        {"experimental":{"calyx":{"version":1}}}
        """#
        try assertRoundtrip(ClientCapabilities.self, json: json)
    }

    func test_clientCapabilities_allFields_roundtrip() throws {
        // Mixed payload exercising every outer-shell field at once.
        let json = #"""
        {
          "experimental":{"calyx":{"version":1}},
          "general":{"positionEncodings":["utf-16"]},
          "notebookDocument":{"synchronization":{"dynamicRegistration":false}},
          "textDocument":{"hover":{"contentFormat":["markdown"]}},
          "window":{"workDoneProgress":true},
          "workspace":{"applyEdit":true}
        }
        """#
        try assertRoundtrip(ClientCapabilities.self, json: json)
    }

    // ====================================================================
    // MARK: - ServerCapabilities (outer shell only)
    // Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#serverCapabilities
    //
    // positionEncoding is typed (PositionEncodingKind). All provider/capability
    // fields remain AnyCodable in this batch — they often have Bool | Options
    // unions that will be typed individually in B4+.
    // ====================================================================

    func test_serverCapabilities_empty_roundtrip() throws {
        let json = "{}"
        try assertRoundtrip(ServerCapabilities.self, json: json)
    }

    func test_serverCapabilities_positionEncoding_typed_roundtrip() throws {
        // positionEncoding is the one typed field in the outer shell.
        let json = #"{"positionEncoding":"utf-16"}"#
        try assertRoundtrip(ServerCapabilities.self, json: json)
    }

    func test_serverCapabilities_hoverProviderBool_roundtrip() throws {
        // hoverProvider: boolean | HoverOptions — boolean variant.
        let json = #"{"hoverProvider":true}"#
        try assertRoundtrip(ServerCapabilities.self, json: json)
    }

    func test_serverCapabilities_hoverProviderOptions_roundtrip() throws {
        // hoverProvider: boolean | HoverOptions — options variant (object form).
        let json = #"{"hoverProvider":{"workDoneProgress":true}}"#
        try assertRoundtrip(ServerCapabilities.self, json: json)
    }

    func test_serverCapabilities_textDocumentSyncOptions_roundtrip() throws {
        let json = #"""
        {"textDocumentSync":{"change":2,"openClose":true,"save":{"includeText":false}}}
        """#
        try assertRoundtrip(ServerCapabilities.self, json: json)
    }

    func test_serverCapabilities_completionProvider_roundtrip() throws {
        let json = #"""
        {"completionProvider":{"resolveProvider":true,"triggerCharacters":[".","("]}}
        """#
        try assertRoundtrip(ServerCapabilities.self, json: json)
    }

    func test_serverCapabilities_renameProvider_roundtrip() throws {
        let json = #"{"renameProvider":{"prepareProvider":true}}"#
        try assertRoundtrip(ServerCapabilities.self, json: json)
    }

    func test_serverCapabilities_semanticTokensProvider_roundtrip() throws {
        let json = #"""
        {"semanticTokensProvider":{"full":{"delta":true},"legend":{"tokenModifiers":["declaration"],"tokenTypes":["function","variable"]},"range":true}}
        """#
        try assertRoundtrip(ServerCapabilities.self, json: json)
    }

    func test_serverCapabilities_executeCommandProvider_roundtrip() throws {
        let json = #"""
        {"executeCommandProvider":{"commands":["calyx.run","calyx.format"]}}
        """#
        try assertRoundtrip(ServerCapabilities.self, json: json)
    }

    func test_serverCapabilities_workspaceField_roundtrip() throws {
        let json = #"""
        {"workspace":{"fileOperations":{"didCreate":{"filters":[{"pattern":{"glob":"**/*.swift"}}]}},"workspaceFolders":{"changeNotifications":true,"supported":true}}}
        """#
        try assertRoundtrip(ServerCapabilities.self, json: json)
    }

    func test_serverCapabilities_experimentalField_roundtrip() throws {
        let json = #"{"experimental":{"calyx":{"semverGated":true}}}"#
        try assertRoundtrip(ServerCapabilities.self, json: json)
    }

    func test_serverCapabilities_kitchenSink_roundtrip() throws {
        // Exercises a representative subset of every outer-shell provider field
        // at once to guarantee the union of CodingKeys is wired up consistently.
        let json = #"""
        {
          "callHierarchyProvider":true,
          "codeActionProvider":{"codeActionKinds":["quickfix","refactor"]},
          "codeLensProvider":{"resolveProvider":true},
          "colorProvider":true,
          "completionProvider":{"resolveProvider":true,"triggerCharacters":["."]},
          "declarationProvider":true,
          "definitionProvider":true,
          "diagnosticProvider":{"identifier":"calyx","interFileDependencies":true,"workspaceDiagnostics":false},
          "documentFormattingProvider":true,
          "documentHighlightProvider":true,
          "documentLinkProvider":{"resolveProvider":false},
          "documentOnTypeFormattingProvider":{"firstTriggerCharacter":"\n"},
          "documentRangeFormattingProvider":true,
          "documentSymbolProvider":true,
          "executeCommandProvider":{"commands":["calyx.run"]},
          "experimental":{"calyx":{"version":1}},
          "foldingRangeProvider":true,
          "hoverProvider":true,
          "implementationProvider":true,
          "inlayHintProvider":{"resolveProvider":true},
          "inlineValueProvider":true,
          "linkedEditingRangeProvider":true,
          "monikerProvider":true,
          "notebookDocumentSync":{"notebookSelector":[{"notebook":"*.ipynb"}]},
          "positionEncoding":"utf-16",
          "referencesProvider":true,
          "renameProvider":{"prepareProvider":true},
          "selectionRangeProvider":true,
          "semanticTokensProvider":{"full":true,"legend":{"tokenModifiers":[],"tokenTypes":["function"]}},
          "signatureHelpProvider":{"triggerCharacters":["("]},
          "textDocumentSync":{"change":2,"openClose":true},
          "typeDefinitionProvider":true,
          "typeHierarchyProvider":true,
          "workspace":{"workspaceFolders":{"supported":true}},
          "workspaceSymbolProvider":true
        }
        """#
        try assertRoundtrip(ServerCapabilities.self, json: json)
    }
}
