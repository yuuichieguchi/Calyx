//
//  TabMissionMapCardOffsetsTests.swift
//  CalyxTests
//
//  Covers Tab.missionMapCardOffsets ([UUID: CGSize], leaf-UUID keyed,
//  mirrors Tab.sessionRefs/Tab.herdrPaneRefs's own shape) and its
//  mutation helper Tab.setMissionMapCardOffset(_:for:), plus
//  Tab.pruneMissionMapCardOffsets() -- the mission-map-card-offset
//  counterpart of Tab.pruneSessionRefs()/pruneHerdrPaneRefs(keeping:).
//
//  Persisting Mission Map's per-card drag offsets on the tab (instead of
//  MissionMapView's own memory-only @State dragOffsets) is the whole
//  point of this feature: the offset must survive the map closing and
//  reopening, and must be dropped once its leaf is no longer part of the
//  tab (closed pane).
//
//  Coverage:
//  - setMissionMapCardOffset(_:for:) sets a new entry
//  - ...replaces an existing entry with a new value
//  - ...passing nil removes the entry
//  - ...passing .zero removes the entry (an un-dragged-back-to-origin
//    card should not linger as a persisted "offset" at all)
//  - pruneMissionMapCardOffsets() drops entries for leaves no longer in
//    the current splitTree, keeps the rest, mirroring
//    TabSessionRefsPruningTests's three cases exactly
//  - Closing a pane through the real pane-close path
//    (`.ghosttyCloseSurface` -> CalyxWindowController
//    .handleCloseSurfaceNotification -> processCloseSurface ->
//    closeSurfaceAndCleanUp`) clears that leaf's missionMapCardOffsets
//    entry while leaving a surviving sibling leaf's entry untouched --
//    modeled on CalyxWindowControllerCloseSurfaceTerminationDiscriminatorTests's
//    own TwoPaneSessionFixture-driven notification-post style.
//

import XCTest
import AppKit
@testable import Calyx

@MainActor
final class TabMissionMapCardOffsetsTests: XCTestCase {

    // MARK: - setMissionMapCardOffset(_:for:)

    func test_setMissionMapCardOffset_setsNewEntry() {
        let leafID = UUID()
        let tab = Tab(splitTree: SplitTree(leafID: leafID))
        let offset = CGSize(width: 12, height: -34)

        tab.setMissionMapCardOffset(offset, for: leafID)

        XCTAssertEqual(tab.missionMapCardOffsets, [leafID: offset])
    }

    func test_setMissionMapCardOffset_replacesExistingEntry() {
        let leafID = UUID()
        let tab = Tab(splitTree: SplitTree(leafID: leafID))
        tab.setMissionMapCardOffset(CGSize(width: 12, height: -34), for: leafID)

        let replacement = CGSize(width: 100, height: 5)
        tab.setMissionMapCardOffset(replacement, for: leafID)

        XCTAssertEqual(tab.missionMapCardOffsets, [leafID: replacement],
                       "Setting a card offset for a leaf that already has one must replace it, not accumulate")
    }

    func test_setMissionMapCardOffset_nilRemovesEntry() {
        let leafID = UUID()
        let tab = Tab(splitTree: SplitTree(leafID: leafID))
        tab.setMissionMapCardOffset(CGSize(width: 12, height: -34), for: leafID)

        tab.setMissionMapCardOffset(nil, for: leafID)

        XCTAssertTrue(tab.missionMapCardOffsets.isEmpty, "Passing nil must remove the entry entirely")
    }

    func test_setMissionMapCardOffset_zeroRemovesEntry() {
        let leafID = UUID()
        let tab = Tab(splitTree: SplitTree(leafID: leafID))
        tab.setMissionMapCardOffset(CGSize(width: 12, height: -34), for: leafID)

        tab.setMissionMapCardOffset(.zero, for: leafID)

        XCTAssertTrue(tab.missionMapCardOffsets.isEmpty,
                     "A card dragged back to its computed layout position (.zero offset) must not linger " +
                     "as a persisted entry")
    }

    // MARK: - pruneMissionMapCardOffsets()

    func test_pruneMissionMapCardOffsets_removesEntriesForLeavesNoLongerInSplitTree() {
        let survivingLeaf = UUID()
        let goneLeaf = UUID()
        let survivingOffset = CGSize(width: 10, height: 20)
        let goneOffset = CGSize(width: -5, height: 8)

        let tab = Tab(splitTree: SplitTree(leafID: survivingLeaf))
        tab.setMissionMapCardOffset(survivingOffset, for: survivingLeaf)
        tab.setMissionMapCardOffset(goneOffset, for: goneLeaf)

        tab.pruneMissionMapCardOffsets()

        XCTAssertEqual(tab.missionMapCardOffsets, [survivingLeaf: survivingOffset],
                       "pruneMissionMapCardOffsets() must drop entries for leaves absent from the current " +
                       "splitTree, keeping only the ones that actually still exist")
    }

