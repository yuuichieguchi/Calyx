//
//  MissionMapPopoverSelectionUIPinsTests.swift
//  CalyxTests
//
//  Compile-level pins for Mission Map UX changes A/B: a close button on
//  the line popover (`MissionMapEdgePopover.onClose`), and the card
//  view's new selection/open affordances
//  (`MissionMapCardView.isSelected`/`onSelect`/`onOpen`). Also pins the
//  new `AccessibilityID` entries those views reach for
//  (`popoverCloseButton`, `cardOpenButton(_:)`). These prove the new
//  parameters/statics exist with the right types and are actually
//  stored, not merely accepted and discarded, mirroring
//  MissionMapViewInitTests and MissionMapEdgePopoverEmphasisTests; the
//  clicks themselves are covered end to end by MissionMapPopoverUITests.
//

import SwiftUI
import XCTest
@testable import Calyx

@MainActor
final class MissionMapPopoverSelectionUIPinsTests: XCTestCase {

    // MARK: - MissionMapEdgePopover.onClose

    func test_edgePopover_acceptsOnClose_andInvokesIt() {
        let edge = MissionMapEdge(
            id: UUID(), from: UUID(), to: UUID(),
            kind: .conflict(file: "main.swift", fullPath: "/projects/app/main.swift")
        )
        var closed = false

        let popover = MissionMapEdgePopover(edge: edge, onClose: { closed = true })

        popover.onClose?()
        XCTAssertTrue(closed, "onClose must be the exact closure passed to init, not discarded")
    }

    // MARK: - MissionMapCardView.isSelected / onSelect / onOpen

    private func makeCard(id: UUID = UUID()) -> MissionMapCard {
        MissionMapCard(
            id: id, groupID: UUID(), groupName: "Default", tabID: UUID(), kindLabel: "claude-code",
            paneTitle: "Shell", cwdLabel: "~/project", state: .working, toolLine: nil,
            children: [], unreadCount: 0, approval: nil, git: nil, focusTarget: id
        )
    }

    func test_cardView_acceptsIsSelected_andStoresIt() {
        let view = MissionMapCardView(card: makeCard(), isSelected: true, onSelect: {}, onOpen: {})

        XCTAssertTrue(view.isSelected, "MissionMapCardView must actually store isSelected, not just accept it")
    }

    func test_cardView_invokesOnSelect_andOnOpen_independently() {
        var selected = false
        var opened = false
        let view = MissionMapCardView(
            card: makeCard(), isSelected: false,
            onSelect: { selected = true },
            onOpen: { opened = true }
        )

        view.onSelect()
        XCTAssertTrue(selected, "onSelect must be the exact closure passed to init")
        XCTAssertFalse(opened, "onSelect must not also invoke onOpen")

        view.onOpen()
        XCTAssertTrue(opened, "onOpen must be the exact closure passed to init")
    }

    // MARK: - AccessibilityID pins

    func test_accessibilityID_popoverCloseButton_isStable() {
        XCTAssertEqual(AccessibilityID.MissionMap.popoverCloseButton, "calyx.missionMap.popoverCloseButton")
    }

    func test_accessibilityID_cardOpenButton_isPerCard() {
        let id = UUID()
        XCTAssertEqual(
            AccessibilityID.MissionMap.cardOpenButton(id),
            "calyx.missionMap.cardOpenButton.\(id.uuidString)"
        )
    }
}
