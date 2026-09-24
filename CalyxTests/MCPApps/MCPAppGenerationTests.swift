//
//  MCPAppGenerationTests.swift
//  CalyxTests
//
//  MCPAppGeneration.viewsToRetire decides, purely from a snapshot of the
//  existing views and the pane a new UI tool call landed on, which views
//  must be retired to make room. Only same-pane views that are already
//  finished (completed or cancelled) retire; anything still in flight, or
//  belonging to a different pane, is untouched. No counts and no timers:
//  the plan explicitly rejects both as sources of truth.
//

import XCTest
@testable import Calyx

final class MCPAppGenerationTests: XCTestCase {

    private let paneA = UUID()
    private let paneB = UUID()

    private func snapshot(_ id: UUID, pane: MCPAppGeneration.PaneKey, status: MCPAppGeneration.Status) -> MCPAppGeneration.ViewSnapshot {
        MCPAppGeneration.ViewSnapshot(id: id, paneKey: pane, status: status)
    }

    func test_completedView_samePane_isRetired() {
        let completed = UUID()
        let existing = [snapshot(completed, pane: .pane(paneA), status: .completed)]

        let retired = MCPAppGeneration.viewsToRetire(existing: existing, newCallPaneKey: .pane(paneA))

        XCTAssertEqual(retired, [completed])
    }

    func test_cancelledView_samePane_isRetired() {
        let cancelled = UUID()
        let existing = [snapshot(cancelled, pane: .pane(paneA), status: .cancelled)]

        let retired = MCPAppGeneration.viewsToRetire(existing: existing, newCallPaneKey: .pane(paneA))

        XCTAssertEqual(retired, [cancelled])
    }

    func test_inFlightView_samePane_isKept() {
        let inFlight = UUID()
        let existing = [snapshot(inFlight, pane: .pane(paneA), status: .inFlight)]

        let retired = MCPAppGeneration.viewsToRetire(existing: existing, newCallPaneKey: .pane(paneA))

        XCTAssertEqual(retired, [])
    }

    func test_mixedStatuses_samePane_onlyFinishedOnesRetired() {
        let completed = UUID()
        let cancelled = UUID()
        let inFlight = UUID()
        let existing = [
            snapshot(completed, pane: .pane(paneA), status: .completed),
            snapshot(cancelled, pane: .pane(paneA), status: .cancelled),
            snapshot(inFlight, pane: .pane(paneA), status: .inFlight),
        ]

        let retired = MCPAppGeneration.viewsToRetire(existing: existing, newCallPaneKey: .pane(paneA))

        XCTAssertEqual(retired, Set([completed, cancelled]))
    }

    func test_otherPane_completedView_isUntouched() {
        let completedOtherPane = UUID()
        let existing = [snapshot(completedOtherPane, pane: .pane(paneB), status: .completed)]

        let retired = MCPAppGeneration.viewsToRetire(existing: existing, newCallPaneKey: .pane(paneA))

        XCTAssertEqual(retired, [])
    }

    func test_paneless_completedView_followsSameRuleAsPane() {
        let completed = UUID()
        let existing = [snapshot(completed, pane: .paneless, status: .completed)]

        let retired = MCPAppGeneration.viewsToRetire(existing: existing, newCallPaneKey: .paneless)

        XCTAssertEqual(retired, [completed])
    }

    func test_paneless_doesNotRetirePaneViews_andViceVersa() {
        let completedPane = UUID()
        let completedPaneless = UUID()
        let existing = [
            snapshot(completedPane, pane: .pane(paneA), status: .completed),
            snapshot(completedPaneless, pane: .paneless, status: .completed),
        ]

        let retiredForPane = MCPAppGeneration.viewsToRetire(existing: existing, newCallPaneKey: .pane(paneA))
        XCTAssertEqual(retiredForPane, [completedPane])

        let retiredForPaneless = MCPAppGeneration.viewsToRetire(existing: existing, newCallPaneKey: .paneless)
        XCTAssertEqual(retiredForPaneless, [completedPaneless])
    }

    func test_noExistingViews_retiresNothing() {
        let retired = MCPAppGeneration.viewsToRetire(existing: [], newCallPaneKey: .pane(paneA))
        XCTAssertEqual(retired, [])
    }
}
