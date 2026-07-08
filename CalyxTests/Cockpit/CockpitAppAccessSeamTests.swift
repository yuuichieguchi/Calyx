//
//  CockpitAppAccessSeamTests.swift
//  CalyxTests
//
//  TDD Red Phase for the CalyxWindowController seams Cockpit's
//  LiveCockpitAppAccess (Calyx/Features/Cockpit/CockpitAppAccess.swift)
//  will call: performSplit(surfaceID:direction:app:) (extracted from
//  handleNewSplitNotification) and resolveNewTabSpawnCwd(override:)
//  (factored out of createNewTab's inline spawnCwd expression, backing
//  its future spawnCwdOverride parameter). LiveCockpitAppAccess itself
//  is untested here -- see CockpitAppAccess.swift's header for why.
//
//  DEVIATIONS FROM THE ORIGINAL P3 SPEC (both forced by this test
//  host's existing constraints, already documented in
//  CalyxWindowControllerCreateManagedSurfaceRemoteHostTests'/
//  AppDelegateSpawnRemoteSessionTabWindowLookupTests' own headers --
//  not new discoveries):
//  - performSplit takes an explicit `app: ghostty_app_t` parameter
//    (like createManagedSurface itself does) rather than resolving
//    GhosttyAppController.shared.app internally -- that global is nil
//    in this test host, so an internally-resolving performSplit could
//    never be driven by a unit test even once correctly implemented.
//  - createNewTab's spawnCwd override is exercised through a new,
//    directly-testable pure helper, resolveNewTabSpawnCwd(override:),
//    rather than driving createNewTab(...) itself end-to-end --
//    createNewTab's own pre-existing `guard let app =
//    GhosttyAppController.shared.app ... else { return }` (same nil
//    constraint) would make the whole call silently no-op before ever
//    reaching the spawnCwd computation, exactly the trap
//    AppDelegateSpawnRemoteSessionTabWindowLookupTests' own header
//    already called out for this identical guard.
//
//  Coverage:
//  - performSplit(direction: .horizontal) inserts a new split node
//    under the source leaf and returns the newly created surface's id
//    (via the existing _createManagedSurfaceHookForTesting hook); an
//    unknown surfaceID (not a leaf in the active tab's current
//    splitTree) returns nil and leaves the tree untouched -- folded
//    into this same test rather than standalone, since a stub that
//    always returns nil coincidentally already satisfies that exact
//    case on its own, so a standalone test for it alone could never be
//    forced to fail here
//  - performSplit(direction: .vertical) does the same shape with a
//    vertical split
//  - resolveNewTabSpawnCwd(override:) with a non-nil override returns
//    exactly that override, taking priority over the active tab's own
//    pwd; with a nil override, returns the active tab's own pwd
//    unchanged (regression pin for createNewTab's pre-Cockpit
//    behavior, folded into the same test as the override case for the
//    same "stub coincidentally already correct" reason as above); an
//    empty or whitespace-only override is treated the same as nil
//    (P3 review F5); a newline-only override also falls back, and a
//    leading/trailing-whitespace-or-newline override is trimmed
//    before use (P3 final gate W2)
//  - cockpitExecutePaletteCommand(id:) (P3 review F1): an unavailable
//    command is found but not executed (handler never called); an
//    available command is executed and its handler called exactly
//    once; an unknown id returns nil
//  - cockpitSendCommand/cockpitSendKeys (P3 final gate Warning 1):
//    both agree with ownsSplitLeaf on tab resolution -- a split-tree
//    leaf with no registry entry and a genuinely-foreign id both
//    return false without crashing
//

import XCTest
import AppKit
import GhosttyKit
@testable import Calyx

@MainActor
final class CockpitAppAccessSeamTests: XCTestCase {

    /// Never dereferenced: `_createManagedSurfaceHookForTesting`
    /// intercepts every call this test drives through
    /// `createManagedSurface`/`performSplit` before the real ghostty FFI
    /// call that would otherwise use this value -- mirrors
    /// `CalyxWindowControllerCreateManagedSurfaceRemoteHostTests`'s
    /// identical `dummyApp`.
    private let dummyApp: ghostty_app_t = UnsafeMutableRawPointer(bitPattern: 1)!

