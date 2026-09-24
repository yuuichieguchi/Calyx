//
//  MCPProtocolVersionTests.swift
//  CalyxTests
//
//  Coverage: `MCPProtocolVersion` raw values, `CaseIterable` ordering
//  contract, and `isModern` classification (2026-07-28 is modern/stateless;
//  everything earlier is legacy).
//

import XCTest
@testable import Calyx

final class MCPProtocolVersionTests: XCTestCase {

    func test_rawValues_matchSpecDateStrings() {
        XCTAssertEqual(MCPProtocolVersion.v2026_07_28.rawValue, "2026-07-28")
        XCTAssertEqual(MCPProtocolVersion.v2025_11_25.rawValue, "2025-11-25")
        XCTAssertEqual(MCPProtocolVersion.v2025_06_18.rawValue, "2025-06-18")
        XCTAssertEqual(MCPProtocolVersion.v2025_03_26.rawValue, "2025-03-26")
        XCTAssertEqual(MCPProtocolVersion.v2024_11_05.rawValue, "2024-11-05")
    }

    func test_isModern_trueOnlyForNewestVersion() {
        XCTAssertTrue(MCPProtocolVersion.v2026_07_28.isModern)
        XCTAssertFalse(MCPProtocolVersion.v2025_11_25.isModern)
        XCTAssertFalse(MCPProtocolVersion.v2025_06_18.isModern)
        XCTAssertFalse(MCPProtocolVersion.v2025_03_26.isModern)
        XCTAssertFalse(MCPProtocolVersion.v2024_11_05.isModern)
    }

    func test_allCases_containsExactlyFiveSupportedVersions() {
        XCTAssertEqual(Set(MCPProtocolVersion.allCases.map(\.rawValue)), [
            "2026-07-28", "2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05",
        ])
    }

    func test_init_fromRawValue_roundTrips() {
        XCTAssertEqual(MCPProtocolVersion(rawValue: "2025-11-25"), .v2025_11_25)
        XCTAssertNil(MCPProtocolVersion(rawValue: "1999-01-01"))
    }
}
