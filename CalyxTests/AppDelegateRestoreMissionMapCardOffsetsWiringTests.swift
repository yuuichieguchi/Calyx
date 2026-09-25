//
//  AppDelegateRestoreMissionMapCardOffsetsWiringTests.swift
//  CalyxTests
//
//  Integration coverage for AppDelegate.restoreTabSurfaces re-keying
//  Tab.missionMapCardOffsets from the snapshot's old leaf UUIDs to the
//  freshly created surface UUIDs, alongside sessionRefs/herdrPaneRefs.
//  Mirrors AppDelegateRestoreHerdrPaneRefsWiringTests.swift's driving
//  style: a real AppDelegate, with `_createSurfaceWithPwdHookForTesting`
//  standing in for the real ghostty surface creation.
//
//  Coverage:
//  - A fully restored two-leaf tab carries each leaf's card offset over
//    to that leaf's new surface UUID, and no old leaf UUID remains.
//

import XCTest
import AppKit
import GhosttyKit
@testable import Calyx

@MainActor
final class AppDelegateRestoreMissionMapCardOffsetsWiringTests: XCTestCase {

    /// Never dereferenced: every createSurfaceWithPwd call is intercepted
    /// by `_createSurfaceWithPwdHookForTesting` first (same precedent as
    /// AppDelegateRestoreHerdrPaneRefsWiringTests).
    private let dummyApp: ghostty_app_t = UnsafeMutableRawPointer(bitPattern: 1)!

    private func makeWindow() -> NSWindow {
        CalyxWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
    }

    func test_restoreTabSurfaces_fullRestore_reKeysMissionMapCardOffsetsToNewSurfaceIDs() {
        let appDelegate = AppDelegate()

        let leafA = UUID()
        let (tree, leafB) = SplitTree(leafID: leafA).insert(at: leafA, direction: .horizontal)
        let newSurfaceA = UUID()
        let newSurfaceB = UUID()
        let mapping = [leafA: newSurfaceA, leafB: newSurfaceB]
        appDelegate._createSurfaceWithPwdHookForTesting = { oldLeafID in
            guard let oldLeafID else { return nil }
            return mapping[oldLeafID]
        }

        let offsetA = CGSize(width: 24, height: -11)
        let offsetB = CGSize(width: -30, height: 8)
        let tab = Tab(splitTree: tree)
        tab.setMissionMapCardOffset(offsetA, for: leafA)
        tab.setMissionMapCardOffset(offsetB, for: leafB)

        let restored = appDelegate.restoreTabSurfaces(tab: tab, app: dummyApp, window: makeWindow())

        XCTAssertTrue(restored, "Precondition: every leaf must restore so the re-key branch runs")
        XCTAssertEqual(
            tab.missionMapCardOffsets, [newSurfaceA: offsetA, newSurfaceB: offsetB],
            "restoreTabSurfaces must move each card offset from its snapshot leaf UUID to the leaf's new " +
            "surface UUID, like sessionRefs/herdrPaneRefs"
        )
    }
}
