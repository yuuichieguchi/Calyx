//
//  LSPTypesFoundationTests.swift
//  Calyx
//
//  Round-trip Codable tests for the LSP 3.18 foundation type batch.
//
//  Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/
//
//  Coverage (this batch — foundation types only):
//    - DocumentUri (typealias String)
//    - Position, Range, Location, LocationLink
//    - TextDocumentIdentifier / VersionedTextDocumentIdentifier /
//      OptionalVersionedTextDocumentIdentifier / TextDocumentItem
//    - TextEdit / AnnotatedTextEdit / ChangeAnnotation / TextDocumentEdit
//    - CreateFile(Options) / RenameFile(Options) / DeleteFile(Options)
//    - WorkspaceEdit + DocumentChange union
//    - DiagnosticSeverity / DiagnosticTag / DiagnosticRelatedInformation /
//      CodeDescription / Diagnostic (incl. code Int|String union)
//    - Command
//    - MarkupKind / MarkupContent / MarkedString union
//    - WorkDoneProgressBegin / Report / End (kind-discriminated three-way enum)
//    - ProgressToken (Int | String union)
//
//  TDD phase: RED. None of these types exist yet. This file is expected to
//  fail to compile until the swift-specialist implements the foundation
//  types under `Calyx/Features/LSP/LSPTypes/`.
//

import XCTest
@testable import Calyx

final class LSPTypesFoundationTests: XCTestCase {

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
    // MARK: - DocumentUri
    // Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#uri
    // ====================================================================

    func test_documentUri_isStringTypealias_roundtrip() throws {
        // DocumentUri is a string in LSP. The Swift typealias must allow
        // direct String assignment and Codable round-trip.
        let uri: DocumentUri = "file:///Users/example/main.swift"
        let data = try encoder.encode(uri)
        let decoded = try decoder.decode(DocumentUri.self, from: data)
        XCTAssertEqual(decoded, uri)
    }

    // ====================================================================
    // MARK: - Position
    // Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#position
    // ====================================================================

    func test_position_roundtrip() throws {
        let json = #"{"character":7,"line":42}"#
        try assertRoundtrip(Position.self, json: json)

        // Direct construction sanity check (ensures public initializer exists).
        let p = Position(line: 42, character: 7)
        XCTAssertEqual(p.line, 42)
        XCTAssertEqual(p.character, 7)
    }

    func test_position_zeroOrigin_roundtrip() throws {
        let json = #"{"character":0,"line":0}"#
        try assertRoundtrip(Position.self, json: json)
    }

    // ====================================================================
    // MARK: - Range
    // Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#range
    // ====================================================================

