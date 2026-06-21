//
//  LSPTypesVisualizationClusterTests.swift
//  Calyx
//
//  Round-trip Codable tests for the LSP 3.18 "visualization" feature cluster:
//
//    Semantic Tokens   (textDocument/semanticTokens/{full,range,full/delta})
//      - SemanticTokensLegend
//      - SemanticTokensParams
//      - SemanticTokensRangeParams
//      - SemanticTokensDeltaParams
//      - SemanticTokens
//      - SemanticTokensEdit
//      - SemanticTokensDelta
//      - SemanticTokensDeltaResult (union: SemanticTokens | SemanticTokensDelta)
//
//    Inlay Hints       (textDocument/inlayHint)
//      - InlayHintParams
//      - InlayHintKind   (1=Type, 2=Parameter)
//      - InlayHintLabelPart
//      - InlayHintLabel  (union: String | InlayHintLabelPart[])
//      - InlayHint
//
//    Inline Values     (textDocument/inlineValue)
//      - InlineValueContext
//      - InlineValueParams
//      - InlineValueText
//      - InlineValueVariableLookup
//      - InlineValueEvaluatableExpression
//      - InlineValue (union: text | variableLookup | evaluatableExpression)
//
//    Document Color    (textDocument/documentColor, textDocument/colorPresentation)
//      - DocumentColorParams
//      - LSPColor        (renamed from spec `Color` to avoid SwiftUI.Color clash)
//      - ColorInformation
//      - ColorPresentationParams
//      - ColorPresentation
//
//  Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/
//
//  TDD phase: RED. None of these types exist yet. This file is expected to
//  fail to compile until the swift-specialist implements them under
//  `Calyx/Features/LSP/LSPTypes/`.
//
//  Re-uses already-defined types:
//    - TextDocumentIdentifier
//    - Position
//    - LSPRange
//    - DocumentUri
//    - ProgressToken
//    - Command
//    - Location
//    - TextEdit
//    - StringOrMarkupContent
//    - MarkupContent / MarkupKind
//    - AnyCodable
//

import XCTest
@testable import Calyx

@MainActor
final class LSPTypesVisualizationClusterTests: XCTestCase {

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
    // MARK: - SemanticTokensLegend
    // Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#semanticTokensLegend
    // ====================================================================

