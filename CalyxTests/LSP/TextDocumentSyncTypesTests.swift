//
//  TextDocumentSyncTypesTests.swift
//  Calyx
//
//  Round-trip Codable tests for the LSP 3.18 textDocument synchronization
//  parameter types.
//
//  Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocument_synchronization
//
//  Coverage (this file):
//    - DidOpenTextDocumentParams                  (1 round-trip)
//    - DidChangeTextDocumentParams +
//      TextDocumentContentChangeEvent             (3 round-trips: incremental,
//                                                  full, and union-array mix)
//    - DidCloseTextDocumentParams                 (1 round-trip)
//    - DidSaveTextDocumentParams                  (2 round-trips: with text,
//                                                  without text)
//
//  Total: 7 tests.
//
//  TDD phase: RED. None of the following types exist yet:
//    - DidOpenTextDocumentParams
//    - DidChangeTextDocumentParams
//    - TextDocumentContentChangeEvent
//    - DidCloseTextDocumentParams
//    - DidSaveTextDocumentParams
//
//  This file is expected to fail to compile until the swift-specialist
//  implements them under `Calyx/Features/LSP/LSPTypes/`.
//

import XCTest
@testable import Calyx

final class TextDocumentSyncTypesTests: XCTestCase {

    // MARK: - Helpers

    private let decoder = JSONDecoder()
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    /// Parse a JSON string literal into a Foundation object for semantic
    /// comparison.
    private func parse(_ json: String) throws -> Any {
        let data = Data(json.utf8)
        return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    /// Encode an Encodable value to a Foundation object.
    private func toJSONObject<T: Encodable>(_ value: T) throws -> Any {
        let data = try encoder.encode(value)
        return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    /// Decode `json` as `T`, re-encode, and assert semantic JSON equality.
    private func assertRoundtrip<T: Codable & Equatable>(
        _ type: T.Type,
        json: String,
        equals expected: T,
        file: StaticString = #file,
        line: UInt = #line
    ) throws {
        let data = Data(json.utf8)
        let decoded = try decoder.decode(T.self, from: data)
        XCTAssertEqual(decoded, expected, "decoded != expected", file: file, line: line)
        let reencoded = try toJSONObject(decoded) as AnyObject
        let original = try parse(json) as AnyObject
        XCTAssertTrue(
            reencoded.isEqual(original),
            "round-trip mismatch for \(T.self):\n  reencoded=\(reencoded)\n  original=\(original)",
            file: file, line: line
        )
    }

    // ====================================================================
    // MARK: - DidOpenTextDocumentParams
    // Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#didOpenTextDocumentParams
    // ====================================================================

    func test_didOpenTextDocumentParams_roundtrip() throws {
        let json = """
        {"textDocument":{"languageId":"swift","text":"import Foundation\\n","uri":"file:///tmp/a.swift","version":1}}
        """
        let expected = DidOpenTextDocumentParams(
            textDocument: TextDocumentItem(
                uri: "file:///tmp/a.swift",
                languageId: "swift",
                version: 1,
                text: "import Foundation\n"
            )
        )
        try assertRoundtrip(DidOpenTextDocumentParams.self, json: json, equals: expected)
    }

    // ====================================================================
    // MARK: - TextDocumentContentChangeEvent (incremental / full)
    // Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocumentContentChangeEvent
    // ====================================================================

    func test_didChangeTextDocumentParams_incrementalChange_roundtrip() throws {
        // Incremental change carries `range`, optional `rangeLength`, and `text`.
        let json = """
        {"contentChanges":[{"range":{"end":{"character":4,"line":0},"start":{"character":0,"line":0}},"rangeLength":4,"text":"let "}],"textDocument":{"uri":"file:///tmp/a.swift","version":2}}
        """
        let expected = DidChangeTextDocumentParams(
            textDocument: VersionedTextDocumentIdentifier(uri: "file:///tmp/a.swift", version: 2),
            contentChanges: [
                .incremental(
                    range: LSPRange(
                        start: Position(line: 0, character: 0),
                        end: Position(line: 0, character: 4)
                    ),
                    rangeLength: 4,
                    text: "let "
                )
            ]
        )
        try assertRoundtrip(DidChangeTextDocumentParams.self, json: json, equals: expected)
    }

    func test_didChangeTextDocumentParams_fullReplaceChange_roundtrip() throws {
        // Full-document replace: only `text` is present (no range, no rangeLength).
        let json = """
        {"contentChanges":[{"text":"// whole new file\\n"}],"textDocument":{"uri":"file:///tmp/b.swift","version":7}}
        """
        let expected = DidChangeTextDocumentParams(
            textDocument: VersionedTextDocumentIdentifier(uri: "file:///tmp/b.swift", version: 7),
            contentChanges: [
                .full(text: "// whole new file\n")
            ]
        )
        try assertRoundtrip(DidChangeTextDocumentParams.self, json: json, equals: expected)
    }

    func test_didChangeTextDocumentParams_mixedIncrementalAndFull_roundtrip() throws {
        // A single batch may legally contain a mix of incremental and full
        // entries. Verify the union decoder + encoder picks the right arm
        // per element.
        let json = """
        {"contentChanges":[{"range":{"end":{"character":1,"line":2},"start":{"character":0,"line":2}},"text":"x"},{"text":"FULL"}],"textDocument":{"uri":"file:///tmp/c.swift","version":99}}
        """
        let expected = DidChangeTextDocumentParams(
            textDocument: VersionedTextDocumentIdentifier(uri: "file:///tmp/c.swift", version: 99),
            contentChanges: [
                .incremental(
                    range: LSPRange(
                        start: Position(line: 2, character: 0),
                        end: Position(line: 2, character: 1)
                    ),
                    rangeLength: nil,
                    text: "x"
                ),
                .full(text: "FULL")
            ]
        )
        try assertRoundtrip(DidChangeTextDocumentParams.self, json: json, equals: expected)
    }

    // ====================================================================
    // MARK: - DidCloseTextDocumentParams
    // Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#didCloseTextDocumentParams
    // ====================================================================

    func test_didCloseTextDocumentParams_roundtrip() throws {
        let json = """
        {"textDocument":{"uri":"file:///tmp/a.swift"}}
        """
        let expected = DidCloseTextDocumentParams(
            textDocument: TextDocumentIdentifier(uri: "file:///tmp/a.swift")
        )
        try assertRoundtrip(DidCloseTextDocumentParams.self, json: json, equals: expected)
    }

    // ====================================================================
    // MARK: - DidSaveTextDocumentParams
    // Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#didSaveTextDocumentParams
    // ====================================================================

    func test_didSaveTextDocumentParams_withText_roundtrip() throws {
        // When the server registered `includeText: true`, the client sends
        // the full document text.
        let json = """
        {"text":"final body","textDocument":{"uri":"file:///tmp/a.swift"}}
        """
        let expected = DidSaveTextDocumentParams(
            textDocument: TextDocumentIdentifier(uri: "file:///tmp/a.swift"),
            text: "final body"
        )
        try assertRoundtrip(DidSaveTextDocumentParams.self, json: json, equals: expected)
    }

    func test_didSaveTextDocumentParams_withoutText_roundtrip() throws {
        // `text` is optional; when omitted on the wire it must NOT be
        // re-encoded as JSON null.
        let json = """
        {"textDocument":{"uri":"file:///tmp/a.swift"}}
        """
        let expected = DidSaveTextDocumentParams(
            textDocument: TextDocumentIdentifier(uri: "file:///tmp/a.swift"),
            text: nil
        )
        try assertRoundtrip(DidSaveTextDocumentParams.self, json: json, equals: expected)
    }
}
