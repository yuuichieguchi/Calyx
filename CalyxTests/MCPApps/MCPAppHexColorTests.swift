//
//  MCPAppHexColorTests.swift
//  CalyxTests
//
//  `MCPAppHexColor` (contract section 13a.1): accepts `#rrggbb` and
//  `rrggbb` in either case and yields the lowercase `#rrggbb` form;
//  anything else is nil. `init(rgb:)` builds the same value from 0xrrggbb.
//

import XCTest
@testable import Calyx

final class MCPAppHexColorTests: XCTestCase {

    func test_acceptsSixDigitsWithHash_lowercased() {
        XCTAssertEqual(MCPAppHexColor("#1A2b3C")?.hex, "#1a2b3c")
    }

    func test_acceptsSixDigitsWithoutHash() {
        XCTAssertEqual(MCPAppHexColor("ffffff")?.hex, "#ffffff")
    }

    func test_fromRGB_equalsTheParsedForm() {
        XCTAssertEqual(MCPAppHexColor(rgb: 0x1A2B3C), MCPAppHexColor("#1a2b3c"))
        XCTAssertEqual(MCPAppHexColor(rgb: 0x00000F).hex, "#00000f")
    }

    func test_rejectsEverythingElse() {
        for text in ["", "#", "#fff", "fff", "#1234567", "#12345g", "##123456", " #123456", "#123456 ", "rgb(1, 2, 3)", "+12345"] {
            XCTAssertNil(MCPAppHexColor(text), "\"\(text)\" is not #rrggbb or rrggbb")
        }
    }
}
