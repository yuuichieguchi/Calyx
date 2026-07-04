//
//  TabSessionRefsPruningTests.swift
//  CalyxTests
//
//  TDD Red Phase for Tab.pruneSessionRefs() (fix round, item 8):
//  partial-restore cleanup. AppDelegate.restoreTabSurfaces's partial
//  failure path and fallbackCreateSurface's whole-tree-failed path both
//  leave tab.sessionRefs holding entries keyed by leaf UUIDs that no
//  longer exist in the tab's actual splitTree — pruneSessionRefs()
//  drops them so a stale/orphaned SessionRef never lingers in the tab
//  or gets written back out by the next snapshot.
//

import XCTest
@testable import Calyx

@MainActor
final class TabSessionRefsPruningTests: XCTestCase {

    func test_pruneSessionRefs_removesEntriesForLeavesNoLongerInSplitTree() {
        let survivingLeaf = UUID()
        let goneLeaf = UUID()
        let survivingRef = SessionRef(sessionID: "01ARZ3NDEKTSV4RRFFQ69G5FAV")
        let goneRef = SessionRef(sessionID: "01BXQZ3NDEKTSV4RRFFQ69G5FB")

        let tab = Tab(
            splitTree: SplitTree(leafID: survivingLeaf),
            sessionRefs: [survivingLeaf: survivingRef, goneLeaf: goneRef]
        )

        tab.pruneSessionRefs()

        XCTAssertEqual(tab.sessionRefs, [survivingLeaf: survivingRef],
                       "pruneSessionRefs() must drop entries for leaves absent from the current splitTree, " +
                       "keeping only the ones that actually still exist")
    }

    func test_pruneSessionRefs_completeFallback_dropsEverySessionRef() {
        // Models AppDelegate.fallbackCreateSurface's whole-tree-failed
        // path: none of the tab's original leaf UUIDs survive at all in
        // the brand-new single-leaf tree, so every SessionRef must go.
        let freshLeaf = UUID()
        let staleLeafA = UUID()
        let staleLeafB = UUID()

        let tab = Tab(
            splitTree: SplitTree(leafID: freshLeaf),
            sessionRefs: [
                staleLeafA: SessionRef(sessionID: "01AAAAAAAAAAAAAAAAAAAAAAAA"),
                staleLeafB: SessionRef(sessionID: "01BBBBBBBBBBBBBBBBBBBBBBBB"),
            ]
        )

        tab.pruneSessionRefs()

        XCTAssertTrue(tab.sessionRefs.isEmpty,
                     "When none of the tab's persisted leaf UUIDs survive in the new tree, all sessionRefs " +
                     "must be dropped")
    }

    func test_pruneSessionRefs_allLeavesSurvive_leavesSessionRefsUntouched() {
        let leafA = UUID()
        let refA = SessionRef(sessionID: "01ARZ3NDEKTSV4RRFFQ69G5FAV")
        let (tree, leafB) = SplitTree(leafID: leafA).insert(at: leafA, direction: .horizontal)
        let refB = SessionRef(sessionID: "01BXQZ3NDEKTSV4RRFFQ69G5FB")

        let tab = Tab(splitTree: tree, sessionRefs: [leafA: refA, leafB: refB])

        tab.pruneSessionRefs()

        XCTAssertEqual(tab.sessionRefs, [leafA: refA, leafB: refB],
                       "When every sessionRefs key is still a leaf in the current splitTree, nothing must be dropped")
    }
}
