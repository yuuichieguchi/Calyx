//
//  LSPTypesEditClusterTests.swift
//  Calyx
//
//  Round-trip Codable tests for the LSP 3.18 code-change feature parameter
//  and response types (the "edit cluster"):
//
//    - textDocument/codeAction       (CodeAction*, CodeActionItem)
//    - textDocument/codeLens         (CodeLens*)
//    - textDocument/rename           (Rename*, PrepareRename*)
//    - textDocument/formatting       (DocumentFormattingParams, FormattingOptions)
//    - textDocument/rangeFormatting  (DocumentRangeFormattingParams)
//    - textDocument/onTypeFormatting (DocumentOnTypeFormattingParams)
//    - textDocument/documentLink     (DocumentLink*)
//    - textDocument/foldingRange     (FoldingRange*, FoldingRangeKind)
//    - textDocument/selectionRange   (SelectionRange*)
//
//  Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/
//
//  TDD phase: RED. None of these types exist yet. This file is expected to
//  fail to compile until the swift-specialist implements them under
//  `Calyx/Features/LSP/LSPTypes/`.
//

import XCTest
@testable import Calyx

@MainActor
final class LSPTypesEditClusterTests: XCTestCase {

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
    // MARK: - CodeActionTriggerKind
    // Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#codeActionTriggerKind
    // ====================================================================

    func test_codeActionTriggerKind_allValues_roundtrip() throws {
        for (raw, expected) in [
            (1, CodeActionTriggerKind.invoked),
            (2, CodeActionTriggerKind.automatic)
        ] {
            let decoded = try decoder.decode(CodeActionTriggerKind.self, from: Data("\(raw)".utf8))
            XCTAssertEqual(decoded, expected, "raw=\(raw)")
            let reencoded = try encoder.encode(decoded)
            XCTAssertEqual(String(data: reencoded, encoding: .utf8), "\(raw)")
        }
    }

    // ====================================================================
    // MARK: - CodeActionKind (open string enum)
    // Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#codeActionKind
    // ====================================================================

    func test_codeActionKind_knownConstants_haveCorrectRawValues() {
        XCTAssertEqual(CodeActionKind.empty.rawValue, "")
        XCTAssertEqual(CodeActionKind.quickFix.rawValue, "quickfix")
        XCTAssertEqual(CodeActionKind.refactor.rawValue, "refactor")
        XCTAssertEqual(CodeActionKind.refactorExtract.rawValue, "refactor.extract")
        XCTAssertEqual(CodeActionKind.refactorInline.rawValue, "refactor.inline")
        XCTAssertEqual(CodeActionKind.refactorRewrite.rawValue, "refactor.rewrite")
        XCTAssertEqual(CodeActionKind.source.rawValue, "source")
        XCTAssertEqual(CodeActionKind.sourceOrganizeImports.rawValue, "source.organizeImports")
        XCTAssertEqual(CodeActionKind.sourceFixAll.rawValue, "source.fixAll")
    }

    func test_codeActionKind_isStringRawRepresentable_roundtrip() throws {
        // Encodes as a bare JSON string.
        let kind = CodeActionKind.quickFix
        let data = try encoder.encode(kind)
        XCTAssertEqual(String(data: data, encoding: .utf8), "\"quickfix\"")
        let decoded = try decoder.decode(CodeActionKind.self, from: data)
        XCTAssertEqual(decoded, kind)
    }

    func test_codeActionKind_acceptsUnknownServerDefinedValue() throws {
        // The spec defines CodeActionKind as an OPEN string enum; servers may
        // ship custom kinds (e.g. "rust.expandMacro"). We must round-trip them.
        let json = "\"rust.expandMacro\""
        let decoded = try decoder.decode(CodeActionKind.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.rawValue, "rust.expandMacro")
        let reencoded = try encoder.encode(decoded)
        XCTAssertEqual(String(data: reencoded, encoding: .utf8), json)
    }

    // ====================================================================
    // MARK: - CodeActionContext
    // Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#codeActionContext
    // ====================================================================

