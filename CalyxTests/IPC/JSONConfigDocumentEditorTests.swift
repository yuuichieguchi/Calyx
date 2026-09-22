//
//  JSONConfigDocumentEditorTests.swift
//  CalyxTests
//
//  Direct coverage of JSONConfigDocumentEditor.removeArrayElements(at
//  path:) for JSONPathSegment.element(where:) -- addressing a specific
//  array element (found by predicate) rather than only an object member
//  by key, which the plain [String] key path can express. This segment
//  kind lets an edit reach a JSON array element's own nested array in
//  place, without removing and re-appending the element itself.
//

import XCTest
@testable import Calyx

final class JSONConfigDocumentEditorTests: XCTestCase {

    // MARK: - No-progress termination
    //
    // A resolved `.element(where:)` group whose leaf array holds no
    // element the terminal predicate matches must return rather than
    // loop: `processLeafArray` removes nothing, no cascade fires, and
    // `resolvePath` keeps re-resolving the exact same node forever.
    // Dispatched to a background thread with a bounded `wait(timeout:)`
    // so a regression fails this test rather than hanging the whole
    // suite (and the flock a real caller would be holding).

    func test_removeArrayElements_leafArrayHasNoMatchingElement_returnsRatherThanLooping() {
        let content = "{\"groups\":[{\"hooks\":[{\"own\":false}]}]}"
        let returned = expectation(description: "removeArrayElements returns")

        DispatchQueue.global().async {
            _ = try? JSONConfigDocumentEditor.removeArrayElements(
                at: [.key("groups"), .element(where: { _ in true }), .key("hooks")],
                in: Data(content.utf8),
                where: { _ in false }
            )
            returned.fulfill()
        }

        wait(for: [returned], timeout: 2.0)
    }

    // MARK: - Predicates

    private let groupHasOwnEntry: (Any) -> Bool = { value in
        guard let group = value as? [String: Any],
              let hooks = group["hooks"] as? [[String: Any]] else { return false }
        return hooks.contains { ($0["own"] as? Bool) == true }
    }

    private let entryIsOwn: (Any) -> Bool = { value in
        guard let entry = value as? [String: Any] else { return false }
        return (entry["own"] as? Bool) == true
    }

    // MARK: - .element(where:) locates the target among its siblings: first

    func test_removeArrayElements_elementSegment_targetFirstAmongSiblings_stripsOwnEntryPreservesSurvivorsAndSiblings() throws {
        let initial =
            "{\n  \"other\": 1,\n  \"groups\": [\n    {\n      \"id\": \"g0\",\n      \"hooks\": [\n" +
            "        {\n          \"own\": true,\n          \"name\": \"a\"\n        },\n        {\n" +
            "          \"own\": false,\n          \"name\": \"user\"\n        }\n      ]\n    },\n    {\n" +
            "      \"id\": \"g1\",\n      \"hooks\": [\n        {\n          \"own\": false,\n" +
            "          \"name\": \"user2\"\n        }\n      ]\n    }\n  ]\n}\n"
        let expected =
            "{\n  \"other\": 1,\n  \"groups\": [\n    {\n      \"id\": \"g0\",\n      \"hooks\": [\n" +
            "        {\n          \"own\": false,\n          \"name\": \"user\"\n        }\n      ]\n    },\n    {\n" +
            "      \"id\": \"g1\",\n      \"hooks\": [\n        {\n          \"own\": false,\n" +
            "          \"name\": \"user2\"\n        }\n      ]\n    }\n  ]\n}\n"

        let result = try JSONConfigDocumentEditor.removeArrayElements(
            at: [.key("groups"), .element(where: groupHasOwnEntry), .key("hooks")],
            in: Data(initial.utf8),
            where: entryIsOwn
        )

        XCTAssertEqual(
            String(decoding: try XCTUnwrap(result), as: UTF8.self), expected,
            "the first sibling's own entry must be stripped in place, and the second sibling's group " +
            "must survive byte-identical"
        )
    }

    // MARK: - .element(where:) locates the target among its siblings: middle

