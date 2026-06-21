//
//  LSPTypesCompletionAndSymbolTests.swift
//  Calyx
//
//  Round-trip Codable tests for LSP 3.18 Completion, DocumentSymbol, and
//  WorkspaceSymbol feature types.
//
//  Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/
//
//  Coverage (this batch — completion + symbol feature types):
//    Completion family
//      - CompletionParams
//      - CompletionContext / CompletionTriggerKind
//      - CompletionList / CompletionItemDefaults
//      - CompletionItem / CompletionItemLabelDetails
//      - CompletionItemKind / CompletionItemTag
//      - InsertTextFormat / InsertTextMode
//      - CompletionResult (union: CompletionItem[] | CompletionList)
//    DocumentSymbol family
//      - DocumentSymbolParams
//      - SymbolKind / SymbolTag
//      - DocumentSymbol (hierarchical, recursive)
//      - SymbolInformation (legacy flat, deprecated since 3.18)
//      - DocumentSymbolResult (union: DocumentSymbol[] | SymbolInformation[])
//    WorkspaceSymbol family
//      - WorkspaceSymbolParams
//      - WorkspaceSymbol
//      - WorkspaceSymbolLocation (union: Location | { uri })
//      - WorkspaceSymbolResult (union: WorkspaceSymbol[] | SymbolInformation[])
//
//  TDD phase: RED. None of these types exist yet. This file is expected to
//  fail to compile until the swift-specialist implements them under
//  `Calyx/Features/LSP/LSPTypes/`.
//

import XCTest
@testable import Calyx

@MainActor
final class LSPTypesCompletionAndSymbolTests: XCTestCase {

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
    // MARK: - CompletionTriggerKind
    // Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#completionTriggerKind
    // ====================================================================

    func test_completionTriggerKind_invoked_rawValueIs1() {
        XCTAssertEqual(CompletionTriggerKind.invoked.rawValue, 1)
    }

    func test_completionTriggerKind_triggerCharacter_rawValueIs2() {
        XCTAssertEqual(CompletionTriggerKind.triggerCharacter.rawValue, 2)
    }

    func test_completionTriggerKind_triggerForIncompleteCompletions_rawValueIs3() {
        XCTAssertEqual(CompletionTriggerKind.triggerForIncompleteCompletions.rawValue, 3)
    }

    func test_completionTriggerKind_roundtrip_allValues() throws {
        for kind in [
            CompletionTriggerKind.invoked,
            .triggerCharacter,
            .triggerForIncompleteCompletions
        ] {
            let data = try encoder.encode(kind)
            let decoded = try decoder.decode(CompletionTriggerKind.self, from: data)
            XCTAssertEqual(decoded, kind)
        }
    }

    // ====================================================================
    // MARK: - CompletionItemKind
    // Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#completionItemKind
    // ====================================================================

    func test_completionItemKind_rawValues_spotCheck() {
        XCTAssertEqual(CompletionItemKind.text.rawValue, 1)
        XCTAssertEqual(CompletionItemKind.method.rawValue, 2)
        XCTAssertEqual(CompletionItemKind.function.rawValue, 3)
        XCTAssertEqual(CompletionItemKind.constructor.rawValue, 4)
        XCTAssertEqual(CompletionItemKind.field.rawValue, 5)
        XCTAssertEqual(CompletionItemKind.variable.rawValue, 6)
        XCTAssertEqual(CompletionItemKind.class.rawValue, 7)
        XCTAssertEqual(CompletionItemKind.interface.rawValue, 8)
        XCTAssertEqual(CompletionItemKind.module.rawValue, 9)
        XCTAssertEqual(CompletionItemKind.snippet.rawValue, 15)
        XCTAssertEqual(CompletionItemKind.enumMember.rawValue, 20)
        XCTAssertEqual(CompletionItemKind.struct.rawValue, 22)
        XCTAssertEqual(CompletionItemKind.operator.rawValue, 24)
        XCTAssertEqual(CompletionItemKind.typeParameter.rawValue, 25)
    }

