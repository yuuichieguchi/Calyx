//
//  GrokCLIVersionTests.swift
//  CalyxTests
//
//  C-D17: Grok's `bearer_token_file` exists from 1.0.52 (absent in
//  1.0.34, V3-3). `GrokCLIVersion.parse` reads `grok --version` output;
//  `detect()` (which runs a real `grok`) is deliberately not exercised.
//

import XCTest
@testable import Calyx

final class GrokCLIVersionTests: XCTestCase {

    private func v(_ a: Int, _ b: Int, _ c: Int) -> GrokCLIVersion { GrokCLIVersion(major: a, minor: b, patch: c) }

    func test_parse_plain() { XCTAssertEqual(GrokCLIVersion.parse("1.0.52"), v(1, 0, 52)) }
    func test_parse_prefixedWithName() { XCTAssertEqual(GrokCLIVersion.parse("grok 1.0.52"), v(1, 0, 52)) }
    func test_parse_withVAndTrailingNewline() {
        XCTAssertEqual(GrokCLIVersion.parse("grok-cli v1.0.52\n"), v(1, 0, 52))
    }
    func test_parse_multiDigitComponents() { XCTAssertEqual(GrokCLIVersion.parse("12.34.567"), v(12, 34, 567)) }
    func test_parse_firstTripleWins() { XCTAssertEqual(GrokCLIVersion.parse("grok 1.0.34 (node 2.3.4)"), v(1, 0, 34)) }
    func test_parse_garbage_isNil() { XCTAssertNil(GrokCLIVersion.parse("command not found")) }
    func test_parse_empty_isNil() { XCTAssertNil(GrokCLIVersion.parse("")) }
    func test_parse_twoComponents_isNil() { XCTAssertNil(GrokCLIVersion.parse("1.0")) }

    func test_ordering() {
        XCTAssertLessThan(v(1, 0, 51), v(1, 0, 52))
        XCTAssertLessThanOrEqual(v(1, 0, 52), v(1, 0, 52))
        XCTAssertFalse(v(1, 0, 52) < v(1, 0, 52))
        XCTAssertLessThan(v(1, 0, 52), v(1, 1, 0))
        XCTAssertLessThan(v(1, 1, 0), v(2, 0, 0))
        XCTAssertLessThan(v(1, 0, 99), v(1, 1, 0), "minor outranks patch")
        XCTAssertLessThan(v(1, 99, 99), v(2, 0, 0), "major outranks minor")
    }

    func test_minimum_is_1_0_52() {
        XCTAssertEqual(GrokCLIVersion.bearerTokenFileMinimum, v(1, 0, 52))
    }

    func test_supportsBearerTokenFile_boundary() {
        XCTAssertFalse(v(1, 0, 34).supportsBearerTokenFile)
        XCTAssertFalse(v(1, 0, 51).supportsBearerTokenFile)
        XCTAssertTrue(v(1, 0, 52).supportsBearerTokenFile)
        XCTAssertTrue(v(1, 0, 53).supportsBearerTokenFile)
        XCTAssertTrue(v(1, 1, 0).supportsBearerTokenFile)
        XCTAssertFalse(v(0, 9, 99).supportsBearerTokenFile)
    }
}
