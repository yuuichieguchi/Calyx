//
//  ReconnectFixture.swift
//  CalyxTests
//
//  Round-18 cleanup: SessionReconnectAttemptResetTimingTests,
//  SessionReconnectEstablishGraceSeamTests, and
//  SessionReconnectGracePositiveSignalSeamTests each carried an
//  identical `pumpRunLoop(timeout:until:)` helper and an identical
//  `ReconnectFixture`/`makeFixture()` pair (SessionReconnectGiveUpTests
//  also carried its own copy of `pumpRunLoop` alone, already using
//  `TwoPaneSessionFixture` for its own fixture shape). Consolidated
//  here, mirroring `TwoPaneSessionFixture.swift`'s own precedent for
//  extracting a verbatim-duplicated fixture shape, so a future change
//  to either only has to land in one place.
//
//  Each call site still owns its own `registeredSessionIDs` cleanup
//  (matching `TwoPaneSessionFixture.swift`'s established discipline):
//  this file only builds the fixture and registers its session with
//  `SessionSurfaceMap.shared`, it does not manage any XCTestCase's
//  tearDown.
//

import XCTest
import AppKit
@testable import Calyx

/// Spins the run loop in short steps, checking `condition()` after
/// each, until it returns `true` or `timeout` elapses. Lets a test
/// observe an asynchronously-scheduled MainActor `Task`'s effect
/// deterministically (bounded wait, no fixed `sleep`) rather than
/// assuming any particular synchronous timing. Mirrors this codebase's
/// own `AppDelegate.saveImmediately`/`restoreSession` bounded-spin style.
func pumpRunLoop(timeout: TimeInterval, until condition: () -> Bool) {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
    }
}

struct ReconnectFixture {
    let controller: CalyxWindowController
    let tab: Tab
    let trackedLeafID: UUID
    let sessionID: String
}

/// A single-leaf tab carrying `sessionID`'s `SessionRef`, placed as the
/// SECOND (non-active) tab of a two-tab group -- a separate, empty
/// `otherTab` is the active one -- so `performReconnect`'s `tab.id ==
/// activeTab?.id` branch (`splitContainerView.updateLayout`/
/// `window.makeFirstResponder`) never runs. That branch's own UI-update
/// behavior is not these tests' concern, and dodging it avoids reasoning
/// about `makeFirstResponder`'s behavior on a detached, `_testInsert`-
/// only `SurfaceView`. `findTab(surfaceID:)` searches every tab in every
/// group regardless of which is active, so `performReconnect` still
/// finds this tab.
@MainActor
func makeReconnectFixture() -> ReconnectFixture {
    let registry = SurfaceRegistry()
    let trackedLeafID = UUID()
    registry._testInsert(view: SurfaceView(frame: .zero), id: trackedLeafID)

    let sessionID = "test-session-\(UUID().uuidString)"
    let tab = Tab(
        splitTree: SplitTree(leafID: trackedLeafID),
        registry: registry,
        sessionRefs: [trackedLeafID: SessionRef(sessionID: sessionID)]
    )
    SessionSurfaceMap.shared.register(sessionID: sessionID, surfaceID: trackedLeafID)

    let otherTab = Tab()
    let group = TabGroup(name: "Default", tabs: [otherTab, tab], activeTabID: otherTab.id)
    let session = WindowSession(groups: [group], activeGroupID: group.id)
    let window = CalyxWindow(
        contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
        styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
        backing: .buffered,
        defer: false
    )
    let controller = CalyxWindowController(window: window, windowSession: session, restoring: true)
    return ReconnectFixture(controller: controller, tab: tab, trackedLeafID: trackedLeafID, sessionID: sessionID)
}
