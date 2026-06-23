//
//  LSPTypesNotebookTests.swift
//  Calyx
//
//  Round-trip Codable tests for the LSP 3.18 notebook-document
//  synchronisation type cluster. Coverage:
//
//    - NotebookDocumentIdentifier
//    - VersionedNotebookDocumentIdentifier
//    - ExecutionSummary
//    - NotebookCellKind
//    - NotebookCell
//    - NotebookDocument
//    - DidOpenNotebookDocumentParams
//    - NotebookCellArrayChange
//    - NotebookDocumentChangeEventCellsStructure
//    - NotebookDocumentChangeEventCellsTextContent
//    - NotebookDocumentChangeEventCells
//    - NotebookDocumentChangeEvent
//    - DidChangeNotebookDocumentParams
//    - DidCloseNotebookDocumentParams
//
//  Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#notebookDocument
//
//  TDD phase: RED. None of these types exist yet. This file is expected to
//  fail to compile until the swift-specialist implements the notebook types
//  under `Calyx/Features/LSP/LSPTypes/NotebookDocument.swift`.
//

import XCTest
@testable import Calyx

final class LSPTypesNotebookTests: XCTestCase {

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

    /// Encode an Encodable value to a Foundation object.
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
    // MARK: - NotebookDocumentIdentifier
    // Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#notebookDocumentIdentifier
    // ====================================================================

    func test_notebookDocumentIdentifier_roundtrip() throws {
        let json = #"{"uri":"file:///tmp/example.ipynb"}"#
        try assertRoundtrip(NotebookDocumentIdentifier.self, json: json)

        let decoded = try decoder.decode(
            NotebookDocumentIdentifier.self,
            from: Data(json.utf8)
        )
        XCTAssertEqual(decoded.uri, "file:///tmp/example.ipynb")
    }

    // ====================================================================
    // MARK: - VersionedNotebookDocumentIdentifier
    // Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#versionedNotebookDocumentIdentifier
    // ====================================================================

    func test_versionedNotebookDocumentIdentifier_roundtrip() throws {
        let json = #"{"uri":"file:///tmp/example.ipynb","version":3}"#
        try assertRoundtrip(VersionedNotebookDocumentIdentifier.self, json: json)

        let decoded = try decoder.decode(
            VersionedNotebookDocumentIdentifier.self,
            from: Data(json.utf8)
        )
        XCTAssertEqual(decoded.uri, "file:///tmp/example.ipynb")
        XCTAssertEqual(decoded.version, 3)
    }

    // ====================================================================
    // MARK: - ExecutionSummary
    // Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#executionSummary
    // ====================================================================

    func test_executionSummary_withSuccess_roundtrip() throws {
        let json = #"{"executionOrder":2,"success":true}"#
        try assertRoundtrip(ExecutionSummary.self, json: json)

        let decoded = try decoder.decode(
            ExecutionSummary.self,
            from: Data(json.utf8)
        )
        XCTAssertEqual(decoded.executionOrder, 2)
        XCTAssertEqual(decoded.success, true)
    }

    func test_executionSummary_omittedSuccess_roundtrip() throws {
        let json = #"{"executionOrder":7}"#
        try assertRoundtrip(ExecutionSummary.self, json: json)

        let decoded = try decoder.decode(
            ExecutionSummary.self,
            from: Data(json.utf8)
        )
        XCTAssertEqual(decoded.executionOrder, 7)
        XCTAssertNil(decoded.success, "missing 'success' must decode as nil so the round-trip omits it on re-encode")
    }

    // ====================================================================
    // MARK: - NotebookCellKind
    // Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#notebookCellKind
    // ====================================================================

    func test_notebookCellKind_allValues_roundtrip() throws {
        for (raw, expected) in [
            (1, NotebookCellKind.markup),
            (2, NotebookCellKind.code),
        ] {
            let decoded = try decoder.decode(
                NotebookCellKind.self,
                from: Data("\(raw)".utf8)
            )
            XCTAssertEqual(decoded, expected, "raw=\(raw)")
            let reencoded = try encoder.encode(decoded)
            XCTAssertEqual(String(data: reencoded, encoding: .utf8), "\(raw)")
        }
    }

    // ====================================================================
    // MARK: - NotebookCell
    // Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#notebookCell
    // ====================================================================

    func test_notebookCell_minimal_roundtrip() throws {
        // `metadata` and `executionSummary` are optional and must drop out of
        // the encoded payload when not provided.
        let json = #"{"document":"file:///tmp/cell-1.py","kind":2}"#
        try assertRoundtrip(NotebookCell.self, json: json)

        let decoded = try decoder.decode(
            NotebookCell.self,
            from: Data(json.utf8)
        )
        XCTAssertEqual(decoded.kind, .code)
        XCTAssertEqual(decoded.document, "file:///tmp/cell-1.py")
        XCTAssertNil(decoded.metadata)
        XCTAssertNil(decoded.executionSummary)
    }

