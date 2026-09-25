//
//  MissionMapPolylineTests.swift
//  CalyxTests
//
//  Pins MissionMapPolyline: point(along:t:) (arc-length parameterized
//  travel along an orthogonal route, for the drawn pulse dot),
//  labelAnchor(_:) (where a line's message/conflict label sits), and
//  length(_:).
//

import XCTest
@testable import Calyx

final class MissionMapPolylineTests: XCTestCase {

    // Three segments of unequal length: (0,0)->(60,0) horizontal, length
    // 60; (60,0)->(60,100) vertical, length 100; (60,100)->(100,100)
    // horizontal, length 40. Total length 200.
    private let path: [CGPoint] = [
        CGPoint(x: 0, y: 0), CGPoint(x: 60, y: 0), CGPoint(x: 60, y: 100), CGPoint(x: 100, y: 100),
    ]

    // MARK: - point(along:t:)

    func test_pointAlong_tZero_isTheStart() {
        let point = MissionMapPolyline.point(along: path, t: 0)

        XCTAssertEqual(point, CGPoint(x: 0, y: 0))
    }

    func test_pointAlong_tOne_isTheEnd() {
        let point = MissionMapPolyline.point(along: path, t: 1)

        XCTAssertEqual(point, CGPoint(x: 100, y: 100))
    }

    /// t = 0.5 is 100 arc-length units in: 60 units consumes segment 1,
    /// leaving 40 units into segment 2 (length 100, vertical from
    /// (60,0)), landing at (60, 40).
    func test_pointAlong_tHalf_isByArcLengthNotByPointIndex() {
        let point = MissionMapPolyline.point(along: path, t: 0.5)

        XCTAssertEqual(point.x, 60, accuracy: 0.01)
        XCTAssertEqual(point.y, 40, accuracy: 0.01)
    }

    /// t = 0.25 is 50 arc-length units in, 50 units into segment 1
    /// (length 60, horizontal from (0,0)): (50, 0).
    func test_pointAlong_tQuarter_isMidSegmentOne() {
        let point = MissionMapPolyline.point(along: path, t: 0.25)

        XCTAssertEqual(point.x, 50, accuracy: 0.01)
        XCTAssertEqual(point.y, 0, accuracy: 0.01)
    }

    /// t = 0.9 is 180 arc-length units in: segments 1+2 consume 160,
    /// leaving 20 units into segment 3 (length 40, horizontal from
    /// (60,100)): (80, 100).
    func test_pointAlong_tNinetyPercent_isMidSegmentThree() {
        let point = MissionMapPolyline.point(along: path, t: 0.9)

        XCTAssertEqual(point.x, 80, accuracy: 0.01)
        XCTAssertEqual(point.y, 100, accuracy: 0.01)
    }

    func test_pointAlong_tBelowZero_clampsToStart() {
        let point = MissionMapPolyline.point(along: path, t: -1)

        XCTAssertEqual(point, CGPoint(x: 0, y: 0))
    }

    func test_pointAlong_tAboveOne_clampsToEnd() {
        let point = MissionMapPolyline.point(along: path, t: 2)

        XCTAssertEqual(point, CGPoint(x: 100, y: 100))
    }

    /// A single-point "path" (a degenerate route) returns that point for
    /// any t: there is nothing to travel along.
    func test_pointAlong_singlePointPath_alwaysReturnsThatPoint() {
        let single = [CGPoint(x: 42, y: 17)]

        XCTAssertEqual(MissionMapPolyline.point(along: single, t: 0), single[0])
        XCTAssertEqual(MissionMapPolyline.point(along: single, t: 0.5), single[0])
        XCTAssertEqual(MissionMapPolyline.point(along: single, t: 1), single[0])
    }

    // MARK: - labelAnchor

    /// The midpoint of the longest segment (segment 2: (60,0)->(60,100),
    /// length 100): (60, 50).
    func test_labelAnchor_isTheMidpointOfTheLongestSegment() {
        let anchor = MissionMapPolyline.labelAnchor(path)

        XCTAssertEqual(anchor.x, 60, accuracy: 0.01)
        XCTAssertEqual(anchor.y, 50, accuracy: 0.01)
    }

    /// Segment 1 ((0,0)->(100,0), length 100) and segment 3
    /// ((100,30)->(200,30), length 100) tie for longest; the FIRST one
    /// wins, so the anchor is segment 1's midpoint (50, 0), not
    /// segment 3's (150, 30).
    func test_labelAnchor_tiedLongestSegments_picksTheFirst() {
        let tiedPath: [CGPoint] = [
            CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0), CGPoint(x: 100, y: 30), CGPoint(x: 200, y: 30),
        ]

        let anchor = MissionMapPolyline.labelAnchor(tiedPath)

        XCTAssertEqual(anchor.x, 50, accuracy: 0.01)
        XCTAssertEqual(anchor.y, 0, accuracy: 0.01)
    }

    /// A 2-point path has exactly one segment, whose midpoint is the
    /// only possible anchor.
    func test_labelAnchor_twoPointPath_isItsMidpoint() {
        let straight: [CGPoint] = [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 40)]

        let anchor = MissionMapPolyline.labelAnchor(straight)

        XCTAssertEqual(anchor.x, 50, accuracy: 0.01)
        XCTAssertEqual(anchor.y, 20, accuracy: 0.01)
    }

    // MARK: - length

    func test_length_threeSegmentPath_sumsToTwoHundred() {
        XCTAssertEqual(MissionMapPolyline.length(path), 200, accuracy: 0.01)
    }

    func test_length_twoPointPath_isTheDistanceBetweenThem() {
        let straight: [CGPoint] = [CGPoint(x: 0, y: 0), CGPoint(x: 30, y: 40)]

        XCTAssertEqual(MissionMapPolyline.length(straight), 50, accuracy: 0.01)
    }

    func test_length_singlePointPath_isZero() {
        XCTAssertEqual(MissionMapPolyline.length([CGPoint(x: 5, y: 5)]), 0, accuracy: 0.01)
    }
}
