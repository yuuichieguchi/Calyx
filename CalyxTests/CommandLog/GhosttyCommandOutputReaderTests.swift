//
//  GhosttyCommandOutputReaderTests.swift
//  CalyxTests
//
//  TDD Red Phase for GhosttyCommandOutputReader.tailLines(_:count:), the
//  pure line-slicing helper behind readScreenTailLines(surfaceID:count:).
//  The instance methods (scrollbarTotal / readScreenTailLines) wrap
//  ghostty FFI calls and cannot run in this unit-test host -- only the
//  pure static function is covered here.
//
//  Contract: split `text` on "\n" via components(separatedBy:) (so a
//  trailing newline yields a trailing empty component, preserved through
//  the slice), take the LAST `count` of the resulting components, rejoin
//  with "\n". Fewer components than `count` returns everything unchanged.
//
//  Coverage:
//  - Fewer lines than count -> unchanged
//  - Exactly count lines -> unchanged
//  - More lines than count -> only the last count kept
//  - A trailing newline's extra empty trailing component is preserved
//  - Empty input -> empty output
//  - A negative count clamps to 0 rather than trapping suffix's
//    non-negative precondition
//

import XCTest
@testable import Calyx

final class GhosttyCommandOutputReaderTests: XCTestCase {

    func test_tailLines_fewerLinesThanCount_returnsAllUnchanged() {
        let result = GhosttyCommandOutputReader.tailLines("a\nb", count: 5)

        XCTAssertEqual(result, "a\nb", "Fewer lines than count must return everything, unchanged")
    }

    func test_tailLines_exactlyCountLines_returnsAllUnchanged() {
        let result = GhosttyCommandOutputReader.tailLines("a\nb\nc", count: 3)

        XCTAssertEqual(result, "a\nb\nc", "Exactly count lines must return everything, unchanged")
    }

    func test_tailLines_moreLinesThanCount_returnsOnlyTheLastCount() {
        let result = GhosttyCommandOutputReader.tailLines("a\nb\nc\nd\ne", count: 3)

        XCTAssertEqual(result, "c\nd\ne", "More lines than count must keep only the last count lines")
    }

    func test_tailLines_trailingNewline_preservesTrailingEmptyComponent() {
        // "a\nb\nc\n".components(separatedBy: "\n") == ["a", "b", "c", ""]
        // (4 components -- the trailing newline yields a trailing empty
        // one). suffix(2) == ["c", ""], joined == "c\n".
        let result = GhosttyCommandOutputReader.tailLines("a\nb\nc\n", count: 2)

        XCTAssertEqual(result, "c\n",
                       "A trailing newline's extra empty trailing component must be preserved through the " +
                       "slice, not silently dropped")
    }

    func test_tailLines_emptyText_returnsEmpty() {
        // Sanity: a control case with real content must actually produce
        // non-empty, correctly-sliced output -- otherwise the empty-input
        // assertion below would be indistinguishable from a function that
        // always returns "".
        XCTAssertEqual(GhosttyCommandOutputReader.tailLines("a\nb\nc", count: 2), "b\nc",
                       "Precondition: tailLines must slice real content correctly")

        let result = GhosttyCommandOutputReader.tailLines("", count: 3)

        XCTAssertEqual(result, "")
    }

    func test_tailLines_negativeCount_clampsToZero_returnsEmptyWithoutTrapping() {
        let result = GhosttyCommandOutputReader.tailLines("a\nb\nc", count: -1)

        XCTAssertEqual(result, "", "A negative count must clamp to 0 (empty suffix), not trap")
    }
}
