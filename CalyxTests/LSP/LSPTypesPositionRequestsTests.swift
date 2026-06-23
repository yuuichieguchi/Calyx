//
//  LSPTypesPositionRequestsTests.swift
//  Calyx
//
//  Round-trip Codable tests for the LSP 3.18 position-based feature request
//  parameter / response types.
//
//  Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/
//
//  Coverage (this batch — position-based feature requests):
//    - TextDocumentPositionParams (the shared base)
//    - HoverParams / Hover / HoverContents (union: MarkupContent | MarkedString | [MarkedString])
//    - DefinitionParams / DefinitionResult (union: Location | [Location] | [LocationLink])
//    - DeclarationParams / DeclarationResult
//    - TypeDefinitionParams / TypeDefinitionResult
//    - ImplementationParams / ImplementationResult
//    - ReferenceParams / ReferenceContext
//    - DocumentHighlightParams / DocumentHighlight / DocumentHighlightKind
//    - SignatureHelpParams / SignatureHelpContext / SignatureHelpTriggerKind
//    - SignatureHelp / SignatureInformation / ParameterInformation / ParameterLabel
//    - StringOrMarkupContent (union: String | MarkupContent)
//
//  TDD phase: RED. None of these types exist yet. This file is expected to
//  fail to compile until the swift-specialist implements them under
//  `Calyx/Features/LSP/LSPTypes/`.
//

import XCTest
@testable import Calyx

@MainActor
final class LSPTypesPositionRequestsTests: XCTestCase {

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
    // MARK: - TextDocumentPositionParams
    // Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocumentPositionParams
    // ====================================================================

