//
//  MissionMapRouterTests.swift
//  CalyxTests
//
//  Pins MissionMapRouter.route(_:obstacles:bounds:options:), the pure
//  orthogonal edge router Mission Map draws IPC and conflict lines
//  through. No behavior branches on rows/groups/card height/"is there a
//  card in between": every layout, including dragged, arbitrary
//  placements, goes through the same orthogonal-visibility-graph +
//  A* + nudging pipeline.
//
//  Coverage:
//  - Every route is orthogonal, starts/ends on its card's boundary, never
//    crosses a card's un-inflated interior, stays within bounds.
//  - Nudging leaves no two different edges' segments collinear and
//    overlapping on the same coordinate.
//  - Determinism: same input twice -> same output. Adding an unrelated
//    edge leaves existing edges' routes unchanged.
//  - Named fixtures from the approved routing addendum (row of three,
//    adjacent round trip, two rows, two bands with a header obstacle,
//    a tall middle card, five randomly dragged overlapping cards, and
//    3, 4 and 5 edges sharing one channel).
//  - A 50-seed property test over random small layouts.
//

import XCTest
@testable import Calyx

final class MissionMapRouterTests: XCTestCase {

    // MARK: - Options pinning

    func test_options_default_hasTheApprovedConstants() {
        let options = MissionMapRouterOptions.default

        XCTAssertEqual(options.obstacleMargin, 6)
        XCTAssertEqual(options.trackSpacing, 8)
        XCTAssertEqual(options.bendPenalty, 40)
    }

    // MARK: - Assertion helpers

    /// Every segment is axis-aligned and non-degenerate, and consecutive
    /// segments alternate between horizontal and vertical -- a simplified
    /// orthogonal polyline, never two collinear segments in a row.
    private func assertOrthogonal(
        _ points: [CGPoint], file: StaticString = #filePath, line: UInt = #line
    ) {
        guard points.count >= 2 else {
            XCTFail("A route needs at least 2 points", file: file, line: line)
            return
        }
        var previousAxis: Int? // 0 = horizontal, 1 = vertical
        for i in 0..<(points.count - 1) {
            let a = points[i]
            let b = points[i + 1]
            let dx = abs(b.x - a.x)
            let dy = abs(b.y - a.y)
            let isHorizontal = dy < 0.001 && dx > 0.001
            let isVertical = dx < 0.001 && dy > 0.001
            XCTAssertTrue(
                isHorizontal || isVertical,
                "Segment \(a)->\(b) is not axis-aligned and non-degenerate",
                file: file, line: line
            )
            let axis = isHorizontal ? 0 : 1
            if let previousAxis {
                XCTAssertNotEqual(
                    previousAxis, axis,
                    "Consecutive segments at index \(i) must alternate axis",
                    file: file, line: line
                )
            }
            previousAxis = axis
        }
    }

    private func assertOnBoundary(
        _ point: CGPoint, of rect: CGRect, tolerance: CGFloat = 0.5,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let onVerticalEdge = (abs(point.x - rect.minX) < tolerance || abs(point.x - rect.maxX) < tolerance)
            && point.y >= rect.minY - tolerance && point.y <= rect.maxY + tolerance
        let onHorizontalEdge = (abs(point.y - rect.minY) < tolerance || abs(point.y - rect.maxY) < tolerance)
            && point.x >= rect.minX - tolerance && point.x <= rect.maxX + tolerance
        XCTAssertTrue(
            onVerticalEdge || onHorizontalEdge,
            "\(point) is not on the boundary of \(rect)",
            file: file, line: line
        )
    }

    /// No segment of `points` crosses the OPEN interior of any un-inflated
    /// card rect in `cards` (touching a boundary is fine).
    private func assertNoSegmentCrossesInterior(
        _ points: [CGPoint], cards: [CGRect], file: StaticString = #filePath, line: UInt = #line
    ) {
        guard points.count >= 2 else { return }
        let eps: CGFloat = 0.01
        for i in 0..<(points.count - 1) {
            let a = points[i]
            let b = points[i + 1]
            for rect in cards {
                if abs(a.y - b.y) < eps {
                    // Horizontal segment at y, x in [x1, x2].
                    let y = a.y
                    let x1 = min(a.x, b.x)
                    let x2 = max(a.x, b.x)
                    let crossesY = y > rect.minY + eps && y < rect.maxY - eps
                    let overlapsX = max(x1, rect.minX) < min(x2, rect.maxX) - eps
                    XCTAssertFalse(
                        crossesY && overlapsX,
                        "Horizontal segment \(a)->\(b) crosses the interior of \(rect)",
                        file: file, line: line
                    )
                } else {
                    // Vertical segment at x, y in [y1, y2].
                    let x = a.x
                    let y1 = min(a.y, b.y)
                    let y2 = max(a.y, b.y)
                    let crossesX = x > rect.minX + eps && x < rect.maxX - eps
                    let overlapsY = max(y1, rect.minY) < min(y2, rect.maxY) - eps
                    XCTAssertFalse(
                        crossesX && overlapsY,
                        "Vertical segment \(a)->\(b) crosses the interior of \(rect)",
                        file: file, line: line
                    )
                }
            }
        }
    }

