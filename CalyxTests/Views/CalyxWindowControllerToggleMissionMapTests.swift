//
//  CalyxWindowControllerToggleMissionMapTests.swift
//  CalyxTests
//
//  Modeled on CalyxWindowControllerToggleCommandPaletteTests. Pins
//  WindowSession.showMissionMap, CalyxWindowController
//  .processToggleMissionMap()/.toggleMissionMap(), and the
//  .ghosttyToggleTabOverview notification route (Ghostty's own
//  `toggle_tab_overview` action, GHOSTTY_ACTION_TOGGLE_TAB_OVERVIEW,
//  repurposed to open Mission Map).
//
//  Coverage:
//  - processToggleMissionMap() is a true toggle (show, then hide)
//  - Showing Mission Map closes an already-open Command Palette /
//    Compose overlay
//  - .ghosttyToggleTabOverview posted for a surface THIS window owns
//    opens Mission Map
//  - .ghosttyToggleTabOverview posted for a surface NO window owns does
//    not open Mission Map
//

import XCTest
import AppKit
@testable import Calyx

@MainActor
final class CalyxWindowControllerToggleMissionMapTests: XCTestCase {

    private func makeController() -> CalyxWindowController {
        let tab = Tab(title: "Shell")
        let group = TabGroup(name: "Default", tabs: [tab], activeTabID: tab.id)
        let session = WindowSession(groups: [group], activeGroupID: group.id)
        let window = CalyxWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        return CalyxWindowController(window: window, windowSession: session, restoring: true)
    }

    func test_processToggleMissionMap_togglesShowMissionMap() {
        let controller = makeController()
        XCTAssertFalse(controller.windowSession.showMissionMap, "Precondition: Mission Map starts hidden")

        controller.processToggleMissionMap()
        XCTAssertTrue(
            controller.windowSession.showMissionMap,
            "The first call to processToggleMissionMap must show Mission Map"
        )

        controller.processToggleMissionMap()
        XCTAssertFalse(
            controller.windowSession.showMissionMap,
            "The second call to processToggleMissionMap must hide Mission Map again"
        )
    }

    /// Opening Mission Map while the Command Palette is already open must
    /// close the palette -- the two overlays are mutually exclusive.
    func test_processToggleMissionMap_whenCommandPaletteOpen_closesCommandPalette() {
        let controller = makeController()
        controller.processToggleCommandPalette()
        XCTAssertTrue(controller.windowSession.showCommandPalette, "Precondition: palette is open")

        controller.processToggleMissionMap()

        XCTAssertTrue(controller.windowSession.showMissionMap, "Mission Map must now be open")
        XCTAssertFalse(
            controller.windowSession.showCommandPalette,
            "Opening Mission Map must close an already-open Command Palette"
        )
    }

    /// Same exclusivity for the Compose overlay.
    func test_processToggleMissionMap_whenComposeOverlayOpen_closesComposeOverlay() {
        let controller = makeController()
        controller.toggleComposeOverlay()
        XCTAssertTrue(controller.windowSession.showComposeOverlay, "Precondition: compose overlay is open")

        controller.processToggleMissionMap()

        XCTAssertTrue(controller.windowSession.showMissionMap, "Mission Map must now be open")
        XCTAssertFalse(
            controller.windowSession.showComposeOverlay,
            "Opening Mission Map must close an already-open Compose overlay"
        )
    }

    // MARK: - Notification post (Tactic A)

    /// Mirrors CalyxWindowControllerToggleCommandPaletteTests
    /// .SurfaceOwningFixture -- findTab(for:) needs a real SurfaceRegistry
    /// entry.
    private struct SurfaceOwningFixture {
        let controller: CalyxWindowController
        let surfaceView: SurfaceView
    }

    private func makeSurfaceOwningFixture() -> SurfaceOwningFixture {
        let registry = SurfaceRegistry()
        let leafID = UUID()
        let surfaceView = SurfaceView(frame: .zero)
        registry._testInsert(view: surfaceView, id: leafID)

        let tab = Tab(splitTree: SplitTree(leafID: leafID), registry: registry)
        let group = TabGroup(name: "Default", tabs: [tab], activeTabID: tab.id)
        let session = WindowSession(groups: [group], activeGroupID: group.id)
        let window = CalyxWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        let controller = CalyxWindowController(window: window, windowSession: session, restoring: true)
        return SurfaceOwningFixture(controller: controller, surfaceView: surfaceView)
    }

    /// Posting the real `.ghosttyToggleTabOverview` notification for a
    /// surface THIS window owns must show Mission Map.
    func test_ghosttyToggleTabOverview_postedForOwnSurface_showsMissionMap() {
        let fixture = makeSurfaceOwningFixture()
        XCTAssertFalse(fixture.controller.windowSession.showMissionMap, "Precondition: Mission Map starts hidden")

        NotificationCenter.default.post(name: .ghosttyToggleTabOverview, object: fixture.surfaceView)

        XCTAssertTrue(
            fixture.controller.windowSession.showMissionMap,
            "Posting .ghosttyToggleTabOverview for a surface this window owns must show Mission Map"
        )
    }

    /// Regression guard: posting for a surface NO controller's
    /// windowSession owns must leave showMissionMap untouched.
    func test_ghosttyToggleTabOverview_postedForSurfaceNoWindowOwns_doesNotShowMissionMap() {
        let fixture = makeSurfaceOwningFixture()
        let orphanSurfaceView = SurfaceView(frame: .zero)
        XCTAssertFalse(fixture.controller.windowSession.showMissionMap, "Precondition: Mission Map starts hidden")

        NotificationCenter.default.post(name: .ghosttyToggleTabOverview, object: orphanSurfaceView)

        XCTAssertFalse(
            fixture.controller.windowSession.showMissionMap,
            "Posting .ghosttyToggleTabOverview for a surface no window owns must not show Mission Map"
        )
    }

    // MARK: - dismissMissionMap

    func test_dismissMissionMap_hidesMissionMap() {
        let controller = makeController()
        controller.processToggleMissionMap()
        XCTAssertTrue(controller.windowSession.showMissionMap, "Precondition: Mission Map is open")

        controller.dismissMissionMap(restoresFocus: false)

        XCTAssertFalse(controller.windowSession.showMissionMap, "dismissMissionMap must hide Mission Map")
    }
}
