//
//  CalyxWindowControllerChildExitedTasksTests.swift
//  CalyxTests
//
//  TDD Red phase for round-16 fix R16-2 (r16-fix-spec.md; evidence in
//  r15-candidates.md): `processChildExited`'s `Task`, tracked in
//  `childExitedTasks` (added R14-B, addendum item 2, so
//  `windowWillClose` could cancel it alongside its `diffTasks`/
//  `expandTasks` siblings), never removes its own entry once it
//  completes, unlike `expandTasks[hash]`'s Task (see
//  `expandCommit(hash:)`), which does `self.expandTasks.removeValue
//  (forKey: hash)` at the end of its own body. A completed
//  `childExitedTasks` entry is therefore retained forever (until the
//  window closes), an unbounded-lifetime leak for any window with
//  repeated persistent-session disconnects.
//
//  Fixture: a single ordinary (non-persistent-session) pane -- its
//  leaf id is registered with the tab's `SurfaceRegistry` (so
//  `processChildExited`'s own `findTab`/`registry.id(for:)` lookup
//  resolves it) but deliberately NOT registered with
//  `SessionSurfaceMap.shared`. `SessionReconnectCoordinator.childExited
//  (surfaceID:)` gates solely on `surfaceMap.sessionID(for:) != nil`
//  (see that method's own doc comment), so for this fixture it returns
//  immediately without any real daemon round-trip -- exactly the "fake/
//  quick coordinator path" this test needs, using the coordinator's own
//  already-documented no-op gate rather than a new injection seam.
//
//  Drives `processChildExited(surfaceView:)` directly rather than
//  posting the real `.ghosttyShowChildExited` notification: that method
//  is not `private` (P4 round-16 fix RED phase, mirroring
//  `handleSessionReconnectDecision`'s own precedent, see its doc
//  comment) specifically so this test can do so without also having to
//  attach the fixture's `SurfaceView` into the real window's view
//  hierarchy to satisfy `handleShowChildExitedNotification`'s
//  `belongsToThisWindow` guard.
//

import XCTest
import AppKit
@testable import Calyx

@MainActor
final class CalyxWindowControllerChildExitedTasksTests: XCTestCase {

    private struct OrdinaryPaneFixture {
        let controller: CalyxWindowController
        let surfaceView: SurfaceView
        let leafID: UUID
    }

    /// Single-pane/single-tab/single-group window whose sole leaf carries
    /// no `SessionRef` and no `SessionSurfaceMap.shared` entry -- an
    /// ordinary pane, exactly the case `SessionReconnectCoordinator
    /// .childExited(surfaceID:)`'s own doc comment describes as a no-op
    /// (its `surfaceMap.sessionID(for:)` lookup finds nothing).
    private func makeOrdinaryPaneFixture() -> OrdinaryPaneFixture {
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
        return OrdinaryPaneFixture(controller: controller, surfaceView: surfaceView, leafID: leafID)
    }

    /// R16-2 (r16-fix-spec.md): `processChildExited`'s `Task` must
    /// remove its own `childExitedTasks[surfaceID]` entry once it
    /// completes, mirroring `expandTasks[hash]`'s self-removing Task
    /// (`expandCommit(hash:)`). Against the CURRENT code, the Task never
    /// touches `childExitedTasks` itself (only `windowWillClose`'s
    /// teardown loop and a same-key re-insert ever remove an entry), so
    /// the entry is still present after the Task has fully completed.
    func test_processChildExited_removesItsOwnEntry_fromChildExitedTasks_onceTaskCompletes() async {
        let fixture = makeOrdinaryPaneFixture()

        fixture.controller.processChildExited(surfaceView: fixture.surfaceView)

        let task = fixture.controller._childExitedTasksForTesting[fixture.leafID]
        XCTAssertNotNil(task,
                        "processChildExited must insert a Task into childExitedTasks keyed by the " +
                        "surface's id (R14-B addendum item 2) as a precondition for this test")

        await task?.value

        XCTAssertNil(fixture.controller._childExitedTasksForTesting[fixture.leafID],
                    "childExitedTasks must self-remove its entry once the Task completes, mirroring " +
                    "expandTasks' pattern -- otherwise a completed entry is retained forever")
    }
}
