//
//  BoundedLogTests.swift
//  CalyxTests
//
//  BoundedLog keeps at most `capacity` elements, oldest first, dropping
//  the oldest on overflow.
//

import XCTest
@testable import Calyx

final class BoundedLogTests: XCTestCase {

    func test_append_underCapacity_keepsEveryElementInOrder() {
        var log = BoundedLog<Int>(capacity: 3)

        log.append(1)
        log.append(2)

        XCTAssertEqual(log.elements, [1, 2])
        XCTAssertEqual(log.capacity, 3)
    }

    func test_append_atCapacity_keepsEveryElement() {
        var log = BoundedLog<Int>(capacity: 3)

        for value in 1...3 { log.append(value) }

        XCTAssertEqual(log.elements, [1, 2, 3])
    }

    func test_append_pastCapacity_evictsOldestFirst() {
        var log = BoundedLog<Int>(capacity: 3)

        for value in 1...5 { log.append(value) }

        XCTAssertEqual(log.elements, [3, 4, 5])
    }

    func test_removeAllWhere_removesOnlyMatchingElementsAndKeepsOrder() {
        var log = BoundedLog<Int>(capacity: 5)
        for value in 1...5 { log.append(value) }

        log.removeAll { $0.isMultiple(of: 2) }

        XCTAssertEqual(log.elements, [1, 3, 5])
    }

    func test_removeAllWhere_freesCapacityForLaterAppends() {
        var log = BoundedLog<Int>(capacity: 3)
        for value in 1...3 { log.append(value) }

        log.removeAll { $0 == 1 }
        log.append(4)

        XCTAssertEqual(log.elements, [2, 3, 4])
    }

    func test_removeAll_emptiesTheLog() {
        var log = BoundedLog<Int>(capacity: 3)
        for value in 1...3 { log.append(value) }

        log.removeAll()

        XCTAssertTrue(log.elements.isEmpty)
    }
}
