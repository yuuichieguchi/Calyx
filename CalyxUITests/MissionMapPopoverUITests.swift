// MissionMapPopoverUITests.swift
// CalyxUITests
//
// End-to-end check of the selected line's popover over real Liquid Glass,
// which a unit test cannot show (`ImageRenderer` renders glass nearly
// invisible, so the render fixture uses the `.flat` style). Launched with
// `--uitesting-mission-map-fixture`, the map shows the shared
// `MissionMapFixture` with its a1->a2 line pre-selected; the test opens
// the map, confirms the popover exists and saves a screenshot for manual
// inspection that the popover draws above the cards.

import XCTest

final class MissionMapPopoverUITests: CalyxUITestCase {

    /// Mirrors `MissionMapFixture.uiTestLaunchArgument` (the UI test
    /// target does not link the app's sources).
    override var additionalLaunchArguments: [String] { ["--uitesting-mission-map-fixture"] }

    /// `CALYX_FIXTURE_OUTPUT_DIR` when set, else a fixed directory under
    /// the temporary directory -- the render fixture's own convention.
    private var outputPath: String {
        let base = ProcessInfo.processInfo.environment["CALYX_FIXTURE_OUTPUT_DIR"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("calyx-mission-map-fixtures")
        return base.appendingPathComponent("mission-map-live-popover.png").path
    }

    func test_fixtureMap_selectedEdgePopover_isShownAndCaptured() throws {
        menuAction("View", item: "Mission Map")

        let container = app.descendants(matching: .any).matching(identifier: "calyx.missionMap").firstMatch
        XCTAssertTrue(waitFor(container, timeout: 5), "Mission Map should appear after View > Mission Map")

        let popover = app.descendants(matching: .any).matching(identifier: "calyx.missionMap.popover").firstMatch
        XCTAssertTrue(waitFor(popover, timeout: 5), "The pre-selected line's popover should be shown")

        // Let the glass settle before capturing.
        Thread.sleep(forTimeInterval: 1)
        let pngData = XCUIScreen.main.screenshot().pngRepresentation
        let window = app.windows.firstMatch
        print("[fixture] window frame: \(window.frame)")
        let windowPNGData = window.screenshot().pngRepresentation

        let outputURL = URL(fileURLWithPath: outputPath)
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try pngData.write(to: outputURL)
        print("[fixture] wrote \(outputURL.path)")
        // The same capture cropped to the app window, for inspection.
        let windowOutputURL = outputURL.deletingLastPathComponent()
            .appendingPathComponent("mission-map-live-popover-window.png")
        try windowPNGData.write(to: windowOutputURL)
        print("[fixture] wrote \(windowOutputURL.path)")

        let attributes = try FileManager.default.attributesOfItem(atPath: outputURL.path)
        let fileSize = try XCTUnwrap(attributes[.size] as? Int)
        XCTAssertGreaterThan(fileSize, 10 * 1024, "Live popover screenshot should be larger than 10 KB")
    }

    /// UX changes A/C end-to-end: the popover's own close (×) button
    /// dismisses it (rather than a click anywhere on the popover body),
    /// and with nothing left selected the first Escape closes the map --
    /// the close click must not leave first responder away from the
    /// map's key catcher.
    func test_fixtureMap_popoverCloseButton_hidesPopover_thenEscapeClosesMap() throws {
        menuAction("View", item: "Mission Map")

        let container = missionMapContainer()
        XCTAssertTrue(waitFor(container, timeout: 5), "Mission Map should appear after View > Mission Map")

        let popover = app.descendants(matching: .any).matching(identifier: "calyx.missionMap.popover").firstMatch
        XCTAssertTrue(waitFor(popover, timeout: 5), "The pre-selected line's popover should be shown")

        let closeButton = app.descendants(matching: .any)
            .matching(identifier: "calyx.missionMap.popoverCloseButton").firstMatch
        XCTAssertTrue(waitFor(closeButton, timeout: 5), "The popover's close button should exist")
        closeButton.click()
        waitForNonExistence(popover)

        app.typeKey(.escape, modifierFlags: [])
        waitForNonExistence(container)
    }

    /// UX changes B/C end-to-end: a single click on a card only selects
    /// it (the map stays open); Escape then clears that selection (the
    /// map still stays open) and a second Escape closes the map -- so the
    /// card click must leave first responder with the map's key catcher.
    /// Finally a double click on a card focuses its pane and closes the
    /// map.
    func test_fixtureMap_cardClick_selects_escapeClearsThenCloses_doubleClickCloses() throws {
        menuAction("View", item: "Mission Map")

        let container = missionMapContainer()
        XCTAssertTrue(waitFor(container, timeout: 5), "Mission Map should appear after View > Mission Map")

        let card = firstCard()
        XCTAssertTrue(waitFor(card, timeout: 5), "At least one card should exist on the fixture map")

        card.click()
        Thread.sleep(forTimeInterval: 1)
        XCTAssertTrue(container.exists, "A single click on a card must select it, not close the map")

        app.typeKey(.escape, modifierFlags: [])
        Thread.sleep(forTimeInterval: 1)
        XCTAssertTrue(container.exists, "The first Escape after a card click must only clear the selection")

        app.typeKey(.escape, modifierFlags: [])
        waitForNonExistence(container)

        menuAction("View", item: "Mission Map")
        XCTAssertTrue(waitFor(container, timeout: 5), "Mission Map should reopen after View > Mission Map")
        let reopenedCard = firstCard()
        XCTAssertTrue(waitFor(reopenedCard, timeout: 5), "The reopened map should show its cards")

        reopenedCard.doubleClick()
        waitForNonExistence(container)
    }

    private func missionMapContainer() -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "calyx.missionMap").firstMatch
    }

    private func firstCard() -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'calyx.missionMap.card.'"))
            .firstMatch
    }
}
