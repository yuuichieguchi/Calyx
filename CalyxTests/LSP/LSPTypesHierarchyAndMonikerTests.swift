//
//  LSPTypesHierarchyAndMonikerTests.swift
//  Calyx
//
//  Round-trip Codable tests for LSP 3.18 hierarchy / tracking feature types:
//
//    Call hierarchy   (textDocument/prepareCallHierarchy,
//                      callHierarchy/incomingCalls,
//                      callHierarchy/outgoingCalls)
//      - CallHierarchyPrepareParams
//      - CallHierarchyItem
//      - CallHierarchyIncomingCallsParams / CallHierarchyIncomingCall
//      - CallHierarchyOutgoingCallsParams / CallHierarchyOutgoingCall
//
//    Type hierarchy   (textDocument/prepareTypeHierarchy,
//                      typeHierarchy/supertypes,
//                      typeHierarchy/subtypes)
//      - TypeHierarchyPrepareParams
//      - TypeHierarchyItem
//      - TypeHierarchySupertypesParams
//      - TypeHierarchySubtypesParams
//
//    Moniker          (textDocument/moniker)
//      - MonikerParams
//      - UniquenessLevel / MonikerKind
//      - Moniker
//
//    LinkedEditingRange (textDocument/linkedEditingRange)
//      - LinkedEditingRangeParams
//      - LinkedEditingRanges
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
//    - SymbolKind / SymbolTag
//    - AnyCodable
//

import XCTest
@testable import Calyx

@MainActor
final class LSPTypesHierarchyAndMonikerTests: XCTestCase {

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
    // MARK: - CallHierarchyPrepareParams
    // Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocument_prepareCallHierarchy
    // ====================================================================

