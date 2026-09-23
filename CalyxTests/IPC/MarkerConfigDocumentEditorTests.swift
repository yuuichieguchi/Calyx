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

    // MARK: - replaceBlock: rewrites the FIRST well-formed block in place, never moves it to EOF

    func test_replaceBlock_blockFollowedByUserContent_staysInPlaceKeepingIndent() throws {
        let content = "mcp_servers:\n  # BEGIN X\n  calyx-ipc:\n    url: \"old\"\n  # END X\n  other: 1\n"
        let result = try editor.replaceBlock(body: "calyx-ipc:\n  url: \"new\"", in: Data(content.utf8))
        let expected = "mcp_servers:\n  # BEGIN X\n  calyx-ipc:\n    url: \"new\"\n  # END X\n  other: 1\n"
        XCTAssertEqual(
            result.map { String(decoding: $0, as: UTF8.self) }, expected,
            "the block must be rewritten at its own position, keeping its BEGIN line's indentation, with the " +
            "user's following content left exactly where it was -- never moved to EOF"
        )
    }

    func test_replaceBlock_noWellFormedBlock_returnsNil() throws {
        XCTAssertNil(try editor.replaceBlock(body: "x", in: Data("no marker here\n".utf8)))
        XCTAssertNil(try editor.replaceBlock(body: "x", in: Data("# BEGIN X\norphan, no end\n".utf8)),
                     "an orphan BEGIN with no matching END is not a well-formed block")
    }

    func test_replaceBlock_nilInput_returnsNil() throws {
        XCTAssertNil(try editor.replaceBlock(body: "x", in: nil))
    }

    func test_replaceBlock_placementRejected_returnsNil() throws {
        let content = "# BEGIN X\nbody\n# END X\n"
        let result = try editor.replaceBlock(body: "body2", in: Data(content.utf8), acceptsPlacement: { _, _ in false })
        XCTAssertNil(result, "acceptsPlacement returning false must make replaceBlock decline the in-place rewrite")
    }

    func test_replaceBlock_sameBodyOnAlreadyCurrentDocument_returnsByteIdenticalData() throws {
        let body = "calyx-ipc:\n  url: \"x\""
        let original = try editor.setBlock(body: body, in: Data("preface: 1\n".utf8))
        let result = try editor.replaceBlock(body: body, in: original)
        XCTAssertEqual(result, original, "re-replacing with an identical body must return byte-identical Data")
    }

    func test_replaceBlock_foreignContentInsideFirstBlock_liftedImmediatelyBeforeRewrittenBlock() throws {
        let foreignEditor = MarkerConfigDocumentEditor(
            beginLine: "# BEGIN X", endLine: "# END X",
            foreignBodyBytes: { doc, range in
                var result: [UInt8] = []
                for i in range where !doc.trimmedLineBytes(doc.lines[i]).starts(with: Array("keep:".utf8)) {
                    result.append(contentsOf: doc.rawBytes(forLines: i..<(i + 1)))
                }
                return result
            }
        )
        let content = "# BEGIN X\nforeign: 1\nkeep: 1\n# END X\nafter: 1\n"
        let result = try foreignEditor.replaceBlock(body: "keep: 2", in: Data(content.utf8))
        let expected = "foreign: 1\n# BEGIN X\nkeep: 2\n# END X\nafter: 1\n"
        XCTAssertEqual(
            result.map { String(decoding: $0, as: UTF8.self) }, expected,
            "foreign content found inside the first block's span must be preserved immediately before the " +
            "rewritten block, not discarded and not left inside it"
        )
    }

    func test_replaceBlock_secondWellFormedBlock_removedPerRemoveBlockRules() throws {
        let content = "# BEGIN X\nbody1\n# END X\n\n# BEGIN X\nbody2\n# END X\nafter: 1\n"
        let result = try editor.replaceBlock(body: "body1-new", in: Data(content.utf8))
        let expected = "# BEGIN X\nbody1-new\n# END X\nafter: 1\n"
        XCTAssertEqual(
            result.map { String(decoding: $0, as: UTF8.self) }, expected,
            "only the FIRST well-formed block is rewritten in place -- every further one is removed together " +
            "with its own preceding blank line, exactly as removeBlock handles it"
        )
    }

    func test_replaceBlock_orphanEndElsewhereRemoved_andOrphanBeginAfterFirstBlockHealed_rewrittenBlockNeverTreatedAsOrphan() throws {
        let healingEditor = MarkerConfigDocumentEditor(
            beginLine: "# BEGIN X", endLine: "# END X",
            isOwnBodyLine: { doc, index in doc.trimmedLineBytes(doc.lines[index]) == Array("ownish".utf8) }
        )
        let content =
            "# BEGIN X\n" +
            "body1\n" +
            "# END X\n" +
            "user: 1\n" +
            "# END X\n" +
            "user2: 1\n" +
            "# BEGIN X\n" +
            "ownish\n" +
            "real: 2\n"
        let result = try healingEditor.replaceBlock(body: "body1-new", in: Data(content.utf8))
        let expected =
            "# BEGIN X\n" +
            "body1-new\n" +
            "# END X\n" +
            "user: 1\n" +
            "user2: 1\n" +
            "real: 2\n"
        XCTAssertEqual(
            result.map { String(decoding: $0, as: UTF8.self) }, expected,
            "the orphan END (no matching BEGIN) must be removed on its own, the orphan BEGIN after the " +
            "rewritten block must self-heal bounded to its own recognized body ('ownish'), real user content " +
            "must survive untouched, and the rewritten block's own fresh BEGIN/END pair must never itself be " +
            "mistaken for an orphan"
        )
    }

    // MARK: - upsertBlock: replaceBlock when possible, else self-heal (removeBlock) + append (setBlock)

    func test_upsertBlock_nilOrEmptyInput_matchesSetBlock() throws {
        let body = "calyx-ipc:\n  a: 1"
        XCTAssertEqual(try editor.upsertBlock(body: body, in: nil), try editor.setBlock(body: body, in: nil))
        XCTAssertEqual(try editor.upsertBlock(body: body, in: Data()), try editor.setBlock(body: body, in: Data()))
    }

    func test_upsertBlock_noBlockPresent_appendsAtEOFWithOneBlankSeparator_matchingSetBlock() throws {
        let content = "preface: 1\n"
        let body = "calyx-ipc:\n  a: 1"
        let result = try editor.upsertBlock(body: body, in: Data(content.utf8))
        let expectedViaSetBlock = try editor.setBlock(body: body, in: Data(content.utf8))
        XCTAssertEqual(result, expectedViaSetBlock)
        XCTAssertEqual(
            String(decoding: result, as: UTF8.self), "preface: 1\n\n# BEGIN X\ncalyx-ipc:\n  a: 1\n# END X\n"
        )
    }

    func test_upsertBlock_orphanOnlyDocument_selfHealedThenAppended() throws {
        let healingEditor = MarkerConfigDocumentEditor(
            beginLine: "# BEGIN X", endLine: "# END X",
            isOwnBodyLine: { doc, index in doc.trimmedLineBytes(doc.lines[index]) == Array("ownish".utf8) }
        )
        let content = "# BEGIN X\nownish\nreal: 1\n"
        let result = try healingEditor.upsertBlock(body: "newbody", in: Data(content.utf8))
        let expected = "real: 1\n\n# BEGIN X\nnewbody\n# END X\n"
        XCTAssertEqual(
            String(decoding: result, as: UTF8.self), expected,
            "with no well-formed block, upsertBlock must self-heal the orphan (removeBlock's own rules) then " +
            "append the fresh block at EOF (setBlock's own rules)"
        )
    }

    func test_upsertBlock_blockPresent_rewritesInPlace_matchingReplaceBlock() throws {
        let content = "mcp_servers:\n  # BEGIN X\n  calyx-ipc:\n    url: \"old\"\n  # END X\n  other: 1\n"
        let body = "calyx-ipc:\n  url: \"new\""
        let result = try editor.upsertBlock(body: body, in: Data(content.utf8))
        let expectedViaReplaceBlock = try XCTUnwrap(try editor.replaceBlock(body: body, in: Data(content.utf8)))
        XCTAssertEqual(result, expectedViaReplaceBlock)
    }
}
