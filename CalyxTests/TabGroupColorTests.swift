//
//  TabGroupColorTests.swift
//  CalyxTests
//
//  Tests for TabGroupColor.nextColor(excluding:) which assigns
//  the next available color to a new tab group.
//

import XCTest
@testable import Calyx

@MainActor
final class TabGroupColorTests: XCTestCase {

    // MARK: - nextColor(excluding:)

    /// An empty used-colors list should return the first case (.red).
    func test_nextColor_emptyList_returnsFirst() {
        let result = TabGroupColor.nextColor(excluding: [])
        XCTAssertEqual(result, .red, "With no colors in use, the first allCases entry should be returned")
    }

    /// When only .red is used, the next unused color in order is .orange.
    func test_nextColor_oneUsed_skipsIt() {
        let result = TabGroupColor.nextColor(excluding: [.red])
        XCTAssertEqual(result, .orange, "Should skip .red and return .orange")
    }

    /// When .red and .orange are both used, the next unused color is .yellow.
    func test_nextColor_skipsMultipleUsed() {
        let result = TabGroupColor.nextColor(excluding: [.red, .orange])
        XCTAssertEqual(result, .yellow, "Should skip .red and .orange, returning .yellow")
    }

    /// When every color appears at least once, returns the least frequently
    /// used color (first in allCases order among ties).
    func test_nextColor_allUsed_returnsLeastFrequent() {
        let allOnce: [TabGroupColor] = [
            .red, .orange, .yellow, .green, .mint,
            .teal, .cyan, .blue, .indigo, .purple,
        ]
        // Add a second .green to make it the most frequent
        let usedColors = allOnce + [.green]
        let result = TabGroupColor.nextColor(excluding: usedColors)
        XCTAssertEqual(result, .red, "Should return .red as the least frequent (count 1) in allCases order")
    }

    /// Simulates deleting first group — only .orange remains.
    /// .red should be returned since it is unused and first in allCases.
    func test_nextColor_duplicateScenario() {
        let result = TabGroupColor.nextColor(excluding: [.orange])
        XCTAssertEqual(result, .red, "Should return .red since it is unused and first in allCases order")
    }
}
