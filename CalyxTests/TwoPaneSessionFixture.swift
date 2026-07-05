//
//  TwoPaneSessionFixture.swift
//  CalyxTests
//
//  R8-G (r8-fix-spec.md, item G2; consolidates a r7-verdicts.md fixture-
//  duplication finding): SessionReconnectGiveUpTests and
//  CalyxWindowControllerNonLastWindowCloseTests each built an identical
//  two-pane, single-tab, single-group window fixture (trackedLeafID
//  carrying a SessionRef registered in both tab.sessionRefs and
//  SessionSurfaceMap.shared; siblingLeafID an ordinary, untracked pane,
//  present only so the fixture isn't a degenerate single-surface case).
//  Unlike this codebase's usual per-file fixture-duplication convention
//  (see AppDelegateOfferAgentResumePipelineBoundTests's header comment),
//  these two were verbatim-identical, not just similar, so this file
//  extracts the single shared shape both consume.
//
//  Each call site still owns its own `registeredSessionIDs` cleanup
//  (matching SessionReconnectGiveUpTests' original discipline, kept as
//  the single pattern both files now follow): this file only builds the
//  fixture and registers its session with SessionSurfaceMap.shared, it
//  does not manage any XCTestCase's tearDown.
//

import XCTest
import AppKit
@testable import Calyx

struct TwoPaneSessionFixture {
    let controller: CalyxWindowController
    let tab: Tab
    let trackedLeafID: UUID
    let siblingLeafID: UUID
    let sessionID: String
}

/// - Parameter host: P5 (remote sessions) addition. `nil` (the default)
///   matches every existing call site's local-session fixture exactly.
///   Non-nil carries a remote host on the fixture's `SessionRef`, for
///   tests asserting kill/close routing's remote-vs-local behavior.
@MainActor
func makeTwoPaneSessionFixture(host: String? = nil) -> TwoPaneSessionFixture {
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
        sessionRefs: [trackedLeafID: SessionRef(sessionID: sessionID, host: host)]
    )
    SessionSurfaceMap.shared.register(sessionID: sessionID, surfaceID: trackedLeafID)

    let group = TabGroup(name: "Default", tabs: [tab], activeTabID: tab.id)
    let session = WindowSession(groups: [group], activeGroupID: group.id)
    let window = CalyxWindow(
        contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
        styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
        backing: .buffered,
        defer: false
    )
    let controller = CalyxWindowController(window: window, windowSession: session, restoring: true)
    return TwoPaneSessionFixture(
        controller: controller,
        tab: tab,
        trackedLeafID: trackedLeafID,
        siblingLeafID: siblingLeafID,
        sessionID: sessionID
    )
}
