//
//  SplitContainerViewInitialActiveLeafSaveTests.swift
//  CalyxTests
//
//  TDD Red phase (save-reliability C1, first-save trigger). ROOT CAUSE:
//  a brand new window's (or a brand new tab's) very first surface never
//  triggers a session save, because nothing calls requestSave() until
//  SOME later focus/split/tab action fires
//  SplitContainerView.onActiveLeafChange (wired in
//  CalyxWindowController.setupUI()/rebuildSplitContainer() to update
//  focusedLeafID AND call requestSave() -- see
//  CalyxWindowControllerFocusSyncTests
//  .testActiveLeafChangeClosureWritesBothFocusedLeafIDAndTriggersSave's
//  own header for that production shape). If the user quits before any
//  such action ever happens (e.g. opens one window, types in its sole
//  pane, and quits within the same launch before splitting/tabbing/
//  refocusing anything), the window/tab never gets its FIRST persisted
//  representation: today's only save triggers are the debounced periodic
//  save on a genuine focus TRANSITION and window-close/terminate saves,
//  none of which fire for a window that never changes focus at all.
//
//  MECHANISM (SplitContainerView.swift):
//    `updateLayout(tree:)` (~80-108) silently assigns
//    `activeLeafID = tree.focusedLeafID` at lines 103-105 whenever
//    `activeLeafID == nil` (a brand new container, or one just reset by
//    `updateRegistry(_:)`) -- this is the FIRST time a container ever
//    picks an active leaf for a freshly laid-out tree, exactly the
//    "window/tab's first persistent surface" moment C1 is about. Unlike
//    `surfaceDidBecomeActive(_:)` (SurfaceFocusHost conformance, ~350-356),
//    which invokes `onActiveLeafChange?(id)` after its own
//    `activeLeafID != id` guard, this silent initial assignment never
//    calls the closure at all -- so the production wiring that would
//    otherwise call `requestSave()` never fires for this transition.
//
//  THE FIX: the initial assignment branch in `updateLayout(tree:)` must
//  also invoke `onActiveLeafChange?(id)` (mirroring
//  `surfaceDidBecomeActive`'s own call), so that
//  `CalyxWindowController`'s EXISTING closure wiring (unchanged --
//  `self?.activeTab?.splitTree.focusedLeafID = leafID;
//  self?.requestSave()`, already covers "whatever reason the callback
//  fired for") requests a save the moment a window/tab's first surface
//  is laid out, with no user action required.
//
//  This is a genuine runtime Red, not a compile-RED: `onActiveLeafChange`
//  already exists as a settable closure property, so these tests compile
//  today and FAIL as real assertion failures (0 invocations recorded)
//  against the current silent-assignment code.
//
//  WHAT THIS FILE CAN AND CANNOT PIN: SplitContainerView itself requires
//  no live ghostty surface or NSWindow (mirrors
//  SplitContainerViewDimmingTests' own `_testInsert`-only fixture), so
//  this file drives `updateLayout(tree:)` directly and pins the callback
//  contract exactly. It CANNOT pin that CalyxWindowController's
//  production closures actually route this into `requestSave()` for a
//  REAL window (CalyxWindowController cannot be instantiated with a live
//  surface in a unit test) -- that wiring is UNCHANGED by this fix (see
//  above), so code review need only confirm no new call site was
//  introduced, not that the existing one still reads correctly.
//
//  Coverage:
//  - a fresh container's first updateLayout (single-leaf tree) fires
//    onActiveLeafChange once with the tree's focusedLeafID
//  - a fresh container's first updateLayout (multi-leaf split tree)
//    fires onActiveLeafChange once with the focused leaf's ID, same as
//    the single-leaf case -- the callback contract does not depend on
//    pane count
//  - a SECOND updateLayout call with the SAME tree (the `oldTree != tree`
//    early-return guard, line 84) must NOT re-fire the callback -- proves
//    the fix does not turn every redundant layout pass into a spurious
//    save request
//  - after updateRegistry(_:) resets activeLeafID to nil (the "new tab's
//    registry" case, not just "new window"), the next updateLayout's
//    reseed must ALSO fire the callback -- the initial-assignment gap is
//    identical for a brand new tab's first surface, not only a brand new
//    window's
//

import AppKit
import XCTest
@testable import Calyx

@MainActor
final class SplitContainerViewInitialActiveLeafSaveTests: XCTestCase {

    // MARK: - Fixtures / Helpers (mirrors SplitContainerViewDimmingTests)

    private static let standardBounds = NSRect(x: 0, y: 0, width: 800, height: 600)

    private struct Fixture {
        let registry: SurfaceRegistry
        let container: SplitContainerView
    }

    private func makeFixture() -> Fixture {
        let registry = SurfaceRegistry()
        let container = SplitContainerView(registry: registry)
        container.frame = Self.standardBounds
        container.layoutSubtreeIfNeeded()
        return Fixture(registry: registry, container: container)
    }

    @discardableResult
    private func registerLeaf(_ id: UUID, in registry: SurfaceRegistry) -> SurfaceView {
        let view = SurfaceView(frame: .zero)
        registry._testInsert(view: view, id: id)
        return view
    }

    // MARK: - 1. Single-leaf tree: first layout fires the callback