    func test_notebookCell_withExecutionSummary_roundtrip() throws {
        let json = """
        {"document":"file:///tmp/cell-2.py","executionSummary":{"executionOrder":4,"success":false},"kind":2}
        """
        try assertRoundtrip(NotebookCell.self, json: json)

        let decoded = try decoder.decode(
            NotebookCell.self,
            from: Data(json.utf8)
        )
        XCTAssertEqual(decoded.kind, .code)
        XCTAssertEqual(decoded.executionSummary?.executionOrder, 4)
        XCTAssertEqual(decoded.executionSummary?.success, false)
    }

    // ====================================================================
    // MARK: - NotebookDocument
    // Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#notebookDocument
    // ====================================================================

    func test_notebookDocument_roundtrip() throws {
        let json = """
        {"cells":[{"document":"file:///tmp/cell-1.py","kind":2}],"notebookType":"jupyter-notebook","uri":"file:///tmp/example.ipynb","version":1}
        """
        try assertRoundtrip(NotebookDocument.self, json: json)

        let decoded = try decoder.decode(
            NotebookDocument.self,
            from: Data(json.utf8)
        )
        XCTAssertEqual(decoded.uri, "file:///tmp/example.ipynb")
        XCTAssertEqual(decoded.notebookType, "jupyter-notebook")
        XCTAssertEqual(decoded.version, 1)
        XCTAssertEqual(decoded.cells.count, 1)
        XCTAssertEqual(decoded.cells[0].kind, .code)
    }

    // ====================================================================
    // MARK: - DidOpenNotebookDocumentParams
    // Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#notebookDocument_didOpen
    // ====================================================================

    func test_didOpenNotebookDocumentParams_roundtrip() throws {
        let json = """
        {"cellTextDocuments":[{"languageId":"python","text":"print(1)","uri":"file:///tmp/cell-1.py","version":1}],"notebookDocument":{"cells":[{"document":"file:///tmp/cell-1.py","kind":2}],"notebookType":"jupyter-notebook","uri":"file:///tmp/example.ipynb","version":1}}
        """
        try assertRoundtrip(DidOpenNotebookDocumentParams.self, json: json)

        let decoded = try decoder.decode(
            DidOpenNotebookDocumentParams.self,
            from: Data(json.utf8)
        )
        XCTAssertEqual(decoded.notebookDocument.cells.count, 1)
        XCTAssertEqual(decoded.cellTextDocuments.count, 1)
        XCTAssertEqual(decoded.cellTextDocuments[0].languageId, "python")
        XCTAssertEqual(decoded.cellTextDocuments[0].text, "print(1)")
    }

    // ====================================================================
    // MARK: - NotebookCellArrayChange
    // Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#notebookCellArrayChange
    // ====================================================================

    func test_notebookCellArrayChange_withCells_roundtrip() throws {
        let json = """
        {"cells":[{"document":"file:///tmp/cell-new.py","kind":2}],"deleteCount":0,"start":1}
        """
        try assertRoundtrip(NotebookCellArrayChange.self, json: json)

        let decoded = try decoder.decode(
            NotebookCellArrayChange.self,
            from: Data(json.utf8)
        )
        XCTAssertEqual(decoded.start, 1)
        XCTAssertEqual(decoded.deleteCount, 0)
        XCTAssertEqual(decoded.cells?.count, 1)
    }

    func test_notebookCellArrayChange_omitsCells_roundtrip() throws {
        // The `cells` field is optional — a pure-delete change omits it.
        let json = #"{"deleteCount":2,"start":0}"#
        try assertRoundtrip(NotebookCellArrayChange.self, json: json)

        let decoded = try decoder.decode(
            NotebookCellArrayChange.self,
            from: Data(json.utf8)
        )
        XCTAssertEqual(decoded.start, 0)
        XCTAssertEqual(decoded.deleteCount, 2)
        XCTAssertNil(decoded.cells)
    }

    // ====================================================================
    // MARK: - NotebookDocumentChangeEventCellsStructure
    // Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#notebookDocumentChangeEvent
    // ====================================================================

    func test_notebookDocumentChangeEventCellsStructure_roundtrip() throws {
        let json = """
        {"array":{"cells":[{"document":"file:///tmp/cell-new.py","kind":2}],"deleteCount":0,"start":1},"didClose":[{"uri":"file:///tmp/cell-old.py"}],"didOpen":[{"languageId":"python","text":"print(2)","uri":"file:///tmp/cell-new.py","version":1}]}
        """
        try assertRoundtrip(NotebookDocumentChangeEventCellsStructure.self, json: json)

        let decoded = try decoder.decode(
            NotebookDocumentChangeEventCellsStructure.self,
            from: Data(json.utf8)
        )
        XCTAssertEqual(decoded.array.start, 1)
        XCTAssertEqual(decoded.didOpen?.count, 1)
        XCTAssertEqual(decoded.didClose?.count, 1)
        XCTAssertEqual(decoded.didClose?[0].uri, "file:///tmp/cell-old.py")
    }