    func test_callHierarchyPrepareParams_minimal_roundtrip() throws {
        let json = #"""
        {"position":{"character":4,"line":10},"textDocument":{"uri":"file:///tmp/ch.swift"}}
        """#
        try assertRoundtrip(CallHierarchyPrepareParams.self, json: json)
    }

    func test_callHierarchyPrepareParams_withWorkDoneToken_string_roundtrip() throws {
        let json = #"""
        {"position":{"character":4,"line":10},"textDocument":{"uri":"file:///tmp/ch.swift"},"workDoneToken":"prep-1"}
        """#
        try assertRoundtrip(CallHierarchyPrepareParams.self, json: json)
    }

    func test_callHierarchyPrepareParams_withWorkDoneToken_int_roundtrip() throws {
        let json = #"""
        {"position":{"character":4,"line":10},"textDocument":{"uri":"file:///tmp/ch.swift"},"workDoneToken":99}
        """#
        try assertRoundtrip(CallHierarchyPrepareParams.self, json: json)
    }

    // ====================================================================
    // MARK: - CallHierarchyItem
    // Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#callHierarchyItem
    // ====================================================================

    func test_callHierarchyItem_minimal_roundtrip() throws {
        let json = #"""
        {
          "kind":12,
          "name":"foo",
          "range":{"end":{"character":3,"line":2},"start":{"character":0,"line":2}},
          "selectionRange":{"end":{"character":3,"line":2},"start":{"character":0,"line":2}},
          "uri":"file:///tmp/ch.swift"
        }
        """#
        try assertRoundtrip(CallHierarchyItem.self, json: json)
    }

    func test_callHierarchyItem_full_roundtrip() throws {
        // Exercise every optional field together, including the opaque `data` blob.
        let json = ##"""
        {
          "data":{"id":"item-1","nested":{"k":1}},
          "detail":"(a: Int) -> Void",
          "kind":6,
          "name":"run",
          "range":{"end":{"character":1,"line":5},"start":{"character":4,"line":2}},
          "selectionRange":{"end":{"character":9,"line":2},"start":{"character":8,"line":2}},
          "tags":[1],
          "uri":"file:///tmp/ch.swift"
        }
        """##
        try assertRoundtrip(CallHierarchyItem.self, json: json)
    }

    func test_callHierarchyItem_directConstruction_minimal() {
        let item = CallHierarchyItem(
            name: "foo",
            kind: .function,
            tags: nil,
            detail: nil,
            uri: "file:///tmp/ch.swift",
            range: LSPRange(
                start: Position(line: 2, character: 0),
                end: Position(line: 2, character: 3)
            ),
            selectionRange: LSPRange(
                start: Position(line: 2, character: 0),
                end: Position(line: 2, character: 3)
            ),
            data: nil
        )
        XCTAssertEqual(item.name, "foo")
        XCTAssertEqual(item.kind, .function)
        XCTAssertNil(item.tags)
        XCTAssertNil(item.detail)
        XCTAssertNil(item.data)
    }

    // ====================================================================
    // MARK: - CallHierarchyIncomingCallsParams / CallHierarchyIncomingCall
    // Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#callHierarchy_incomingCalls
    // ====================================================================

    func test_callHierarchyIncomingCallsParams_minimal_roundtrip() throws {
        let json = #"""
        {
          "item":{
            "kind":12,
            "name":"foo",
            "range":{"end":{"character":3,"line":2},"start":{"character":0,"line":2}},
            "selectionRange":{"end":{"character":3,"line":2},"start":{"character":0,"line":2}},
            "uri":"file:///tmp/ch.swift"
          }
        }
        """#
        try assertRoundtrip(CallHierarchyIncomingCallsParams.self, json: json)
    }

    func test_callHierarchyIncomingCallsParams_withTokens_roundtrip() throws {
        let json = #"""
        {
          "item":{
            "kind":12,
            "name":"foo",
            "range":{"end":{"character":3,"line":2},"start":{"character":0,"line":2}},
            "selectionRange":{"end":{"character":3,"line":2},"start":{"character":0,"line":2}},
            "uri":"file:///tmp/ch.swift"
          },
          "partialResultToken":"in-part",
          "workDoneToken":7
        }
        """#
        try assertRoundtrip(CallHierarchyIncomingCallsParams.self, json: json)
    }

    func test_callHierarchyIncomingCall_minimal_roundtrip() throws {
        let json = #"""
        {
          "from":{
            "kind":12,
            "name":"caller",
            "range":{"end":{"character":1,"line":9},"start":{"character":0,"line":5}},
            "selectionRange":{"end":{"character":6,"line":5},"start":{"character":0,"line":5}},
            "uri":"file:///tmp/a.swift"
          },
          "fromRanges":[
            {"end":{"character":7,"line":7},"start":{"character":4,"line":7}}
          ]
        }
        """#
        try assertRoundtrip(CallHierarchyIncomingCall.self, json: json)
    }

    func test_callHierarchyIncomingCall_multipleFromRanges_roundtrip() throws {
        let json = #"""
        {
          "from":{
            "kind":12,
            "name":"caller",
            "range":{"end":{"character":1,"line":9},"start":{"character":0,"line":5}},
            "selectionRange":{"end":{"character":6,"line":5},"start":{"character":0,"line":5}},
            "uri":"file:///tmp/a.swift"
          },
          "fromRanges":[
            {"end":{"character":7,"line":7},"start":{"character":4,"line":7}},
            {"end":{"character":7,"line":8},"start":{"character":4,"line":8}},
            {"end":{"character":7,"line":9},"start":{"character":4,"line":9}}
          ]
        }
        """#
        let decoded = try decoder.decode(CallHierarchyIncomingCall.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.fromRanges.count, 3)
        XCTAssertEqual(decoded.fromRanges[0].start.line, 7)
        XCTAssertEqual(decoded.fromRanges[2].start.line, 9)
        XCTAssertEqual(decoded.from.name, "caller")
    }

    // ====================================================================
    // MARK: - CallHierarchyOutgoingCallsParams / CallHierarchyOutgoingCall
    // Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#callHierarchy_outgoingCalls
    // ====================================================================

    func test_callHierarchyOutgoingCallsParams_withTokens_roundtrip() throws {
        let json = #"""
        {
          "item":{
            "kind":12,
            "name":"foo",
            "range":{"end":{"character":3,"line":2},"start":{"character":0,"line":2}},
            "selectionRange":{"end":{"character":3,"line":2},"start":{"character":0,"line":2}},
            "uri":"file:///tmp/ch.swift"
          },
          "partialResultToken":12,
          "workDoneToken":"out-1"
        }
        """#
        try assertRoundtrip(CallHierarchyOutgoingCallsParams.self, json: json)
    }

    func test_callHierarchyOutgoingCall_minimal_roundtrip() throws {
        let json = #"""
        {
          "fromRanges":[
            {"end":{"character":12,"line":3},"start":{"character":8,"line":3}}
          ],
          "to":{
            "kind":12,
            "name":"callee",
            "range":{"end":{"character":3,"line":2},"start":{"character":0,"line":2}},
            "selectionRange":{"end":{"character":3,"line":2},"start":{"character":0,"line":2}},
            "uri":"file:///tmp/b.swift"
          }
        }
        """#
        try assertRoundtrip(CallHierarchyOutgoingCall.self, json: json)
    }

    func test_callHierarchyOutgoingCall_fromRangesContents() throws {
        let json = #"""
        {
          "fromRanges":[
            {"end":{"character":12,"line":3},"start":{"character":8,"line":3}},
            {"end":{"character":20,"line":4},"start":{"character":16,"line":4}}
          ],
          "to":{
            "kind":12,
            "name":"callee",
            "range":{"end":{"character":3,"line":2},"start":{"character":0,"line":2}},
            "selectionRange":{"end":{"character":3,"line":2},"start":{"character":0,"line":2}},
            "uri":"file:///tmp/b.swift"
          }
        }
        """#
        let decoded = try decoder.decode(CallHierarchyOutgoingCall.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.to.name, "callee")
        XCTAssertEqual(decoded.fromRanges.count, 2)
        XCTAssertEqual(decoded.fromRanges[0].start.character, 8)
        XCTAssertEqual(decoded.fromRanges[1].end.character, 20)
    }

    // ====================================================================
    // MARK: - TypeHierarchyPrepareParams
    // Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocument_prepareTypeHierarchy
    // ====================================================================

    func test_typeHierarchyPrepareParams_minimal_roundtrip() throws {
        let json = #"""
        {"position":{"character":4,"line":10},"textDocument":{"uri":"file:///tmp/th.swift"}}
        """#
        try assertRoundtrip(TypeHierarchyPrepareParams.self, json: json)
    }

    func test_typeHierarchyPrepareParams_withWorkDoneToken_roundtrip() throws {
        let json = #"""
        {"position":{"character":4,"line":10},"textDocument":{"uri":"file:///tmp/th.swift"},"workDoneToken":"th-prep"}
        """#
        try assertRoundtrip(TypeHierarchyPrepareParams.self, json: json)
    }

    // ====================================================================
    // MARK: - TypeHierarchyItem
    // Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#typeHierarchyItem
    // ====================================================================

    func test_typeHierarchyItem_minimal_roundtrip() throws {
        let json = #"""
        {
          "kind":5,
          "name":"Foo",
          "range":{"end":{"character":3,"line":2},"start":{"character":0,"line":2}},
          "selectionRange":{"end":{"character":3,"line":2},"start":{"character":0,"line":2}},
          "uri":"file:///tmp/th.swift"
        }
        """#
        try assertRoundtrip(TypeHierarchyItem.self, json: json)
    }

    func test_typeHierarchyItem_full_roundtrip() throws {
        let json = ##"""
        {
          "data":{"resolveId":"abc"},
          "detail":"class Foo: Bar",
          "kind":5,
          "name":"Foo",
          "range":{"end":{"character":1,"line":9},"start":{"character":0,"line":1}},
          "selectionRange":{"end":{"character":9,"line":1},"start":{"character":6,"line":1}},
          "tags":[1],
          "uri":"file:///tmp/th.swift"
        }
        """##
        try assertRoundtrip(TypeHierarchyItem.self, json: json)
    }

    func test_typeHierarchyItem_directConstruction_minimal() {
        let item = TypeHierarchyItem(
            name: "Foo",
            kind: .class,
            tags: nil,
            detail: nil,
            uri: "file:///tmp/th.swift",
            range: LSPRange(
                start: Position(line: 2, character: 0),
                end: Position(line: 2, character: 3)
            ),
            selectionRange: LSPRange(
                start: Position(line: 2, character: 0),
                end: Position(line: 2, character: 3)
            ),
            data: nil
        )
        XCTAssertEqual(item.name, "Foo")
        XCTAssertEqual(item.kind, .class)
        XCTAssertNil(item.detail)
    }

    // ====================================================================
    // MARK: - TypeHierarchySupertypesParams / TypeHierarchySubtypesParams
    // Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#typeHierarchy_supertypes
    //       https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#typeHierarchy_subtypes
    // ====================================================================

    func test_typeHierarchySupertypesParams_minimal_roundtrip() throws {
        let json = #"""
        {
          "item":{
            "kind":5,
            "name":"Foo",
            "range":{"end":{"character":3,"line":2},"start":{"character":0,"line":2}},
            "selectionRange":{"end":{"character":3,"line":2},"start":{"character":0,"line":2}},
            "uri":"file:///tmp/th.swift"
          }
        }
        """#
        try assertRoundtrip(TypeHierarchySupertypesParams.self, json: json)
    }

    func test_typeHierarchySupertypesParams_withTokens_roundtrip() throws {
        let json = #"""
        {
          "item":{
            "kind":5,
            "name":"Foo",
            "range":{"end":{"character":3,"line":2},"start":{"character":0,"line":2}},
            "selectionRange":{"end":{"character":3,"line":2},"start":{"character":0,"line":2}},
            "uri":"file:///tmp/th.swift"
          },
          "partialResultToken":"sup-part",
          "workDoneToken":3
        }
        """#
        try assertRoundtrip(TypeHierarchySupertypesParams.self, json: json)
    }

    func test_typeHierarchySubtypesParams_minimal_roundtrip() throws {
        let json = #"""
        {
          "item":{
            "kind":5,
            "name":"Foo",
            "range":{"end":{"character":3,"line":2},"start":{"character":0,"line":2}},
            "selectionRange":{"end":{"character":3,"line":2},"start":{"character":0,"line":2}},
            "uri":"file:///tmp/th.swift"
          }
        }
        """#
        try assertRoundtrip(TypeHierarchySubtypesParams.self, json: json)
    }

    func test_typeHierarchySubtypesParams_withTokens_roundtrip() throws {
        let json = #"""
        {
          "item":{
            "kind":5,
            "name":"Foo",
            "range":{"end":{"character":3,"line":2},"start":{"character":0,"line":2}},
            "selectionRange":{"end":{"character":3,"line":2},"start":{"character":0,"line":2}},
            "uri":"file:///tmp/th.swift"
          },
          "partialResultToken":42,
          "workDoneToken":"sub-1"
        }
        """#
        try assertRoundtrip(TypeHierarchySubtypesParams.self, json: json)
    }

    // ====================================================================
    // MARK: - UniquenessLevel (string enum)
    // Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#uniquenessLevel
    // ====================================================================

    func test_uniquenessLevel_rawValues_allFive() {
        XCTAssertEqual(UniquenessLevel.document.rawValue, "document")
        XCTAssertEqual(UniquenessLevel.project.rawValue, "project")
        XCTAssertEqual(UniquenessLevel.group.rawValue, "group")
        XCTAssertEqual(UniquenessLevel.scheme.rawValue, "scheme")
        XCTAssertEqual(UniquenessLevel.global.rawValue, "global")
    }

    func test_uniquenessLevel_roundtrip_allValues() throws {
        for value in [
            UniquenessLevel.document,
            .project,
            .group,
            .scheme,
            .global
        ] {
            let data = try encoder.encode(value)
            let decoded = try decoder.decode(UniquenessLevel.self, from: data)
            XCTAssertEqual(decoded, value)
        }
    }

    func test_uniquenessLevel_decodesFromQuotedString_global() throws {
        let data = Data("\"global\"".utf8)
        let decoded = try decoder.decode(UniquenessLevel.self, from: data)
        XCTAssertEqual(decoded, .global)
    }

    // ====================================================================
    // MARK: - MonikerKind (string enum, with reserved word `import`)
    // Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#monikerKind
    // ====================================================================

    func test_monikerKind_rawValues_allThree() {
        XCTAssertEqual(MonikerKind.import.rawValue, "import")
        XCTAssertEqual(MonikerKind.export.rawValue, "export")
        XCTAssertEqual(MonikerKind.local.rawValue, "local")
    }

    func test_monikerKind_roundtrip_import_reservedWord() throws {
        // The `import` case must encode/decode as the literal string "import"
        // despite Swift's reserved-word backticks at the source level.
        let value = MonikerKind.import
        let data = try encoder.encode(value)
        XCTAssertEqual(String(data: data, encoding: .utf8), "\"import\"")
        let decoded = try decoder.decode(MonikerKind.self, from: data)
        XCTAssertEqual(decoded, .import)
    }

    func test_monikerKind_roundtrip_export() throws {
        let data = try encoder.encode(MonikerKind.export)
        XCTAssertEqual(String(data: data, encoding: .utf8), "\"export\"")
        XCTAssertEqual(try decoder.decode(MonikerKind.self, from: data), .export)
    }

    func test_monikerKind_roundtrip_local() throws {
        let data = try encoder.encode(MonikerKind.local)
        XCTAssertEqual(String(data: data, encoding: .utf8), "\"local\"")
        XCTAssertEqual(try decoder.decode(MonikerKind.self, from: data), .local)
    }

    // ====================================================================
    // MARK: - MonikerParams
    // Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocument_moniker
    // ====================================================================

    func test_monikerParams_minimal_roundtrip() throws {
        let json = #"""
        {"position":{"character":4,"line":10},"textDocument":{"uri":"file:///tmp/m.swift"}}
        """#
        try assertRoundtrip(MonikerParams.self, json: json)
    }

    func test_monikerParams_withTokens_roundtrip() throws {
        let json = #"""
        {"partialResultToken":"mon-part","position":{"character":4,"line":10},"textDocument":{"uri":"file:///tmp/m.swift"},"workDoneToken":1}
        """#
        try assertRoundtrip(MonikerParams.self, json: json)
    }

    // ====================================================================
    // MARK: - Moniker
    // Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#moniker
    // ====================================================================

    func test_moniker_minimal_roundtrip() throws {
        let json = #"""
        {"identifier":"calyx::foo","scheme":"calyx","unique":"document"}
        """#
        try assertRoundtrip(Moniker.self, json: json)
    }

    func test_moniker_withKind_import_roundtrip() throws {
        let json = #"""
        {"identifier":"calyx::Bar","kind":"import","scheme":"calyx","unique":"global"}
        """#
        try assertRoundtrip(Moniker.self, json: json)
    }

    func test_moniker_withKind_export_roundtrip() throws {
        let json = #"""
        {"identifier":"calyx::Baz","kind":"export","scheme":"calyx","unique":"project"}
        """#
        try assertRoundtrip(Moniker.self, json: json)
    }

    func test_moniker_directConstruction_minimal() {
        let m = Moniker(
            scheme: "calyx",
            identifier: "calyx::foo",
            unique: .document,
            kind: nil
        )
        XCTAssertEqual(m.scheme, "calyx")
        XCTAssertEqual(m.identifier, "calyx::foo")
        XCTAssertEqual(m.unique, .document)
        XCTAssertNil(m.kind)
    }

    // ====================================================================
    // MARK: - LinkedEditingRangeParams
    // Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocument_linkedEditingRange
    // ====================================================================

    func test_linkedEditingRangeParams_minimal_roundtrip() throws {
        let json = #"""
        {"position":{"character":4,"line":10},"textDocument":{"uri":"file:///tmp/ler.swift"}}
        """#
        try assertRoundtrip(LinkedEditingRangeParams.self, json: json)
    }

    func test_linkedEditingRangeParams_withWorkDoneToken_roundtrip() throws {
        let json = #"""
        {"position":{"character":4,"line":10},"textDocument":{"uri":"file:///tmp/ler.swift"},"workDoneToken":"ler-1"}
        """#
        try assertRoundtrip(LinkedEditingRangeParams.self, json: json)
    }

    // ====================================================================
    // MARK: - LinkedEditingRanges
    // Spec: LinkedEditingRanges is the response of textDocument/linkedEditingRange.
    //       `wordPattern` is optional (server may omit it).
    // ====================================================================

    func test_linkedEditingRanges_withoutWordPattern_roundtrip() throws {
        let json = #"""
        {"ranges":[{"end":{"character":7,"line":2},"start":{"character":4,"line":2}}]}
        """#
        try assertRoundtrip(LinkedEditingRanges.self, json: json)
    }

    func test_linkedEditingRanges_withWordPattern_roundtrip() throws {
        let json = ##"""
        {
          "ranges":[
            {"end":{"character":7,"line":2},"start":{"character":4,"line":2}},
            {"end":{"character":7,"line":5},"start":{"character":4,"line":5}}
          ],
          "wordPattern":"[a-zA-Z_][a-zA-Z0-9_]*"
        }
        """##
        try assertRoundtrip(LinkedEditingRanges.self, json: json)
    }

    func test_linkedEditingRanges_emptyRanges_roundtrip() throws {
        let json = #"""
        {"ranges":[]}
        """#
        try assertRoundtrip(LinkedEditingRanges.self, json: json)
    }

    // ====================================================================
    // MARK: - Equatable sanity
    // ====================================================================

    func test_moniker_equatable() {
        let a = Moniker(scheme: "calyx", identifier: "x", unique: .global, kind: .export)
        let b = Moniker(scheme: "calyx", identifier: "x", unique: .global, kind: .export)
        let c = Moniker(scheme: "calyx", identifier: "y", unique: .global, kind: .export)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    func test_linkedEditingRanges_equatable() {
        let r = LSPRange(
            start: Position(line: 0, character: 0),
            end: Position(line: 0, character: 3)
        )
        let a = LinkedEditingRanges(ranges: [r], wordPattern: nil)
        let b = LinkedEditingRanges(ranges: [r], wordPattern: nil)
        let c = LinkedEditingRanges(ranges: [r], wordPattern: "[a-z]+")
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }
}