    /// Given: a fresh container (activeLeafID == nil, matching a brand
    ///        new window's freshly-constructed SplitContainerView) and a
    ///        single-leaf tree (a window's sole initial tab, unsplit).
    /// When:  updateLayout(tree:) is called for the first time.
    /// Then:  onActiveLeafChange fires exactly once, with the leaf's ID --
    ///        the exact save trigger a brand new window/tab needs with no
    ///        user action.
    func testFirstLayoutOfSingleLeafTreeFiresOnActiveLeafChange() {
        let fixture = makeFixture()
        let leafID = UUID()
        registerLeaf(leafID, in: fixture.registry)
        let tree = SplitTree(root: .leaf(id: leafID), focusedLeafID: leafID)

        var received: [UUID] = []
        fixture.container.onActiveLeafChange = { received.append($0) }

        fixture.container.updateLayout(tree: tree)

        XCTAssertEqual(
            received,
            [leafID],
            "A brand new window/tab's first layout pass (single, unsplit leaf) must fire " +
            "onActiveLeafChange with the leaf's ID exactly once, so the production wiring's " +
            "requestSave() runs without requiring any later focus/split/tab action"
        )
    }

    // MARK: - 2. Multi-leaf split tree: first layout still fires the callback

    /// Given: a fresh container and a two-pane split tree with
    ///        focusedLeafID pointing at the first leaf (a window whose
    ///        very first tab was created already split, e.g. restored
    ///        from a snapshot with a split tree -- though restore takes
    ///        a separate path, the container-level contract is identical
    ///        for any tree shape on first layout).
    /// When:  updateLayout(tree:) is called for the first time.
    /// Then:  onActiveLeafChange fires exactly once, with the focused
    ///        leaf's ID -- the callback contract does not depend on pane
    ///        count.
    func testFirstLayoutOfSplitTreeFiresOnActiveLeafChange() {
        let fixture = makeFixture()
        let firstLeafID = UUID()
        let secondLeafID = UUID()
        registerLeaf(firstLeafID, in: fixture.registry)
        registerLeaf(secondLeafID, in: fixture.registry)
        let root = SplitNode.split(SplitData(
            direction: .horizontal,
            ratio: 0.5,
            first: .leaf(id: firstLeafID),
            second: .leaf(id: secondLeafID)
        ))
        let tree = SplitTree(root: root, focusedLeafID: firstLeafID)

        var received: [UUID] = []
        fixture.container.onActiveLeafChange = { received.append($0) }

        fixture.container.updateLayout(tree: tree)

        XCTAssertEqual(
            received,
            [firstLeafID],
            "A brand new window's first layout pass must fire onActiveLeafChange with the " +
            "focused leaf's ID even when the initial tree already has multiple panes"
        )
    }

    // MARK: - 3. A redundant second call with the identical tree does not re-fire

    /// Given: a container whose first updateLayout already fired the
    ///        callback once (test 1's scenario).
    /// When:  updateLayout(tree:) is called again with the EXACT SAME
    ///        tree value (e.g. an unrelated caller re-running layout).
    /// Then:  the callback must NOT fire again -- `oldTree != tree`'s
    ///        existing early-return guard (line 84) already short-circuits
    ///        before reaching the initial-assignment branch, and the fix
    ///        must not disturb that.
    func testRedundantSecondLayoutWithIdenticalTreeDoesNotRefire() {
        let fixture = makeFixture()
        let leafID = UUID()
        registerLeaf(leafID, in: fixture.registry)
        let tree = SplitTree(root: .leaf(id: leafID), focusedLeafID: leafID)
        fixture.container.updateLayout(tree: tree)

        var received: [UUID] = []
        fixture.container.onActiveLeafChange = { received.append($0) }

        fixture.container.updateLayout(tree: tree)

        XCTAssertTrue(
            received.isEmpty,
            "Calling updateLayout(tree:) again with an identical tree must not re-fire " +
            "onActiveLeafChange -- only a genuinely new/changed tree (or a fresh container) " +
            "should ever trigger the initial-assignment save"
        )
    }

    // MARK: - 4. updateRegistry(_:) resets the gap for a brand new tab too

    /// Given: a container that already laid out one tree (so
    ///        activeLeafID is non-nil), then has its registry swapped via
    ///        updateRegistry(_:) -- the real lifecycle for switching to a
    ///        brand new tab, which resets activeLeafID back to nil
    ///        (SplitContainerView.swift ~68-78).
    /// When:  updateLayout(tree:) lays out the new tab's own first tree.
    /// Then:  onActiveLeafChange fires exactly once for the new tab's
    ///        focused leaf -- the initial-assignment gap applies to a
    ///        brand new TAB's first surface exactly as it does to a
    ///        brand new WINDOW's.
    func testLayoutAfterRegistrySwapFiresOnActiveLeafChangeForNewTab() {
        let fixture = makeFixture()
        let oldLeafID = UUID()
        registerLeaf(oldLeafID, in: fixture.registry)
        fixture.container.updateLayout(tree: SplitTree(root: .leaf(id: oldLeafID), focusedLeafID: oldLeafID))

        let freshRegistry = SurfaceRegistry()
        fixture.container.updateRegistry(freshRegistry)

        let newLeafID = UUID()
        registerLeaf(newLeafID, in: freshRegistry)
        let newTree = SplitTree(root: .leaf(id: newLeafID), focusedLeafID: newLeafID)

        var received: [UUID] = []
        fixture.container.onActiveLeafChange = { received.append($0) }

        fixture.container.updateLayout(tree: newTree)

        XCTAssertEqual(
            received,
            [newLeafID],
            "A brand new tab's first layout pass, after updateRegistry(_:) resets activeLeafID " +
            "to nil, must fire onActiveLeafChange exactly once for the new tab's focused leaf"
        )
    }
}