    func test_range_roundtrip() throws {
        let json = #"""
        {"end":{"character":10,"line":2},"start":{"character":3,"line":1}}
        """#
        try assertRoundtrip(LSPRange.self, json: json)

        let r = LSPRange(
            start: Position(line: 1, character: 3),
            end: Position(line: 2, character: 10)
        )
        XCTAssertEqual(r.start.line, 1)
        XCTAssertEqual(r.end.character, 10)
    }

    // ====================================================================
    // MARK: - Location
    // Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#location
    // ====================================================================

    func test_location_roundtrip() throws {
        let json = #"""
        {"range":{"end":{"character":5,"line":3},"start":{"character":0,"line":3}},"uri":"file:///tmp/a.swift"}
        """#
        try assertRoundtrip(Location.self, json: json)
    }

    // ====================================================================
    // MARK: - LocationLink
    // Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#locationLink
    // ====================================================================

    func test_locationLink_withOriginSelectionRange_roundtrip() throws {
        let json = #"""
        {
          "originSelectionRange":{"end":{"character":4,"line":0},"start":{"character":0,"line":0}},
          "targetRange":{"end":{"character":10,"line":5},"start":{"character":0,"line":5}},
          "targetSelectionRange":{"end":{"character":8,"line":5},"start":{"character":2,"line":5}},
          "targetUri":"file:///tmp/b.swift"
        }
        """#
        try assertRoundtrip(LocationLink.self, json: json)
    }

    func test_locationLink_withoutOriginSelectionRange_roundtrip() throws {
        // originSelectionRange is optional; absent on output when nil.
        let json = #"""
        {
          "targetRange":{"end":{"character":10,"line":5},"start":{"character":0,"line":5}},
          "targetSelectionRange":{"end":{"character":8,"line":5},"start":{"character":2,"line":5}},
          "targetUri":"file:///tmp/b.swift"
        }
        """#
        try assertRoundtrip(LocationLink.self, json: json)
    }

    // ====================================================================
    // MARK: - TextDocumentIdentifier family
    // Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocumentIdentifier
    // Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#versionedTextDocumentIdentifier
    // Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#optionalVersionedTextDocumentIdentifier
    // Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocumentItem
    // ====================================================================

    func test_textDocumentIdentifier_roundtrip() throws {
        let json = #"{"uri":"file:///tmp/c.swift"}"#
        try assertRoundtrip(TextDocumentIdentifier.self, json: json)
    }

    func test_versionedTextDocumentIdentifier_roundtrip() throws {
        let json = #"{"uri":"file:///tmp/c.swift","version":7}"#
        try assertRoundtrip(VersionedTextDocumentIdentifier.self, json: json)
    }

    func test_optionalVersionedTextDocumentIdentifier_withVersion_roundtrip() throws {
        let json = #"{"uri":"file:///tmp/c.swift","version":3}"#
        try assertRoundtrip(OptionalVersionedTextDocumentIdentifier.self, json: json)
    }

    func test_optionalVersionedTextDocumentIdentifier_nullVersion_roundtrip() throws {
        // Spec allows version: integer | null. `null` must be preserved
        // explicitly (not omitted) to disambiguate from "absent".
        let json = #"{"uri":"file:///tmp/c.swift","version":null}"#
        try assertRoundtrip(OptionalVersionedTextDocumentIdentifier.self, json: json)
    }

    func test_textDocumentItem_roundtrip() throws {
        let json = #"""
        {"languageId":"swift","text":"print(\"hi\")\n","uri":"file:///tmp/d.swift","version":1}
        """#
        try assertRoundtrip(TextDocumentItem.self, json: json)
    }

    // ====================================================================
    // MARK: - TextEdit / AnnotatedTextEdit / ChangeAnnotation
    // Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textEdit
    // Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#annotatedTextEdit
    // Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#changeAnnotation
    // ====================================================================

    func test_textEdit_roundtrip() throws {
        let json = #"""
        {"newText":"foo","range":{"end":{"character":3,"line":0},"start":{"character":0,"line":0}}}
        """#
        try assertRoundtrip(TextEdit.self, json: json)
    }

    func test_annotatedTextEdit_roundtrip() throws {
        let json = #"""
        {"annotationId":"rename-1","newText":"bar","range":{"end":{"character":3,"line":0},"start":{"character":0,"line":0}}}
        """#
        try assertRoundtrip(AnnotatedTextEdit.self, json: json)
    }

    func test_changeAnnotation_minimal_roundtrip() throws {
        let json = #"{"label":"Rename foo"}"#
        try assertRoundtrip(ChangeAnnotation.self, json: json)
    }

    func test_changeAnnotation_allFields_roundtrip() throws {
        let json = #"""
        {"description":"Renames `foo` to `bar`","label":"Rename foo","needsConfirmation":true}
        """#
        try assertRoundtrip(ChangeAnnotation.self, json: json)
    }

    // ====================================================================
    // MARK: - TextDocumentEdit (mixed TextEdit / AnnotatedTextEdit)
    // Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocumentEdit
    // ====================================================================

    func test_textDocumentEdit_textEditOnly_roundtrip() throws {
        let json = #"""
        {
          "edits":[
            {"newText":"foo","range":{"end":{"character":3,"line":0},"start":{"character":0,"line":0}}}
          ],
          "textDocument":{"uri":"file:///tmp/e.swift","version":1}
        }
        """#
        try assertRoundtrip(TextDocumentEdit.self, json: json)
    }

    func test_textDocumentEdit_mixedAnnotated_roundtrip() throws {
        // edits is `(TextEdit | AnnotatedTextEdit)[]`; the AnnotatedTextEdit
        // variant carries an `annotationId` discriminator.
        let json = #"""
        {
          "edits":[
            {"newText":"foo","range":{"end":{"character":3,"line":0},"start":{"character":0,"line":0}}},
            {"annotationId":"a1","newText":"bar","range":{"end":{"character":6,"line":0},"start":{"character":4,"line":0}}}
          ],
          "textDocument":{"uri":"file:///tmp/e.swift","version":null}
        }
        """#
        try assertRoundtrip(TextDocumentEdit.self, json: json)
    }

    // ====================================================================
    // MARK: - CreateFile / RenameFile / DeleteFile (+ options)
    // Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#resourceChanges
    // ====================================================================

    func test_createFileOptions_roundtrip() throws {
        let json = #"{"ignoreIfExists":true,"overwrite":false}"#
        try assertRoundtrip(CreateFileOptions.self, json: json)
    }

    func test_renameFileOptions_roundtrip() throws {
        let json = #"{"ignoreIfExists":false,"overwrite":true}"#
        try assertRoundtrip(RenameFileOptions.self, json: json)
    }

    func test_deleteFileOptions_roundtrip() throws {
        let json = #"{"ignoreIfNotExists":true,"recursive":true}"#
        try assertRoundtrip(DeleteFileOptions.self, json: json)
    }

    // ====================================================================
    // MARK: - DocumentChange union (discriminated by `kind`)
    // Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#workspaceEdit
    //   - { kind: "create" }   → CreateFile
    //   - { kind: "rename" }   → RenameFile
    //   - { kind: "delete" }   → DeleteFile
    //   - (no `kind`)          → TextDocumentEdit
    // ====================================================================

    func test_documentChange_textDocumentEdit_roundtrip() throws {
        let json = #"""
        {
          "edits":[
            {"newText":"x","range":{"end":{"character":1,"line":0},"start":{"character":0,"line":0}}}
          ],
          "textDocument":{"uri":"file:///tmp/x.swift","version":2}
        }
        """#
        try assertRoundtrip(DocumentChange.self, json: json)
    }

    func test_documentChange_createFile_roundtrip() throws {
        let json = #"""
        {"kind":"create","options":{"ignoreIfExists":false,"overwrite":true},"uri":"file:///tmp/new.swift"}
        """#
        try assertRoundtrip(DocumentChange.self, json: json)
    }

    func test_documentChange_renameFile_roundtrip() throws {
        let json = #"""
        {"kind":"rename","newUri":"file:///tmp/renamed.swift","oldUri":"file:///tmp/old.swift","options":{"ignoreIfExists":false,"overwrite":true}}
        """#
        try assertRoundtrip(DocumentChange.self, json: json)
    }

    func test_documentChange_deleteFile_roundtrip() throws {
        let json = #"""
        {"kind":"delete","options":{"ignoreIfNotExists":false,"recursive":true},"uri":"file:///tmp/gone.swift"}
        """#
        try assertRoundtrip(DocumentChange.self, json: json)
    }

    // ====================================================================
    // MARK: - WorkspaceEdit
    // Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#workspaceEdit
    // ====================================================================

    func test_workspaceEdit_changesOnly_roundtrip() throws {
        let json = #"""
        {
          "changes":{
            "file:///tmp/a.swift":[
              {"newText":"a","range":{"end":{"character":1,"line":0},"start":{"character":0,"line":0}}}
            ]
          }
        }
        """#
        try assertRoundtrip(WorkspaceEdit.self, json: json)
    }

    func test_workspaceEdit_documentChangesAndAnnotations_roundtrip() throws {
        let json = #"""
        {
          "changeAnnotations":{
            "rename-1":{"label":"Rename","needsConfirmation":true}
          },
          "documentChanges":[
            {
              "edits":[
                {"annotationId":"rename-1","newText":"bar","range":{"end":{"character":3,"line":0},"start":{"character":0,"line":0}}}
              ],
              "textDocument":{"uri":"file:///tmp/x.swift","version":1}
            },
            {"kind":"create","uri":"file:///tmp/new.swift"}
          ]
        }
        """#
        try assertRoundtrip(WorkspaceEdit.self, json: json)
    }

    // ====================================================================
    // MARK: - DiagnosticSeverity (enum, Int raw 1..4)
    // Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#diagnosticSeverity
    // ====================================================================

    func test_diagnosticSeverity_minValue_error() throws {
        let decoded = try decoder.decode(DiagnosticSeverity.self, from: Data("1".utf8))
        XCTAssertEqual(decoded, .error)
    }

    func test_diagnosticSeverity_maxValue_hint() throws {
        let decoded = try decoder.decode(DiagnosticSeverity.self, from: Data("4".utf8))
        XCTAssertEqual(decoded, .hint)
    }

    func test_diagnosticSeverity_allValues_roundtrip() throws {
        for (raw, expected) in [
            (1, DiagnosticSeverity.error),
            (2, DiagnosticSeverity.warning),
            (3, DiagnosticSeverity.information),
            (4, DiagnosticSeverity.hint)
        ] {
            let decoded = try decoder.decode(DiagnosticSeverity.self, from: Data("\(raw)".utf8))
            XCTAssertEqual(decoded, expected, "raw=\(raw)")
            let reencoded = try encoder.encode(decoded)
            XCTAssertEqual(String(data: reencoded, encoding: .utf8), "\(raw)")
        }
    }

    func test_diagnosticSeverity_undefinedValue_decodeFails() {
        XCTAssertThrowsError(
            try decoder.decode(DiagnosticSeverity.self, from: Data("0".utf8)),
            "0 is not a valid DiagnosticSeverity"
        )
        XCTAssertThrowsError(
            try decoder.decode(DiagnosticSeverity.self, from: Data("5".utf8)),
            "5 is not a valid DiagnosticSeverity"
        )
    }

    // ====================================================================
    // MARK: - DiagnosticTag (enum, Int raw 1..2)
    // Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#diagnosticTag
    // ====================================================================

    func test_diagnosticTag_minValue_unnecessary() throws {
        let decoded = try decoder.decode(DiagnosticTag.self, from: Data("1".utf8))
        XCTAssertEqual(decoded, .unnecessary)
    }

    func test_diagnosticTag_maxValue_deprecated() throws {
        let decoded = try decoder.decode(DiagnosticTag.self, from: Data("2".utf8))
        XCTAssertEqual(decoded, .deprecated)
    }

    func test_diagnosticTag_undefinedValue_decodeFails() {
        XCTAssertThrowsError(
            try decoder.decode(DiagnosticTag.self, from: Data("0".utf8))
        )
        XCTAssertThrowsError(
            try decoder.decode(DiagnosticTag.self, from: Data("3".utf8))
        )
    }

    // ====================================================================
    // MARK: - DiagnosticRelatedInformation / CodeDescription
    // Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#diagnosticRelatedInformation
    // Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#codeDescription
    // ====================================================================

    func test_diagnosticRelatedInformation_roundtrip() throws {
        let json = #"""
        {
          "location":{
            "range":{"end":{"character":5,"line":1},"start":{"character":0,"line":1}},
            "uri":"file:///tmp/r.swift"
          },
          "message":"first defined here"
        }
        """#
        try assertRoundtrip(DiagnosticRelatedInformation.self, json: json)
    }

    func test_codeDescription_roundtrip() throws {
        let json = #"{"href":"https://example.com/lint/E001"}"#
        try assertRoundtrip(CodeDescription.self, json: json)
    }

    // ====================================================================
    // MARK: - Diagnostic
    // Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#diagnostic
    // ====================================================================

    func test_diagnostic_minimal_roundtrip() throws {
        // Only `range` and `message` are required.
        let json = #"""
        {"message":"unused variable","range":{"end":{"character":5,"line":0},"start":{"character":0,"line":0}}}
        """#
        try assertRoundtrip(Diagnostic.self, json: json)
    }

    func test_diagnostic_withAllOptionalFields_intCode_roundtrip() throws {
        let json = #"""
        {
          "code":404,
          "codeDescription":{"href":"https://example.com/E404"},
          "data":{"hint":"x"},
          "message":"not found",
          "range":{"end":{"character":5,"line":0},"start":{"character":0,"line":0}},
          "relatedInformation":[
            {
              "location":{
                "range":{"end":{"character":3,"line":2},"start":{"character":0,"line":2}},
                "uri":"file:///tmp/r.swift"
              },
              "message":"see also"
            }
          ],
          "severity":1,
          "source":"swiftc",
          "tags":[1,2]
        }
        """#
        try assertRoundtrip(Diagnostic.self, json: json)
    }

    func test_diagnostic_stringCode_roundtrip() throws {
        // `code` is `integer | string` in spec — exercise string variant.
        let json = #"""
        {
          "code":"E_UNUSED",
          "message":"unused",
          "range":{"end":{"character":5,"line":0},"start":{"character":0,"line":0}},
          "severity":2
        }
        """#
        try assertRoundtrip(Diagnostic.self, json: json)
    }

    // ====================================================================
    // MARK: - Command
    // Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#command
    // ====================================================================

    func test_command_withoutArguments_roundtrip() throws {
        let json = #"{"command":"editor.action.formatDocument","title":"Format"}"#
        try assertRoundtrip(Command.self, json: json)
    }

    func test_command_withArguments_roundtrip() throws {
        let json = #"""
        {"arguments":["arg1",42,true],"command":"editor.action.applyEdit","title":"Apply"}
        """#
        try assertRoundtrip(Command.self, json: json)
    }

    // ====================================================================
    // MARK: - MarkupKind / MarkupContent / MarkedString
    // Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#markupContent
    // ====================================================================

    func test_markupKind_plaintext_roundtrip() throws {
        let decoded = try decoder.decode(MarkupKind.self, from: Data(#""plaintext""#.utf8))
        XCTAssertEqual(decoded, .plaintext)
        let reencoded = try encoder.encode(decoded)
        XCTAssertEqual(String(data: reencoded, encoding: .utf8), #""plaintext""#)
    }

    func test_markupKind_markdown_roundtrip() throws {
        let decoded = try decoder.decode(MarkupKind.self, from: Data(#""markdown""#.utf8))
        XCTAssertEqual(decoded, .markdown)
    }

    func test_markupKind_undefinedValue_decodeFails() {
        XCTAssertThrowsError(
            try decoder.decode(MarkupKind.self, from: Data(#""rtf""#.utf8))
        )
    }

    func test_markupContent_roundtrip() throws {
        // NOTE: `##"..."##` is used so the `"#` byte inside the markdown heading
        // text does not prematurely terminate the raw string literal.
        let json = ##"{"kind":"markdown","value":"# Title\n\nbody"}"##
        try assertRoundtrip(MarkupContent.self, json: json)
    }

    func test_markedString_stringVariant_roundtrip() throws {
        // MarkedString = string | { language, value }
        let json = #""plain text""#
        try assertRoundtrip(MarkedString.self, json: json)
    }

    func test_markedString_objectVariant_roundtrip() throws {
        let json = #"{"language":"swift","value":"let x = 1"}"#
        try assertRoundtrip(MarkedString.self, json: json)
    }

    // ====================================================================
    // MARK: - WorkDoneProgress (Begin / Report / End, kind-discriminated)
    // Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#workDoneProgress
    // ====================================================================

    func test_workDoneProgress_begin_roundtrip() throws {
        let json = #"""
        {"cancellable":true,"kind":"begin","message":"loading","percentage":0,"title":"Indexing"}
        """#
        try assertRoundtrip(WorkDoneProgress.self, json: json)
    }

    func test_workDoneProgress_report_roundtrip() throws {
        let json = #"""
        {"cancellable":false,"kind":"report","message":"halfway","percentage":50}
        """#
        try assertRoundtrip(WorkDoneProgress.self, json: json)
    }

    func test_workDoneProgress_end_roundtrip() throws {
        let json = #"{"kind":"end","message":"done"}"#
        try assertRoundtrip(WorkDoneProgress.self, json: json)
    }

    func test_workDoneProgress_unknownKind_decodeFails() {
        // Unknown discriminator must surface as a decode error rather than
        // silently constructing a malformed value.
        let json = Data(#"{"kind":"unknown"}"#.utf8)
        XCTAssertThrowsError(try decoder.decode(WorkDoneProgress.self, from: json))
    }

    // ====================================================================
    // MARK: - ProgressToken (Int | String union)
    // Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#progress
    // ====================================================================

    func test_progressToken_intVariant_roundtrip() throws {
        let decoded = try decoder.decode(ProgressToken.self, from: Data("42".utf8))
        XCTAssertEqual(decoded, .int(42))
        let reencoded = try encoder.encode(decoded)
        XCTAssertEqual(String(data: reencoded, encoding: .utf8), "42")
    }

    func test_progressToken_stringVariant_roundtrip() throws {
        let decoded = try decoder.decode(ProgressToken.self, from: Data(#""tok-1""#.utf8))
        XCTAssertEqual(decoded, .string("tok-1"))
        let reencoded = try encoder.encode(decoded)
        XCTAssertEqual(String(data: reencoded, encoding: .utf8), #""tok-1""#)
    }

    func test_progressToken_invalidType_decodeFails() {
        XCTAssertThrowsError(
            try decoder.decode(ProgressToken.self, from: Data("true".utf8)),
            "boolean is not a valid ProgressToken"
        )
    }
}
