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
    // Assignment order: red, blue, yellow, purple, green, orange, indigo, mint, cyan, teal

    /// An empty used-colors list should return the first in assignment order (.red).
    func test_nextColor_emptyList_returnsFirst() {
        let result = TabGroupColor.nextColor(excluding: [])
        XCTAssertEqual(result, .red, "With no colors in use, the first assignment order entry should be returned")
    }

    /// When only .red is used, the next color in assignment order is .blue.
    func test_nextColor_oneUsed_skipsIt() {
        let result = TabGroupColor.nextColor(excluding: [.red])
        XCTAssertEqual(result, .blue, "Should skip .red and return .blue (2nd in assignment order)")
    }

    /// When .red and .blue are both used, the next color is .yellow.
    func test_nextColor_skipsMultipleUsed() {
        let result = TabGroupColor.nextColor(excluding: [.red, .blue])
        XCTAssertEqual(result, .yellow, "Should skip .red and .blue, returning .yellow")
    }

    /// When every color appears at least once, returns the least frequently
    /// used color (first in assignment order among ties).
    func test_nextColor_allUsed_returnsLeastFrequent() {
        let allOnce: [TabGroupColor] = [
            .red, .orange, .yellow, .green, .mint,
            .teal, .cyan, .blue, .indigo, .purple,
        ]
        // Add a second .green to make it the most frequent
        let usedColors = allOnce + [.green]
        let result = TabGroupColor.nextColor(excluding: usedColors)
        XCTAssertEqual(result, .red, "Should return .red as the least frequent (count 1) in assignment order")
    }

    /// Simulates deleting first group — only .blue remains.
    /// .red should be returned since it is unused and first in assignment order.
    func test_nextColor_duplicateScenario() {
        let result = TabGroupColor.nextColor(excluding: [.blue])
        XCTAssertEqual(result, .red, "Should return .red since it is unused and first in assignment order")
    }

    /// When all 10 colors are used exactly once (exact tie), returns
    /// the first color in assignment order (.red).
    func test_nextColor_allUsedEqualFrequency_returnsFirst() {
        let allOnce: [TabGroupColor] = [
            .red, .orange, .yellow, .green, .mint,
            .teal, .cyan, .blue, .indigo, .purple,
        ]
        let result = TabGroupColor.nextColor(excluding: allOnce)
        XCTAssertEqual(result, .red, "Equal frequency tie should return .red (first in assignment order)")
    }

    /// Consecutive colors in assignment order should be visually distinct.
    func test_nextColor_consecutiveColorsAreDistinct() {
        var used: [TabGroupColor] = []
        var sequence: [TabGroupColor] = []
        for _ in 0..<10 {
            let next = TabGroupColor.nextColor(excluding: used)
            sequence.append(next)
            used.append(next)
        }
        XCTAssertEqual(sequence, [.red, .blue, .yellow, .purple, .green, .orange, .indigo, .mint, .cyan, .teal])
    }
}