    // ====================================================================
    // MARK: - NotebookDocumentChangeEventCellsTextContent
    // ====================================================================

    func test_notebookDocumentChangeEventCellsTextContent_roundtrip() throws {
        let json = """
        {"changes":[{"text":"print(99)"}],"document":{"uri":"file:///tmp/cell-1.py","version":2}}
        """
        try assertRoundtrip(NotebookDocumentChangeEventCellsTextContent.self, json: json)

        let decoded = try decoder.decode(
            NotebookDocumentChangeEventCellsTextContent.self,
            from: Data(json.utf8)
        )
        XCTAssertEqual(decoded.document.uri, "file:///tmp/cell-1.py")
        XCTAssertEqual(decoded.document.version, 2)
        XCTAssertEqual(decoded.changes.count, 1)
        switch decoded.changes[0] {
        case .full(let text):
            XCTAssertEqual(text, "print(99)")
        case .incremental:
            XCTFail("expected a full-document change, got incremental")
        }
    }

    // ====================================================================
    // MARK: - NotebookDocumentChangeEventCells
    // ====================================================================

    func test_notebookDocumentChangeEventCells_structureOnly_roundtrip() throws {
        // Only the `structure` arm is populated — `data` and `textContent`
        // must drop out of the encoded payload.
        let json = """
        {"structure":{"array":{"cells":[{"document":"file:///tmp/cell-new.py","kind":2}],"deleteCount":0,"start":1}}}
        """
        try assertRoundtrip(NotebookDocumentChangeEventCells.self, json: json)

        let decoded = try decoder.decode(
            NotebookDocumentChangeEventCells.self,
            from: Data(json.utf8)
        )
        XCTAssertNotNil(decoded.structure)
        XCTAssertNil(decoded.data)
        XCTAssertNil(decoded.textContent)
    }

    // ====================================================================
    // MARK: - NotebookDocumentChangeEvent
    // ====================================================================

    func test_notebookDocumentChangeEvent_roundtrip() throws {
        let json = """
        {"cells":{"textContent":[{"changes":[{"text":"x = 1"}],"document":{"uri":"file:///tmp/cell-1.py","version":2}}]}}
        """
        try assertRoundtrip(NotebookDocumentChangeEvent.self, json: json)

        let decoded = try decoder.decode(
            NotebookDocumentChangeEvent.self,
            from: Data(json.utf8)
        )
        XCTAssertNil(decoded.metadata)
        XCTAssertNotNil(decoded.cells)
        XCTAssertEqual(decoded.cells?.textContent?.count, 1)
    }

    // ====================================================================
    // MARK: - DidChangeNotebookDocumentParams
    // Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#notebookDocument_didChange
    // ====================================================================

    func test_didChangeNotebookDocumentParams_roundtrip() throws {
        let json = """
        {"change":{"cells":{"textContent":[{"changes":[{"text":"y = 2"}],"document":{"uri":"file:///tmp/cell-1.py","version":3}}]}},"notebookDocument":{"uri":"file:///tmp/example.ipynb","version":3}}
        """
        try assertRoundtrip(DidChangeNotebookDocumentParams.self, json: json)

        let decoded = try decoder.decode(
            DidChangeNotebookDocumentParams.self,
            from: Data(json.utf8)
        )
        XCTAssertEqual(decoded.notebookDocument.uri, "file:///tmp/example.ipynb")
        XCTAssertEqual(decoded.notebookDocument.version, 3)
        XCTAssertNotNil(decoded.change.cells)
    }

    // ====================================================================
    // MARK: - DidCloseNotebookDocumentParams
    // Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#notebookDocument_didClose
    // ====================================================================

    func test_didCloseNotebookDocumentParams_roundtrip() throws {
        let json = """
        {"cellTextDocuments":[{"uri":"file:///tmp/cell-1.py"},{"uri":"file:///tmp/cell-2.py"}],"notebookDocument":{"uri":"file:///tmp/example.ipynb"}}
        """
        try assertRoundtrip(DidCloseNotebookDocumentParams.self, json: json)

        let decoded = try decoder.decode(
            DidCloseNotebookDocumentParams.self,
            from: Data(json.utf8)
        )
        XCTAssertEqual(decoded.notebookDocument.uri, "file:///tmp/example.ipynb")
        XCTAssertEqual(decoded.cellTextDocuments.count, 2)
        XCTAssertEqual(decoded.cellTextDocuments[0].uri, "file:///tmp/cell-1.py")
    }
}
