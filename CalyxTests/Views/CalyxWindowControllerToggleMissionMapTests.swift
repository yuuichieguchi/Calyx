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
//  CalyxWindowControllerMissionMapCardOffsetsTests below additionally
//  pins the persisted-drag-offset read/write surface the map reads from
//  and writes back to: CalyxWindowController.missionMapCardOffsets()
//  (merged across the window's tabs) and
//  .missionMapCardOffsetChanged(surfaceID:offset:) (writes back to the
//  owning tab and requests a save).
//

import XCTest
import AppKit
import SwiftUI
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

// MARK: - Mission Map popover host stacking

@MainActor
final class CalyxWindowControllerMissionMapPopoverStackingTests: XCTestCase {

    private func makeOpenMapController() -> (CalyxWindowController, CalyxWindow) {
        let tab = Tab(title: "Shell")
        let group = TabGroup(name: "Default", tabs: [tab], activeTabID: tab.id)
        let session = WindowSession(groups: [group], activeGroupID: group.id)
        let window = CalyxWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        let controller = CalyxWindowController(window: window, windowSession: session, restoring: true)
        controller.processToggleMissionMap()
        return (controller, window)
    }

    private func makeEdge() -> MissionMapEdge {
        MissionMapEdge(
            id: UUID(), from: UUID(), to: UUID(),
            kind: .conflict(file: "main.swift", fullPath: "/projects/app/main.swift")
        )
    }

    /// After the popover is shown and the main hosting view is recreated
    /// (which adds the new one on top), the popover's view must sit
    /// directly above the NEW main hosting view in the content view.
    func test_recreateHostingView_restacksPopoverHostDirectlyAboveNewMainHostingView() throws {
        let (controller, window) = makeOpenMapController()
        let contentView = try XCTUnwrap(window.contentView)

        let edge = makeEdge()
        controller.missionMapSelection.edgeID = edge.id
        controller.missionMapPopoverPlacementChanged(MissionMapPopoverPlacementInfo(
            edge: edge, rect: CGRect(x: 40, y: 60, width: 320, height: 80), emphasized: false
        ))
        let hostView = try XCTUnwrap(controller.missionMapPopoverHost.view)
        let oldMain = try XCTUnwrap(contentView.subviews.first { $0 is NSHostingView<MainContentView> })
        XCTAssertTrue(controller.missionMapPopoverHost.isShown, "Precondition: the popover is shown")

        controller.recreateHostingView()

        let subviews = contentView.subviews
        let newMainIndex = try XCTUnwrap(subviews.firstIndex { $0 is NSHostingView<MainContentView> })
        XCTAssertFalse(subviews[newMainIndex] === oldMain, "Precondition: the main hosting view was recreated")
        let hostIndex = try XCTUnwrap(subviews.firstIndex(of: hostView))
        XCTAssertEqual(hostIndex, newMainIndex + 1, "The popover host must sit directly above the new main hosting view")
    }

    /// Switching the selection A -> B: the re-identified map reports `nil`
    /// before B is measured, which must not hide the popover while a line
    /// is still selected; B's placement then moves it; `nil` with no
    /// selection hides it.
    func test_placementChanged_nilWhileSelected_keepsHost_untilNextPlacement_nilWithoutSelection_hides() throws {
        let (controller, window) = makeOpenMapController()
        let contentView = try XCTUnwrap(window.contentView)
        let host = controller.missionMapPopoverHost
        let edgeA = makeEdge()
        let edgeB = makeEdge()

        controller.missionMapSelection.edgeID = edgeA.id
        controller.missionMapPopoverPlacementChanged(MissionMapPopoverPlacementInfo(
            edge: edgeA, rect: CGRect(x: 40, y: 60, width: 320, height: 80), emphasized: false
        ))
        XCTAssertTrue(host.isShown, "Precondition: A's popover is shown")
        let frameA = try XCTUnwrap(host.view).frame

        controller.missionMapSelection.edgeID = edgeB.id
        controller.missionMapPopoverPlacementChanged(nil)
        XCTAssertTrue(host.isShown, "A nil placement while a line is selected must not hide the popover")
        XCTAssertEqual(try XCTUnwrap(host.view).frame, frameA, "The popover stays where it was until B is placed")

        let rectB = CGRect(x: 200, y: 300, width: 320, height: 120)
        controller.missionMapPopoverPlacementChanged(MissionMapPopoverPlacementInfo(
            edge: edgeB, rect: rectB, emphasized: true
        ))
        XCTAssertTrue(host.isShown)
        let mainHosting = try XCTUnwrap(contentView.subviews.first { $0 is NSHostingView<MainContentView> })
        XCTAssertEqual(
            try XCTUnwrap(host.view).frame, contentView.convert(rectB, from: mainHosting),
            "B's placement must move the popover to B's rect"
        )

        controller.missionMapSelection.edgeID = nil
        controller.missionMapPopoverPlacementChanged(nil)
        XCTAssertFalse(host.isShown, "A nil placement with no selection must hide the popover")
    }
}

// MARK: - Persisted card-offset read/write surface

