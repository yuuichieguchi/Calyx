//
//  AppDelegateRestoreTabSurfacesOwnershipTests.swift
//  CalyxTests
//
//  TDD Red phase for round-8 fix R8-B (r8-fix-spec.md; CONFIRMED
//  evidence in r7-verdicts.md R7-V3): restoreTabSurfaces' partial-
//  failure cleanup loop (AppDelegate.swift, near :1146-1154) unregisters
//  a leaf's SessionSurfaceMap entry by sessionID unconditionally. With
//  a duplicate sessionID across two tabs (a corrupted/hand-edited
//  sessions.json, explicitly in this function's own threat model, see
//  its :1105-1111 doc comment), this rips a DIFFERENT, still-live
//  tab's mapping for the same sessionID.
//
//  SAFETY / WHY THIS USES A SEAM INSTEAD OF A REAL GHOSTTY SURFACE: a
//  real ghostty_app_t/GhosttySurfaceController is unsafe to construct
//  in this test host (confirmed empirically, see
//  AppDelegateAttachWindowTests's header comment for the hang this
//  caused previously). This file drives the real, unmodified
//  restoreTabSurfaces (made non-private for this purpose, see its own
//  doc comment) with AppDelegate._createSurfaceWithPwdHookForTesting
//  (also new, see that seam's doc comment on createSurfaceWithPwd)
//  standing in for the one actually-unsafe call
//  (tab.registry.createSurface), scripted per-leaf by oldLeafID.
//  Everything else, including the ==nil register guard and the
//  partial-failure cleanup loop under test, is real, unmodified
//  production code.
//
//  Scenario: tab A has a single leaf carrying sessionRef S and
//  restores fully (registers S). Tab B has two leaves: one ALSO
//  carrying sessionRef S (a duplicate; its register is skipped by the
//  ==nil guard, since S is already registered to tab A's surface), and
//  one whose surface creation is forced to fail (so tab B's restore is
//  a partial failure, triggering the cleanup loop). Asserts S still
//  maps to tab A's surface afterward.
//

import XCTest
import AppKit
import GhosttyKit
@testable import Calyx

@MainActor
final class AppDelegateRestoreTabSurfacesOwnershipTests: XCTestCase {

    /// A well-formed 26-character Crockford base32 ULID (see
    /// SessionRef.isValidULID), required for restoreTabSurfaces to
    /// keep this sessionRef at all rather than silently stripping it as
    /// corrupt before the loop under test ever runs.
    private let duplicateSessionID = "01ARZ3NDEKTSV4RRFFQ69G5FAV"

    /// Never dereferenced: every call this test drives through
    /// createSurfaceWithPwd is intercepted by
    /// _createSurfaceWithPwdHookForTesting before the real ghostty FFI
    /// call that would otherwise use this value.
    private let dummyApp: ghostty_app_t = UnsafeMutableRawPointer(bitPattern: 1)!

    private func makeWindow() -> NSWindow {
        CalyxWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
    }

    /// R8-B (r8-fix-spec.md; r7-verdicts.md R7-V3): against the
    /// CURRENT code, tab B's partial-failure cleanup unregisters
    /// duplicateSessionID unconditionally (it only checks that tab B's
    /// own sessionRefs still has an entry for the failed-mapping leaf,
    /// never whether SessionSurfaceMap's CURRENT registration actually
    /// still points at THIS restore's surface), ripping tab A's
    /// already-succeeded, live mapping for the same sessionID out from
    /// under it. The fix must unregister only when SessionSurfaceMap's
    /// current mapping actually still belongs to the surface THIS
    /// (failed) restore created.
    func test_restoreTabSurfaces_partialFailureCleanup_doesNotUnregisterAnotherTabsLiveMapping() {
        let appDelegate = AppDelegate()

        let tabALeafID = UUID()
        let tabB1LeafID = UUID()
        let tabB2LeafID = UUID()
        let newSurfaceA = UUID()
        let newSurfaceB1 = UUID()

        appDelegate._createSurfaceWithPwdHookForTesting = { oldLeafID in
            switch oldLeafID {
            case tabALeafID: return newSurfaceA
            case tabB1LeafID: return newSurfaceB1
            case tabB2LeafID: return nil // forced surface-creation failure
            default: return nil
            }
        }

        // Tab A: single leaf carrying duplicateSessionID, restores
        // fully and registers it.
        let tabA = Tab(
            splitTree: SplitTree(leafID: tabALeafID),
            sessionRefs: [tabALeafID: SessionRef(sessionID: duplicateSessionID)]
        )
        let restoredA = appDelegate.restoreTabSurfaces(tab: tabA, app: dummyApp, window: makeWindow())

        XCTAssertTrue(restoredA, "Precondition: tab A's single-leaf restore must fully succeed")
        XCTAssertEqual(SessionSurfaceMap.shared.surfaceID(for: duplicateSessionID), newSurfaceA,
                      "Precondition: tab A's restore must register duplicateSessionID to its own new surface")

        defer { SessionSurfaceMap.shared.unregister(sessionID: duplicateSessionID) }

        // Tab B: two leaves. tabB1 duplicates tab A's sessionID (its
        // own register is skipped by the ==nil guard, since
        // SessionSurfaceMap already maps duplicateSessionID to
        // newSurfaceA at this point). tabB2 has no sessionRef at all;
        // its forced creation failure alone is what makes tab B's
        // restore a partial failure and triggers the cleanup loop.
        let tabBRoot = SplitNode.split(SplitData(
            direction: .horizontal,
            ratio: 0.5,
            first: .leaf(id: tabB1LeafID),
            second: .leaf(id: tabB2LeafID)
        ))
        let tabB = Tab(
            splitTree: SplitTree(root: tabBRoot, focusedLeafID: tabB1LeafID),
            sessionRefs: [tabB1LeafID: SessionRef(sessionID: duplicateSessionID)]
        )
        let restoredB = appDelegate.restoreTabSurfaces(tab: tabB, app: dummyApp, window: makeWindow())

        XCTAssertFalse(restoredB, "Precondition: tab B's restore must be a partial failure (tabB2 forced to fail)")

        XCTAssertEqual(SessionSurfaceMap.shared.surfaceID(for: duplicateSessionID), newSurfaceA,
                      "Tab B's partial-failure cleanup must not unregister duplicateSessionID: it still " +
                      "belongs to tab A's live, already-succeeded surface, not to anything tab B's failed " +
                      "restore created")
    }
}