    func test_codeActionContext_minimal_roundtrip() throws {
        // Only `diagnostics` is required.
        let json = #"""
        {"diagnostics":[]}
        """#
        try assertRoundtrip(CodeActionContext.self, json: json)
    }

    func test_codeActionContext_withOnlyAndTriggerKind_roundtrip() throws {
        let json = #"""
        {
          "diagnostics":[
            {
              "message":"unused import",
              "range":{"end":{"character":10,"line":0},"start":{"character":0,"line":0}},
              "severity":2
            }
          ],
          "only":["quickfix","refactor.extract"],
          "triggerKind":1
        }
        """#
        try assertRoundtrip(CodeActionContext.self, json: json)
    }

    // ====================================================================
    // MARK: - CodeActionParams
    // Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocument_codeAction
    // ====================================================================

    func test_codeActionParams_minimal_roundtrip() throws {
        let json = #"""
        {
          "context":{"diagnostics":[]},
          "range":{"end":{"character":5,"line":3},"start":{"character":0,"line":3}},
          "textDocument":{"uri":"file:///tmp/ca.swift"}
        }
        """#
        try assertRoundtrip(CodeActionParams.self, json: json)
    }

    func test_codeActionParams_withProgressTokens_roundtrip() throws {
        let json = #"""
        {
          "context":{"diagnostics":[],"only":["source"],"triggerKind":2},
          "partialResultToken":"ca-part",
          "range":{"end":{"character":5,"line":3},"start":{"character":0,"line":3}},
          "textDocument":{"uri":"file:///tmp/ca.swift"},
          "workDoneToken":42
        }
        """#
        try assertRoundtrip(CodeActionParams.self, json: json)
    }

    // ====================================================================
    // MARK: - CodeAction
    // Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#codeAction
    // ====================================================================

    func test_codeAction_minimal_roundtrip() throws {
        // Only `title` is required.
        let json = #"""
        {"title":"Fix it"}
        """#
        try assertRoundtrip(CodeAction.self, json: json)
    }

    func test_codeAction_withKindAndIsPreferred_roundtrip() throws {
        let json = #"""
        {"isPreferred":true,"kind":"quickfix","title":"Remove unused import"}
        """#
        try assertRoundtrip(CodeAction.self, json: json)
    }

    func test_codeAction_withDisabled_roundtrip() throws {
        let json = #"""
        {
          "disabled":{"reason":"Selection contains no fixable diagnostics"},
          "kind":"quickfix",
          "title":"Quick fix unavailable"
        }
        """#
        try assertRoundtrip(CodeAction.self, json: json)
    }

    func test_codeAction_withEditAndCommand_roundtrip() throws {
        // CodeAction may carry both an edit and a follow-up command.
        let json = #"""
        {
          "command":{"command":"editor.action.format","title":"Format Document"},
          "edit":{
            "changes":{
              "file:///tmp/x.swift":[
                {"newText":"foo","range":{"end":{"character":3,"line":0},"start":{"character":0,"line":0}}}
              ]
            }
          },
          "kind":"refactor.rewrite",
          "title":"Refactor and format"
        }
        """#
        try assertRoundtrip(CodeAction.self, json: json)
    }

    func test_codeAction_withDiagnosticsAndData_roundtrip() throws {
        let json = #"""
        {
          "data":{"actionId":"act-7","seq":3},
          "diagnostics":[
            {
              "message":"variable shadows outer scope",
              "range":{"end":{"character":4,"line":2},"start":{"character":0,"line":2}}
            }
          ],
          "kind":"quickfix",
          "title":"Rename to avoid shadowing"
        }
        """#
        try assertRoundtrip(CodeAction.self, json: json)
    }

    func test_codeActionDisabled_roundtrip() throws {
        let json = #"{"reason":"not applicable"}"#
        try assertRoundtrip(CodeActionDisabled.self, json: json)
    }

    // ====================================================================
    // MARK: - CodeActionItem (union: Command | CodeAction)
    // The result of textDocument/codeAction is `(Command | CodeAction)[] | null`.
    // ====================================================================

    func test_codeActionItem_commandVariant_roundtrip() throws {
        // A Command has a required `command` identifier; presence of the
        // `command` key (and absence of CodeAction-only keys like `edit`,
        // `kind`, `diagnostics`) discriminates the variant.
        let json = #"""
        {"command":"editor.action.format","title":"Format Document"}
        """#
        try assertRoundtrip(CodeActionItem.self, json: json)
    }

    func test_codeActionItem_actionVariant_roundtrip() throws {
        // A CodeAction with `kind` cannot be confused with a Command.
        let json = #"""
        {"kind":"quickfix","title":"Fix it"}
        """#
        try assertRoundtrip(CodeActionItem.self, json: json)
    }

    func test_codeActionItem_actionVariant_withEdit_roundtrip() throws {
        // Presence of `edit` is a strong discriminator for CodeAction.
        let json = #"""
        {
          "edit":{
            "changes":{
              "file:///tmp/x.swift":[
                {"newText":"y","range":{"end":{"character":1,"line":0},"start":{"character":0,"line":0}}}
              ]
            }
          },
          "title":"Apply edit"
        }
        """#
        try assertRoundtrip(CodeActionItem.self, json: json)
    }

    func test_codeActionItem_caseConstruction() throws {
        let cmd: CodeActionItem = .command(Command(title: "Format", command: "editor.action.format"))
        let act: CodeActionItem = .action(CodeAction(
            title: "Fix it",
            kind: .quickFix,
            diagnostics: nil,
            isPreferred: nil,
            disabled: nil,
            edit: nil,
            command: nil,
            data: nil
        ))
        XCTAssertNotEqual(cmd, act)

        let cmdData = try encoder.encode(cmd)
        XCTAssertEqual(try decoder.decode(CodeActionItem.self, from: cmdData), cmd)

        let actData = try encoder.encode(act)
        XCTAssertEqual(try decoder.decode(CodeActionItem.self, from: actData), act)
    }

    // ====================================================================
    // MARK: - CodeLensParams / CodeLens
    // Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocument_codeLens
    // ====================================================================

    func test_codeLensParams_minimal_roundtrip() throws {
        let json = #"""
        {"textDocument":{"uri":"file:///tmp/cl.swift"}}
        """#
        try assertRoundtrip(CodeLensParams.self, json: json)
    }

    func test_codeLensParams_withTokens_roundtrip() throws {
        let json = #"""
        {
          "partialResultToken":"cl-part",
          "textDocument":{"uri":"file:///tmp/cl.swift"},
          "workDoneToken":"cl-work"
        }
        """#
        try assertRoundtrip(CodeLensParams.self, json: json)
    }

    func test_codeLens_minimal_roundtrip() throws {
        // `range` is the only required field — codeLens entries may be
        // returned unresolved (no command, no data).
        let json = #"""
        {"range":{"end":{"character":10,"line":2},"start":{"character":0,"line":2}}}
        """#
        try assertRoundtrip(CodeLens.self, json: json)
    }

    func test_codeLens_withCommand_roundtrip() throws {
        let json = #"""
        {
          "command":{"arguments":["arg-1",2],"command":"editor.action.showReferences","title":"3 references"},
          "range":{"end":{"character":10,"line":2},"start":{"character":0,"line":2}}
        }
        """#
        try assertRoundtrip(CodeLens.self, json: json)
    }

    func test_codeLens_withData_roundtrip() throws {
        let json = #"""
        {
          "data":{"resolveKey":"refs-7"},
          "range":{"end":{"character":10,"line":2},"start":{"character":0,"line":2}}
        }
        """#
        try assertRoundtrip(CodeLens.self, json: json)
    }

    // ====================================================================
    // MARK: - RenameParams / PrepareRenameParams
    // Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocument_rename
    // ====================================================================

    func test_renameParams_minimal_roundtrip() throws {
        let json = #"""
        {
          "newName":"newSymbol",
          "position":{"character":3,"line":5},
          "textDocument":{"uri":"file:///tmp/r.swift"}
        }
        """#
        try assertRoundtrip(RenameParams.self, json: json)
    }

    func test_renameParams_withWorkDoneToken_roundtrip() throws {
        let json = #"""
        {
          "newName":"newSymbol",
          "position":{"character":3,"line":5},
          "textDocument":{"uri":"file:///tmp/r.swift"},
          "workDoneToken":"rename-1"
        }
        """#
        try assertRoundtrip(RenameParams.self, json: json)
    }

    func test_prepareRenameParams_minimal_roundtrip() throws {
        let json = #"""
        {
          "position":{"character":3,"line":5},
          "textDocument":{"uri":"file:///tmp/r.swift"}
        }
        """#
        try assertRoundtrip(PrepareRenameParams.self, json: json)
    }

    // ====================================================================
    // MARK: - PrepareRenameResult (Range | { range, placeholder } | { defaultBehavior })
    // Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#prepareRenameResult
    // ====================================================================

    func test_prepareRenameResult_rangeVariant_roundtrip() throws {
        // A bare Range object: { "start": ..., "end": ... }
        let json = #"""
        {"end":{"character":10,"line":3},"start":{"character":4,"line":3}}
        """#
        try assertRoundtrip(PrepareRenameResult.self, json: json)
    }

    func test_prepareRenameResult_placeholderVariant_roundtrip() throws {
        let json = #"""
        {
          "placeholder":"oldName",
          "range":{"end":{"character":10,"line":3},"start":{"character":4,"line":3}}
        }
        """#
        try assertRoundtrip(PrepareRenameResult.self, json: json)
    }

    func test_prepareRenameResult_defaultBehaviorVariant_roundtrip() throws {
        let json = #"{"defaultBehavior":true}"#
        try assertRoundtrip(PrepareRenameResult.self, json: json)
    }

    func test_prepareRenameResult_caseConstruction() throws {
        let r: PrepareRenameResult = .range(LSPRange(
            start: Position(line: 1, character: 2),
            end: Position(line: 1, character: 8)
        ))
        let p: PrepareRenameResult = .placeholder(
            range: LSPRange(
                start: Position(line: 1, character: 2),
                end: Position(line: 1, character: 8)
            ),
            placeholder: "name"
        )
        let d: PrepareRenameResult = .defaultBehavior(true)
        XCTAssertNotEqual(r, p)
        XCTAssertNotEqual(p, d)
        XCTAssertNotEqual(r, d)

        for value in [r, p, d] {
            let data = try encoder.encode(value)
            let decoded = try decoder.decode(PrepareRenameResult.self, from: data)
            XCTAssertEqual(decoded, value)
        }
    }

    // ====================================================================
    // MARK: - FormattingOptions
    // Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#formattingOptions
    // ====================================================================

    func test_formattingOptions_requiredOnly_roundtrip() throws {
        let json = #"""
        {"insertSpaces":true,"tabSize":4}
        """#
        try assertRoundtrip(FormattingOptions.self, json: json)
    }

    func test_formattingOptions_allOptionalsPresent_roundtrip() throws {
        let json = #"""
        {
          "insertFinalNewline":true,
          "insertSpaces":false,
          "tabSize":2,
          "trimFinalNewlines":true,
          "trimTrailingWhitespace":true
        }
        """#
        try assertRoundtrip(FormattingOptions.self, json: json)
    }

    // ====================================================================
    // MARK: - DocumentFormattingParams
    // Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocument_formatting
    // ====================================================================

    func test_documentFormattingParams_minimal_roundtrip() throws {
        let json = #"""
        {
          "options":{"insertSpaces":true,"tabSize":4},
          "textDocument":{"uri":"file:///tmp/f.swift"}
        }
        """#
        try assertRoundtrip(DocumentFormattingParams.self, json: json)
    }

    func test_documentFormattingParams_withWorkDoneToken_roundtrip() throws {
        let json = #"""
        {
          "options":{"insertSpaces":true,"tabSize":4},
          "textDocument":{"uri":"file:///tmp/f.swift"},
          "workDoneToken":"fmt-1"
        }
        """#
        try assertRoundtrip(DocumentFormattingParams.self, json: json)
    }

    // ====================================================================
    // MARK: - DocumentRangeFormattingParams
    // Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocument_rangeFormatting
    // ====================================================================

    func test_documentRangeFormattingParams_minimal_roundtrip() throws {
        let json = #"""
        {
          "options":{"insertSpaces":true,"tabSize":4},
          "range":{"end":{"character":0,"line":10},"start":{"character":0,"line":0}},
          "textDocument":{"uri":"file:///tmp/f.swift"}
        }
        """#
        try assertRoundtrip(DocumentRangeFormattingParams.self, json: json)
    }

    func test_documentRangeFormattingParams_withWorkDoneToken_roundtrip() throws {
        let json = #"""
        {
          "options":{"insertSpaces":true,"tabSize":4},
          "range":{"end":{"character":0,"line":10},"start":{"character":0,"line":0}},
          "textDocument":{"uri":"file:///tmp/f.swift"},
          "workDoneToken":7
        }
        """#
        try assertRoundtrip(DocumentRangeFormattingParams.self, json: json)
    }

    // ====================================================================
    // MARK: - DocumentOnTypeFormattingParams
    // Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocument_onTypeFormatting
    // ====================================================================

    func test_documentOnTypeFormattingParams_roundtrip() throws {
        let json = #"""
        {
          "ch":"}",
          "options":{"insertSpaces":true,"tabSize":4},
          "position":{"character":1,"line":12},
          "textDocument":{"uri":"file:///tmp/f.swift"}
        }
        """#
        try assertRoundtrip(DocumentOnTypeFormattingParams.self, json: json)
    }

    // ====================================================================
    // MARK: - DocumentLinkParams / DocumentLink
    // Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocument_documentLink
    // ====================================================================

    func test_documentLinkParams_minimal_roundtrip() throws {
        let json = #"""
        {"textDocument":{"uri":"file:///tmp/dl.swift"}}
        """#
        try assertRoundtrip(DocumentLinkParams.self, json: json)
    }

    func test_documentLinkParams_withTokens_roundtrip() throws {
        let json = #"""
        {
          "partialResultToken":"dl-part",
          "textDocument":{"uri":"file:///tmp/dl.swift"},
          "workDoneToken":3
        }
        """#
        try assertRoundtrip(DocumentLinkParams.self, json: json)
    }

    func test_documentLink_minimal_roundtrip() throws {
        // Only `range` is required — `target`, `tooltip` and `data` may be
        // resolved later via documentLink/resolve.
        let json = #"""
        {"range":{"end":{"character":40,"line":0},"start":{"character":10,"line":0}}}
        """#
        try assertRoundtrip(DocumentLink.self, json: json)
    }

    func test_documentLink_full_roundtrip() throws {
        let json = #"""
        {
          "data":{"id":"link-3"},
          "range":{"end":{"character":40,"line":0},"start":{"character":10,"line":0}},
          "target":"https://example.com/docs",
          "tooltip":"Open documentation"
        }
        """#
        try assertRoundtrip(DocumentLink.self, json: json)
    }

    // ====================================================================
    // MARK: - FoldingRangeParams / FoldingRange / FoldingRangeKind
    // Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocument_foldingRange
    // ====================================================================

    func test_foldingRangeParams_minimal_roundtrip() throws {
        let json = #"""
        {"textDocument":{"uri":"file:///tmp/fr.swift"}}
        """#
        try assertRoundtrip(FoldingRangeParams.self, json: json)
    }

    func test_foldingRangeParams_withTokens_roundtrip() throws {
        let json = #"""
        {
          "partialResultToken":2,
          "textDocument":{"uri":"file:///tmp/fr.swift"},
          "workDoneToken":"fr-w"
        }
        """#
        try assertRoundtrip(FoldingRangeParams.self, json: json)
    }

    func test_foldingRangeKind_allKnownValues_roundtrip() throws {
        for (raw, expected) in [
            ("comment", FoldingRangeKind.comment),
            ("imports", FoldingRangeKind.imports),
            ("region",  FoldingRangeKind.region)
        ] {
            let json = "\"\(raw)\""
            let decoded = try decoder.decode(FoldingRangeKind.self, from: Data(json.utf8))
            XCTAssertEqual(decoded, expected, "raw=\(raw)")
            let reencoded = try encoder.encode(decoded)
            XCTAssertEqual(String(data: reencoded, encoding: .utf8), json)
        }
    }

    func test_foldingRange_minimal_roundtrip() throws {
        // Only startLine and endLine are required.
        let json = #"""
        {"endLine":10,"startLine":0}
        """#
        try assertRoundtrip(FoldingRange.self, json: json)
    }

    func test_foldingRange_withCharactersAndKind_roundtrip() throws {
        let json = #"""
        {
          "endCharacter":2,
          "endLine":12,
          "kind":"region",
          "startCharacter":4,
          "startLine":3
        }
        """#
        try assertRoundtrip(FoldingRange.self, json: json)
    }

    func test_foldingRange_withCollapsedText_roundtrip() throws {
        let json = #"""
        {
          "collapsedText":"// MARK: - Helpers",
          "endLine":40,
          "kind":"comment",
          "startLine":10
        }
        """#
        try assertRoundtrip(FoldingRange.self, json: json)
    }

    func test_foldingRange_imports_kind_roundtrip() throws {
        let json = #"""
        {"endLine":5,"kind":"imports","startLine":0}
        """#
        try assertRoundtrip(FoldingRange.self, json: json)
    }

    // ====================================================================
    // MARK: - SelectionRangeParams / SelectionRange
    // Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocument_selectionRange
    //
    // `SelectionRange` is a recursive structure: each node has an optional
    // `parent` pointing to a surrounding selection range. Swift requires a
    // boxed reference (class or indirect enum) to express this.
    // ====================================================================

    func test_selectionRangeParams_minimal_roundtrip() throws {
        let json = #"""
        {
          "positions":[{"character":0,"line":0}],
          "textDocument":{"uri":"file:///tmp/sr.swift"}
        }
        """#
        try assertRoundtrip(SelectionRangeParams.self, json: json)
    }

    func test_selectionRangeParams_multiplePositionsAndTokens_roundtrip() throws {
        let json = #"""
        {
          "partialResultToken":"sr-part",
          "positions":[
            {"character":0,"line":0},
            {"character":5,"line":10}
          ],
          "textDocument":{"uri":"file:///tmp/sr.swift"},
          "workDoneToken":"sr-w"
        }
        """#
        try assertRoundtrip(SelectionRangeParams.self, json: json)
    }

    func test_selectionRange_leaf_roundtrip() throws {
        // A leaf has no `parent`.
        let json = #"""
        {"range":{"end":{"character":5,"line":3},"start":{"character":0,"line":3}}}
        """#
        try assertRoundtrip(SelectionRange.self, json: json)
    }

    func test_selectionRange_oneLevelNested_roundtrip() throws {
        let json = #"""
        {
          "parent":{
            "range":{"end":{"character":40,"line":10},"start":{"character":0,"line":3}}
          },
          "range":{"end":{"character":5,"line":3},"start":{"character":0,"line":3}}
        }
        """#
        try assertRoundtrip(SelectionRange.self, json: json)
    }

    func test_selectionRange_twoLevelNested_roundtrip() throws {
        let json = #"""
        {
          "parent":{
            "parent":{
              "range":{"end":{"character":0,"line":80},"start":{"character":0,"line":0}}
            },
            "range":{"end":{"character":40,"line":10},"start":{"character":0,"line":3}}
          },
          "range":{"end":{"character":5,"line":3},"start":{"character":0,"line":3}}
        }
        """#
        try assertRoundtrip(SelectionRange.self, json: json)
    }
}
