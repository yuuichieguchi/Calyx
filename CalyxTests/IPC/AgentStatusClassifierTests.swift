//
//  AgentStatusClassifierTests.swift
//  CalyxTests
//
//  TDD Red Phase — tests for AgentStatusClassifier and AgentActivityState.
//
//  Neither AgentStatusClassifier nor AgentActivityState exist yet; this file
//  will produce a compile error (Red phase) until they are implemented.
//
//  Boundary specification:
//    now.timeIntervalSince(lastSeen) in [0, 30)        → .active
//    now.timeIntervalSince(lastSeen) in [30, 5*60)     → .idle
//    now.timeIntervalSince(lastSeen) in [5*60, ...)    → .stale
//

import XCTest
@testable import Calyx

final class AgentStatusClassifierTests: XCTestCase {

    // ==================== Active boundary ====================

    func test_classify_returnsActive_whenIntervalIsZero() {
        // Given: lastSeen == now (interval == 0)
        let now = Date()
        let lastSeen = now

        // When
        let result = AgentStatusClassifier.classify(lastSeen: lastSeen, now: now)

        // Then
        XCTAssertEqual(result, .active,
                       "interval == 0 should be .active")
    }

    func test_classify_returnsActive_whenIntervalIsJustBelowActiveThreshold() {
        // Given: interval == 29.999 (just under the 30-second boundary)
        let now = Date()
        let lastSeen = now.addingTimeInterval(-29.999)

        // When
        let result = AgentStatusClassifier.classify(lastSeen: lastSeen, now: now)

        // Then
        XCTAssertEqual(result, .active,
                       "interval == 29.999 should still be .active (boundary is exclusive)")
    }

    // ==================== Idle boundary ====================

    func test_classify_returnsIdle_whenIntervalIsExactlyActiveThreshold() {
        // Given: interval == 30.0 (exactly at the active→idle boundary)
        let now = Date()
        let lastSeen = now.addingTimeInterval(-30.0)

        // When
        let result = AgentStatusClassifier.classify(lastSeen: lastSeen, now: now)

        // Then
        XCTAssertEqual(result, .idle,
                       "interval == 30.0 should be .idle (lower bound of idle range)")
    }

    func test_classify_returnsIdle_whenIntervalIsJustAboveActiveThreshold() {
        // Given: interval == 30.001
        let now = Date()
        let lastSeen = now.addingTimeInterval(-30.001)

        // When
        let result = AgentStatusClassifier.classify(lastSeen: lastSeen, now: now)

        // Then
        XCTAssertEqual(result, .idle,
                       "interval == 30.001 should be .idle")
    }

    func test_classify_returnsIdle_whenIntervalIsJustBelowStaleThreshold() {
        // Given: interval == 4*60 + 59 == 299 seconds (just under 5 minutes)
        let now = Date()
        let lastSeen = now.addingTimeInterval(-(4 * 60 + 59))

        // When
        let result = AgentStatusClassifier.classify(lastSeen: lastSeen, now: now)

        // Then
        XCTAssertEqual(result, .idle,
                       "interval == 4m59s should still be .idle (stale boundary is exclusive)")
    }

    func test_classify_returnsIdle_whenIntervalIsFractionallyBelowStaleThreshold() {
        // Given: interval == 299.999 seconds (symmetric with the 29.999 active-boundary test)
        let now = Date()
        let lastSeen = now.addingTimeInterval(-299.999)

        // When
        let result = AgentStatusClassifier.classify(lastSeen: lastSeen, now: now)

        // Then
        XCTAssertEqual(result, .idle,
                       "interval == 299.999 should still be .idle (stale boundary is 300.0)")
    }

    // ==================== Stale boundary ====================

    func test_classify_returnsStale_whenIntervalIsExactlyStaleThreshold() {
        // Given: interval == 5*60 == 300 seconds (exactly at the idle→stale boundary)
        let now = Date()
        let lastSeen = now.addingTimeInterval(-(5 * 60))

        // When
        let result = AgentStatusClassifier.classify(lastSeen: lastSeen, now: now)

        // Then
        XCTAssertEqual(result, .stale,
                       "interval == 5m00s should be .stale (lower bound of stale range)")
    }

    func test_classify_returnsStale_whenIntervalIsWellAboveStaleThreshold() {
        // Given: interval == 9*60 + 59 == 599 seconds
        let now = Date()
        let lastSeen = now.addingTimeInterval(-(9 * 60 + 59))

        // When
        let result = AgentStatusClassifier.classify(lastSeen: lastSeen, now: now)

        // Then
        XCTAssertEqual(result, .stale,
                       "interval == 9m59s should be .stale")
    }

    func test_classify_returnsStale_whenIntervalIsTenMinutes() {
        // Given: interval == 10*60 == 600 seconds
        let now = Date()
        let lastSeen = now.addingTimeInterval(-(10 * 60))

        // When
        let result = AgentStatusClassifier.classify(lastSeen: lastSeen, now: now)

        // Then
        XCTAssertEqual(result, .stale,
                       "interval == 10m00s should be .stale")
    }
}