    private func assertWithin(
        _ points: [CGPoint], _ bounds: CGRect, tolerance: CGFloat = 0.5,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        for point in points {
            XCTAssertTrue(
                point.x >= bounds.minX - tolerance && point.x <= bounds.maxX + tolerance
                    && point.y >= bounds.minY - tolerance && point.y <= bounds.maxY + tolerance,
                "\(point) is outside \(bounds)",
                file: file, line: line
            )
        }
    }

    /// No two segments from DIFFERENT routes are collinear (same axis,
    /// same coordinate) and overlap with positive length along the
    /// shared axis. Touching at a single endpoint is allowed.
    private func assertNoCollinearOverlap(
        _ routes: [[CGPoint]], file: StaticString = #filePath, line: UInt = #line
    ) {
        let eps: CGFloat = 0.01
        struct Seg { let horizontal: Bool; let coord: CGFloat; let lo: CGFloat; let hi: CGFloat; let routeIndex: Int }
        var segments: [Seg] = []
        for (routeIndex, points) in routes.enumerated() {
            guard points.count >= 2 else { continue }
            for i in 0..<(points.count - 1) {
                let a = points[i]
                let b = points[i + 1]
                if abs(a.y - b.y) < eps {
                    segments.append(Seg(horizontal: true, coord: a.y, lo: min(a.x, b.x), hi: max(a.x, b.x), routeIndex: routeIndex))
                } else {
                    segments.append(Seg(horizontal: false, coord: a.x, lo: min(a.y, b.y), hi: max(a.y, b.y), routeIndex: routeIndex))
                }
            }
        }
        for i in 0..<segments.count {
            for j in (i + 1)..<segments.count {
                let s1 = segments[i]
                let s2 = segments[j]
                guard s1.routeIndex != s2.routeIndex else { continue }
                guard s1.horizontal == s2.horizontal else { continue }
                guard abs(s1.coord - s2.coord) < eps else { continue }
                let overlap = min(s1.hi, s2.hi) - max(s1.lo, s2.lo)
                XCTAssertFalse(
                    overlap > eps,
                    "Routes \(s1.routeIndex) and \(s2.routeIndex) have a collinear overlapping segment at coord \(s1.coord)",
                    file: file, line: line
                )
            }
        }
    }

    /// Runs the full invariant suite for one route against its (from, to)
    /// card pair and the full obstacle set.
    private func assertValidRoute(
        _ points: [CGPoint], from: CGRect, to: CGRect, cards: [CGRect], bounds: CGRect,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        assertOrthogonal(points, file: file, line: line)
        assertOnBoundary(points.first!, of: from, file: file, line: line)
        assertOnBoundary(points.last!, of: to, file: file, line: line)
        assertNoSegmentCrossesInterior(points, cards: cards, file: file, line: line)
        assertWithin(points, bounds, file: file, line: line)
    }

    // MARK: - Fixture: row of three

    func test_route_rowOfThree_detoursAroundMiddleCard() {
        let a = CGRect(x: 40, y: 40, width: 260, height: 150)
        let b = CGRect(x: 340, y: 40, width: 260, height: 150)
        let c = CGRect(x: 640, y: 40, width: 260, height: 150)
        let bounds = CGRect(x: 0, y: 0, width: 940, height: 230)
        let edgeID = UUID()
        let requests = [MissionMapRouteRequest(id: edgeID, from: c, to: a)]

        let routes = MissionMapRouter.route(requests, obstacles: [a, b, c], bounds: bounds)

        guard let points = routes[edgeID] else {
            return XCTFail("Missing route for row-of-three edge")
        }
        assertValidRoute(points, from: c, to: a, cards: [a, b, c], bounds: bounds)
        XCTAssertGreaterThanOrEqual(points.count, 4, "Detouring around b needs at least 2 bends")
    }

    // MARK: - Fixture: adjacent round trip (acf3d0538 visual regression)