    func test_removeArrayElements_elementSegment_targetMiddleAmongSiblings_stripsOwnEntryPreservesSurvivorsAndSiblings() throws {
        let initial =
            "{\n  \"groups\": [\n    {\n      \"id\": \"g0\",\n      \"hooks\": [\n        {\n" +
            "          \"own\": false,\n          \"name\": \"u0\"\n        }\n      ]\n    },\n    {\n" +
            "      \"id\": \"g1\",\n      \"hooks\": [\n        {\n          \"own\": false,\n" +
            "          \"name\": \"u1\"\n        },\n        {\n          \"own\": true,\n" +
            "          \"name\": \"c1\"\n        }\n      ]\n    },\n    {\n      \"id\": \"g2\",\n" +
            "      \"hooks\": [\n        {\n          \"own\": false,\n          \"name\": \"u2\"\n        }\n      ]\n    }\n  ]\n}\n"
        let expected =
            "{\n  \"groups\": [\n    {\n      \"id\": \"g0\",\n      \"hooks\": [\n        {\n" +
            "          \"own\": false,\n          \"name\": \"u0\"\n        }\n      ]\n    },\n    {\n" +
            "      \"id\": \"g1\",\n      \"hooks\": [\n        {\n          \"own\": false,\n" +
            "          \"name\": \"u1\"\n        }\n      ]\n    },\n    {\n      \"id\": \"g2\",\n" +
            "      \"hooks\": [\n        {\n          \"own\": false,\n          \"name\": \"u2\"\n        }\n      ]\n    }\n  ]\n}\n"

        let result = try JSONConfigDocumentEditor.removeArrayElements(
            at: [.key("groups"), .element(where: groupHasOwnEntry), .key("hooks")],
            in: Data(initial.utf8),
            where: entryIsOwn
        )

        XCTAssertEqual(
            String(decoding: try XCTUnwrap(result), as: UTF8.self), expected,
            "the middle sibling's own entry must be stripped in place, and its non-own survivor plus " +
            "both outer siblings must remain byte-identical"
        )
    }

    // MARK: - .element(where:) locates the target among its siblings: last

    func test_removeArrayElements_elementSegment_targetLastAmongSiblings_stripsOwnEntryPreservesSurvivorsAndSiblings() throws {
        let initial =
            "{\n  \"groups\": [\n    {\n      \"id\": \"g0\",\n      \"hooks\": [\n        {\n" +
            "          \"own\": false,\n          \"name\": \"u0\"\n        }\n      ]\n    },\n    {\n" +
            "      \"id\": \"g1\",\n      \"hooks\": [\n        {\n          \"own\": false,\n" +
            "          \"name\": \"u1\"\n        },\n        {\n          \"own\": true,\n" +
            "          \"name\": \"c1\"\n        }\n      ]\n    }\n  ]\n}\n"
        let expected =
            "{\n  \"groups\": [\n    {\n      \"id\": \"g0\",\n      \"hooks\": [\n        {\n" +
            "          \"own\": false,\n          \"name\": \"u0\"\n        }\n      ]\n    },\n    {\n" +
            "      \"id\": \"g1\",\n      \"hooks\": [\n        {\n          \"own\": false,\n" +
            "          \"name\": \"u1\"\n        }\n      ]\n    }\n  ]\n}\n"

        let result = try JSONConfigDocumentEditor.removeArrayElements(
            at: [.key("groups"), .element(where: groupHasOwnEntry), .key("hooks")],
            in: Data(initial.utf8),
            where: entryIsOwn
        )

        XCTAssertEqual(
            String(decoding: try XCTUnwrap(result), as: UTF8.self), expected,
            "the last sibling's own entry must be stripped in place, and its non-own survivor plus the " +
            "preceding sibling must remain byte-identical"
        )
    }

    // MARK: - Cascade when the nested array empties: sibling groups survive

    func test_removeArrayElements_elementSegment_nestedArrayEmpties_removesWholeElementLeavingSiblingsUntouched() throws {
        let initial =
            "{\n  \"other\": 1,\n  \"groups\": [\n    {\n      \"id\": \"g0\",\n      \"hooks\": [\n" +
            "        {\n          \"own\": false,\n          \"name\": \"u0\"\n        }\n      ]\n    },\n    {\n" +
            "      \"id\": \"g1\",\n      \"hooks\": [\n        {\n          \"own\": true,\n" +
            "          \"name\": \"c1\"\n        }\n      ]\n    }\n  ]\n}\n"
        let expected =
            "{\n  \"other\": 1,\n  \"groups\": [\n    {\n      \"id\": \"g0\",\n      \"hooks\": [\n" +
            "        {\n          \"own\": false,\n          \"name\": \"u0\"\n        }\n      ]\n    }\n  ]\n}\n"

        let result = try JSONConfigDocumentEditor.removeArrayElements(
            at: [.key("groups"), .element(where: groupHasOwnEntry), .key("hooks")],
            in: Data(initial.utf8),
            where: entryIsOwn
        )

        XCTAssertEqual(
            String(decoding: try XCTUnwrap(result), as: UTF8.self), expected,
            "a group whose nested \"hooks\" array becomes empty (nothing but an own entry) must be " +
            "removed from \"groups\" as a whole -- not left behind as an empty-hooks group -- while its " +
            "surviving sibling group is untouched"
        )
    }

    // MARK: - Cascade when the nested array empties: cascades all the way up, stopping before the root

    func test_removeArrayElements_elementSegment_soleGroupNestedArrayEmpties_cascadesToRemovingGroupsKeyStoppingBeforeRoot() throws {
        let initial =
            "{\n  \"other\": 1,\n  \"groups\": [\n    {\n      \"id\": \"g0\",\n      \"hooks\": [\n" +
            "        {\n          \"own\": true,\n          \"name\": \"c0\"\n        }\n      ]\n    }\n  ]\n}\n"
        let expected = "{\n  \"other\": 1\n}\n"

        let result = try JSONConfigDocumentEditor.removeArrayElements(
            at: [.key("groups"), .element(where: groupHasOwnEntry), .key("hooks")],
            in: Data(initial.utf8),
            where: entryIsOwn
        )

        XCTAssertEqual(
            String(decoding: try XCTUnwrap(result), as: UTF8.self), expected,
            "when the sole group's nested \"hooks\" array empties, the cascade must remove the group " +
            "element, then the now-empty \"groups\" array's own key, stopping before the root -- leaving " +
            "the unrelated \"other\" key exactly as it was"
        )
    }

