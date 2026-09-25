// MissionMapUITests.swift
// CalyxUITests
//
// End-to-end: View > Mission Map shows the map with a card for the
// launch window's pane, and Escape closes it again.

import XCTest

final class MissionMapUITests: CalyxUITestCase {

    private func missionMapContainer() -> XCUIElement {
        app.descendants(matching: .any)
            .matching(identifier: "calyx.missionMap")
            .firstMatch
    }

    private func firstMissionMapCard() -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "calyx.missionMap.card."))
            .firstMatch
    }

    func test_openViaMenu_showsCards_escapeDismisses() {
        menuAction("View", item: "Mission Map")

        let container = missionMapContainer()
        XCTAssertTrue(waitFor(container, timeout: 5), "Mission Map should appear after View > Mission Map")

        let card = firstMissionMapCard()
        XCTAssertTrue(waitFor(card, timeout: 5), "Mission Map should show at least one pane card")

        app.typeKey(.escape, modifierFlags: [])
        waitForNonExistence(container)
    }
}
