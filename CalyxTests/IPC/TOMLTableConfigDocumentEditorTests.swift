//
//  TOMLTableConfigDocumentEditorTests.swift
//  CalyxTests
//
//  Direct coverage of TOMLTableConfigDocumentEditor's region scan
//  (isAnyTableHeader), independent of CodexConfigManager/
//  GrokConfigManager's own fixed body shape: the scanner must recognize
//  only an actual `[table]` / `[[table]]` header as a region boundary,
//  not any line that merely starts with `[` -- a multi-line array
//  element's own continuation line (`["a", "b"],`) starts with `[` too,
//  but is not a header.
//

import XCTest
@testable import Calyx

final class TOMLTableConfigDocumentEditorTests: XCTestCase {

    private let editor = TOMLTableConfigDocumentEditor(tablePath: "mcp_servers.calyx-ipc")

    func test_removeTable_multiLineArrayElementLineInsideRegion_doesNotEndRegionEarly() throws {
        let content = """
        [other]
        zeta = 1

        [mcp_servers.calyx-ipc]
        url = "http://127.0.0.1:41830/mcp"
        matrix = [
          ["a", "b"],
          ["c", "d"],
        ]
        timeout = 5
        """ + "\n"

        let result = try editor.removeTable(in: Data(content.utf8))

        let expected = "[other]\nzeta = 1\n"
        XCTAssertEqual(
            String(decoding: try XCTUnwrap(result), as: UTF8.self), expected,
            "removeTable must remove the whole Calyx table, including every line of the multi-line array " +
            "value inside it -- a `[\"a\", \"b\"],` continuation line must not be mistaken for a table header " +
            "that ends the region early"
        )
    }

    func test_containsTable_multiLineArrayElementLineInsideRegion_stillReportsInstalled() {
        let content = """
        [mcp_servers.calyx-ipc]
        matrix = [
          ["a", "b"],
        ]
        timeout = 5
        """ + "\n"

        XCTAssertTrue(
            editor.containsTable(in: Data(content.utf8)),
            "A multi-line array element line starting with '[' inside the region must not truncate the " +
            "scan before the region's own content (here, timeout = 5) is reached"
        )
    }

    // MARK: - Never delete a user-owned file: removeTable returns empty Data(), never nil, once content existed

    func test_removeTable_nilInput_returnsNil() throws {
        let result = try editor.removeTable(in: nil)
        XCTAssertNil(result, "an absent file must stay absent -- removeTable must never conjure a file")
    }

    func test_removeTable_onlyCalyxTableRemains_returnsNonNilEmptyData() throws {
        let content = "[mcp_servers.calyx-ipc]\nurl = \"x\"\n"
        let result = try editor.removeTable(in: Data(content.utf8))
        XCTAssertNotNil(result, "removeTable must never signal file deletion (nil) -- Calyx never deletes a user-owned file")
        XCTAssertEqual(result, Data(), "once nothing but Calyx's own table remains, removeTable must return empty Data(), not nil")
    }

    func test_removeTable_onlyCalyxTableRemains_crlf_returnsNonNilEmptyData() throws {
        let content = "[mcp_servers.calyx-ipc]\r\nurl = \"x\"\r\n"
        let result = try editor.removeTable(in: Data(content.utf8))
        XCTAssertNotNil(result, "removeTable must never signal file deletion (nil) -- Calyx never deletes a user-owned file")
        XCTAssertEqual(result, Data(), "once nothing but Calyx's own table remains, removeTable must return empty Data(), not nil")
    }
}