    private func makeController() -> (controller: CalyxWindowController, tab: Tab) {
        let window = CalyxWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        let tab = Tab(title: "Shell")
        let group = TabGroup(name: "Default", tabs: [tab], activeTabID: tab.id)
        let session = WindowSession(groups: [group], activeGroupID: group.id)
        let controller = CalyxWindowController(window: window, windowSession: session, restoring: true)
        return (controller, tab)
    }

    // MARK: - performSplit

    func test_performSplit_right_insertsHorizontalAtSourceLeaf_returnsNewUUID() {
        let (controller, tab) = makeController()
        let sourceSurfaceID = UUID()
        tab.splitTree = SplitTree(leafID: sourceSurfaceID)
        let newSurfaceID = UUID()
        controller._createManagedSurfaceHookForTesting = { newSurfaceID }

        let result = controller.performSplit(surfaceID: sourceSurfaceID, direction: .horizontal, app: dummyApp)

        XCTAssertEqual(result, newSurfaceID as UUID?, "performSplit must return the newly created surface's id")

        if case .split(let data) = tab.splitTree.root {
            XCTAssertEqual(data.direction, .horizontal)
            let leafIDs = Set([data.first.leafID, data.second.leafID].compactMap { $0 })
            XCTAssertEqual(leafIDs, Set([sourceSurfaceID, newSurfaceID]))
        } else {
            XCTFail("performSplit must insert a new split node under the source leaf")
        }

        // An unknown surface id must return nil and leave the tree
        // untouched -- folded in here rather than a standalone test, see
        // this file's header for why.
        let treeBeforeUnknown = tab.splitTree
        let unknownResult = controller.performSplit(surfaceID: UUID(), direction: .horizontal, app: dummyApp)
        XCTAssertNil(unknownResult)
        XCTAssertEqual(tab.splitTree, treeBeforeUnknown)
    }

    func test_performSplit_down_insertsVertical() {
        let (controller, tab) = makeController()
        let sourceSurfaceID = UUID()
        tab.splitTree = SplitTree(leafID: sourceSurfaceID)
        let newSurfaceID = UUID()
        controller._createManagedSurfaceHookForTesting = { newSurfaceID }

        let result = controller.performSplit(surfaceID: sourceSurfaceID, direction: .vertical, app: dummyApp)

        XCTAssertEqual(result, newSurfaceID as UUID?)

        if case .split(let data) = tab.splitTree.root {
            XCTAssertEqual(data.direction, .vertical)
        } else {
            XCTFail("performSplit must insert a new split node under the source leaf")
        }
    }

    // MARK: - resolveNewTabSpawnCwd

    func test_resolveNewTabSpawnCwd_overrideTakesPriority_defaultPathUnchanged() {
        let (controller, tab) = makeController()
        tab.pwd = "/Users/dev/existing-tab-pwd"

        XCTAssertEqual(controller.resolveNewTabSpawnCwd(override: nil), "/Users/dev/existing-tab-pwd",
                       "regression pin: with no override, the active tab's own pwd must still be used, unchanged")

        XCTAssertEqual(controller.resolveNewTabSpawnCwd(override: "/Users/dev/custom-cwd"), "/Users/dev/custom-cwd",
                       "an explicit Cockpit-supplied cwd override must take priority over the active tab's own pwd")

        // P3 review (F5): an empty or whitespace-only override must fall
        // back exactly like `nil` -- an MCP caller passing "" almost
        // certainly means "no override", not "spawn at the empty path".
        XCTAssertEqual(controller.resolveNewTabSpawnCwd(override: ""), "/Users/dev/existing-tab-pwd",
                       "an empty-string override must be treated the same as no override")
        XCTAssertEqual(controller.resolveNewTabSpawnCwd(override: "   "), "/Users/dev/existing-tab-pwd",
                       "a whitespace-only override must be treated the same as no override")

        // P3 final gate (W2): .whitespaces alone doesn't cover newlines
        // -- a newline-only override must ALSO fall back, and a
        // leading/trailing-whitespace-or-newline override (plausible
        // from an agent-constructed payload built from raw shell
        // output, e.g. `$(pwd)`) must be trimmed before use, not passed
        // through raw.
        XCTAssertEqual(controller.resolveNewTabSpawnCwd(override: "\n"), "/Users/dev/existing-tab-pwd",
                       "a newline-only override must be treated the same as no override")
        XCTAssertEqual(controller.resolveNewTabSpawnCwd(override: "  /tmp \n"), "/tmp",
                       "a trailing/leading-whitespace-or-newline override must be trimmed before use")
    }

    // MARK: - cockpitSendCommand / cockpitSendKeys

