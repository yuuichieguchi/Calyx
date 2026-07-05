//
//  SessionReconnectGiveUpTests.swift
//  CalyxTests
//
//  Controller-level coverage for the give-up redesign (review
//  findings): `SessionReconnectDecision.giveUp` now closes the pane
//  DETERMINISTICALLY, with DETACH (not kill) semantics, instead of
//  being left dangling for a later keypress to close.
//
//  Drives `CalyxWindowController.handleSessionReconnectDecision
//  (surfaceID:decision:)` directly (made non-private for this purpose
//  — see its P4 review-fix doc comment) with `.giveUp`, rather than
//  exhausting `maxReconnectAttempts` through a live
//  `SessionReconnectCoordinator` + daemon round-trip:
//  `SessionReconnectCoordinatorTests` already fully covers the
//  coordinator's own contract (repeated `.unreachable` -> `.giveUp`
//  after the cap). This file covers only what `CalyxWindowController`
//  does once that decision is delivered.
//
//  Coverage:
//  - `.giveUp` removes the given-up leaf from the split tree (the pane
//    actually closes, right now — not deferred to a later keypress)
//  - `.giveUp` clears `tab.sessionRefs` for that leaf
//  - `.giveUp` clears `SessionSurfaceMap.shared`'s entry for that leaf
//    (detach semantics — see `detachSessionIfPersistent`'s doc
//    comment; unlike `killSessionIfPersistent`, that method never
//    calls `SessionDaemonClient.kill`, which has no injectable seam at
//    this call site to spy on directly)
//  - A stale surfaceID (the pane was already closed some other way) is
//    a safe no-op
//

import XCTest
import AppKit
@testable import Calyx

@MainActor
final class SessionReconnectGiveUpTests: XCTestCase {

    /// sessionIDs registered with `SessionSurfaceMap.shared` by
    /// `makeFixture()`, so `tearDown` can unregister exactly those
    /// entries rather than nuking the whole shared singleton (review
    /// finding: fixtures registered sessions here but never
    /// unregistered them, leaking entries into other tests that share
    /// the same process-wide singleton).
    private var registeredSessionIDs: [String] = []

    override func tearDown() {
        for sessionID in registeredSessionIDs {
            SessionSurfaceMap.shared.unregister(sessionID: sessionID)
        }
        registeredSessionIDs.removeAll()
        super.tearDown()
    }

    /// Two-pane fixture: `trackedLeafID` carries a `SessionRef` (both in
    /// `tab.sessionRefs` and `SessionSurfaceMap.shared`); `siblingLeafID`
    /// is an ordinary, untracked pane. Two panes (rather than a single-
    /// leaf tab) keep `closeSurfaceAndCleanUp`'s tab/window-removal
    /// branch out of play — that cascade is normal, pre-existing
    /// behavior exercised elsewhere, not this test's concern, and it
    /// would otherwise invoke `window.close()`.
    private struct Fixture {
        let controller: CalyxWindowController
        let tab: Tab
        let trackedLeafID: UUID
        let siblingLeafID: UUID
        let sessionID: String
    }

    private func makeFixture() -> Fixture {
        let registry = SurfaceRegistry()
        let trackedLeafID = UUID()
        let siblingLeafID = UUID()
        registry._testInsert(view: SurfaceView(frame: .zero), id: trackedLeafID)
        registry._testInsert(view: SurfaceView(frame: .zero), id: siblingLeafID)

        let root = SplitNode.split(SplitData(
            direction: .horizontal,
            ratio: 0.5,
            first: .leaf(id: trackedLeafID),
            second: .leaf(id: siblingLeafID)
        ))
        let sessionID = "test-session-\(UUID().uuidString)"
        let tab = Tab(
            splitTree: SplitTree(root: root, focusedLeafID: trackedLeafID),
            registry: registry,
            sessionRefs: [trackedLeafID: SessionRef(sessionID: sessionID)]
        )
        SessionSurfaceMap.shared.register(sessionID: sessionID, surfaceID: trackedLeafID)
        registeredSessionIDs.append(sessionID)

        let group = TabGroup(name: "Default", tabs: [tab], activeTabID: tab.id)
        let session = WindowSession(groups: [group], activeGroupID: group.id)
        let window = CalyxWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        let controller = CalyxWindowController(window: window, windowSession: session, restoring: true)
        return Fixture(
            controller: controller,
            tab: tab,
            trackedLeafID: trackedLeafID,
            siblingLeafID: siblingLeafID,
            sessionID: sessionID
        )
    }

    func test_giveUp_closesPaneDeterministically_leavesSiblingPaneIntact() {
        let fixture = makeFixture()

        fixture.controller.handleSessionReconnectDecision(surfaceID: fixture.trackedLeafID, decision: .giveUp)

        XCTAssertEqual(fixture.tab.splitTree.allLeafIDs(), [fixture.siblingLeafID],
                       "giveUp must close the pane right now (remove its leaf from the split tree), not " +
                       "leave it dangling for a later keypress to close")
    }

    func test_giveUp_detachesRatherThanLeaksSessionTracking() {
        let fixture = makeFixture()

        fixture.controller.handleSessionReconnectDecision(surfaceID: fixture.trackedLeafID, decision: .giveUp)

        XCTAssertNil(fixture.tab.sessionRefs[fixture.trackedLeafID],
                    "giveUp must clear tab.sessionRefs for the given-up leaf, not leak it into the next " +
                    "snapshot (a review finding: the prior 'leave the pane dangling' design never cleared " +
                    "this)")
        XCTAssertNil(SessionSurfaceMap.shared.sessionID(for: fixture.trackedLeafID),
                    "giveUp must clear SessionSurfaceMap's entry for the given-up leaf")
    }

    /// The pane was already closed some other way before the decision
    /// arrived — `findTabAndGroup` finds nothing, so this must be a
    /// safe no-op, not a crash, and must not touch any real tab.
    func test_giveUp_staleSurfaceID_isSafeNoOp() {
        let fixture = makeFixture()
        let staleSurfaceID = UUID()

        fixture.controller.handleSessionReconnectDecision(surfaceID: staleSurfaceID, decision: .giveUp)

        XCTAssertEqual(
            Set(fixture.tab.splitTree.allLeafIDs()),
            Set([fixture.trackedLeafID, fixture.siblingLeafID]),
            "A stale surfaceID must not affect any real tab's split tree"
        )
        XCTAssertNotNil(SessionSurfaceMap.shared.sessionID(for: fixture.trackedLeafID),
                        "A stale surfaceID must not detach an unrelated, still-live session")
    }
}
