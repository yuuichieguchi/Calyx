//
//  MissionMapSelectionTests.swift
//  CalyxTests
//
//  Pins MissionMapSelection's exclusive-selection redesign (Mission Map
//  UX change C): selection now holds ONE target -- an edge (line) OR a
//  card -- never both, via `MissionMapSelectionTarget` and the
//  `selectEdge(_:)`/`selectCard(_:)`/`clear()` mutators.  `edgeID`/
//  `cardID` are read-only projections of `target`, kept for existing call
//  sites (`missionMapSelection.edgeID`) that only care about one branch.
//

import XCTest
@testable import Calyx

@MainActor
final class MissionMapSelectionTests: XCTestCase {

    func test_selectCardAfterEdge_clearsEdgeID() {
        let selection = MissionMapSelection()
        let edgeID = UUID()
        let cardID = UUID()

        selection.selectEdge(edgeID)
        XCTAssertEqual(selection.edgeID, edgeID, "Precondition: an edge is selected")

        selection.selectCard(cardID)

        XCTAssertNil(selection.edgeID, "Selecting a card must clear the previously selected edge")
        XCTAssertEqual(selection.cardID, cardID, "Selecting a card must record it as the selected card")
        XCTAssertEqual(selection.target, .card(cardID))
    }

    func test_selectEdgeAfterCard_clearsCardID() {
        let selection = MissionMapSelection()
        let cardID = UUID()
        let edgeID = UUID()

        selection.selectCard(cardID)
        XCTAssertEqual(selection.cardID, cardID, "Precondition: a card is selected")

        selection.selectEdge(edgeID)

        XCTAssertNil(selection.cardID, "Selecting an edge must clear the previously selected card")
        XCTAssertEqual(selection.edgeID, edgeID, "Selecting an edge must record it as the selected edge")
        XCTAssertEqual(selection.target, .edge(edgeID))
    }

    func test_clear_removesAnySelection() {
        let selection = MissionMapSelection()
        selection.selectEdge(UUID())

        selection.clear()

        XCTAssertNil(selection.target)
        XCTAssertNil(selection.edgeID)
        XCTAssertNil(selection.cardID)
    }

    // MARK: - prune(cards:edges:)

    func test_prune_selectedEdgeMissing_clearsSelection() {
        let selection = MissionMapSelection()
        let edgeID = UUID()
        let cardID = UUID()
        selection.selectEdge(edgeID)

        let cleared = selection.prune(cards: [cardID], edges: [UUID()])

        XCTAssertTrue(cleared, "Pruning a selection whose line left must report that it cleared")
        XCTAssertNil(selection.target, "A selected line no longer on the map must be cleared")
    }

    func test_prune_selectedCardMissing_clearsSelection() {
        let selection = MissionMapSelection()
        let cardID = UUID()
        selection.selectCard(cardID)

        let cleared = selection.prune(cards: [UUID()], edges: [])

        XCTAssertTrue(cleared, "Pruning a selection whose card left must report that it cleared")
        XCTAssertNil(selection.target, "A selected card no longer on the map must be cleared")
    }

    func test_prune_targetPresent_leavesSelectionUnchanged() {
        let selection = MissionMapSelection()
        let edgeID = UUID()
        let cardID = UUID()

        selection.selectEdge(edgeID)
        XCTAssertFalse(selection.prune(cards: [cardID], edges: [edgeID]))
        XCTAssertEqual(selection.target, .edge(edgeID), "A selected line still on the map must stay selected")

        selection.selectCard(cardID)
        XCTAssertFalse(selection.prune(cards: [cardID], edges: [edgeID]))
        XCTAssertEqual(selection.target, .card(cardID), "A selected card still on the map must stay selected")
    }

    /// A card id is not a line id: a selected card is pruned against the
    /// cards only, even if an edge happens to share its id.
    func test_prune_cardCheckedAgainstCardsOnly() {
        let selection = MissionMapSelection()
        let id = UUID()
        selection.selectCard(id)

        XCTAssertTrue(selection.prune(cards: [], edges: [id]))
        XCTAssertNil(selection.target)
    }

    func test_prune_noSelection_isNoOp() {
        let selection = MissionMapSelection()

        XCTAssertFalse(selection.prune(cards: [], edges: []))
        XCTAssertNil(selection.target)
    }

    func test_selectingSameEdgeTwice_isIdempotent() {
        let selection = MissionMapSelection()
        let edgeID = UUID()

        selection.selectEdge(edgeID)
        selection.selectEdge(edgeID)

        XCTAssertEqual(selection.target, .edge(edgeID))
        XCTAssertEqual(selection.edgeID, edgeID)
        XCTAssertNil(selection.cardID)
    }
}
