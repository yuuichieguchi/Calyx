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
}
