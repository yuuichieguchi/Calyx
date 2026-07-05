//
//  AppDelegateAttachWindowHostTests.swift
//  CalyxTests
//
//  P5 (remote sessions) RED phase, BUG 3 (five-angle convergence review
//  finding), contract 3c (attachWindow level): AppDelegate.attachWindow
//  (~369-425) builds its placeholder Tab with
//  `sessionRefs: [placeholderLeafID: SessionRef(sessionID: sessionID)]` --
//  host always nil, with no way for a caller (e.g. a future session
//  browser row carrying a remote host) to attach a window for a REMOTE
//  session and have that host survive into the SessionRef at all.
//
//  FIX CONTRACT: attachWindow gains a `host: String? = nil` parameter
//  (default preserves both existing call sites --
//  SessionBrowserWindowController.swift:56 and every test in
//  AppDelegateAttachWindowTests/AppDelegateFocusExistingSessionTests --
//  unchanged, all still local), stored into the placeholder tab's
//  SessionRef.
//
//  PROPOSED FIX (attachWindow):
//
//    func attachWindow(sessionID: String, cwd: String?, host: String? = nil) {
//        guard let app = GhosttyAppController.shared.app else { return }
//        if SessionSurfaceMap.shared.surfaceID(for: sessionID) != nil {
//            if focusWindowForExistingSession(sessionID: sessionID) { return }
//        }
//        let placeholderLeafID = UUID()
//        let tab = Tab(
//            pwd: cwd,
//            splitTree: SplitTree(leafID: placeholderLeafID),
//            sessionRefs: [placeholderLeafID: SessionRef(sessionID: sessionID, host: host)]
//        )
//        #if DEBUG
//        _attachWindowPlaceholderTabObserverForTesting?(tab)
//        if let hook = _attachWindowCreationHookForTesting {
//            hook()
//            return
//        }
//        #endif
//        ... // unchanged
//    }
//
//  Note the placeholder tab's construction moves ahead of the existing
//  `_attachWindowCreationHookForTesting` early-return check (today it
//  runs BEFORE the tab is built at all) -- Tab's own init has no
//  side effects (no FFI, no SessionSurfaceMap/global registration), so
//  this reordering is behaviorally inert for every existing caller: the
//  hook still fires (and still returns early) at exactly the same
//  decision point relative to every OTHER guard, just after the
//  (side-effect-free) tab value now exists to observe.
//
//  THE MISSING OBSERVATION SEAM: today's `_attachWindowCreationHookForTesting`
//  fires and returns BEFORE the placeholder tab is even constructed, so
//  no existing seam can observe the SessionRef it would have produced.
//  Mirrors this codebase's established "second, independent, purely
//  additive observer instead of changing an existing hook's signature"
//  precedent (see AppDelegateRestoreRemoteSessionTests'
//  _createSurfaceWithPwdCommandObserverForTesting and
//  CalyxWindowControllerRemoteReconnectCommandTests'
//  _performReconnectCommandObserverForTesting, both citing this exact
//  reasoning):
//
//    #if DEBUG
//    extension AppDelegate {
//        var _attachWindowPlaceholderTabObserverForTesting: ((Tab) -> Void)? { get set }
//    }
//    #endif
//
//  Called with the constructed placeholder `tab`, immediately before the
//  existing `_attachWindowCreationHookForTesting` check. `nil` (the
//  default) leaves production behavior unchanged; every existing test
//  using `_attachWindowCreationHookForTesting` alone is unaffected.
//
//  Held-out compile-RED file per this codebase's established convention:
//  neither `attachWindow`'s `host` parameter nor
//  `_attachWindowPlaceholderTabObserverForTesting` exist yet. Expected to
//  FAIL TO COMPILE until the Green phase adds both. That compile failure
//  IS this file's RED evidence. Must be excluded from the build while
//  running the rest of the round's RED suite and verified separately for
//  its own specific compiler errors.
//
//  Reuses AppDelegateAttachWindowTests' exact makeController()-less,
//  direct-AppDelegate-construction style (no live ghostty app needed:
//  the placeholder tab is built and observed before attachWindow's own
//  `_attachWindowCreationHookForTesting` short-circuits away from any
//  real window/surface creation).
//
//  Coverage:
//  - attachWindow(sessionID:cwd:host:) with a non-nil host builds a
//    placeholder tab whose SessionRef carries exactly that host
//  - attachWindow(sessionID:cwd:) (host omitted, every existing caller's
//    shape) still builds a placeholder tab whose SessionRef host is nil --
//    regression guard
//

import XCTest
import GhosttyKit
@testable import Calyx

@MainActor
final class AppDelegateAttachWindowHostTests: XCTestCase {

    func test_attachWindow_withHost_placeholderTabSessionRefCarriesGivenHost() throws {
        let appDelegate = AppDelegate()
        let sessionID = "01ARZ3NDEKTSV4RRFFQ69G5FAV"
        var observedTab: Tab?
        appDelegate._attachWindowPlaceholderTabObserverForTesting = { observedTab = $0 }
        appDelegate._attachWindowCreationHookForTesting = {}
        defer { SessionSurfaceMap.shared.unregister(sessionID: sessionID) }

        appDelegate.attachWindow(sessionID: sessionID, cwd: nil, host: "devbox.example.com")

        let tab = try XCTUnwrap(observedTab, "attachWindow must call the placeholder-tab observer")
        let leafID = try XCTUnwrap(tab.splitTree.allLeafIDs().first)
        XCTAssertEqual(tab.sessionRefs[leafID]?.host, "devbox.example.com",
                       "The placeholder tab's SessionRef must carry exactly the given host")
    }

    func test_attachWindow_withoutHost_placeholderTabSessionRefCarriesNilHost() throws {
        let appDelegate = AppDelegate()
        let sessionID = "01ARZ3NDEKTSV4RRFFQ69G5FAV"
        var observedTab: Tab?
        appDelegate._attachWindowPlaceholderTabObserverForTesting = { observedTab = $0 }
        appDelegate._attachWindowCreationHookForTesting = {}
        defer { SessionSurfaceMap.shared.unregister(sessionID: sessionID) }

        appDelegate.attachWindow(sessionID: sessionID, cwd: nil)

        let tab = try XCTUnwrap(observedTab, "attachWindow must call the placeholder-tab observer")
        let leafID = try XCTUnwrap(tab.splitTree.allLeafIDs().first)
        XCTAssertNil(tab.sessionRefs[leafID]?.host,
                     "Every existing caller (host omitted) must still produce a placeholder tab whose " +
                     "SessionRef host is nil -- regression guard for unchanged local-attach behavior")
    }
}
