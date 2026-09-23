// MarkerConfigDocumentEditorTests.swift
// CalyxTests
//
// Pins two defects found while wiring HermesConfigManager onto
// MarkerConfigDocumentEditor: `insertBlock`'s child-insertion point relative
// to a trailing user blank line, and `setBlock`'s in-place replacement
// losing an existing block's own indentation.

import XCTest
@testable import Calyx

final class MarkerConfigDocumentEditorTests: XCTestCase {

    private let editor = MarkerConfigDocumentEditor(beginLine: "# BEGIN X", endLine: "# END X")

    // MARK: - Defect A: insertBlock must land before a trailing blank line,
    // not after it, so the blank line stays the next key's own separator.

    func test_insertBlock_insertsBeforeTrailingBlankLine_notAfterIt() {
        let content = "mcp_servers:\n  foo: bar\n\nother: 1\n"
        let result = editor.insertBlock(
            body: "calyx-ipc:\n  a: 1",
            asChildOfLine: 0,
            unit: 2,
            in: Data(content.utf8)
        )
        let expected = "mcp_servers:\n  foo: bar\n  # BEGIN X\n  calyx-ipc:\n    a: 1\n  # END X\n\nother: 1\n"
        XCTAssertEqual(String(decoding: result, as: UTF8.self), expected)
    }

    func test_insertBlock_thenRemoveBlock_roundTripsByteIdentically_whenTrailingBlankLinePrecedesNextTopLevelKey() throws {
        let original = "mcp_servers:\n  foo: bar\n\nother: 1\n"
        let inserted = editor.insertBlock(
            body: "calyx-ipc:\n  a: 1",
            asChildOfLine: 0,
            unit: 2,
            in: Data(original.utf8)
        )
        let removed = try editor.removeBlock(in: inserted)
        XCTAssertEqual(removed.map { String(decoding: $0, as: UTF8.self) }, original)
    }

    // MARK: - Defect B: setBlock's in-place replacement must preserve the
    // existing block's own indentation, not flatten it to column 0.

    func test_setBlock_inPlaceReplace_preservesExistingNestedIndent() throws {
        let content = "mcp_servers:\n  # BEGIN X\n  calyx-ipc:\n    url: \"old\"\n  # END X\n"
        let result = try editor.setBlock(body: "calyx-ipc:\n  url: \"new\"", in: Data(content.utf8))
        let expected = "mcp_servers:\n  # BEGIN X\n  calyx-ipc:\n    url: \"new\"\n  # END X\n"
        XCTAssertEqual(String(decoding: result, as: UTF8.self), expected)
    }

    // MARK: - Never delete a user-owned file: removeBlock returns empty Data(), never nil, once content existed

    func test_removeBlock_nilInput_returnsNil() throws {
        let result = try editor.removeBlock(in: nil)
        XCTAssertNil(result, "an absent file must stay absent -- removeBlock must never conjure a file")
    }

    func test_removeBlock_onlyCalyxBlockRemains_returnsNonNilEmptyData() throws {
        let content = "# BEGIN X\nbody\n# END X\n"
        let result = try editor.removeBlock(in: Data(content.utf8))
        XCTAssertNotNil(result, "removeBlock must never signal file deletion (nil) -- Calyx never deletes a user-owned file")
        XCTAssertEqual(result, Data(), "once nothing but Calyx's own block remains, removeBlock must return empty Data(), not nil")
    }

    func test_removeBlock_onlyCalyxBlockRemains_crlf_returnsNonNilEmptyData() throws {
        let content = "# BEGIN X\r\nbody\r\n# END X\r\n"
        let result = try editor.removeBlock(in: Data(content.utf8))
        XCTAssertNotNil(result, "removeBlock must never signal file deletion (nil) -- Calyx never deletes a user-owned file")
        XCTAssertEqual(result, Data(), "once nothing but Calyx's own block remains, removeBlock must return empty Data(), not nil")
    }
}