    // MARK: - Leading UTF-8 BOM: outside the document, preserved byte-for-byte

    private let bomPrefix = "\u{FEFF}"

    func test_setValue_leadingBOM_preservedByteIdentically_restMatchesNoBOMResult() throws {
        let noBOM = "{\"a\":1}"
        let withBOM = bomPrefix + noBOM
        let value = Data("2".utf8)

        let resultNoBOM = try JSONConfigDocumentEditor.setValue(value, at: ["b"], in: Data(noBOM.utf8))
        let resultWithBOM = try JSONConfigDocumentEditor.setValue(value, at: ["b"], in: Data(withBOM.utf8))

        XCTAssertEqual(Array(resultWithBOM.prefix(3)), [0xEF, 0xBB, 0xBF])
        XCTAssertEqual(resultWithBOM.dropFirst(3), resultNoBOM)
    }

    func test_setValue_thenRemoveValue_leadingBOM_roundTripsToOriginalBytes() throws {
        let original = Data((bomPrefix + "{\"a\":1}").utf8)

        let added = try JSONConfigDocumentEditor.setValue(Data("2".utf8), at: ["b"], in: original)
        let roundTripped = try JSONConfigDocumentEditor.removeValue(at: ["b"], in: added)

        XCTAssertEqual(try XCTUnwrap(roundTripped), original)
    }

    func test_removeValue_leadingBOM_preservedByteIdentically_restMatchesNoBOMResult() throws {
        let noBOM = "{\"other\":true,\"a\":1}"
        let withBOM = bomPrefix + noBOM

        let resultNoBOM = try JSONConfigDocumentEditor.removeValue(at: ["a"], in: Data(noBOM.utf8))
        let resultWithBOM = try JSONConfigDocumentEditor.removeValue(at: ["a"], in: Data(withBOM.utf8))

        let unwrappedNoBOM = try XCTUnwrap(resultNoBOM)
        let unwrappedWithBOM = try XCTUnwrap(resultWithBOM)
        XCTAssertEqual(Array(unwrappedWithBOM.prefix(3)), [0xEF, 0xBB, 0xBF])
        XCTAssertEqual(unwrappedWithBOM.dropFirst(3), unwrappedNoBOM)
    }

    func test_containsValue_leadingBOM_trueSameAsNoBOM() {
        let noBOM = "{\"a\":1}"
        let withBOM = bomPrefix + noBOM

        XCTAssertTrue(JSONConfigDocumentEditor.containsValue(at: ["a"], in: Data(withBOM.utf8)))
        XCTAssertEqual(
            JSONConfigDocumentEditor.containsValue(at: ["a"], in: Data(withBOM.utf8)),
            JSONConfigDocumentEditor.containsValue(at: ["a"], in: Data(noBOM.utf8))
        )
    }

    func test_appendArrayElement_leadingBOM_preservedByteIdentically_restMatchesNoBOMResult() throws {
        let noBOM = "{\"items\":[1]}"
        let withBOM = bomPrefix + noBOM
        let element = Data("2".utf8)

        let resultNoBOM = try JSONConfigDocumentEditor.appendArrayElement(element, at: ["items"], in: Data(noBOM.utf8))
        let resultWithBOM = try JSONConfigDocumentEditor.appendArrayElement(element, at: ["items"], in: Data(withBOM.utf8))

        XCTAssertEqual(Array(resultWithBOM.prefix(3)), [0xEF, 0xBB, 0xBF])
        XCTAssertEqual(resultWithBOM.dropFirst(3), resultNoBOM)
    }

    func test_removeArrayElements_leadingBOM_preservedByteIdentically_restMatchesNoBOMResult() throws {
        let noBOM = "{\"items\":[{\"own\":true},{\"own\":false}]}"
        let withBOM = bomPrefix + noBOM

        let resultNoBOM = try JSONConfigDocumentEditor.removeArrayElements(
            at: [.key("items")], in: Data(noBOM.utf8), where: entryIsOwn
        )
        let resultWithBOM = try JSONConfigDocumentEditor.removeArrayElements(
            at: [.key("items")], in: Data(withBOM.utf8), where: entryIsOwn
        )

        let unwrappedNoBOM = try XCTUnwrap(resultNoBOM)
        let unwrappedWithBOM = try XCTUnwrap(resultWithBOM)
        XCTAssertEqual(Array(unwrappedWithBOM.prefix(3)), [0xEF, 0xBB, 0xBF])
        XCTAssertEqual(unwrappedWithBOM.dropFirst(3), unwrappedNoBOM)
    }
}