    func test_textDocumentPositionParams_roundtrip() throws {
        let json = #"""
        {"position":{"character":7,"line":42},"textDocument":{"uri":"file:///tmp/a.swift"}}
        """#
        try assertRoundtrip(TextDocumentPositionParams.self, json: json)

        // Direct construction sanity check (ensures public memberwise init exists).
        let p = TextDocumentPositionParams(
            textDocument: TextDocumentIdentifier(uri: "file:///tmp/a.swift"),
            position: Position(line: 42, character: 7)
        )
        XCTAssertEqual(p.textDocument.uri, "file:///tmp/a.swift")
        XCTAssertEqual(p.position.line, 42)
        XCTAssertEqual(p.position.character, 7)
    }

    // ====================================================================
    // MARK: - HoverParams
    // Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocument_hover
    // ====================================================================

    func test_hoverParams_withoutWorkDoneToken_roundtrip() throws {
        let json = #"""
        {"position":{"character":3,"line":10},"textDocument":{"uri":"file:///tmp/h.swift"}}
        """#
        try assertRoundtrip(HoverParams.self, json: json)
    }

    func test_hoverParams_withWorkDoneToken_string_roundtrip() throws {
        let json = #"""
        {"position":{"character":3,"line":10},"textDocument":{"uri":"file:///tmp/h.swift"},"workDoneToken":"hover-1"}
        """#
        try assertRoundtrip(HoverParams.self, json: json)
    }

    func test_hoverParams_withWorkDoneToken_int_roundtrip() throws {
        let json = #"""
        {"position":{"character":3,"line":10},"textDocument":{"uri":"file:///tmp/h.swift"},"workDoneToken":99}
        """#
        try assertRoundtrip(HoverParams.self, json: json)
    }

    // ====================================================================
    // MARK: - Hover / HoverContents
    // Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#hover
    //
    // Hover.contents = MarkupContent | MarkedString | MarkedString[]
    // ====================================================================

    func test_hover_contents_markupContent_roundtrip() throws {
        let json = ##"""
        {"contents":{"kind":"markdown","value":"# Title"},"range":{"end":{"character":5,"line":0},"start":{"character":0,"line":0}}}
        """##
        try assertRoundtrip(Hover.self, json: json)
    }

    func test_hover_contents_markedString_stringVariant_roundtrip() throws {
        // Bare string MarkedString.
        let json = #"""
        {"contents":"some markdown"}
        """#
        try assertRoundtrip(Hover.self, json: json)
    }

    func test_hover_contents_markedString_objectVariant_roundtrip() throws {
        // MarkedString as `{ language, value }` object.
        let json = #"""
        {"contents":{"language":"swift","value":"let x = 1"}}
        """#
        try assertRoundtrip(Hover.self, json: json)
    }

    func test_hover_contents_markedStringArray_roundtrip() throws {
        // MarkedString[] — mixed bare-string and object variants.
        let json = #"""
        {"contents":["plain note",{"language":"swift","value":"let y = 2"}]}
        """#
        try assertRoundtrip(Hover.self, json: json)
    }

    func test_hover_withoutRange_roundtrip() throws {
        let json = ##"""
        {"contents":{"kind":"plaintext","value":"docs"}}
        """##
        try assertRoundtrip(Hover.self, json: json)
    }

    func test_hoverContents_markupContent_caseConstruction() throws {
        // Ensure the enum exposes a `.markupContent` case taking MarkupContent.
        let contents: HoverContents = .markupContent(
            MarkupContent(kind: .markdown, value: "**bold**")
        )
        let data = try encoder.encode(contents)
        let roundTripped = try decoder.decode(HoverContents.self, from: data)
        XCTAssertEqual(roundTripped, contents)
    }

    func test_hoverContents_markedStrings_caseConstruction() throws {
        // Ensure the enum exposes a `.markedStrings` case taking [MarkedString].
        let contents: HoverContents = .markedStrings([
            .string("note"),
            .codeBlock(language: "swift", value: "let z = 3")
        ])
        let data = try encoder.encode(contents)
        let roundTripped = try decoder.decode(HoverContents.self, from: data)
        XCTAssertEqual(roundTripped, contents)
    }

    // ====================================================================
    // MARK: - DefinitionParams / DefinitionResult
    // Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocument_definition
    //
    // Result = Location | Location[] | LocationLink[] | null
    // ====================================================================

    func test_definitionParams_minimal_roundtrip() throws {
        let json = #"""
        {"position":{"character":1,"line":2},"textDocument":{"uri":"file:///tmp/d.swift"}}
        """#
        try assertRoundtrip(DefinitionParams.self, json: json)
    }

    func test_definitionParams_withProgressTokens_roundtrip() throws {
        let json = #"""
        {"partialResultToken":"part-1","position":{"character":1,"line":2},"textDocument":{"uri":"file:///tmp/d.swift"},"workDoneToken":7}
        """#
        try assertRoundtrip(DefinitionParams.self, json: json)
    }

    func test_definitionResult_singleLocation_roundtrip() throws {
        let json = #"""
        {"range":{"end":{"character":5,"line":3},"start":{"character":0,"line":3}},"uri":"file:///tmp/d.swift"}
        """#
        try assertRoundtrip(DefinitionResult.self, json: json)
    }

    func test_definitionResult_locationArray_roundtrip() throws {
        let json = #"""
        [
          {"range":{"end":{"character":5,"line":3},"start":{"character":0,"line":3}},"uri":"file:///tmp/a.swift"},
          {"range":{"end":{"character":9,"line":7},"start":{"character":4,"line":7}},"uri":"file:///tmp/b.swift"}
        ]
        """#
        try assertRoundtrip(DefinitionResult.self, json: json)
    }

    func test_definitionResult_locationLinkArray_roundtrip() throws {
        let json = #"""
        [
          {
            "originSelectionRange":{"end":{"character":4,"line":0},"start":{"character":0,"line":0}},
            "targetRange":{"end":{"character":10,"line":5},"start":{"character":0,"line":5}},
            "targetSelectionRange":{"end":{"character":8,"line":5},"start":{"character":2,"line":5}},
            "targetUri":"file:///tmp/b.swift"
          }
        ]
        """#
        try assertRoundtrip(DefinitionResult.self, json: json)
    }

    // ====================================================================
    // MARK: - DeclarationParams / DeclarationResult
    // Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocument_declaration
    // ====================================================================

    func test_declarationParams_minimal_roundtrip() throws {
        let json = #"""
        {"position":{"character":2,"line":4},"textDocument":{"uri":"file:///tmp/decl.swift"}}
        """#
        try assertRoundtrip(DeclarationParams.self, json: json)
    }

    func test_declarationResult_singleLocation_roundtrip() throws {
        let json = #"""
        {"range":{"end":{"character":3,"line":1},"start":{"character":0,"line":1}},"uri":"file:///tmp/decl.swift"}
        """#
        try assertRoundtrip(DeclarationResult.self, json: json)
    }

    func test_declarationResult_locationLinkArray_roundtrip() throws {
        let json = #"""
        [
          {
            "targetRange":{"end":{"character":10,"line":5},"start":{"character":0,"line":5}},
            "targetSelectionRange":{"end":{"character":8,"line":5},"start":{"character":2,"line":5}},
            "targetUri":"file:///tmp/decl.swift"
          }
        ]
        """#
        try assertRoundtrip(DeclarationResult.self, json: json)
    }

    // ====================================================================
    // MARK: - TypeDefinitionParams / TypeDefinitionResult
    // Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocument_typeDefinition
    // ====================================================================

    func test_typeDefinitionParams_withTokens_roundtrip() throws {
        let json = #"""
        {"partialResultToken":3,"position":{"character":5,"line":10},"textDocument":{"uri":"file:///tmp/t.swift"},"workDoneToken":"td-1"}
        """#
        try assertRoundtrip(TypeDefinitionParams.self, json: json)
    }

    func test_typeDefinitionResult_locationArray_roundtrip() throws {
        let json = #"""
        [
          {"range":{"end":{"character":4,"line":2},"start":{"character":0,"line":2}},"uri":"file:///tmp/t.swift"}
        ]
        """#
        try assertRoundtrip(TypeDefinitionResult.self, json: json)
    }

    // ====================================================================
    // MARK: - ImplementationParams / ImplementationResult
    // Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocument_implementation
    // ====================================================================

    func test_implementationParams_minimal_roundtrip() throws {
        let json = #"""
        {"position":{"character":0,"line":0},"textDocument":{"uri":"file:///tmp/i.swift"}}
        """#
        try assertRoundtrip(ImplementationParams.self, json: json)
    }

    func test_implementationResult_singleLocation_roundtrip() throws {
        let json = #"""
        {"range":{"end":{"character":7,"line":12},"start":{"character":4,"line":12}},"uri":"file:///tmp/i.swift"}
        """#
        try assertRoundtrip(ImplementationResult.self, json: json)
    }

    func test_implementationResult_locationLinkArray_roundtrip() throws {
        let json = #"""
        [
          {
            "targetRange":{"end":{"character":12,"line":20},"start":{"character":0,"line":20}},
            "targetSelectionRange":{"end":{"character":10,"line":20},"start":{"character":4,"line":20}},
            "targetUri":"file:///tmp/i.swift"
          }
        ]
        """#
        try assertRoundtrip(ImplementationResult.self, json: json)
    }

    // ====================================================================
    // MARK: - ReferenceParams / ReferenceContext
    // Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocument_references
    // ====================================================================

    func test_referenceContext_includeDeclarationTrue_roundtrip() throws {
        let json = #"{"includeDeclaration":true}"#
        try assertRoundtrip(ReferenceContext.self, json: json)
    }

    func test_referenceContext_includeDeclarationFalse_roundtrip() throws {
        let json = #"{"includeDeclaration":false}"#
        try assertRoundtrip(ReferenceContext.self, json: json)
    }

    func test_referenceParams_minimal_roundtrip() throws {
        let json = #"""
        {"context":{"includeDeclaration":true},"position":{"character":3,"line":5},"textDocument":{"uri":"file:///tmp/r.swift"}}
        """#
        try assertRoundtrip(ReferenceParams.self, json: json)
    }

    func test_referenceParams_withProgressTokens_roundtrip() throws {
        let json = #"""
        {"context":{"includeDeclaration":false},"partialResultToken":"ref-part","position":{"character":3,"line":5},"textDocument":{"uri":"file:///tmp/r.swift"},"workDoneToken":11}
        """#
        try assertRoundtrip(ReferenceParams.self, json: json)
    }

    // ====================================================================
    // MARK: - DocumentHighlightParams / DocumentHighlight / DocumentHighlightKind
    // Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocument_documentHighlight
    // ====================================================================

    func test_documentHighlightParams_minimal_roundtrip() throws {
        let json = #"""
        {"position":{"character":0,"line":0},"textDocument":{"uri":"file:///tmp/dh.swift"}}
        """#
        try assertRoundtrip(DocumentHighlightParams.self, json: json)
    }

    func test_documentHighlightParams_withTokens_roundtrip() throws {
        let json = #"""
        {"partialResultToken":"dh-p","position":{"character":0,"line":0},"textDocument":{"uri":"file:///tmp/dh.swift"},"workDoneToken":"dh-w"}
        """#
        try assertRoundtrip(DocumentHighlightParams.self, json: json)
    }

    func test_documentHighlightKind_allValues_roundtrip() throws {
        for (raw, expected) in [
            (1, DocumentHighlightKind.text),
            (2, DocumentHighlightKind.read),
            (3, DocumentHighlightKind.write)
        ] {
            let decoded = try decoder.decode(DocumentHighlightKind.self, from: Data("\(raw)".utf8))
            XCTAssertEqual(decoded, expected, "raw=\(raw)")
            let reencoded = try encoder.encode(decoded)
            XCTAssertEqual(String(data: reencoded, encoding: .utf8), "\(raw)")
        }
    }

    func test_documentHighlight_withoutKind_roundtrip() throws {
        let json = #"""
        {"range":{"end":{"character":7,"line":3},"start":{"character":0,"line":3}}}
        """#
        try assertRoundtrip(DocumentHighlight.self, json: json)
    }

    func test_documentHighlight_withKind_roundtrip() throws {
        let json = #"""
        {"kind":2,"range":{"end":{"character":7,"line":3},"start":{"character":0,"line":3}}}
        """#
        try assertRoundtrip(DocumentHighlight.self, json: json)
    }

    // ====================================================================
    // MARK: - SignatureHelp request types
    // Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocument_signatureHelp
    // ====================================================================

    func test_signatureHelpTriggerKind_allValues_roundtrip() throws {
        for (raw, expected) in [
            (1, SignatureHelpTriggerKind.invoked),
            (2, SignatureHelpTriggerKind.triggerCharacter),
            (3, SignatureHelpTriggerKind.contentChange)
        ] {
            let decoded = try decoder.decode(SignatureHelpTriggerKind.self, from: Data("\(raw)".utf8))
            XCTAssertEqual(decoded, expected, "raw=\(raw)")
            let reencoded = try encoder.encode(decoded)
            XCTAssertEqual(String(data: reencoded, encoding: .utf8), "\(raw)")
        }
    }

    func test_signatureHelpParams_minimal_roundtrip() throws {
        let json = #"""
        {"position":{"character":3,"line":5},"textDocument":{"uri":"file:///tmp/sh.swift"}}
        """#
        try assertRoundtrip(SignatureHelpParams.self, json: json)
    }

    func test_signatureHelpParams_withContext_invoked_roundtrip() throws {
        let json = #"""
        {"context":{"isRetrigger":false,"triggerKind":1},"position":{"character":3,"line":5},"textDocument":{"uri":"file:///tmp/sh.swift"}}
        """#
        try assertRoundtrip(SignatureHelpParams.self, json: json)
    }

    func test_signatureHelpParams_withContext_retrigger_andActiveSignatureHelp_roundtrip() throws {
        // Exercises every optional inside SignatureHelpContext + activeSignatureHelp.
        let json = #"""
        {
          "context":{
            "activeSignatureHelp":{
              "activeParameter":0,
              "activeSignature":0,
              "signatures":[
                {"label":"f(x: Int)"}
              ]
            },
            "isRetrigger":true,
            "triggerCharacter":"(",
            "triggerKind":2
          },
          "position":{"character":3,"line":5},
          "textDocument":{"uri":"file:///tmp/sh.swift"},
          "workDoneToken":"sh-w"
        }
        """#
        try assertRoundtrip(SignatureHelpParams.self, json: json)
    }

    // ====================================================================
    // MARK: - SignatureHelp / SignatureInformation / ParameterInformation
    // ====================================================================

    func test_signatureHelp_minimal_roundtrip() throws {
        let json = #"""
        {"signatures":[{"label":"f()"}]}
        """#
        try assertRoundtrip(SignatureHelp.self, json: json)
    }

    func test_signatureHelp_fullActiveIndexes_roundtrip() throws {
        let json = #"""
        {"activeParameter":1,"activeSignature":0,"signatures":[{"label":"f(x: Int, y: Int)"}]}
        """#
        try assertRoundtrip(SignatureHelp.self, json: json)
    }

    func test_signatureInformation_withStringDocumentation_andStringLabelParameter_roundtrip() throws {
        let json = #"""
        {
          "documentation":"computes f",
          "label":"f(x: Int)",
          "parameters":[
            {"documentation":"the input","label":"x: Int"}
          ]
        }
        """#
        try assertRoundtrip(SignatureInformation.self, json: json)
    }

    func test_signatureInformation_withMarkupContentDocumentation_andRangeLabelParameter_roundtrip() throws {
        // ParameterInformation.label may be `[Int, Int]` representing inclusive
        // offsets into the parent signature's label string.
        let json = ##"""
        {
          "activeParameter":0,
          "documentation":{"kind":"markdown","value":"**docs**"},
          "label":"f(x: Int, y: Int)",
          "parameters":[
            {"label":[2,8]},
            {"documentation":{"kind":"plaintext","value":"second"},"label":[10,16]}
          ]
        }
        """##
        try assertRoundtrip(SignatureInformation.self, json: json)
    }

    func test_parameterInformation_stringLabel_roundtrip() throws {
        let json = #"""
        {"label":"x: Int"}
        """#
        try assertRoundtrip(ParameterInformation.self, json: json)
    }

    func test_parameterInformation_rangeLabel_roundtrip() throws {
        let json = #"{"label":[2,8]}"#
        try assertRoundtrip(ParameterInformation.self, json: json)
    }

    func test_parameterLabel_caseConstruction_string() throws {
        let label: ParameterLabel = .string("x: Int")
        let data = try encoder.encode(label)
        let decoded = try decoder.decode(ParameterLabel.self, from: data)
        XCTAssertEqual(decoded, label)
    }

    func test_parameterLabel_caseConstruction_range() throws {
        let label: ParameterLabel = .range(start: 2, end: 8)
        let data = try encoder.encode(label)
        let decoded = try decoder.decode(ParameterLabel.self, from: data)
        XCTAssertEqual(decoded, label)
    }

    // ====================================================================
    // MARK: - StringOrMarkupContent (shared documentation union)
    // ====================================================================

    func test_stringOrMarkupContent_stringVariant_roundtrip() throws {
        let json = #""plain docs""#
        try assertRoundtrip(StringOrMarkupContent.self, json: json)
    }

    func test_stringOrMarkupContent_markupVariant_roundtrip() throws {
        let json = ##"""
        {"kind":"markdown","value":"# docs"}
        """##
        try assertRoundtrip(StringOrMarkupContent.self, json: json)
    }

    func test_stringOrMarkupContent_caseConstruction() throws {
        let s: StringOrMarkupContent = .string("hello")
        let m: StringOrMarkupContent = .markupContent(
            MarkupContent(kind: .plaintext, value: "world")
        )
        XCTAssertNotEqual(s, m)

        let sData = try encoder.encode(s)
        XCTAssertEqual(try decoder.decode(StringOrMarkupContent.self, from: sData), s)

        let mData = try encoder.encode(m)
        XCTAssertEqual(try decoder.decode(StringOrMarkupContent.self, from: mData), m)
    }
}