    func test_pruneMissionMapCardOffsets_completeFallback_dropsEveryEntry() {
        let freshLeaf = UUID()
        let staleLeafA = UUID()
        let staleLeafB = UUID()

        let tab = Tab(splitTree: SplitTree(leafID: freshLeaf))
        tab.setMissionMapCardOffset(CGSize(width: 1, height: 1), for: staleLeafA)
        tab.setMissionMapCardOffset(CGSize(width: 2, height: 2), for: staleLeafB)

        tab.pruneMissionMapCardOffsets()

        XCTAssertTrue(tab.missionMapCardOffsets.isEmpty,
                     "When none of the tab's persisted leaf UUIDs survive in the new tree, all " +
                     "missionMapCardOffsets entries must be dropped")
    }

    func test_pruneMissionMapCardOffsets_allLeavesSurvive_leavesOffsetsUntouched() {
        let leafA = UUID()
        let offsetA = CGSize(width: 3, height: 4)
        let (tree, leafB) = SplitTree(leafID: leafA).insert(at: leafA, direction: .horizontal)
        let offsetB = CGSize(width: -7, height: 9)

        let tab = Tab(splitTree: tree)
        tab.setMissionMapCardOffset(offsetA, for: leafA)
        tab.setMissionMapCardOffset(offsetB, for: leafB)

        tab.pruneMissionMapCardOffsets()

        XCTAssertEqual(tab.missionMapCardOffsets, [leafA: offsetA, leafB: offsetB],
                       "When every missionMapCardOffsets key is still a leaf in the current splitTree, " +
                       "nothing must be dropped")
    }

    // MARK: - Real pane-close path clears the entry

    /// Neutral `AppDelegate` stand-in, identical in purpose to
    /// `CalyxWindowControllerCloseSurfaceTerminationDiscriminatorTests`'s
    /// own `RequestSaveSpyAppDelegate`: `closeSurfaceAndCleanUp`'s
    /// "tab still has leaves" branch calls `requestSave()` on its way
    /// out, which must never reach the real `SessionPersistenceActor`
    /// and write to the developer's actual `~/.calyx` during this test.
    private final class NoOpRequestSaveAppDelegate: AppDelegate {
        override func requestSave() {}

        override func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
            .terminateCancel
        }

        override func removeWindowController(_ controller: CalyxWindowController) {}
    }

    func test_closingPaneViaGhosttyCloseSurface_clearsItsOffset_keepsSiblingsOffset() throws {
        let fixture = makeTwoPaneSessionFixture()
        defer { SessionSurfaceMap.shared.unregister(sessionID: fixture.sessionID) }

        let trackedOffset = CGSize(width: 41, height: -17)
        let siblingOffset = CGSize(width: 6, height: 6)
        fixture.tab.setMissionMapCardOffset(trackedOffset, for: fixture.trackedLeafID)
        fixture.tab.setMissionMapCardOffset(siblingOffset, for: fixture.siblingLeafID)

        let trackedSurfaceView = try XCTUnwrap(
            fixture.tab.registry.view(for: fixture.trackedLeafID),
            "makeTwoPaneSessionFixture's _testInsert must make the tracked leaf's SurfaceView resolvable"
        )

        let mock = NoOpRequestSaveAppDelegate()
        let originalDelegate = NSApp.delegate
        NSApp.delegate = mock
        defer { NSApp.delegate = originalDelegate }

        withExtendedLifetime(mock) {
            NotificationCenter.default.post(
                name: .ghosttyCloseSurface, object: trackedSurfaceView, userInfo: ["process_alive": false]
            )
        }

        XCTAssertEqual(fixture.tab.splitTree.allLeafIDs(), [fixture.siblingLeafID],
                       "Precondition: the tracked leaf must actually be gone from the split tree")
        XCTAssertNil(fixture.tab.missionMapCardOffsets[fixture.trackedLeafID],
                     "Closing a pane through the real pane-close path must clear its missionMapCardOffsets entry")
        XCTAssertEqual(fixture.tab.missionMapCardOffsets[fixture.siblingLeafID], siblingOffset,
                       "The surviving sibling pane's own offset must be left untouched")
    }
}
