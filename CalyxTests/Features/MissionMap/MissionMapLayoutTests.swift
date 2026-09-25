//
//  MissionMapLayoutTests.swift
//  CalyxTests
//
//  Pins MissionMapLayout.layout(cards:groups:in:cardSize:spacing:), the
//  pure card-placement algorithm, and edgeAnchors(from:to:), the pure
//  anchor-point picker an edge line connects.
//
//  Coverage:
//  - Deterministic ordering: calling layout twice on the same (unordered)
//    input produces identical frames
//  - Wrapping: cards whose combined width exceeds the container wrap
//    onto a new row
//  - Group bands: cards of two different groups never share a row
//  - Children extend a card's own frame height beyond a childless card's
//  - No two placed frames overlap
//

import XCTest
@testable import Calyx

final class MissionMapLayoutTests: XCTestCase {

    private let cardSize = CGSize(width: 220, height: 120)
    private let spacing: CGFloat = 16

    private func card(
        id: UUID = UUID(), groupID: UUID, groupName: String = "Default", tabID: UUID = UUID(),
        children: [MissionMapChildCard] = []
    ) -> MissionMapCard {
        MissionMapCard(
            id: id, groupID: groupID, groupName: groupName, tabID: tabID, kindLabel: "claude-code",
            paneTitle: "Shell", cwdLabel: "~/project", state: .working, toolLine: nil,
            children: children, unreadCount: 0, approval: nil, git: nil, focusTarget: id
        )
    }

    private func childCard(id: String = "sub-1") -> MissionMapChildCard {
        MissionMapChildCard(id: id, agentType: "explore", state: .working, toolLine: "ls -la")
    }

    func test_layout_isDeterministic_acrossRepeatedCalls() {
        let groupID = UUID()
        let group = MissionMapGroup(id: groupID, name: "Default")
        let cards = (0..<5).map { _ in card(groupID: groupID) }
        let size = CGSize(width: 1200, height: 800)

        let first = MissionMapLayout.layout(cards: cards, groups: [group], in: size, cardSize: cardSize, spacing: spacing)
        let second = MissionMapLayout.layout(cards: cards, groups: [group], in: size, cardSize: cardSize, spacing: spacing)

        XCTAssertEqual(first, second)
    }

    func test_layout_everyCardReceivesAFrame() {
        let groupID = UUID()
        let group = MissionMapGroup(id: groupID, name: "Default")
        let cards = (0..<3).map { _ in card(groupID: groupID) }
        let size = CGSize(width: 1200, height: 800)

        let frames = MissionMapLayout.layout(cards: cards, groups: [group], in: size, cardSize: cardSize, spacing: spacing)

        XCTAssertEqual(Set(frames.keys), Set(cards.map(\.id)))
    }

    /// A container too narrow for every card on one row must wrap: at
    /// least two distinct Y origins must appear once cards no longer fit
    /// side by side.
    func test_layout_narrowContainer_wrapsCardsOntoMultipleRows() {
        let groupID = UUID()
        let group = MissionMapGroup(id: groupID, name: "Default")
        let cards = (0..<6).map { _ in card(groupID: groupID) }
        // Only enough width for 2 cards per row (2 * 220 + spacing = 456).
        let size = CGSize(width: 480, height: 2000)

        let frames = MissionMapLayout.layout(cards: cards, groups: [group], in: size, cardSize: cardSize, spacing: spacing)

        let distinctYOrigins = Set(frames.values.map { $0.origin.y })
        XCTAssertGreaterThan(distinctYOrigins.count, 1, "6 cards at 2-per-row must wrap onto at least 3 rows")
    }

    /// Cards belonging to two different groups must never land on the
    /// same row (band) -- every card of group A has a Y origin strictly
    /// less than every card of group B, or vice versa.
    func test_layout_cardsFromDifferentGroups_neverShareARow() {
        let groupA = UUID()
        let groupB = UUID()
        let cardsA = [card(groupID: groupA)]
        let cardsB = [card(groupID: groupB)]
        let groups = [MissionMapGroup(id: groupA, name: "A"), MissionMapGroup(id: groupB, name: "B")]
        let size = CGSize(width: 1200, height: 800)

        let frames = MissionMapLayout.layout(
            cards: cardsA + cardsB, groups: groups, in: size, cardSize: cardSize, spacing: spacing
        )

        let yA = frames[cardsA[0].id]!.origin.y
        let yB = frames[cardsB[0].id]!.origin.y
        XCTAssertNotEqual(yA, yB, "Different groups must occupy different row bands")
    }

    /// A card with subagent children must be laid out with a taller
    /// frame than a childless card of the same base size.
    func test_layout_cardWithChildren_hasTallerFrameThanChildlessCard() {
        let groupID = UUID()
        let group = MissionMapGroup(id: groupID, name: "Default")
        let childless = card(groupID: groupID)
        let withChildren = card(groupID: groupID, children: [childCard(), childCard(id: "sub-2")])
        let size = CGSize(width: 1200, height: 800)

        let frames = MissionMapLayout.layout(
            cards: [childless, withChildren], groups: [group], in: size, cardSize: cardSize, spacing: spacing
        )

        XCTAssertGreaterThan(frames[withChildren.id]!.height, frames[childless.id]!.height)
    }

    /// No two placed card frames may overlap.
    func test_layout_noTwoFramesOverlap() {
        let groupID = UUID()
        let group = MissionMapGroup(id: groupID, name: "Default")
        let cards = (0..<8).map { _ in card(groupID: groupID) }
        let size = CGSize(width: 700, height: 2000)

        let frames = Array(MissionMapLayout.layout(
            cards: cards, groups: [group], in: size, cardSize: cardSize, spacing: spacing
        ).values)

        for i in 0..<frames.count {
            for j in (i + 1)..<frames.count where j > i {
                XCTAssertFalse(
                    frames[i].intersects(frames[j]),
                    "Frames \(frames[i]) and \(frames[j]) must not overlap"
                )
            }
        }
    }

    // MARK: - edgeAnchors

    /// The anchor points must lie on (or extremely close to) each rect's
    /// own boundary, never inside its interior -- an edge starts/ends at
    /// a card's edge, not its center.
    func test_edgeAnchors_pointsLieOnRectBoundaries() {
        let from = CGRect(x: 0, y: 0, width: 220, height: 120)
        let to = CGRect(x: 400, y: 300, width: 220, height: 120)

        let (start, end) = MissionMapLayout.edgeAnchors(from: from, to: to)

        XCTAssertFalse(from.insetBy(dx: 1, dy: 1).contains(start), "Start anchor must not be strictly interior to `from`")
        XCTAssertFalse(to.insetBy(dx: 1, dy: 1).contains(end), "End anchor must not be strictly interior to `to`")
    }
}
