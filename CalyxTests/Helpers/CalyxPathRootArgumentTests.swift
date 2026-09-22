//
//  CalyxPathRootArgumentTests.swift
//  CalyxTests
//
//  Coverage for CalyxPathRootArgument.parse(_:) (Calyx/Helpers
//  /CalyxPathRootArgument.swift), the pure `--calyx-path-root=<dir>`
//  parser CalyxPathRoot consults first. Mirrors
//  DemoWindowFrameArgumentTests's own coverage shape for the sibling
//  `--demo-window-frame=` parser.
//

import XCTest
@testable import Calyx

final class CalyxPathRootArgumentTests: XCTestCase {

    func test_validValue_parsesToString() {
        let root = CalyxPathRootArgument.parse(["--uitesting", "--calyx-path-root=/tmp/some-dir"])
        XCTAssertEqual(root, "/tmp/some-dir")
    }

    func test_missingFlag_returnsNil() {
        XCTAssertNil(CalyxPathRootArgument.parse(["--uitesting", "-AppleLanguages", "(en)"]))
    }

    func test_emptyValue_returnsNil() {
        XCTAssertNil(CalyxPathRootArgument.parse(["--calyx-path-root="]),
                     "An empty value is never a usable directory path")
    }

    func test_noArguments_returnsNil() {
        XCTAssertNil(CalyxPathRootArgument.parse([]))
    }

    func test_valueContainingEqualsSign_keepsEverythingAfterTheFirstEquals() {
        let root = CalyxPathRootArgument.parse(["--calyx-path-root=/tmp/a=b"])
        XCTAssertEqual(root, "/tmp/a=b",
                       "Only the fixed `--calyx-path-root=` prefix is stripped -- an `=` inside the " +
                       "path value itself is part of the value, not a second delimiter")
    }

    func test_multipleOccurrences_usesTheFirstOne() {
        let root = CalyxPathRootArgument.parse(["--calyx-path-root=/tmp/first", "--calyx-path-root=/tmp/second"])
        XCTAssertEqual(root, "/tmp/first")
    }
}