    func test_route_adjacentRoundTrip_bothLinesAreTwoPointsSharingXDifferingByTrackSpacing() {
        let a = CGRect(x: 40, y: 40, width: 260, height: 150)
        let b = CGRect(x: 340, y: 40, width: 260, height: 150)
        let bounds = CGRect(x: 0, y: 0, width: 640, height: 230)
        let forward = UUID()
        let backward = UUID()
        let requests = [
            MissionMapRouteRequest(id: forward, from: a, to: b),
            MissionMapRouteRequest(id: backward, from: b, to: a),
        ]

        let routes = MissionMapRouter.route(requests, obstacles: [a, b], bounds: bounds)

        guard let forwardPoints = routes[forward], let backwardPoints = routes[backward] else {
            return XCTFail("Missing adjacent round-trip routes")
        }
        XCTAssertEqual(forwardPoints.count, 2)
        XCTAssertEqual(backwardPoints.count, 2)
        let forwardXs = Set(forwardPoints.map(\.x))
        let backwardXs = Set(backwardPoints.map(\.x))
        XCTAssertEqual(forwardXs, Set([300, 340]))
        XCTAssertEqual(backwardXs, Set([300, 340]))
        // Both endpoints of each 2-point route are at the same y (a
        // horizontal segment); the two routes are nudged to opposite
        // sides of the card-center line (y = 115), symmetric by
        // trackSpacing / 2.
        let forwardY = forwardPoints[0].y
        let backwardY = backwardPoints[0].y
        XCTAssertEqual(forwardPoints[1].y, forwardY, accuracy: 0.01)
        XCTAssertEqual(backwardPoints[1].y, backwardY, accuracy: 0.01)
        XCTAssertEqual(abs(forwardY - backwardY), 8, accuracy: 0.01, "trackSpacing is 8")
        XCTAssertEqual(Set([forwardY, backwardY]), Set([111, 119]))
        assertValidRoute(forwardPoints, from: a, to: b, cards: [a, b], bounds: bounds)
        assertValidRoute(backwardPoints, from: b, to: a, cards: [a, b], bounds: bounds)
        assertNoCollinearOverlap([forwardPoints, backwardPoints])
    }

    // MARK: - Fixture: two rows, cross-row edge

    func test_route_twoRows_crossRowEdgeIsValid() {
        let p1 = CGRect(x: 40, y: 40, width: 260, height: 150)
        let p2 = CGRect(x: 340, y: 40, width: 260, height: 150)
        let q1 = CGRect(x: 40, y: 270, width: 260, height: 150)
        let bounds = CGRect(x: 0, y: 0, width: 640, height: 460)
        let edgeID = UUID()
        let requests = [MissionMapRouteRequest(id: edgeID, from: p2, to: q1)]
        let obstacles = [p1, p2, q1]

        let routes = MissionMapRouter.route(requests, obstacles: obstacles, bounds: bounds)

        guard let points = routes[edgeID] else { return XCTFail("Missing cross-row route") }
        assertValidRoute(points, from: p2, to: q1, cards: obstacles, bounds: bounds)
    }

    // MARK: - Fixture: two bands with a header obstacle

    func test_route_twoBands_crossBandEdgeAvoidsHeaderObstacle() {
        let header1 = CGRect(x: 40, y: 40, width: 200, height: 24)
        let card1 = CGRect(x: 40, y: 104, width: 260, height: 150) // midX = 170
        let header2 = CGRect(x: 40, y: 294, width: 200, height: 24) // x-range [40, 240] covers midX 170
        let card2 = CGRect(x: 40, y: 358, width: 260, height: 150)
        let bounds = CGRect(x: 0, y: 0, width: 340, height: 548)
        let edgeID = UUID()
        let requests = [MissionMapRouteRequest(id: edgeID, from: card1, to: card2)]
        let obstacles = [header1, card1, header2, card2]

        let routes = MissionMapRouter.route(requests, obstacles: obstacles, bounds: bounds)

        guard let points = routes[edgeID] else { return XCTFail("Missing cross-band route") }
        assertValidRoute(points, from: card1, to: card2, cards: obstacles, bounds: bounds)
        // A straight vertical drop at x = 170 would cut through header2's
        // [40, 240] x-range: the route must have detoured, i.e. is not
        // a single 2-point straight line.
        XCTAssertGreaterThan(points.count, 2, "Header2 must force a detour")
    }

    // MARK: - Fixture: tall middle card (3 children, 150 + 60)

