//
//  MissionMapEdgeHitTesterTests.swift
//  CalyxTests
//
//  Pins MissionMapEdgeHitTester.nearest(point:edges:tolerance:), the
//  pure point-to-segment hit test Mission Map's Canvas-drawn edges need
//  since Canvas has no per-element hit testing of its own.
//
//  Coverage:
//  - A point exactly on a line segment is hit
//  - A point beyond `tolerance` from every segment is a miss (nil)
//  - Given two segments, the CLOSER one wins
//

import XCTest
@testable import Calyx

final class MissionMapEdgeHitTesterTests: XCTestCase {

    func test_nearest_pointOnSegment_hits() {
        let edgeID = UUID()
        let edges: [(id: UUID, a: CGPoint, b: CGPoint)] = [
            (id: edgeID, a: CGPoint(x: 0, y: 0), b: CGPoint(x: 100, y: 0)),
        ]

        let result = MissionMapEdgeHitTester.nearest(point: CGPoint(x: 50, y: 0), edges: edges, tolerance: 6)

        XCTAssertEqual(result, edgeID)
    }

    func test_nearest_pointWithinTolerance_hits() {
        let edgeID = UUID()
        let edges: [(id: UUID, a: CGPoint, b: CGPoint)] = [
            (id: edgeID, a: CGPoint(x: 0, y: 0), b: CGPoint(x: 100, y: 0)),
        ]

        // 4pt perpendicular distance, under the 6pt tolerance.
        let result = MissionMapEdgeHitTester.nearest(point: CGPoint(x: 50, y: 4), edges: edges, tolerance: 6)

        XCTAssertEqual(result, edgeID)
    }

    func test_nearest_pointBeyondTolerance_misses() {
        let edgeID = UUID()
        let edges: [(id: UUID, a: CGPoint, b: CGPoint)] = [
            (id: edgeID, a: CGPoint(x: 0, y: 0), b: CGPoint(x: 100, y: 0)),
        ]

        let result = MissionMapEdgeHitTester.nearest(point: CGPoint(x: 50, y: 50), edges: edges, tolerance: 6)

        XCTAssertNil(result)
    }

    /// Beyond a segment's own endpoints (off the end, not just off to the
    /// side), even within perpendicular tolerance of the infinite line,
    /// must miss -- the hit test is against the SEGMENT, not the line
    /// through it.
    func test_nearest_pointBeyondSegmentEndpoint_misses() {
        let edgeID = UUID()
        let edges: [(id: UUID, a: CGPoint, b: CGPoint)] = [
            (id: edgeID, a: CGPoint(x: 0, y: 0), b: CGPoint(x: 100, y: 0)),
        ]

        let result = MissionMapEdgeHitTester.nearest(point: CGPoint(x: 150, y: 0), edges: edges, tolerance: 6)

        XCTAssertNil(result)
    }

    /// With two segments both within tolerance, the CLOSER one must win.
    func test_nearest_twoSegmentsWithinTolerance_closerOneWins() {
        let nearID = UUID()
        let farID = UUID()
        let edges: [(id: UUID, a: CGPoint, b: CGPoint)] = [
            (id: farID, a: CGPoint(x: 0, y: 5), b: CGPoint(x: 100, y: 5)),
            (id: nearID, a: CGPoint(x: 0, y: 1), b: CGPoint(x: 100, y: 1)),
        ]

        let result = MissionMapEdgeHitTester.nearest(point: CGPoint(x: 50, y: 0), edges: edges, tolerance: 10)

        XCTAssertEqual(result, nearID)
    }

    func test_nearest_noEdges_returnsNil() {
        let result = MissionMapEdgeHitTester.nearest(point: CGPoint(x: 0, y: 0), edges: [], tolerance: 6)

        XCTAssertNil(result)
    }
}