    /// P3 final gate (Warning 1): `cockpitSendCommand`/`cockpitSendKeys`
    /// must resolve their tab the SAME way `ownsSplitLeaf`/`performSplit`
    /// do (split-tree leaf membership), not the registry-based
    /// `findTab(surfaceID:)` -- otherwise `LiveCockpitAppAccess
    /// .paneExists`/`listPanes` (leaf-based) can report a pane that
    /// `sendCommand`/`sendKeys` then rejects for the same id. This test
    /// host cannot construct a live `GhosttySurfaceController` (see this
    /// file's own header / `SurfaceLocator.swift`'s), so the actual send
    /// can't be observed directly; instead this pins that `ownsSplitLeaf`
    /// (the F3-unified check) and both send seams agree on tab
    /// resolution: a leaf with no registry entry is reached (fails only
    /// at controller resolution, returns false, does not crash) exactly
    /// like a genuinely-foreign id is (fails at tab resolution, also
    /// returns false) -- the fix itself (`findTab(bySplitLeaf:)`
    /// replacing `findTab(surfaceID:)`) is verified by reading the diff.
    func test_cockpitSendCommand_and_cockpitSendKeys_agreeWithOwnsSplitLeaf() {
        let (controller, tab) = makeController()
        let sourceSurfaceID = UUID()
        tab.splitTree = SplitTree(leafID: sourceSurfaceID) // leaf present, NO registry entry

        XCTAssertTrue(controller.ownsSplitLeaf(sourceSurfaceID),
                      "precondition: the leaf is reachable via the F3-unified split-tree membership check")
        XCTAssertFalse(controller.cockpitSendCommand(surfaceID: sourceSurfaceID, command: "ls", doubleReturn: false),
                       "no live registry controller for this leaf -- must return false, not crash")
        XCTAssertFalse(controller.cockpitSendKeys(surfaceID: sourceSurfaceID, text: "ls"),
                       "no live registry controller for this leaf -- must return false, not crash")

        let foreignID = UUID()
        XCTAssertFalse(controller.ownsSplitLeaf(foreignID), "precondition: not a leaf in any tab this window owns")
        XCTAssertFalse(controller.cockpitSendCommand(surfaceID: foreignID, command: "ls", doubleReturn: false))
        XCTAssertFalse(controller.cockpitSendKeys(surfaceID: foreignID, text: "ls"))
    }

    // MARK: - cockpitExecutePaletteCommand

    /// P3 review (F1): an MCP caller can name any command id directly,
    /// with no upstream filter like `CommandPaletteView`'s own
    /// `search(query:)` (which excludes unavailable commands before the
    /// user could ever select one) -- this seam must gate on
    /// `isAvailable()` itself and never run an unavailable command's
    /// handler (crash risk from unmet preconditions).
    func test_cockpitExecutePaletteCommand_unavailableCommand_notExecuted_returnsExecutedFalse() {
        let (controller, _) = makeController()
        var handlerCallCount = 0
        controller.commandRegistry.register(PaletteCommand(
            id: "test.unavailable",
            title: "Unavailable Test Command",
            isAvailable: { false },
            handler: { handlerCallCount += 1 }
        ))

        let result = controller.cockpitExecutePaletteCommand(id: "test.unavailable")

        XCTAssertEqual(result?.command.id, "test.unavailable")
        XCTAssertEqual(result?.executed, false, "an unavailable command must report executed == false")
        XCTAssertEqual(handlerCallCount, 0, "an unavailable command's handler must never be called")
    }

    func test_cockpitExecutePaletteCommand_availableCommand_executed_returnsExecutedTrue() {
        let (controller, _) = makeController()
        var handlerCallCount = 0
        controller.commandRegistry.register(PaletteCommand(
            id: "test.available",
            title: "Available Test Command",
            isAvailable: { true },
            handler: { handlerCallCount += 1 }
        ))

        let result = controller.cockpitExecutePaletteCommand(id: "test.available")

        XCTAssertEqual(result?.command.id, "test.available")
        XCTAssertEqual(result?.executed, true)
        XCTAssertEqual(handlerCallCount, 1, "an available command's handler must be called exactly once")
    }

    func test_cockpitExecutePaletteCommand_unknownID_returnsNil() {
        let (controller, _) = makeController()

        XCTAssertNil(controller.cockpitExecutePaletteCommand(id: "test.doesNotExist"))
    }
}