    func test_route_tallMiddleCard_detoursAroundFullHeight() {
        let a = CGRect(x: 40, y: 40, width: 260, height: 150)
        let mid = CGRect(x: 340, y: 40, width: 260, height: 210) // 150 base + 3*20 child rows
        let c = CGRect(x: 640, y: 40, width: 260, height: 150)
        let bounds = CGRect(x: 0, y: 0, width: 940, height: 330)
        let edgeID = UUID()
        let requests = [MissionMapRouteRequest(id: edgeID, from: a, to: c)]
        let obstacles = [a, mid, c]

        let routes = MissionMapRouter.route(requests, obstacles: obstacles, bounds: bounds)

        guard let points = routes[edgeID] else { return XCTFail("Missing tall-middle-card route") }
        assertValidRoute(points, from: a, to: c, cards: obstacles, bounds: bounds)
        XCTAssertGreaterThanOrEqual(points.count, 4)
    }

    // MARK: - Fixture: five randomly dragged, partially overlapping cards

    func test_route_fiveDraggedCards_routesEveryDisjointPair() {
        var rng = SplitMix64(seed: 20260925)
        let baseOrigins: [CGPoint] = [
            CGPoint(x: 40, y: 40), CGPoint(x: 340, y: 40), CGPoint(x: 640, y: 40),
            CGPoint(x: 40, y: 270), CGPoint(x: 340, y: 270),
        ]
        let size = CGSize(width: 260, height: 150)
        let cards: [CGRect] = baseOrigins.map { origin in
            let dx = CGFloat(rng.next() % 161) - 80 // [-80, 80]
            let dy = CGFloat(rng.next() % 161) - 80
            return CGRect(x: origin.x + dx, y: origin.y + dy, width: size.width, height: size.height)
        }

        // Precondition: the seed must actually produce overlaps, or this
        // fixture is not testing what it claims to.
        var overlapExists = false
        for i in 0..<cards.count {
            for j in (i + 1)..<cards.count where cards[i].intersects(cards[j]) {
                overlapExists = true
            }
        }
        XCTAssertTrue(overlapExists, "Seed must produce at least one overlapping pair")

        // Route only pairs whose un-inflated rects are disjoint -- a
        // request whose `from` and `to` already overlap has no boundary
        // to start from.
        var requests: [MissionMapRouteRequest] = []
        for i in 0..<cards.count {
            for j in 0..<cards.count where i != j && !cards[i].intersects(cards[j]) {
                requests.append(MissionMapRouteRequest(id: UUID(), from: cards[i], to: cards[j]))
            }
        }
        XCTAssertGreaterThanOrEqual(requests.count, 2, "Seed must leave enough disjoint pairs to route")

        let minX = cards.map(\.minX).min()! - 40
        let minY = cards.map(\.minY).min()! - 40
        let maxX = cards.map(\.maxX).max()! + 40
        let maxY = cards.map(\.maxY).max()! + 40
        let bounds = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)

        let routes = MissionMapRouter.route(requests, obstacles: cards, bounds: bounds)