    func test_completionItemKind_roundtrip_typeParameter() throws {
        let data = try encoder.encode(CompletionItemKind.typeParameter)
        XCTAssertEqual(try decoder.decode(CompletionItemKind.self, from: data), .typeParameter)
    }

    // ====================================================================
    // MARK: - CompletionItemTag
    // Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#completionItemTag
    // ====================================================================

    func test_completionItemTag_deprecated_rawValueIs1() {
        XCTAssertEqual(CompletionItemTag.deprecated.rawValue, 1)
    }

    // ====================================================================
    // MARK: - InsertTextFormat / InsertTextMode
    // Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#insertTextFormat
    // ====================================================================

    func test_insertTextFormat_rawValues() {
        XCTAssertEqual(InsertTextFormat.plainText.rawValue, 1)
        XCTAssertEqual(InsertTextFormat.snippet.rawValue, 2)
    }

    func test_insertTextMode_rawValues() {
        XCTAssertEqual(InsertTextMode.asIs.rawValue, 1)
        XCTAssertEqual(InsertTextMode.adjustIndentation.rawValue, 2)
    }

    // ====================================================================
    // MARK: - CompletionParams
    // Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocument_completion
    // ====================================================================

    func test_completionParams_minimal_roundtrip() throws {
        let json = #"""
        {"position":{"character":3,"line":10},"textDocument":{"uri":"file:///tmp/c.swift"}}
        """#
        try assertRoundtrip(CompletionParams.self, json: json)
    }

    func test_completionParams_withContext_invoked_roundtrip() throws {
        let json = #"""
        {"context":{"triggerKind":1},"position":{"character":3,"line":10},"textDocument":{"uri":"file:///tmp/c.swift"}}
        """#
        try assertRoundtrip(CompletionParams.self, json: json)
    }

    func test_completionParams_withContext_triggerCharacter_roundtrip() throws {
        let json = #"""
        {"context":{"triggerCharacter":".","triggerKind":2},"position":{"character":3,"line":10},"textDocument":{"uri":"file:///tmp/c.swift"}}
        """#
        try assertRoundtrip(CompletionParams.self, json: json)
    }

    func test_completionParams_withProgressTokens_roundtrip() throws {
        let json = #"""
        {"partialResultToken":"part-1","position":{"character":3,"line":10},"textDocument":{"uri":"file:///tmp/c.swift"},"workDoneToken":42}
        """#
        try assertRoundtrip(CompletionParams.self, json: json)
    }

    // ====================================================================
    // MARK: - CompletionContext
    // Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#completionContext
    // ====================================================================

    func test_completionContext_invoked_noTriggerCharacter_roundtrip() throws {
        let json = #"""
        {"triggerKind":1}
        """#
        try assertRoundtrip(CompletionContext.self, json: json)
    }

    func test_completionContext_triggerCharacter_roundtrip() throws {
        let json = #"""
        {"triggerCharacter":".","triggerKind":2}
        """#
        try assertRoundtrip(CompletionContext.self, json: json)
    }

    func test_completionContext_triggerForIncomplete_roundtrip() throws {
        let json = #"""
        {"triggerKind":3}
        """#
        try assertRoundtrip(CompletionContext.self, json: json)
    }

    // ====================================================================
    // MARK: - CompletionItemLabelDetails
    // ====================================================================

    func test_completionItemLabelDetails_full_roundtrip() throws {
        let json = #"""
        {"description":"some-module","detail":"(a: Int) -> String"}
        """#
        try assertRoundtrip(CompletionItemLabelDetails.self, json: json)
    }

    func test_completionItemLabelDetails_empty_roundtrip() throws {
        let json = #"""
        {}
        """#
        try assertRoundtrip(CompletionItemLabelDetails.self, json: json)
    }

    // ====================================================================
    // MARK: - CompletionItem
    // Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#completionItem
    // ====================================================================

    func test_completionItem_minimal_roundtrip() throws {
        let json = #"""
        {"label":"foo"}
        """#
        try assertRoundtrip(CompletionItem.self, json: json)
    }

    func test_completionItem_withKindAndDocumentation_stringDoc_roundtrip() throws {
        let json = #"""
        {"documentation":"docs","kind":3,"label":"bar"}
        """#
        try assertRoundtrip(CompletionItem.self, json: json)
    }

    func test_completionItem_withKindAndDocumentation_markupDoc_roundtrip() throws {
        let json = ##"""
        {"documentation":{"kind":"markdown","value":"**bold**"},"kind":3,"label":"bar"}
        """##
        try assertRoundtrip(CompletionItem.self, json: json)
    }

    func test_completionItem_withTextEdit_roundtrip() throws {
        let json = #"""
        {"label":"qux","textEdit":{"newText":"qux()","range":{"end":{"character":3,"line":5},"start":{"character":0,"line":5}}}}
        """#
        try assertRoundtrip(CompletionItem.self, json: json)
    }

    func test_completionItem_full_roundtrip() throws {
        // Exercise every optional field together.
        let json = ##"""
        {
          "additionalTextEdits":[{"newText":"import Foo\n","range":{"end":{"character":0,"line":0},"start":{"character":0,"line":0}}}],
          "command":{"command":"editor.action.triggerSuggest","title":"Re-trigger"},
          "commitCharacters":[".",";"],
          "data":{"id":"item-1"},
          "deprecated":false,
          "detail":"(a: Int) -> String",
          "documentation":{"kind":"markdown","value":"docs"},
          "filterText":"foo",
          "insertText":"foo()",
          "insertTextFormat":2,
          "insertTextMode":2,
          "kind":3,
          "label":"foo",
          "labelDetails":{"description":"mod","detail":"(a: Int)"},
          "preselect":true,
          "sortText":"0001",
          "tags":[1],
          "textEdit":{"newText":"foo()","range":{"end":{"character":3,"line":5},"start":{"character":0,"line":5}}},
          "textEditText":"foo()"
        }
        """##
        try assertRoundtrip(CompletionItem.self, json: json)
    }

    func test_completionItem_directConstruction_minimal() throws {
        // Sanity-check that the memberwise init is callable with just `label`.
        let item = CompletionItem(label: "foo")
        XCTAssertEqual(item.label, "foo")
        XCTAssertNil(item.kind)
        XCTAssertNil(item.insertText)
    }

    // ====================================================================
    // MARK: - CompletionList / CompletionItemDefaults
    // Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#completionList
    // ====================================================================

    func test_completionList_empty_roundtrip() throws {
        let json = #"""
        {"isIncomplete":false,"items":[]}
        """#
        try assertRoundtrip(CompletionList.self, json: json)
    }

    func test_completionList_withItems_roundtrip() throws {
        let json = #"""
        {"isIncomplete":true,"items":[{"label":"foo"},{"kind":6,"label":"bar"}]}
        """#
        try assertRoundtrip(CompletionList.self, json: json)
    }

    func test_completionList_withItemDefaults_roundtrip() throws {
        let json = #"""
        {"isIncomplete":false,"itemDefaults":{"commitCharacters":[".",";"],"data":{"x":1},"insertTextFormat":2,"insertTextMode":1},"items":[{"label":"foo"}]}
        """#
        try assertRoundtrip(CompletionList.self, json: json)
    }

    // ====================================================================
    // MARK: - CompletionResult (union: CompletionItem[] | CompletionList)
    // Spec: `textDocument/completion` returns `CompletionItem[] | CompletionList | null`.
    // ====================================================================

    func test_completionResult_items_arrayForm_roundtrip() throws {
        let json = #"""
        [{"label":"foo"},{"kind":6,"label":"bar"}]
        """#
        try assertRoundtrip(CompletionResult.self, json: json)
    }

    func test_completionResult_list_objectForm_roundtrip() throws {
        let json = #"""
        {"isIncomplete":true,"items":[{"label":"foo"}]}
        """#
        try assertRoundtrip(CompletionResult.self, json: json)
    }

    func test_completionResult_caseConstruction_items() throws {
        let result: CompletionResult = .items([
            CompletionItem(label: "foo")
        ])
        let data = try encoder.encode(result)
        let decoded = try decoder.decode(CompletionResult.self, from: data)
        XCTAssertEqual(decoded, result)
        // And confirm the wire form is a raw array, not a wrapped object.
        let obj = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        XCTAssertTrue(obj is [Any], "items case must encode as a JSON array")
    }

    func test_completionResult_caseConstruction_list() throws {
        let result: CompletionResult = .list(
            CompletionList(
                isIncomplete: false,
                itemDefaults: nil,
                items: [CompletionItem(label: "foo")]
            )
        )
        let data = try encoder.encode(result)
        let decoded = try decoder.decode(CompletionResult.self, from: data)
        XCTAssertEqual(decoded, result)
        let obj = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        XCTAssertTrue(obj is [String: Any], "list case must encode as a JSON object")
    }

    // ====================================================================
    // MARK: - SymbolKind
    // Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#symbolKind
    // ====================================================================

    func test_symbolKind_rawValues_spotCheck() {
        XCTAssertEqual(SymbolKind.file.rawValue, 1)
        XCTAssertEqual(SymbolKind.module.rawValue, 2)
        XCTAssertEqual(SymbolKind.namespace.rawValue, 3)
        XCTAssertEqual(SymbolKind.package.rawValue, 4)
        XCTAssertEqual(SymbolKind.class.rawValue, 5)
        XCTAssertEqual(SymbolKind.method.rawValue, 6)
        XCTAssertEqual(SymbolKind.function.rawValue, 12)
        XCTAssertEqual(SymbolKind.variable.rawValue, 13)
        XCTAssertEqual(SymbolKind.constant.rawValue, 14)
        XCTAssertEqual(SymbolKind.enumMember.rawValue, 22)
        XCTAssertEqual(SymbolKind.struct.rawValue, 23)
        XCTAssertEqual(SymbolKind.operator.rawValue, 25)
        XCTAssertEqual(SymbolKind.typeParameter.rawValue, 26)
    }

    func test_symbolKind_roundtrip_class() throws {
        let data = try encoder.encode(SymbolKind.class)
        XCTAssertEqual(try decoder.decode(SymbolKind.self, from: data), .class)
    }

    // ====================================================================
    // MARK: - SymbolTag
    // Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#symbolTag
    // ====================================================================

    func test_symbolTag_deprecated_rawValueIs1() {
        XCTAssertEqual(SymbolTag.deprecated.rawValue, 1)
    }

    // ====================================================================
    // MARK: - DocumentSymbolParams
    // Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocument_documentSymbol
    // ====================================================================

    func test_documentSymbolParams_minimal_roundtrip() throws {
        let json = #"""
        {"textDocument":{"uri":"file:///tmp/ds.swift"}}
        """#
        try assertRoundtrip(DocumentSymbolParams.self, json: json)
    }

    func test_documentSymbolParams_withProgressTokens_roundtrip() throws {
        let json = #"""
        {"partialResultToken":7,"textDocument":{"uri":"file:///tmp/ds.swift"},"workDoneToken":"ds-1"}
        """#
        try assertRoundtrip(DocumentSymbolParams.self, json: json)
    }

    // ====================================================================
    // MARK: - DocumentSymbol
    // Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#documentSymbol
    // ====================================================================

    func test_documentSymbol_leaf_roundtrip() throws {
        let json = #"""
        {"kind":12,"name":"foo","range":{"end":{"character":4,"line":2},"start":{"character":0,"line":2}},"selectionRange":{"end":{"character":3,"line":2},"start":{"character":0,"line":2}}}
        """#
        try assertRoundtrip(DocumentSymbol.self, json: json)
    }

    func test_documentSymbol_withChildren_roundtrip() throws {
        // Hierarchy: a class `Container` with one method child `run`.
        let json = #"""
        {
          "children":[
            {
              "detail":"() -> Void",
              "kind":6,
              "name":"run",
              "range":{"end":{"character":2,"line":4},"start":{"character":4,"line":2}},
              "selectionRange":{"end":{"character":9,"line":2},"start":{"character":8,"line":2}}
            }
          ],
          "kind":5,
          "name":"Container",
          "range":{"end":{"character":1,"line":5},"start":{"character":0,"line":1}},
          "selectionRange":{"end":{"character":15,"line":1},"start":{"character":6,"line":1}},
          "tags":[1]
        }
        """#
        try assertRoundtrip(DocumentSymbol.self, json: json)
    }

    // ====================================================================
    // MARK: - SymbolInformation (legacy flat, deprecated since 3.18)
    // Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#symbolInformation
    // ====================================================================

    func test_symbolInformation_minimal_roundtrip() throws {
        let json = #"""
        {"kind":12,"location":{"range":{"end":{"character":3,"line":2},"start":{"character":0,"line":2}},"uri":"file:///tmp/s.swift"},"name":"foo"}
        """#
        try assertRoundtrip(SymbolInformation.self, json: json)
    }

    func test_symbolInformation_full_roundtrip() throws {
        let json = #"""
        {"containerName":"MyClass","deprecated":true,"kind":6,"location":{"range":{"end":{"character":3,"line":2},"start":{"character":0,"line":2}},"uri":"file:///tmp/s.swift"},"name":"run","tags":[1]}
        """#
        try assertRoundtrip(SymbolInformation.self, json: json)
    }

    // ====================================================================
    // MARK: - DocumentSymbolResult (union: DocumentSymbol[] | SymbolInformation[])
    // Spec: `textDocument/documentSymbol` returns
    //       `DocumentSymbol[] | SymbolInformation[] | null`.
    //
    // Discrimination rule: DocumentSymbol has a required `selectionRange`,
    // SymbolInformation has a required `location` and no `selectionRange`.
    // ====================================================================

    func test_documentSymbolResult_hierarchical_roundtrip() throws {
        let json = #"""
        [
          {
            "kind":5,
            "name":"Foo",
            "range":{"end":{"character":1,"line":5},"start":{"character":0,"line":1}},
            "selectionRange":{"end":{"character":3,"line":1},"start":{"character":0,"line":1}}
          }
        ]
        """#
        try assertRoundtrip(DocumentSymbolResult.self, json: json)
    }

    func test_documentSymbolResult_flat_roundtrip() throws {
        let json = #"""
        [
          {"kind":12,"location":{"range":{"end":{"character":3,"line":2},"start":{"character":0,"line":2}},"uri":"file:///tmp/s.swift"},"name":"foo"}
        ]
        """#
        try assertRoundtrip(DocumentSymbolResult.self, json: json)
    }

    func test_documentSymbolResult_hierarchical_isDiscriminatedBySelectionRange() throws {
        let json = #"""
        [
          {
            "kind":5,
            "name":"Foo",
            "range":{"end":{"character":1,"line":5},"start":{"character":0,"line":1}},
            "selectionRange":{"end":{"character":3,"line":1},"start":{"character":0,"line":1}}
          }
        ]
        """#
        let decoded = try decoder.decode(DocumentSymbolResult.self, from: Data(json.utf8))
        switch decoded {
        case .hierarchical(let arr):
            XCTAssertEqual(arr.count, 1)
            XCTAssertEqual(arr.first?.name, "Foo")
        case .flat:
            XCTFail("Expected `.hierarchical`, got `.flat`")
        }
    }

    func test_documentSymbolResult_flat_isDiscriminatedByLocation() throws {
        let json = #"""
        [
          {"kind":12,"location":{"range":{"end":{"character":3,"line":2},"start":{"character":0,"line":2}},"uri":"file:///tmp/s.swift"},"name":"foo"}
        ]
        """#
        let decoded = try decoder.decode(DocumentSymbolResult.self, from: Data(json.utf8))
        switch decoded {
        case .hierarchical:
            XCTFail("Expected `.flat`, got `.hierarchical`")
        case .flat(let arr):
            XCTAssertEqual(arr.count, 1)
            XCTAssertEqual(arr.first?.name, "foo")
        }
    }

    // ====================================================================
    // MARK: - WorkspaceSymbolParams
    // Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#workspace_symbol
    // ====================================================================

    func test_workspaceSymbolParams_minimal_roundtrip() throws {
        let json = #"""
        {"query":"foo"}
        """#
        try assertRoundtrip(WorkspaceSymbolParams.self, json: json)
    }

    func test_workspaceSymbolParams_emptyQuery_roundtrip() throws {
        let json = #"""
        {"query":""}
        """#
        try assertRoundtrip(WorkspaceSymbolParams.self, json: json)
    }

    func test_workspaceSymbolParams_withProgressTokens_roundtrip() throws {
        let json = #"""
        {"partialResultToken":"ws-part","query":"f","workDoneToken":11}
        """#
        try assertRoundtrip(WorkspaceSymbolParams.self, json: json)
    }

    // ====================================================================
    // MARK: - WorkspaceSymbolLocation (union: Location | { uri })
    // Spec: WorkspaceSymbol.location may be a full Location or a partial
    //       `{ uri: DocumentUri }` (server can resolve the range lazily via
    //       `workspaceSymbol/resolve`).
    // ====================================================================

    func test_workspaceSymbolLocation_full_roundtrip() throws {
        let json = #"""
        {"range":{"end":{"character":3,"line":2},"start":{"character":0,"line":2}},"uri":"file:///tmp/ws.swift"}
        """#
        try assertRoundtrip(WorkspaceSymbolLocation.self, json: json)
    }

    func test_workspaceSymbolLocation_uriOnly_roundtrip() throws {
        let json = #"""
        {"uri":"file:///tmp/ws.swift"}
        """#
        try assertRoundtrip(WorkspaceSymbolLocation.self, json: json)
    }

    func test_workspaceSymbolLocation_full_isDiscriminatedByRangeKey() throws {
        let json = #"""
        {"range":{"end":{"character":3,"line":2},"start":{"character":0,"line":2}},"uri":"file:///tmp/ws.swift"}
        """#
        let decoded = try decoder.decode(WorkspaceSymbolLocation.self, from: Data(json.utf8))
        switch decoded {
        case .full(let loc):
            XCTAssertEqual(loc.uri, "file:///tmp/ws.swift")
        case .uriOnly:
            XCTFail("Expected `.full`, got `.uriOnly`")
        }
    }

    func test_workspaceSymbolLocation_uriOnly_isDiscriminatedByAbsentRange() throws {
        let json = #"""
        {"uri":"file:///tmp/ws.swift"}
        """#
        let decoded = try decoder.decode(WorkspaceSymbolLocation.self, from: Data(json.utf8))
        switch decoded {
        case .full:
            XCTFail("Expected `.uriOnly`, got `.full`")
        case .uriOnly(let uri):
            XCTAssertEqual(uri, "file:///tmp/ws.swift")
        }
    }

    // ====================================================================
    // MARK: - WorkspaceSymbol
    // Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#workspaceSymbol
    // ====================================================================

    func test_workspaceSymbol_withFullLocation_roundtrip() throws {
        let json = #"""
        {"kind":12,"location":{"range":{"end":{"character":3,"line":2},"start":{"character":0,"line":2}},"uri":"file:///tmp/ws.swift"},"name":"foo"}
        """#
        try assertRoundtrip(WorkspaceSymbol.self, json: json)
    }

    func test_workspaceSymbol_withUriOnlyLocation_roundtrip() throws {
        let json = #"""
        {"kind":12,"location":{"uri":"file:///tmp/ws.swift"},"name":"foo"}
        """#
        try assertRoundtrip(WorkspaceSymbol.self, json: json)
    }

    func test_workspaceSymbol_full_roundtrip() throws {
        let json = ##"""
        {
          "containerName":"MyMod",
          "data":{"id":42},
          "kind":6,
          "location":{"uri":"file:///tmp/ws.swift"},
          "name":"run",
          "tags":[1]
        }
        """##
        try assertRoundtrip(WorkspaceSymbol.self, json: json)
    }

    // ====================================================================
    // MARK: - WorkspaceSymbolResult (union)
    // Spec: `workspace/symbol` returns
    //       `WorkspaceSymbol[] | SymbolInformation[] | null`.
    //
    // Discrimination rule: WorkspaceSymbol's `location` may have `uri` only,
    // SymbolInformation's `location` always has both `uri` and `range` AND
    // SymbolInformation is the legacy flat shape (no nested partial location).
    // Pragmatically: try the WorkspaceSymbol decode first; on failure, try
    // SymbolInformation. Both have `name`, `kind`, `location`, so empty arrays
    // collapse to `.workspaceSymbols([])` by convention.
    // ====================================================================

    func test_workspaceSymbolResult_workspaceSymbols_uriOnly_roundtrip() throws {
        let json = #"""
        [{"kind":12,"location":{"uri":"file:///tmp/ws.swift"},"name":"foo"}]
        """#
        try assertRoundtrip(WorkspaceSymbolResult.self, json: json)
    }

    func test_workspaceSymbolResult_workspaceSymbols_isDiscriminatedByUriOnlyLocation() throws {
        let json = #"""
        [{"kind":12,"location":{"uri":"file:///tmp/ws.swift"},"name":"foo"}]
        """#
        let decoded = try decoder.decode(WorkspaceSymbolResult.self, from: Data(json.utf8))
        switch decoded {
        case .workspaceSymbols(let arr):
            XCTAssertEqual(arr.count, 1)
            XCTAssertEqual(arr.first?.name, "foo")
        case .symbolInformations:
            XCTFail("Expected `.workspaceSymbols`, got `.symbolInformations`")
        }
    }

    func test_workspaceSymbolResult_symbolInformations_fullLocation_decodes() throws {
        // A response with full Location entries decodes successfully as one of
        // the two cases. Both shapes are wire-compatible here, but the union
        // must accept the legacy SymbolInformation[] form per spec.
        let json = #"""
        [{"kind":12,"location":{"range":{"end":{"character":3,"line":2},"start":{"character":0,"line":2}},"uri":"file:///tmp/ws.swift"},"name":"foo"}]
        """#
        let decoded = try decoder.decode(WorkspaceSymbolResult.self, from: Data(json.utf8))
        switch decoded {
        case .workspaceSymbols(let arr):
            XCTAssertEqual(arr.count, 1)
            XCTAssertEqual(arr.first?.name, "foo")
        case .symbolInformations(let arr):
            XCTAssertEqual(arr.count, 1)
            XCTAssertEqual(arr.first?.name, "foo")
        }
    }

    // ====================================================================
    // MARK: - Equatable sanity for union enums
    // ====================================================================

    func test_completionResult_equatable_items() {
        let a: CompletionResult = .items([CompletionItem(label: "x")])
        let b: CompletionResult = .items([CompletionItem(label: "x")])
        let c: CompletionResult = .items([CompletionItem(label: "y")])
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    func test_documentSymbolResult_equatable_hierarchical() {
        let leaf = DocumentSymbol(
            name: "foo",
            detail: nil,
            kind: .function,
            tags: nil,
            deprecated: nil,
            range: LSPRange(
                start: Position(line: 0, character: 0),
                end: Position(line: 0, character: 3)
            ),
            selectionRange: LSPRange(
                start: Position(line: 0, character: 0),
                end: Position(line: 0, character: 3)
            ),
            children: nil
        )
        let a: DocumentSymbolResult = .hierarchical([leaf])
        let b: DocumentSymbolResult = .hierarchical([leaf])
        XCTAssertEqual(a, b)
    }

    func test_workspaceSymbolLocation_equatable() {
        let a: WorkspaceSymbolLocation = .uriOnly(uri: "file:///x")
        let b: WorkspaceSymbolLocation = .uriOnly(uri: "file:///x")
        let c: WorkspaceSymbolLocation = .uriOnly(uri: "file:///y")
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }
}
