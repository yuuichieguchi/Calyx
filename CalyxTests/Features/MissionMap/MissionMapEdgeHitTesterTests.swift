//
//  MissionMapEdgeHitTesterTests.swift
//  CalyxTests
//
//  Pins MissionMapEdgeHitTester.nearest(point:edges:tolerance:) and
//  nearest(point:polylines:tolerance:), the pure point-to-segment /
//  point-to-polyline hit tests Mission Map's Canvas-drawn edges need
//  since Canvas has no per-element hit testing of its own. Now that
//  every line is an orthogonal route (see MissionMapRouterTests), the
//  polyline fixture is a 4-point orthogonal U-route rather than a
//  flattened quad curve.
//
//  Coverage:
//  - A point exactly on a line segment is hit
//  - A point beyond `tolerance` from every segment is a miss (nil)
//  - Given two segments, the CLOSER one wins
//  - A point near the U-route's flat top, far from the straight chord
//    between its endpoints, hits
//  - The chord midpoint of the U-route misses it (too far from every
//    actual segment)
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

    // MARK: - Polylines (orthogonal routes)

    /// A U-shaped orthogonal route: down from (0,0) to (0,50), across to
    /// (200,50), back up to (200,0). Its chord (the straight line from
    /// (0,0) to (200,0)) runs right along y = 0, 50pt from the route's
    /// actual middle segment.
    private let uRoute: [CGPoint] = [
        CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 50), CGPoint(x: 200, y: 50), CGPoint(x: 200, y: 0),
    ]

    func test_nearestPolyline_pointNearMiddleSegment_farFromChord_hits() {
        let edgeID = UUID()

        // 2pt perpendicular distance from the horizontal segment at y=50.
        let result = MissionMapEdgeHitTester.nearest(
            point: CGPoint(x: 100, y: 48), polylines: [(id: edgeID, points: uRoute)], tolerance: 6
        )

        XCTAssertEqual(result, edgeID)
    }

    func test_nearestPolyline_chordMidpoint_misses() {
        let edgeID = UUID()

        // (100, 0) is 50pt from every actual segment of the U-route.
        let result = MissionMapEdgeHitTester.nearest(
            point: CGPoint(x: 100, y: 0), polylines: [(id: edgeID, points: uRoute)], tolerance: 6
        )

        XCTAssertNil(result)
    }

    /// A 2-point polyline behaves as the plain segment.
    func test_nearestPolyline_twoPointPolyline_behavesAsSegment() {
        let edgeID = UUID()
        let polylines: [(id: UUID, points: [CGPoint])] = [
            (id: edgeID, points: [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0)]),
        ]

        XCTAssertEqual(
            MissionMapEdgeHitTester.nearest(point: CGPoint(x: 50, y: 4), polylines: polylines, tolerance: 6),
            edgeID
        )
        XCTAssertNil(
            MissionMapEdgeHitTester.nearest(point: CGPoint(x: 150, y: 0), polylines: polylines, tolerance: 6)
        )
    }

    /// Among polylines within tolerance, the closer one wins.
    func test_nearestPolyline_closerOneWins() {
        let nearID = UUID()
        let farID = UUID()
        let polylines: [(id: UUID, points: [CGPoint])] = [
            (id: farID, points: [CGPoint(x: 0, y: 5), CGPoint(x: 50, y: 5), CGPoint(x: 100, y: 5)]),
            (id: nearID, points: [CGPoint(x: 0, y: 1), CGPoint(x: 50, y: 1), CGPoint(x: 100, y: 1)]),
        ]

        let result = MissionMapEdgeHitTester.nearest(point: CGPoint(x: 50, y: 0), polylines: polylines, tolerance: 10)

        XCTAssertEqual(result, nearID)
    }
}