        XCTAssertEqual(routes.count, requests.count)
        for request in requests {
            guard let points = routes[request.id] else {
                XCTFail("Missing route for \(request.id)")
                continue
            }
            assertValidRoute(points, from: request.from, to: request.to, cards: cards, bounds: bounds)
        }
        assertNoCollinearOverlap(requests.compactMap { routes[$0.id] })
    }

    // MARK: - Fixture: 3, 4 and 5 edges through the same channel
    //
    // D (row 1, full width) and F (row 2, full width) each expose a
    // single bottom/top port at their own center (350, ...): every
    // D->F edge is forced onto that SAME pair of port nodes. E_left and
    // E_right sandwich a 40pt gap between D and F (free channel after
    // the 6pt obstacle margin: [336, 364], width 28, center 350) so the
    // straight vertical D->F line has no obstacle to bend around, but
    // nudging apart the identical, overlapping straight lines is
    // constrained to that 28pt-wide channel and nothing wider.

    private func channelFixture() -> (d: CGRect, f: CGRect, obstacles: [CGRect], bounds: CGRect) {
        let d = CGRect(x: 0, y: 0, width: 700, height: 150)
        let eLeft = CGRect(x: 0, y: 150, width: 330, height: 190)
        let eRight = CGRect(x: 370, y: 150, width: 330, height: 190)
        let f = CGRect(x: 0, y: 340, width: 700, height: 150)
        let bounds = CGRect(x: 0, y: 0, width: 700, height: 490)
        return (d, f, [d, eLeft, eRight, f], bounds)
    }

    func test_route_threeEdgesThroughSameChannel_useThreeNonCompressedTracks() {
        let (d, f, obstacles, bounds) = channelFixture()
        let ids = [UUID(), UUID(), UUID()]
        let requests = ids.map { MissionMapRouteRequest(id: $0, from: d, to: f) }

        let routes = MissionMapRouter.route(requests, obstacles: obstacles, bounds: bounds)

        var xs: [CGFloat] = []
        for id in ids {
            guard let points = routes[id] else { return XCTFail("Missing channel route for \(id)") }
            assertValidRoute(points, from: d, to: f, cards: obstacles, bounds: bounds)
            xs.append(points[0].x)
        }
        XCTAssertEqual(Set(xs.map { ($0 * 100).rounded() / 100 }).count, 3, "3 tracks must be distinct")
        let sorted = xs.sorted()
        XCTAssertEqual(sorted[0], 342, accuracy: 0.01)
        XCTAssertEqual(sorted[1], 350, accuracy: 0.01)
        XCTAssertEqual(sorted[2], 358, accuracy: 0.01)
        assertNoCollinearOverlap(ids.map { routes[$0]! })
    }

    /// 4 edges need (4 - 1) * 8 = 24pt, which fits the 28pt channel: the
    /// tracks stay uncompressed, symmetric about the channel center 350.
    func test_route_fourEdgesThroughSameChannel_stayUncompressedAndCentered() {
        let (d, f, obstacles, bounds) = channelFixture()
        let ids = [UUID(), UUID(), UUID(), UUID()]
        let requests = ids.map { MissionMapRouteRequest(id: $0, from: d, to: f) }

        let routes = MissionMapRouter.route(requests, obstacles: obstacles, bounds: bounds)

        var xs: [CGFloat] = []
        for id in ids {
            guard let points = routes[id] else { return XCTFail("Missing channel route for \(id)") }
            assertValidRoute(points, from: d, to: f, cards: obstacles, bounds: bounds)
            xs.append(points[0].x)
        }
        let sorted = xs.sorted()
        XCTAssertEqual(sorted[0], 338, accuracy: 0.01)
        XCTAssertEqual(sorted[1], 346, accuracy: 0.01)
        XCTAssertEqual(sorted[2], 354, accuracy: 0.01)
        XCTAssertEqual(sorted[3], 362, accuracy: 0.01)
        assertNoCollinearOverlap(ids.map { routes[$0]! })
    }

    /// 5 edges would need (5 - 1) * 8 = 32pt, more than the 28pt channel:
    /// the tracks spread evenly across it, touching both limits
    /// [336, 364] (spacing 28 / 4 = 7).
    func test_route_fiveEdgesThroughSameChannel_spreadEvenlyAcrossTheFreeWidth() {
        let (d, f, obstacles, bounds) = channelFixture()
        let ids = [UUID(), UUID(), UUID(), UUID(), UUID()]
        let requests = ids.map { MissionMapRouteRequest(id: $0, from: d, to: f) }

        let routes = MissionMapRouter.route(requests, obstacles: obstacles, bounds: bounds)

        var xs: [CGFloat] = []
        for id in ids {
            guard let points = routes[id] else { return XCTFail("Missing channel route for \(id)") }
            assertValidRoute(points, from: d, to: f, cards: obstacles, bounds: bounds)
            xs.append(points[0].x)
        }
        let sorted = xs.sorted()
        for (k, expected) in [336, 343, 350, 357, 364].enumerated() {
            XCTAssertEqual(sorted[k], CGFloat(expected), accuracy: 0.01)
        }
        assertNoCollinearOverlap(ids.map { routes[$0]! })
    }

    // MARK: - Facing-side ports

    /// Adjacent cards of heights 150 and 190 with the same top: their
    /// y-ranges overlap on [40, 190], so each facing side gets a port at
    /// y = 115 and both round-trip lines run straight (2 points,
    /// horizontal), inside the overlap, 8pt apart.
    func test_route_adjacentCardsOfDifferentHeights_roundTripIsStraight() {
        let a = CGRect(x: 40, y: 40, width: 260, height: 150)
        let b = CGRect(x: 340, y: 40, width: 260, height: 190)
        let bounds = CGRect(x: 0, y: 0, width: 640, height: 270)
        let forward = UUID()
        let backward = UUID()
        let requests = [
            MissionMapRouteRequest(id: forward, from: a, to: b),
            MissionMapRouteRequest(id: backward, from: b, to: a),
        ]

        let routes = MissionMapRouter.route(requests, obstacles: [a, b], bounds: bounds)

        guard let forwardPoints = routes[forward], let backwardPoints = routes[backward] else {
            return XCTFail("Missing round-trip routes")
        }
        for points in [forwardPoints, backwardPoints] {
            XCTAssertEqual(points.count, 2)
            XCTAssertEqual(points[0].y, points[1].y, accuracy: 0.01, "Route must be horizontal")
            XCTAssertGreaterThanOrEqual(points[0].y, 40)
            XCTAssertLessThanOrEqual(points[0].y, 190)
        }
        XCTAssertEqual(abs(forwardPoints[0].y - backwardPoints[0].y), 8, accuracy: 0.01)
        assertValidRoute(forwardPoints, from: a, to: b, cards: [a, b], bounds: bounds)
        assertValidRoute(backwardPoints, from: b, to: a, cards: [a, b], bounds: bounds)
    }

    /// Two stacked cards of different widths: their x-ranges overlap on
    /// [40, 240], so both round-trip lines run straight down (2 points,
    /// vertical), inside the overlap, 8pt apart.
    func test_route_stackedCardsOfDifferentWidths_roundTripIsStraight() {
        let top = CGRect(x: 40, y: 40, width: 260, height: 150)
        let bottom = CGRect(x: 40, y: 230, width: 200, height: 150)
        let bounds = CGRect(x: 0, y: 0, width: 340, height: 420)
        let down = UUID()
        let up = UUID()
        let requests = [
            MissionMapRouteRequest(id: down, from: top, to: bottom),
            MissionMapRouteRequest(id: up, from: bottom, to: top),
        ]

        let routes = MissionMapRouter.route(requests, obstacles: [top, bottom], bounds: bounds)

        guard let downPoints = routes[down], let upPoints = routes[up] else {
            return XCTFail("Missing stacked round-trip routes")
        }
        for points in [downPoints, upPoints] {
            XCTAssertEqual(points.count, 2)
            XCTAssertEqual(points[0].x, points[1].x, accuracy: 0.01, "Route must be vertical")
            XCTAssertGreaterThanOrEqual(points[0].x, 40)
            XCTAssertLessThanOrEqual(points[0].x, 240)
        }
        XCTAssertEqual(abs(downPoints[0].x - upPoints[0].x), 8, accuracy: 0.01)
        assertValidRoute(downPoints, from: top, to: bottom, cards: [top, bottom], bounds: bounds)
        assertValidRoute(upPoints, from: bottom, to: top, cards: [top, bottom], bounds: bounds)
    }

    // MARK: - Crossing-aware track order

    /// Whether any segment of `p` meets any segment of `q`, ignoring a
    /// point that is an endpoint of both segments and lies on one of
    /// `cards`' borders (two lines ending on the same card side).
    private func polylinesIntersect(_ p: [CGPoint], _ q: [CGPoint], cards: [CGRect]) -> Bool {
        let eps: CGFloat = 0.01
        func onBorder(_ point: CGPoint) -> Bool {
            cards.contains { rect in
                let inX = point.x >= rect.minX - eps && point.x <= rect.maxX + eps
                let inY = point.y >= rect.minY - eps && point.y <= rect.maxY + eps
                return inX && inY
                    && (abs(point.x - rect.minX) < eps || abs(point.x - rect.maxX) < eps
                        || abs(point.y - rect.minY) < eps || abs(point.y - rect.maxY) < eps)
            }
        }
        func same(_ a: CGPoint, _ b: CGPoint) -> Bool { abs(a.x - b.x) < eps && abs(a.y - b.y) < eps }
        for i in 0..<(p.count - 1) {
            for j in 0..<(q.count - 1) {
                let a1 = p[i], a2 = p[i + 1], b1 = q[j], b2 = q[j + 1]
                // Axis-aligned bounding-box overlap is exact for
                // axis-aligned segments.
                let overlapX = max(min(a1.x, a2.x), min(b1.x, b2.x)) <= min(max(a1.x, a2.x), max(b1.x, b2.x)) + eps
                let overlapY = max(min(a1.y, a2.y), min(b1.y, b2.y)) <= min(max(a1.y, a2.y), max(b1.y, b2.y)) + eps
                guard overlapX, overlapY else { continue }
                let shared = [a1, a2].first { a in [b1, b2].contains { same(a, $0) } }
                if let shared, onBorder(shared) { continue }
                return true
            }
        }
        return false
    }

    /// Cards whose y-ranges do not overlap force a Z-shaped round trip
    /// through the gap. The two lines share the whole path; their tracks
    /// must be ordered consistently in every group so they never cross.
    func test_route_zShapedRoundTrip_linesDoNotCross() {
        let a = CGRect(x: 40, y: 40, width: 260, height: 100)
        let b = CGRect(x: 340, y: 160, width: 260, height: 100)
        let bounds = CGRect(x: 0, y: 0, width: 640, height: 300)
        let forward = UUID()
        let backward = UUID()
        let requests = [
            MissionMapRouteRequest(id: forward, from: a, to: b),
            MissionMapRouteRequest(id: backward, from: b, to: a),
        ]

        let routes = MissionMapRouter.route(requests, obstacles: [a, b], bounds: bounds)

        guard let forwardPoints = routes[forward], let backwardPoints = routes[backward] else {
            return XCTFail("Missing Z round-trip routes")
        }
        XCTAssertGreaterThan(forwardPoints.count, 2, "Fixture must force bends")
        assertValidRoute(forwardPoints, from: a, to: b, cards: [a, b], bounds: bounds)
        assertValidRoute(backwardPoints, from: b, to: a, cards: [a, b], bounds: bounds)
        XCTAssertFalse(polylinesIntersect(forwardPoints, backwardPoints, cards: [a, b]))
    }

    /// The dragged render fixture's geometry (a4 dragged under the a2/a3
    /// gap and over a2's bottom edge, b2 dragged down, band headers as
    /// obstacles): the a1<->a2 round-trip lines must not cross.
    func test_route_draggedFixture_roundTripLinesDoNotCross() {
        let a1 = CGRect(x: 40, y: 64, width: 260, height: 150)
        let a2 = CGRect(x: 340, y: 64, width: 260, height: 190)
        let a3 = CGRect(x: 640, y: 64, width: 260, height: 150)
        let a4 = CGRect(x: 520, y: 234, width: 260, height: 150)
        let b1 = CGRect(x: 40, y: 508, width: 260, height: 150)
        let b2 = CGRect(x: 340, y: 538, width: 260, height: 150)
        let headers = [CGRect(x: 40, y: 40, width: 200, height: 24), CGRect(x: 40, y: 484, width: 200, height: 24)]
        let cards = [a1, a2, a3, a4, b1, b2]
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 700)
        let ping = UUID()
        let pong = UUID()
        let requests = [
            MissionMapRouteRequest(id: ping, from: a1, to: a2),
            MissionMapRouteRequest(id: pong, from: a2, to: a1),
            MissionMapRouteRequest(id: UUID(), from: a2, to: a4),
            MissionMapRouteRequest(id: UUID(), from: a4, to: b1),
            MissionMapRouteRequest(id: UUID(), from: a1, to: a3),
        ]

        let routes = MissionMapRouter.route(requests, obstacles: cards + headers, bounds: bounds)

        guard let pingPoints = routes[ping], let pongPoints = routes[pong] else {
            return XCTFail("Missing round-trip routes")
        }
        XCTAssertFalse(polylinesIntersect(pingPoints, pongPoints, cards: cards))
    }

    /// Two straight round-trip lines and a third line leaving the same
    /// card side that turns up inside the gap (a conflict line routed
    /// over the neighbour): the turning line's track must be above both
    /// straight ones, whatever the edge ids, or it cuts across them.
    func test_route_lineTurningInsideAGap_takesTheTrackOnItsTurnSide() {
        let a1 = CGRect(x: 40, y: 64, width: 260, height: 150)
        let a2 = CGRect(x: 340, y: 64, width: 260, height: 190)
        let a3 = CGRect(x: 640, y: 64, width: 260, height: 150)
        let cards = [a1, a2, a3]
        let bounds = CGRect(x: 0, y: 0, width: 940, height: 300)
        // Several id draws, so a pass does not depend on id order.
        for _ in 0..<20 {
            let ping = UUID()
            let pong = UUID()
            let over = UUID()
            let requests = [
                MissionMapRouteRequest(id: ping, from: a1, to: a2),
                MissionMapRouteRequest(id: pong, from: a2, to: a1),
                MissionMapRouteRequest(id: over, from: a1, to: a3),
            ]

            let routes = MissionMapRouter.route(requests, obstacles: cards, bounds: bounds)

            guard let pingPoints = routes[ping], let pongPoints = routes[pong], let overPoints = routes[over] else {
                return XCTFail("Missing routes")
            }
            XCTAssertFalse(polylinesIntersect(overPoints, pingPoints, cards: cards))
            XCTAssertFalse(polylinesIntersect(overPoints, pongPoints, cards: cards))
            XCTAssertFalse(polylinesIntersect(pingPoints, pongPoints, cards: cards))
        }
    }

    // MARK: - Degenerate input

    /// Identical `from` and `to` rects share every port, so there is no
    /// orthogonal route; the router must not crash and returns the
    /// documented straight fallback (2 points).
    func test_route_identicalFromAndTo_doesNotCrashAndReturnsTwoPoints() {
        let a = CGRect(x: 40, y: 40, width: 260, height: 150)
        let bounds = CGRect(x: 0, y: 0, width: 340, height: 230)
        let edgeID = UUID()

        let routes = MissionMapRouter.route(
            [MissionMapRouteRequest(id: edgeID, from: a, to: a)], obstacles: [a], bounds: bounds
        )

        XCTAssertEqual(routes[edgeID]?.count, 2)
    }

    // MARK: - Determinism

    func test_route_sameInputTwice_producesIdenticalOutput() {
        let a = CGRect(x: 40, y: 40, width: 260, height: 150)
        let b = CGRect(x: 340, y: 40, width: 260, height: 150)
        let bounds = CGRect(x: 0, y: 0, width: 640, height: 230)
        let requests = [MissionMapRouteRequest(id: UUID(), from: a, to: b)]

        let first = MissionMapRouter.route(requests, obstacles: [a, b], bounds: bounds)
        let second = MissionMapRouter.route(requests, obstacles: [a, b], bounds: bounds)

        XCTAssertEqual(first, second)
    }

    func test_route_addingUnrelatedEdge_leavesExistingRoutesUnchanged() {
        let a = CGRect(x: 40, y: 40, width: 260, height: 150)
        let b = CGRect(x: 340, y: 40, width: 260, height: 150)
        let x = CGRect(x: 1040, y: 640, width: 260, height: 150)
        let y = CGRect(x: 1340, y: 640, width: 260, height: 150)
        let bounds = CGRect(x: 0, y: 0, width: 1700, height: 900)
        let existingID = UUID()
        let unrelatedID = UUID()
        let existingRequest = MissionMapRouteRequest(id: existingID, from: a, to: b)

        let before = MissionMapRouter.route([existingRequest], obstacles: [a, b, x, y], bounds: bounds)
        let after = MissionMapRouter.route(
            [existingRequest, MissionMapRouteRequest(id: unrelatedID, from: x, to: y)],
            obstacles: [a, b, x, y], bounds: bounds
        )

        XCTAssertEqual(before[existingID], after[existingID])
    }

    // MARK: - Property test: 50 seeded random small layouts

    /// A tiny deterministic PRNG so the property test is reproducible
    /// across runs and machines.
    struct SplitMix64 {
        private var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }

    func test_property_fiftySeededRandomLayouts_satisfyAllInvariants() {
        let heights: [CGFloat] = [150, 170, 190, 210]
        for seed in 0..<50 {
            var rng = SplitMix64(seed: UInt64(seed) + 1)
            let cardCount = Int(rng.next() % 6) + 3 // 3...8
            let perRow = 3
            var cards: [CGRect] = []
            for i in 0..<cardCount {
                let row = i / perRow
                let col = i % perRow
                let height = heights[Int(rng.next() % UInt64(heights.count))]
                let baseX = CGFloat(col) * (260 + 40) + 40
                let baseY = CGFloat(row) * (210 + 40) + 40 // 210 = tallest possible height, keeps rows from colliding
                let dragX = CGFloat(rng.next() % 25) - 12 // +/-12, keeps a 16pt gap intact
                let dragY = CGFloat(rng.next() % 25) - 12
                cards.append(CGRect(x: baseX + dragX, y: baseY + dragY, width: 260, height: height))
            }

            var requests: [MissionMapRouteRequest] = []
            let edgeCount = Int(rng.next() % 4) + 1
            for _ in 0..<edgeCount {
                let fromIndex = Int(rng.next() % UInt64(cards.count))
                var toIndex = Int(rng.next() % UInt64(cards.count))
                if toIndex == fromIndex { toIndex = (toIndex + 1) % cards.count }
                requests.append(MissionMapRouteRequest(id: UUID(), from: cards[fromIndex], to: cards[toIndex]))
            }

            let minX = cards.map(\.minX).min()! - 40
            let minY = cards.map(\.minY).min()! - 40
            let maxX = cards.map(\.maxX).max()! + 40
            let maxY = cards.map(\.maxY).max()! + 40
            let bounds = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)

            let routes = MissionMapRouter.route(requests, obstacles: cards, bounds: bounds)

            for request in requests {
                guard let points = routes[request.id] else {
                    XCTFail("Seed \(seed): missing route for \(request.id)")
                    continue
                }
                assertValidRoute(points, from: request.from, to: request.to, cards: cards, bounds: bounds)
            }
            assertNoCollinearOverlap(requests.compactMap { routes[$0.id] })
        }
    }
}