    func test_semanticTokensLegend_roundtrip() throws {
        let json = #"""
        {
          "tokenModifiers":["declaration","readonly","deprecated"],
          "tokenTypes":["namespace","type","class","function","variable"]
        }
        """#
        try assertRoundtrip(SemanticTokensLegend.self, json: json)
    }

    func test_semanticTokensLegend_emptyArrays_roundtrip() throws {
        let json = #"""
        {"tokenModifiers":[],"tokenTypes":[]}
        """#
        try assertRoundtrip(SemanticTokensLegend.self, json: json)
    }

    func test_semanticTokensLegend_directConstruction() {
        let legend = SemanticTokensLegend(
            tokenTypes: ["namespace", "type"],
            tokenModifiers: ["declaration", "readonly"]
        )
        XCTAssertEqual(legend.tokenTypes, ["namespace", "type"])
        XCTAssertEqual(legend.tokenModifiers, ["declaration", "readonly"])
    }

    // ====================================================================
    // MARK: - SemanticTokensParams
    // Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocument_semanticTokens
    // ====================================================================

    func test_semanticTokensParams_minimal_roundtrip() throws {
        let json = #"""
        {"textDocument":{"uri":"file:///tmp/s.swift"}}
        """#
        try assertRoundtrip(SemanticTokensParams.self, json: json)
    }

    func test_semanticTokensParams_withBothTokens_roundtrip() throws {
        let json = #"""
        {
          "partialResultToken":"sem-part",
          "textDocument":{"uri":"file:///tmp/s.swift"},
          "workDoneToken":42
        }
        """#
        try assertRoundtrip(SemanticTokensParams.self, json: json)
    }

    // ====================================================================
    // MARK: - SemanticTokensRangeParams
    // Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#semanticTokens_rangeRequest
    // ====================================================================

    func test_semanticTokensRangeParams_minimal_roundtrip() throws {
        let json = #"""
        {
          "range":{"end":{"character":0,"line":10},"start":{"character":0,"line":0}},
          "textDocument":{"uri":"file:///tmp/s.swift"}
        }
        """#
        try assertRoundtrip(SemanticTokensRangeParams.self, json: json)
    }

    func test_semanticTokensRangeParams_withTokens_roundtrip() throws {
        let json = #"""
        {
          "partialResultToken":7,
          "range":{"end":{"character":0,"line":10},"start":{"character":0,"line":0}},
          "textDocument":{"uri":"file:///tmp/s.swift"},
          "workDoneToken":"rng-1"
        }
        """#
        try assertRoundtrip(SemanticTokensRangeParams.self, json: json)
    }

    // ====================================================================
    // MARK: - SemanticTokensDeltaParams
    // Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#semanticTokens_deltaRequest
    // ====================================================================

    func test_semanticTokensDeltaParams_minimal_roundtrip() throws {
        let json = #"""
        {
          "previousResultId":"result-1",
          "textDocument":{"uri":"file:///tmp/s.swift"}
        }
        """#
        try assertRoundtrip(SemanticTokensDeltaParams.self, json: json)
    }

    func test_semanticTokensDeltaParams_full_roundtrip() throws {
        let json = #"""
        {
          "partialResultToken":"delta-part",
          "previousResultId":"r-42",
          "textDocument":{"uri":"file:///tmp/s.swift"},
          "workDoneToken":3
        }
        """#
        try assertRoundtrip(SemanticTokensDeltaParams.self, json: json)
    }

    // ====================================================================
    // MARK: - SemanticTokens
    // Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#semanticTokens
    // ====================================================================

    func test_semanticTokens_minimal_roundtrip() throws {
        // Pure data array, no resultId. data is the standard 5-tuple-per-token
        // encoding: (deltaLine, deltaStart, length, tokenType, tokenModifierBitset).
        let json = #"""
        {"data":[0,0,3,0,0, 0,4,5,1,0, 1,0,2,2,1]}
        """#
        try assertRoundtrip(SemanticTokens.self, json: json)
    }

    func test_semanticTokens_withResultId_roundtrip() throws {
        let json = #"""
        {"data":[0,0,3,0,0],"resultId":"r-1"}
        """#
        try assertRoundtrip(SemanticTokens.self, json: json)
    }

    func test_semanticTokens_emptyData_roundtrip() throws {
        let json = #"""
        {"data":[]}
        """#
        try assertRoundtrip(SemanticTokens.self, json: json)
    }

    func test_semanticTokens_decodesIntegerData() throws {
        let json = #"""
        {"data":[1,2,3,4,5,6,7,8,9,10],"resultId":"abc"}
        """#
        let decoded = try decoder.decode(SemanticTokens.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.resultId, "abc")
        XCTAssertEqual(decoded.data, [1, 2, 3, 4, 5, 6, 7, 8, 9, 10])
    }

    // ====================================================================
    // MARK: - SemanticTokensEdit
    // Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#semanticTokensEdit
    // ====================================================================

    func test_semanticTokensEdit_minimal_roundtrip() throws {
        // Delete only — no data array.
        let json = #"""
        {"deleteCount":5,"start":0}
        """#
        try assertRoundtrip(SemanticTokensEdit.self, json: json)
    }

    func test_semanticTokensEdit_withData_roundtrip() throws {
        let json = #"""
        {"data":[0,1,2,3,4],"deleteCount":3,"start":10}
        """#
        try assertRoundtrip(SemanticTokensEdit.self, json: json)
    }

    // ====================================================================
    // MARK: - SemanticTokensDelta
    // Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#semanticTokensDelta
    // ====================================================================

    func test_semanticTokensDelta_minimal_roundtrip() throws {
        let json = #"""
        {"edits":[]}
        """#
        try assertRoundtrip(SemanticTokensDelta.self, json: json)
    }

    func test_semanticTokensDelta_withResultIdAndEdits_roundtrip() throws {
        let json = #"""
        {
          "edits":[
            {"data":[0,1,2,3,4],"deleteCount":2,"start":0},
            {"deleteCount":1,"start":15}
          ],
          "resultId":"delta-7"
        }
        """#
        try assertRoundtrip(SemanticTokensDelta.self, json: json)
    }

    // ====================================================================
    // MARK: - SemanticTokensDeltaResult
    // Union: SemanticTokens | SemanticTokensDelta
    // Discriminator: presence of `edits` key => delta, else full.
    // ====================================================================

    func test_semanticTokensDeltaResult_full_decodes() throws {
        let json = #"""
        {"data":[0,0,3,0,0],"resultId":"r-1"}
        """#
        let decoded = try decoder.decode(SemanticTokensDeltaResult.self, from: Data(json.utf8))
        switch decoded {
        case .full(let t):
            XCTAssertEqual(t.resultId, "r-1")
            XCTAssertEqual(t.data, [0, 0, 3, 0, 0])
        case .delta:
            XCTFail("Expected .full case for JSON containing data array")
        }
    }

    func test_semanticTokensDeltaResult_delta_decodes() throws {
        let json = #"""
        {"edits":[{"deleteCount":2,"start":0}],"resultId":"r-2"}
        """#
        let decoded = try decoder.decode(SemanticTokensDeltaResult.self, from: Data(json.utf8))
        switch decoded {
        case .full:
            XCTFail("Expected .delta case for JSON containing edits array")
        case .delta(let d):
            XCTAssertEqual(d.resultId, "r-2")
            XCTAssertEqual(d.edits.count, 1)
            XCTAssertEqual(d.edits[0].start, 0)
            XCTAssertEqual(d.edits[0].deleteCount, 2)
        }
    }

    func test_semanticTokensDeltaResult_full_roundtrip() throws {
        let json = #"""
        {"data":[1,2,3,4,5],"resultId":"r-3"}
        """#
        try assertRoundtrip(SemanticTokensDeltaResult.self, json: json)
    }

    func test_semanticTokensDeltaResult_delta_roundtrip() throws {
        let json = #"""
        {"edits":[{"data":[1,1,1,1,1],"deleteCount":0,"start":5}],"resultId":"r-4"}
        """#
        try assertRoundtrip(SemanticTokensDeltaResult.self, json: json)
    }

    // ====================================================================
    // MARK: - InlayHintParams
    // Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocument_inlayHint
    // ====================================================================

    func test_inlayHintParams_minimal_roundtrip() throws {
        let json = #"""
        {
          "range":{"end":{"character":0,"line":20},"start":{"character":0,"line":0}},
          "textDocument":{"uri":"file:///tmp/ih.swift"}
        }
        """#
        try assertRoundtrip(InlayHintParams.self, json: json)
    }

    func test_inlayHintParams_withWorkDoneToken_roundtrip() throws {
        let json = #"""
        {
          "range":{"end":{"character":0,"line":20},"start":{"character":0,"line":0}},
          "textDocument":{"uri":"file:///tmp/ih.swift"},
          "workDoneToken":"hint-1"
        }
        """#
        try assertRoundtrip(InlayHintParams.self, json: json)
    }

    // ====================================================================
    // MARK: - InlayHintKind
    // Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#inlayHintKind
    // ====================================================================

    func test_inlayHintKind_typeEncoding() throws {
        let data = try encoder.encode(InlayHintKind.type)
        XCTAssertEqual(String(data: data, encoding: .utf8), "1")
    }

    func test_inlayHintKind_parameterEncoding() throws {
        let data = try encoder.encode(InlayHintKind.parameter)
        XCTAssertEqual(String(data: data, encoding: .utf8), "2")
    }

    func test_inlayHintKind_decoding() throws {
        let type = try decoder.decode(InlayHintKind.self, from: Data("1".utf8))
        let param = try decoder.decode(InlayHintKind.self, from: Data("2".utf8))
        XCTAssertEqual(type, .type)
        XCTAssertEqual(param, .parameter)
    }

    // ====================================================================
    // MARK: - InlayHintLabelPart
    // Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#inlayHintLabelPart
    // ====================================================================

    func test_inlayHintLabelPart_minimal_roundtrip() throws {
        let json = #"""
        {"value":": Int"}
        """#
        try assertRoundtrip(InlayHintLabelPart.self, json: json)
    }

    func test_inlayHintLabelPart_full_roundtrip() throws {
        let json = #"""
        {
          "command":{"command":"calyx.gotoDef","title":"Go to Definition"},
          "location":{
            "range":{"end":{"character":3,"line":2},"start":{"character":0,"line":2}},
            "uri":"file:///tmp/ih.swift"
          },
          "tooltip":{"kind":"markdown","value":"**Int**"},
          "value":"Int"
        }
        """#
        try assertRoundtrip(InlayHintLabelPart.self, json: json)
    }

    func test_inlayHintLabelPart_stringTooltip_roundtrip() throws {
        let json = #"""
        {"tooltip":"plain","value":"x"}
        """#
        try assertRoundtrip(InlayHintLabelPart.self, json: json)
    }

    // ====================================================================
    // MARK: - InlayHintLabel union
    // Spec: label is either a `String` or `InlayHintLabelPart[]`.
    // ====================================================================

    func test_inlayHintLabel_string_decodes() throws {
        let json = #"""
        ": Int"
        """#
        let decoded = try decoder.decode(InlayHintLabel.self, from: Data(json.utf8))
        switch decoded {
        case .string(let s):
            XCTAssertEqual(s, ": Int")
        case .parts:
            XCTFail("Expected .string case for plain string label")
        }
    }

    func test_inlayHintLabel_parts_decodes() throws {
        let json = #"""
        [{"value":": "},{"value":"Int"}]
        """#
        let decoded = try decoder.decode(InlayHintLabel.self, from: Data(json.utf8))
        switch decoded {
        case .string:
            XCTFail("Expected .parts case for array label")
        case .parts(let parts):
            XCTAssertEqual(parts.count, 2)
            XCTAssertEqual(parts[0].value, ": ")
            XCTAssertEqual(parts[1].value, "Int")
        }
    }

    func test_inlayHintLabel_string_encodes_asString() throws {
        let label: InlayHintLabel = .string(": Int")
        let data = try encoder.encode(label)
        XCTAssertEqual(String(data: data, encoding: .utf8), "\": Int\"")
    }

    func test_inlayHintLabel_parts_encodes_asArray() throws {
        let label: InlayHintLabel = .parts([
            InlayHintLabelPart(value: ": ", tooltip: nil, location: nil, command: nil),
            InlayHintLabelPart(value: "Int", tooltip: nil, location: nil, command: nil)
        ])
        let data = try encoder.encode(label)
        let parsed = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        XCTAssertEqual(parsed?.count, 2)
        XCTAssertEqual(parsed?[0]["value"] as? String, ": ")
        XCTAssertEqual(parsed?[1]["value"] as? String, "Int")
    }

    // ====================================================================
    // MARK: - InlayHint
    // Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#inlayHint
    // ====================================================================

    func test_inlayHint_minimalString_roundtrip() throws {
        let json = #"""
        {"label":": Int","position":{"character":7,"line":3}}
        """#
        try assertRoundtrip(InlayHint.self, json: json)
    }

    func test_inlayHint_minimalParts_roundtrip() throws {
        let json = #"""
        {
          "label":[{"value":": "},{"value":"Int"}],
          "position":{"character":7,"line":3}
        }
        """#
        try assertRoundtrip(InlayHint.self, json: json)
    }

    func test_inlayHint_full_roundtrip() throws {
        // Exercise every optional field. `data` carries an opaque JSON object.
        let json = ##"""
        {
          "data":{"id":"hint-7"},
          "kind":1,
          "label":[
            {"location":{"range":{"end":{"character":3,"line":0},"start":{"character":0,"line":0}},"uri":"file:///tmp/ih.swift"},"value":"Int"}
          ],
          "paddingLeft":true,
          "paddingRight":false,
          "position":{"character":7,"line":3},
          "textEdits":[
            {"newText":": Int","range":{"end":{"character":7,"line":3},"start":{"character":7,"line":3}}}
          ],
          "tooltip":{"kind":"markdown","value":"**Type:** `Int`"}
        }
        """##
        try assertRoundtrip(InlayHint.self, json: json)
    }

    func test_inlayHint_directConstruction_minimal() {
        let hint = InlayHint(
            position: Position(line: 3, character: 7),
            label: .string(": Int"),
            kind: nil,
            textEdits: nil,
            tooltip: nil,
            paddingLeft: nil,
            paddingRight: nil,
            data: nil
        )
        XCTAssertEqual(hint.position.line, 3)
        XCTAssertEqual(hint.position.character, 7)
        if case .string(let s) = hint.label {
            XCTAssertEqual(s, ": Int")
        } else {
            XCTFail("Expected .string label")
        }
        XCTAssertNil(hint.kind)
        XCTAssertNil(hint.textEdits)
    }

    // ====================================================================
    // MARK: - InlineValueContext / InlineValueParams
    // Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocument_inlineValue
    // ====================================================================

    func test_inlineValueContext_roundtrip() throws {
        let json = #"""
        {
          "frameId":7,
          "stoppedLocation":{"end":{"character":0,"line":12},"start":{"character":0,"line":10}}
        }
        """#
        try assertRoundtrip(InlineValueContext.self, json: json)
    }

    func test_inlineValueParams_minimal_roundtrip() throws {
        let json = #"""
        {
          "context":{
            "frameId":1,
            "stoppedLocation":{"end":{"character":0,"line":5},"start":{"character":0,"line":4}}
          },
          "range":{"end":{"character":0,"line":20},"start":{"character":0,"line":0}},
          "textDocument":{"uri":"file:///tmp/iv.swift"}
        }
        """#
        try assertRoundtrip(InlineValueParams.self, json: json)
    }

    func test_inlineValueParams_withWorkDoneToken_roundtrip() throws {
        let json = #"""
        {
          "context":{
            "frameId":1,
            "stoppedLocation":{"end":{"character":0,"line":5},"start":{"character":0,"line":4}}
          },
          "range":{"end":{"character":0,"line":20},"start":{"character":0,"line":0}},
          "textDocument":{"uri":"file:///tmp/iv.swift"},
          "workDoneToken":99
        }
        """#
        try assertRoundtrip(InlineValueParams.self, json: json)
    }

    // ====================================================================
    // MARK: - InlineValueText / VariableLookup / EvaluatableExpression
    // ====================================================================

    func test_inlineValueText_roundtrip() throws {
        let json = #"""
        {
          "range":{"end":{"character":10,"line":3},"start":{"character":0,"line":3}},
          "text":"x = 42"
        }
        """#
        try assertRoundtrip(InlineValueText.self, json: json)
    }

    func test_inlineValueVariableLookup_minimal_roundtrip() throws {
        let json = #"""
        {
          "caseSensitiveLookup":true,
          "range":{"end":{"character":4,"line":3},"start":{"character":0,"line":3}}
        }
        """#
        try assertRoundtrip(InlineValueVariableLookup.self, json: json)
    }

    func test_inlineValueVariableLookup_withName_roundtrip() throws {
        let json = #"""
        {
          "caseSensitiveLookup":false,
          "range":{"end":{"character":4,"line":3},"start":{"character":0,"line":3}},
          "variableName":"counter"
        }
        """#
        try assertRoundtrip(InlineValueVariableLookup.self, json: json)
    }

    func test_inlineValueEvaluatableExpression_minimal_roundtrip() throws {
        let json = #"""
        {"range":{"end":{"character":4,"line":3},"start":{"character":0,"line":3}}}
        """#
        try assertRoundtrip(InlineValueEvaluatableExpression.self, json: json)
    }

    func test_inlineValueEvaluatableExpression_withExpression_roundtrip() throws {
        let json = #"""
        {
          "expression":"a + b",
          "range":{"end":{"character":5,"line":3},"start":{"character":0,"line":3}}
        }
        """#
        try assertRoundtrip(InlineValueEvaluatableExpression.self, json: json)
    }

    // ====================================================================
    // MARK: - InlineValue union
    // Spec discriminator:
    //   - `text` key present                -> InlineValueText
    //   - `caseSensitiveLookup` key present -> InlineValueVariableLookup
    //   - otherwise                         -> InlineValueEvaluatableExpression
    // ====================================================================

    func test_inlineValue_text_decodes() throws {
        let json = #"""
        {
          "range":{"end":{"character":10,"line":3},"start":{"character":0,"line":3}},
          "text":"x = 42"
        }
        """#
        let decoded = try decoder.decode(InlineValue.self, from: Data(json.utf8))
        guard case .text(let t) = decoded else {
            XCTFail("Expected .text case")
            return
        }
        XCTAssertEqual(t.text, "x = 42")
    }

    func test_inlineValue_variableLookup_decodes() throws {
        let json = #"""
        {
          "caseSensitiveLookup":true,
          "range":{"end":{"character":4,"line":3},"start":{"character":0,"line":3}},
          "variableName":"counter"
        }
        """#
        let decoded = try decoder.decode(InlineValue.self, from: Data(json.utf8))
        guard case .variableLookup(let v) = decoded else {
            XCTFail("Expected .variableLookup case")
            return
        }
        XCTAssertEqual(v.variableName, "counter")
        XCTAssertTrue(v.caseSensitiveLookup)
    }

    func test_inlineValue_evaluatableExpression_decodes() throws {
        let json = #"""
        {
          "expression":"a + b",
          "range":{"end":{"character":5,"line":3},"start":{"character":0,"line":3}}
        }
        """#
        let decoded = try decoder.decode(InlineValue.self, from: Data(json.utf8))
        guard case .evaluatableExpression(let e) = decoded else {
            XCTFail("Expected .evaluatableExpression case")
            return
        }
        XCTAssertEqual(e.expression, "a + b")
    }

    func test_inlineValue_evaluatableExpression_minimal_decodes() throws {
        // No `text`, no `caseSensitiveLookup`, no `expression` -> still evaluatableExpression.
        let json = #"""
        {"range":{"end":{"character":5,"line":3},"start":{"character":0,"line":3}}}
        """#
        let decoded = try decoder.decode(InlineValue.self, from: Data(json.utf8))
        guard case .evaluatableExpression(let e) = decoded else {
            XCTFail("Expected .evaluatableExpression case for range-only payload")
            return
        }
        XCTAssertNil(e.expression)
    }

    func test_inlineValue_text_roundtrip() throws {
        let json = #"""
        {
          "range":{"end":{"character":10,"line":3},"start":{"character":0,"line":3}},
          "text":"x = 42"
        }
        """#
        try assertRoundtrip(InlineValue.self, json: json)
    }

    func test_inlineValue_variableLookup_roundtrip() throws {
        let json = #"""
        {
          "caseSensitiveLookup":false,
          "range":{"end":{"character":4,"line":3},"start":{"character":0,"line":3}},
          "variableName":"foo"
        }
        """#
        try assertRoundtrip(InlineValue.self, json: json)
    }

    // ====================================================================
    // MARK: - DocumentColorParams
    // Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocument_documentColor
    // ====================================================================

    func test_documentColorParams_minimal_roundtrip() throws {
        let json = #"""
        {"textDocument":{"uri":"file:///tmp/c.css"}}
        """#
        try assertRoundtrip(DocumentColorParams.self, json: json)
    }

    func test_documentColorParams_withBothTokens_roundtrip() throws {
        let json = #"""
        {
          "partialResultToken":"dc-part",
          "textDocument":{"uri":"file:///tmp/c.css"},
          "workDoneToken":11
        }
        """#
        try assertRoundtrip(DocumentColorParams.self, json: json)
    }

    // ====================================================================
    // MARK: - LSPColor
    // Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#color
    // Named LSPColor to avoid SwiftUI.Color clash.
    // ====================================================================

    func test_lspColor_roundtrip() throws {
        let json = #"""
        {"alpha":1,"blue":0.25,"green":0.5,"red":0.75}
        """#
        try assertRoundtrip(LSPColor.self, json: json)
    }

    func test_lspColor_directConstruction() {
        let c = LSPColor(red: 0.1, green: 0.2, blue: 0.3, alpha: 0.4)
        XCTAssertEqual(c.red, 0.1, accuracy: 1e-9)
        XCTAssertEqual(c.green, 0.2, accuracy: 1e-9)
        XCTAssertEqual(c.blue, 0.3, accuracy: 1e-9)
        XCTAssertEqual(c.alpha, 0.4, accuracy: 1e-9)
    }

    // ====================================================================
    // MARK: - ColorInformation
    // Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#colorInformation
    // ====================================================================

    func test_colorInformation_roundtrip() throws {
        let json = #"""
        {
          "color":{"alpha":1,"blue":0,"green":0.5,"red":1},
          "range":{"end":{"character":15,"line":4},"start":{"character":7,"line":4}}
        }
        """#
        try assertRoundtrip(ColorInformation.self, json: json)
    }

    // ====================================================================
    // MARK: - ColorPresentationParams
    // Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocument_colorPresentation
    // ====================================================================

    func test_colorPresentationParams_minimal_roundtrip() throws {
        let json = #"""
        {
          "color":{"alpha":1,"blue":0,"green":0,"red":1},
          "range":{"end":{"character":10,"line":2},"start":{"character":0,"line":2}},
          "textDocument":{"uri":"file:///tmp/c.css"}
        }
        """#
        try assertRoundtrip(ColorPresentationParams.self, json: json)
    }

    func test_colorPresentationParams_withTokens_roundtrip() throws {
        let json = #"""
        {
          "color":{"alpha":1,"blue":0,"green":0,"red":1},
          "partialResultToken":"cp-part",
          "range":{"end":{"character":10,"line":2},"start":{"character":0,"line":2}},
          "textDocument":{"uri":"file:///tmp/c.css"},
          "workDoneToken":5
        }
        """#
        try assertRoundtrip(ColorPresentationParams.self, json: json)
    }

    // ====================================================================
    // MARK: - ColorPresentation
    // Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#colorPresentation
    // ====================================================================

    func test_colorPresentation_minimal_roundtrip() throws {
        let json = #"""
        {"label":"#ff0000"}
        """#
        try assertRoundtrip(ColorPresentation.self, json: json)
    }

    func test_colorPresentation_full_roundtrip() throws {
        let json = #"""
        {
          "additionalTextEdits":[
            {"newText":"  ","range":{"end":{"character":2,"line":3},"start":{"character":0,"line":3}}}
          ],
          "label":"rgb(255, 0, 0)",
          "textEdit":{"newText":"rgb(255, 0, 0)","range":{"end":{"character":7,"line":4},"start":{"character":0,"line":4}}}
        }
        """#
        try assertRoundtrip(ColorPresentation.self, json: json)
    }

    // ====================================================================
    // MARK: - Equatable sanity
    // ====================================================================

    func test_semanticTokens_equatable() {
        let a = SemanticTokens(resultId: "r-1", data: [1, 2, 3])
        let b = SemanticTokens(resultId: "r-1", data: [1, 2, 3])
        let c = SemanticTokens(resultId: "r-2", data: [1, 2, 3])
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    func test_lspColor_equatable() {
        let a = LSPColor(red: 1, green: 0, blue: 0, alpha: 1)
        let b = LSPColor(red: 1, green: 0, blue: 0, alpha: 1)
        let c = LSPColor(red: 0, green: 1, blue: 0, alpha: 1)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    func test_inlayHintKind_equatable() {
        XCTAssertEqual(InlayHintKind.type, InlayHintKind.type)
        XCTAssertNotEqual(InlayHintKind.type, InlayHintKind.parameter)
    }
}
