//
//  MissionMapPopoverPlacementTests.swift
//  CalyxTests
//
//  Pins MissionMapPopoverPlacement.place(extent:anchor:gap:obstacles:bounds:):
//  candidates in order above, below, left, right of the anchor (bubble
//  edge `gap` away, centered on the anchor along the other axis), then
//  the four diagonal corners (bubble corner `gap` from the anchor); each
//  clamped (translated) into `bounds` first, then scored by total
//  overlap area with `obstacles` -- lowest score wins, ties -> earlier
//  candidate. Also pins `score(_:obstacles:)`.
//
//  All expected values below are computed by hand from the spec's rule,
//  not by running an implementation.
//

import XCTest
@testable import Calyx

final class MissionMapPopoverPlacementTests: XCTestCase {

    private let gap: CGFloat = 8
    private let extent = CGSize(width: 320, height: 80)
    private let bounds = CGRect(x: 0, y: 0, width: 1000, height: 700)

    /// Two adjacent cards with an 8 pt gap directly above them (card top
    /// edge at y=100) and the anchor sitting on that gap's midline. The
    /// "above" candidate (bubble bottom edge 8 pt above the anchor, i.e.
    /// 8 pt above the cards' top edge) then clears both cards entirely:
    ///   above candidate: y 12...92 (bottom = 100-8 = 92, top = 92-80 = 12),
    ///   x 120...440 (centered on anchor.x = 280, width 320).
    /// Neither card (y 100...250) overlaps y 12...92, so score = 0, and
    /// "above" is tried before below/left/right/diagonals, all of which
    /// do overlap the cards -- so it wins outright.
    ///
    /// (Note: the task's original fixture -- cards flush at y=40...190
    /// with the anchor at their shared gap's *midpoint*, y=115 -- has NO
    /// zero-overlap candidate: the cards leave only 40 pt above/below,
    /// less than the bubble's 80 pt height, and every one of the 8
    /// candidates (hand-computed) scores at least 17420. That fixture is
    /// used unmodified in `test_place_noRoomAboveOrBelow_stillWithinBounds`
    /// below, without asserting score == 0.)
    func test_place_adjacentCardsWithRoomAbove_placesAboveWithZeroOverlap() {
        let card1 = CGRect(x: 0, y: 100, width: 260, height: 150)
        let card2 = CGRect(x: 300, y: 100, width: 260, height: 150)
        let anchor = CGPoint(x: 280, y: 100)

        let rect = MissionMapPopoverPlacement.place(
            extent: extent, anchor: anchor, gap: gap, obstacles: [card1, card2], bounds: bounds
        )

        XCTAssertEqual(rect, CGRect(x: 120, y: 12, width: 320, height: 80))
        XCTAssertEqual(MissionMapPopoverPlacement.score(rect, obstacles: [card1, card2]), 0)
    }

    /// The task's original fixture: cards flush at y=40...190, anchor at
    /// their shared gap's midpoint (280, 115). By hand, none of the 8
    /// candidates clears the cards (the gap is only 40 pt tall, the
    /// bubble 80 pt); the best is 17420 (a diagonal). A shrunk bounds
    /// height (240, still taller than every candidate's clamped rect, so
    /// clamping itself does not change any candidate's score here) does
    /// not change that -- there is no room above or below either way.
    /// This asserts only what is unambiguous: the result stays inside
    /// bounds, scores strictly above zero, and is no worse than the best
    /// hand-computed axis candidate ("above", 18760) -- so an
    /// implementation that ignores obstacles (e.g. always "above") or
    /// ignores bounds fails this test.
    func test_place_noRoomAboveOrBelow_stillWithinBounds() {
        let card1 = CGRect(x: 0, y: 40, width: 260, height: 150)
        let card2 = CGRect(x: 300, y: 40, width: 260, height: 150)
        let anchor = CGPoint(x: 280, y: 115)
        let shortBounds = CGRect(x: 0, y: 0, width: 1000, height: 240)

        let rect = MissionMapPopoverPlacement.place(
            extent: extent, anchor: anchor, gap: gap, obstacles: [card1, card2], bounds: shortBounds
        )

        XCTAssertTrue(shortBounds.contains(rect.origin))
        XCTAssertLessThanOrEqual(rect.maxX, shortBounds.maxX)
        XCTAssertLessThanOrEqual(rect.maxY, shortBounds.maxY)
        let score = MissionMapPopoverPlacement.score(rect, obstacles: [card1, card2])
        XCTAssertGreaterThan(score, 0)
        XCTAssertLessThanOrEqual(score, 18760)
    }

    /// No obstacles: the anchor is 10 pt from the right edge of a
    /// 1000-wide bounds, so the "above" candidate (first tried, always
    /// tied at score 0 with no obstacles) would overhang the right edge
    /// (x 830...1150) and must be clamped (translated left) to fit:
    /// x 680...1000, y 212...292 (bottom = 300-8 = 292, top = 292-80 = 212).
    func test_place_nearRightEdge_clampsIntoBounds() {
        let anchor = CGPoint(x: 990, y: 300)

        let rect = MissionMapPopoverPlacement.place(
            extent: extent, anchor: anchor, gap: gap, obstacles: [], bounds: bounds
        )

        XCTAssertEqual(rect, CGRect(x: 680, y: 212, width: 320, height: 80))
        XCTAssertLessThanOrEqual(rect.maxX, bounds.maxX)
    }

    /// One obstacle covering the whole bounds: every candidate, once
    /// clamped into bounds, is fully contained in the obstacle, so every
    /// candidate scores the same (320*80 = 25600) and the tie goes to
    /// the first candidate, "above": x 340...660 (centered on anchor.x =
    /// 500), y 262...342 (bottom = 350-8 = 342, top = 262).
    func test_place_fullyPackedObstacles_returnsFirstCandidateDeterministically() {
        let anchor = CGPoint(x: 500, y: 350)
        let obstacle = bounds

        let rect = MissionMapPopoverPlacement.place(
            extent: extent, anchor: anchor, gap: gap, obstacles: [obstacle], bounds: bounds
        )

        XCTAssertEqual(rect, CGRect(x: 340, y: 262, width: 320, height: 80))
        XCTAssertTrue(bounds.contains(rect.origin))
        XCTAssertLessThanOrEqual(rect.maxX, bounds.maxX)
        XCTAssertLessThanOrEqual(rect.maxY, bounds.maxY)
    }

    /// score(_:obstacles:) sums intersection areas over several
    /// obstacles: a 100x100 rect at the origin against an obstacle that
    /// overlaps it by 50x50 (2500), one fully inside it 20x20 (400), and
    /// one entirely outside it (0). Total: 2900.
    func test_score_sumsOverlapAreasAcrossObstacles() {
        let rect = CGRect(x: 0, y: 0, width: 100, height: 100)
        let obstacles = [
            CGRect(x: 50, y: 50, width: 100, height: 100),
            CGRect(x: 0, y: 0, width: 20, height: 20),
            CGRect(x: 200, y: 200, width: 10, height: 10),
        ]

        XCTAssertEqual(MissionMapPopoverPlacement.score(rect, obstacles: obstacles), 2900)
    }
}