@MainActor
final class CalyxWindowControllerMissionMapCardOffsetsTests: XCTestCase {

    /// Neutral `AppDelegate` stand-in, identical in purpose to
    /// `CalyxWindowControllerCloseSurfaceTerminationDiscriminatorTests`'s
    /// own `RequestSaveSpyAppDelegate`: swapped into `NSApp.delegate` so
    /// `requestSave()` never reaches the real `SessionPersistenceActor`
    /// (and never writes to the developer's actual `~/.calyx`), while
    /// still letting this test observe whether it fired.
    private final class RequestSaveSpyAppDelegate: AppDelegate {
        var requestSaveCallCount = 0

        override func requestSave() {
            requestSaveCallCount += 1
        }

        override func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
            .terminateCancel
        }

        override func removeWindowController(_ controller: CalyxWindowController) {}
    }

    private func makeWindow() -> CalyxWindow {
        CalyxWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
    }

    /// Two tabs (in the same group), each with a single leaf and its own
    /// pre-set missionMapCardOffsets entry -- so missionMapCardOffsets()
    /// merging across tabs is actually exercised, not vacuously true for
    /// a single-tab window.
    private func makeTwoTabFixture() -> (controller: CalyxWindowController, leafA: UUID, leafB: UUID, offsetA: CGSize, offsetB: CGSize) {
        let leafA = UUID()
        let leafB = UUID()
        let offsetA = CGSize(width: 18, height: -2)
        let offsetB = CGSize(width: -9, height: 40)

        let tabA = Tab(splitTree: SplitTree(leafID: leafA))
        tabA.setMissionMapCardOffset(offsetA, for: leafA)
        let tabB = Tab(splitTree: SplitTree(leafID: leafB))
        tabB.setMissionMapCardOffset(offsetB, for: leafB)

        let group = TabGroup(name: "Default", tabs: [tabA, tabB], activeTabID: tabA.id)
        let session = WindowSession(groups: [group], activeGroupID: group.id)
        let controller = CalyxWindowController(window: makeWindow(), windowSession: session, restoring: true)
        return (controller, leafA, leafB, offsetA, offsetB)
    }

    func test_missionMapCardOffsets_mergesEntriesAcrossAllOfTheWindowsTabs() {
        let fixture = makeTwoTabFixture()

        let merged = fixture.controller.missionMapCardOffsets()

        XCTAssertEqual(merged, [fixture.leafA: fixture.offsetA, fixture.leafB: fixture.offsetB],
                       "missionMapCardOffsets() must merge missionMapCardOffsets from every tab in the window, " +
                       "not just the active one")
    }

    func test_missionMapCardOffsetChanged_writesBackToOwningTab_andRequestsSave() {
        let fixture = makeTwoTabFixture()

        let mock = RequestSaveSpyAppDelegate()
        let originalDelegate = NSApp.delegate
        NSApp.delegate = mock
        defer { NSApp.delegate = originalDelegate }

        // CalyxWindowController.requestSave() resolves NSApp.delegate
        // INSIDE its DispatchQueue.main.async body, at execution time --
        // not when requestSave() itself is called. So any requestSave()
        // dispatched by an earlier test's (already-deallocated) controller
        // that hadn't yet drained off the main queue would, once this
        // test's mock is installed above, resolve against THIS mock and
        // inflate requestSaveCallCount with saves this test never asked
        // for. Drain the queue once right after installing the mock (and
        // before the fixture's own action) to flush out any such stale
        // blocks, then reset the counter -- so the count asserted below
        // reflects only what this test's own action triggered.
        let drainStaleBlocks = XCTestExpectation(description: "drain pre-existing main-queue work")
        DispatchQueue.main.async { drainStaleBlocks.fulfill() }
        wait(for: [drainStaleBlocks], timeout: 1)
        mock.requestSaveCallCount = 0

        let newOffset = CGSize(width: 77, height: -3)
        withExtendedLifetime(mock) {
            fixture.controller.missionMapCardOffsetChanged(surfaceID: fixture.leafB, offset: newOffset)
        }

        XCTAssertEqual(fixture.controller.missionMapCardOffsets()[fixture.leafB], newOffset,
                       "missionMapCardOffsetChanged(surfaceID:offset:) must write the new offset back to the " +
                       "owning tab")
        XCTAssertEqual(fixture.controller.missionMapCardOffsets()[fixture.leafA], fixture.offsetA,
                       "The other tab's own offset must be untouched by a change to a different tab's leaf")

        // requestSave() is dispatched async onto the main queue (see
        // CalyxWindowController.requestSave()'s own DispatchQueue.main
        // .async body) -- drain one turn of the run loop so the spy
        // actually observes the call before asserting.
        let expectation = XCTestExpectation(description: "requestSave dispatched")
        DispatchQueue.main.async { expectation.fulfill() }
        wait(for: [expectation], timeout: 1)

        XCTAssertEqual(mock.requestSaveCallCount, 1,
                      "missionMapCardOffsetChanged must mark the session dirty via the same requestSave() " +
                      "path other tab mutations use")
    }
}
