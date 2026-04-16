//
//  SplitContainerViewDimmingTests.swift
//  CalyxTests
//
//  Tests for Issue #28 — inactive split panes should be visually dimmed by
//  setting `SurfaceView.alphaValue = 0.75` on non-active wrappers while the
//  active wrapper stays at `alphaValue = 1.0`. Single-pane tabs are never
//  dimmed.
//
//  These tests target a future API surface that does NOT exist yet:
//
//    1. `@MainActor protocol SurfaceFocusHost: AnyObject`
//       with `func surfaceDidBecomeActive(_ surfaceView: SurfaceView)`,
//       declared at file scope in `Calyx/GhosttyBridge/SurfaceView.swift`.
//    2. `weak var focusHost: (any SurfaceFocusHost)?` stored on `SurfaceView`.
//    3. `extension SplitContainerView: SurfaceFocusHost` implementing
//       `surfaceDidBecomeActive(_:)`, plus `private var activeLeafID: UUID?`
//       and `private func applyActiveDimming()`.
//
//  Until the production TDD Green phase lands those symbols, the test file
//  is expected to FAIL TO COMPILE on references to `SurfaceFocusHost`,
//  `SurfaceView.focusHost`, and `SplitContainerView.surfaceDidBecomeActive`.
//  That is the Red phase for this feature.
//
//  Observable behaviour under test:
//
//    • testSinglePaneIsNeverDimmed — a tree with a single leaf never dims.
//    • testTwoPaneSplitDimsInactivePane — after `updateLayout` on a 2-leaf
//      horizontal split with `focusedLeafID = firstLeafID`, the first pane's
//      alpha is 1.0 and the second pane's alpha is 0.75.
//    • testSurfaceDidBecomeActiveSwitchesDimming — calling
//      `surfaceDidBecomeActive(secondSurface)` flips the alpha assignment so
//      first → 0.75 and second → 1.0.
//    • testUpdateLayoutReseedsActiveLeafFromTreeWhenStale — replacing the tree
//      with a completely new set of leaf UUIDs forces `activeLeafID` to be
//      reseeded from the new `tree.focusedLeafID`.
//    • testCollapseToSinglePaneForcesAllOpaque — transitioning from a 2-pane
//      split to a single-leaf tree must force the remaining wrapper's
//      surfaceView alpha back to 1.0.
//    • testSurfaceHasFocusHostProperty — the `focusHost` property on
//      `SurfaceView` accepts a `SurfaceFocusHost` conformer and stores the
//      reference weakly (assignment compiles and does not retain strongly).
//
//  Constraints for the reader:
//
//  - `SplitContainerView` fetches `SurfaceView`s from its injected
//    `SurfaceRegistry` via `registry.view(for: id)`. `SurfaceRegistry` has no
//    public seam for injecting test fixtures — `createSurface(...)` requires
//    a live `ghostty_app_t` which is not constructable in a unit test. The
//    tests below reference the natural API shape; tests that exercise
//    `updateLayout`-driven wrapper population will observe an empty
//    `scrollWrappers` dictionary until a test seam is introduced. This is an
//    acknowledged Red-phase limitation: these tests are syntactically valid
//    Swift that pins the intended API contract. A subsequent task may add a
//    `#if DEBUG`-guarded test seam on `SurfaceRegistry` so the implementation
//    subagent can make all six tests pass at runtime.
//

import AppKit
import XCTest
@testable import Calyx

@MainActor
final class SplitContainerViewDimmingTests: XCTestCase {

    // MARK: - Constants

    /// Alpha value the active pane must carry.
    private static let activeAlpha: CGFloat = 1.0

    /// Alpha value inactive panes must carry when there is more than one pane.
    private static let inactiveAlpha: CGFloat = 0.75

    /// Standard bounds used by tests that need non-zero layout geometry.
    private static let standardBounds = NSRect(x: 0, y: 0, width: 800, height: 600)

    // MARK: - Fixtures / Helpers

    /// Holds a freshly constructed registry + container pair. Tests build a
    /// new one per-case to avoid main-actor isolation issues around
    /// XCTestCase `setUp` / `tearDown` (those default to nonisolated contexts
    /// under Swift 6, even when the enclosing class is `@MainActor`).
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

    /// Create a fresh bare `SurfaceView` and register it against `id` in the
    /// provided registry via the `#if DEBUG` test seam. Returns the created
    /// view so the caller can assert on it directly. This bypasses the real
    /// `SurfaceRegistry.createSurface(app:config:)` pipeline — which requires
    /// a live `ghostty_app_t` — and is the only supported way to exercise
    /// `SplitContainerView` against pre-known leaf UUIDs in unit tests.
    @discardableResult
    private func registerLeaf(_ id: UUID, in registry: SurfaceRegistry) -> SurfaceView {
        let view = SurfaceView(frame: .zero)
        registry._testInsert(view: view, id: id)
        return view
    }

    /// Return all `SurfaceScrollView` wrappers currently installed on the
    /// container (i.e. the visible, non-divider subviews that host surfaces).
    private func installedWrappers(in container: SplitContainerView) -> [SurfaceScrollView] {
        container.subviews.compactMap { $0 as? SurfaceScrollView }
    }

    /// Look up the wrapper whose underlying `SurfaceView` is `surface`.
    private func wrapper(hosting surface: SurfaceView, in container: SplitContainerView) -> SurfaceScrollView? {
        installedWrappers(in: container).first { $0.surfaceView === surface }
    }

    /// Minimal `SurfaceFocusHost` conformer used solely by
    /// `testSurfaceHasFocusHostProperty` to verify weak-assignment semantics.
    /// Records each invocation so the test can assert on call history.
    @MainActor
    private final class RecordingFocusHost: SurfaceFocusHost {
        private(set) var receivedSurfaces: [SurfaceView] = []

        func surfaceDidBecomeActive(_ surfaceView: SurfaceView) {
            receivedSurfaces.append(surfaceView)
        }
    }

    // MARK: - 1. Single pane is never dimmed

    /// Given: a tree containing a single leaf and a container with non-zero
    ///        bounds.
    /// When:  `updateLayout(tree:)` is invoked.
    /// Then:  the sole installed `SurfaceScrollView`'s underlying
    ///        `surfaceView.alphaValue` must equal `1.0` — single-pane tabs
    ///        are NEVER dimmed, even though no explicit focus was given.
    func testSinglePaneIsNeverDimmed() {
        // Arrange
        let fixture = makeFixture()
        let leafID = UUID()
        // Pre-register a SurfaceView fixture against the leaf so the
        // container's layout path can resolve it via `registry.view(for:)`.
        registerLeaf(leafID, in: fixture.registry)
        let tree = SplitTree(root: .leaf(id: leafID), focusedLeafID: leafID)

        // Act
        fixture.container.updateLayout(tree: tree)

        // Assert
        let wrappers = installedWrappers(in: fixture.container)
        XCTAssertEqual(
            wrappers.count,
            1,
            "A single-leaf tree must install exactly one SurfaceScrollView wrapper"
        )
        guard let only = wrappers.first else {
            XCTFail("No SurfaceScrollView wrapper was installed for the single leaf")
            return
        }
        XCTAssertEqual(
            only.surfaceView.alphaValue,
            Self.activeAlpha,
            accuracy: 0.0001,
            "A single-pane tab must keep alphaValue == 1.0 (no dimming)"
        )
    }

    // MARK: - 2. Two-pane split dims the inactive pane

    /// Given: a horizontal split tree with two leaves, where
    ///        `focusedLeafID == firstLeafID`, and a container with non-zero
    ///        bounds.
    /// When:  `updateLayout(tree:)` is invoked.
    /// Then:  the first leaf's surface alpha is 1.0 (active) and the second
    ///        leaf's surface alpha is 0.75 (inactive, dimmed).
    func testTwoPaneSplitDimsInactivePane() {
        // Arrange
        let fixture = makeFixture()
        let firstLeafID = UUID()
        let secondLeafID = UUID()
        // Pre-register SurfaceView fixtures for both leaves so the layout
        // path can resolve them via `registry.view(for:)`.
        registerLeaf(firstLeafID, in: fixture.registry)
        registerLeaf(secondLeafID, in: fixture.registry)
        let root = SplitNode.split(SplitData(
            direction: .horizontal,
            ratio: 0.5,
            first: .leaf(id: firstLeafID),
            second: .leaf(id: secondLeafID)
        ))
        let tree = SplitTree(root: root, focusedLeafID: firstLeafID)

        // Act
        fixture.container.updateLayout(tree: tree)

        // Assert
        let wrappers = installedWrappers(in: fixture.container)
        XCTAssertEqual(
            wrappers.count,
            2,
            "A 2-leaf split tree must install exactly two SurfaceScrollView wrappers"
        )

        guard
            let firstSurface = fixture.registry.view(for: firstLeafID),
            let secondSurface = fixture.registry.view(for: secondLeafID)
        else {
            XCTFail("Registry must provide SurfaceView instances for the two leaves")
            return
        }

        XCTAssertEqual(
            firstSurface.alphaValue,
            Self.activeAlpha,
            accuracy: 0.0001,
            "The active (focused) pane must have alphaValue == 1.0"
        )
        XCTAssertEqual(
            secondSurface.alphaValue,
            Self.inactiveAlpha,
            accuracy: 0.0001,
            "The inactive pane must have alphaValue == 0.75"
        )
    }

    // MARK: - 3. surfaceDidBecomeActive switches dimming

    /// Given: a two-pane split tree with the first leaf focused, laid out in
    ///        the container.
    /// When:  `container.surfaceDidBecomeActive(secondSurface)` is invoked
    ///        (simulating the user clicking/tabbing to the second pane).
    /// Then:  the alphas flip — firstSurface.alphaValue == 0.75,
    ///        secondSurface.alphaValue == 1.0.
    func testSurfaceDidBecomeActiveSwitchesDimming() {
        // Arrange
        let fixture = makeFixture()
        let firstLeafID = UUID()
        let secondLeafID = UUID()
        // Pre-register SurfaceView fixtures for both leaves so the layout
        // path can resolve them via `registry.view(for:)`.
        registerLeaf(firstLeafID, in: fixture.registry)
        registerLeaf(secondLeafID, in: fixture.registry)
        let root = SplitNode.split(SplitData(
            direction: .horizontal,
            ratio: 0.5,
            first: .leaf(id: firstLeafID),
            second: .leaf(id: secondLeafID)
        ))
        let tree = SplitTree(root: root, focusedLeafID: firstLeafID)
        fixture.container.updateLayout(tree: tree)

        guard
            let firstSurface = fixture.registry.view(for: firstLeafID),
            let secondSurface = fixture.registry.view(for: secondLeafID)
        else {
            XCTFail("Registry must provide SurfaceView instances for the two leaves")
            return
        }

        // Sanity: initial dimming should place focus on the first leaf.
        XCTAssertEqual(
            firstSurface.alphaValue,
            Self.activeAlpha,
            accuracy: 0.0001,
            "Precondition: first pane starts active"
        )
        XCTAssertEqual(
            secondSurface.alphaValue,
            Self.inactiveAlpha,
            accuracy: 0.0001,
            "Precondition: second pane starts dimmed"
        )

        // Act — simulate the focus host callback firing for the second pane.
        fixture.container.surfaceDidBecomeActive(secondSurface)

        // Assert — alphas must have swapped.
        XCTAssertEqual(
            firstSurface.alphaValue,
            Self.inactiveAlpha,
            accuracy: 0.0001,
            "After surfaceDidBecomeActive(second), the first pane must be dimmed to 0.75"
        )
        XCTAssertEqual(
            secondSurface.alphaValue,
            Self.activeAlpha,
            accuracy: 0.0001,
            "After surfaceDidBecomeActive(second), the second pane must be opaque at 1.0"
        )
    }

    // MARK: - 4. updateLayout reseeds activeLeafID from a fresh tree

    /// Given: a two-pane split laid out with `focusedLeafID = firstLeafID`
    ///        resulting in the canonical (1.0, 0.75) alpha assignment.
    /// When:  `updateLayout` is invoked with a BRAND NEW tree whose leaf
    ///        UUIDs are entirely different and whose `focusedLeafID` points
    ///        at the first of the new pair.
    /// Then:  the stale `activeLeafID` from the previous tree must be
    ///        discarded and reseeded from `tree.focusedLeafID`; the new
    ///        first leaf's surface alpha becomes 1.0 and the new second
    ///        leaf's surface alpha becomes 0.75.
    func testUpdateLayoutReseedsActiveLeafFromTreeWhenStale() {
        // Arrange — initial two-pane tree.
        let fixture = makeFixture()
        let oldFirstID = UUID()
        let oldSecondID = UUID()
        // Pre-register the first registry with the old leaves so the
        // initial layout path can resolve them.
        registerLeaf(oldFirstID, in: fixture.registry)
        registerLeaf(oldSecondID, in: fixture.registry)
        let oldRoot = SplitNode.split(SplitData(
            direction: .horizontal,
            ratio: 0.5,
            first: .leaf(id: oldFirstID),
            second: .leaf(id: oldSecondID)
        ))
        fixture.container.updateLayout(tree: SplitTree(root: oldRoot, focusedLeafID: oldFirstID))

        if let oldFirst = fixture.registry.view(for: oldFirstID),
           let oldSecond = fixture.registry.view(for: oldSecondID) {
            XCTAssertEqual(oldFirst.alphaValue, Self.activeAlpha, accuracy: 0.0001)
            XCTAssertEqual(oldSecond.alphaValue, Self.inactiveAlpha, accuracy: 0.0001)
        }

        // Swap the registry with a fresh one so the container clears its
        // cached `activeLeafID` via `updateRegistry(_:)` — this mirrors the
        // real lifecycle where a tab's registry is rebuilt under it.
        let freshRegistry = SurfaceRegistry()
        fixture.container.updateRegistry(freshRegistry)

        // Act — install a fresh tree whose UUIDs are disjoint from the old ones.
        let newFirstID = UUID()
        let newSecondID = UUID()
        XCTAssertNotEqual(newFirstID, oldFirstID)
        XCTAssertNotEqual(newSecondID, oldSecondID)

        // Pre-register the fresh registry with the new leaves so the
        // second layout pass can resolve them.
        registerLeaf(newFirstID, in: freshRegistry)
        registerLeaf(newSecondID, in: freshRegistry)

        let newRoot = SplitNode.split(SplitData(
            direction: .horizontal,
            ratio: 0.5,
            first: .leaf(id: newFirstID),
            second: .leaf(id: newSecondID)
        ))
        fixture.container.updateLayout(tree: SplitTree(root: newRoot, focusedLeafID: newFirstID))

        // Assert — reseed must have happened: new first = 1.0, new second = 0.75.
        guard
            let newFirst = freshRegistry.view(for: newFirstID),
            let newSecond = freshRegistry.view(for: newSecondID)
        else {
            XCTFail("Fresh registry must provide SurfaceView instances for the newly added leaves")
            return
        }
        XCTAssertEqual(
            newFirst.alphaValue,
            Self.activeAlpha,
            accuracy: 0.0001,
            "After reseeding from the new tree's focusedLeafID, the new first leaf must be active"
        )
        XCTAssertEqual(
            newSecond.alphaValue,
            Self.inactiveAlpha,
            accuracy: 0.0001,
            "After reseeding, the new second leaf must be dimmed"
        )
    }

    // MARK: - 5. Collapsing to a single pane forces opaque

    /// Given: a two-pane split tree where the inactive (second) pane has been
    ///        dimmed to 0.75.
    /// When:  `updateLayout` is invoked with a tree containing only the
    ///        surviving leaf.
    /// Then:  the surviving pane's `alphaValue` must be forced back to 1.0,
    ///        because single-pane tabs are never dimmed.
    func testCollapseToSinglePaneForcesAllOpaque() {
        // Arrange — start with a two-pane split.
        let fixture = makeFixture()
        let firstLeafID = UUID()
        let secondLeafID = UUID()
        // Pre-register SurfaceView fixtures for both leaves so the layout
        // path can resolve them via `registry.view(for:)`.
        registerLeaf(firstLeafID, in: fixture.registry)
        registerLeaf(secondLeafID, in: fixture.registry)
        let splitRoot = SplitNode.split(SplitData(
            direction: .horizontal,
            ratio: 0.5,
            first: .leaf(id: firstLeafID),
            second: .leaf(id: secondLeafID)
        ))
        fixture.container.updateLayout(tree: SplitTree(root: splitRoot, focusedLeafID: firstLeafID))

        // Precondition: the inactive pane is dimmed before we collapse.
        if let secondSurface = fixture.registry.view(for: secondLeafID) {
            XCTAssertEqual(
                secondSurface.alphaValue,
                Self.inactiveAlpha,
                accuracy: 0.0001,
                "Precondition: second pane is dimmed in the two-pane state"
            )
        }

        // Act — collapse to a single leaf (the first one survives).
        let collapsedTree = SplitTree(root: .leaf(id: firstLeafID), focusedLeafID: firstLeafID)
        fixture.container.updateLayout(tree: collapsedTree)

        // Assert — the surviving surface must be fully opaque again.
        guard let firstSurface = fixture.registry.view(for: firstLeafID) else {
            XCTFail("Registry must still provide the surviving SurfaceView")
            return
        }
        XCTAssertEqual(
            firstSurface.alphaValue,
            Self.activeAlpha,
            accuracy: 0.0001,
            "Collapsing to a single pane must force the surviving surface's alphaValue back to 1.0"
        )
    }

    // MARK: - 6. SurfaceView has a focusHost property that holds weakly

    /// Compile-time smoke test: `SurfaceView` exposes a settable
    /// `focusHost` property typed `(any SurfaceFocusHost)?`. Assignment must
    /// compile, round-trip (the getter returns the same conformer), and
    /// release on nil-out so the strong side retains the only reference.
    ///
    /// This test pins down the declared shape of the new protocol and
    /// property. It does NOT invoke `surfaceDidBecomeActive` — that path is
    /// covered by testSurfaceDidBecomeActiveSwitchesDimming above.
    func testSurfaceHasFocusHostProperty() {
        // Arrange
        let surfaceView = SurfaceView(frame: .zero)
        var host: RecordingFocusHost? = RecordingFocusHost()

        // Act — assign the host and verify round-trip.
        surfaceView.focusHost = host
        XCTAssertTrue(
            surfaceView.focusHost === host,
            "SurfaceView.focusHost getter must return the assigned conformer"
        )

        // Act — drop the strong ref. Because `focusHost` is declared `weak`,
        // the surface must observe nil once the only strong owner goes away.
        weak var weakHostProbe = host
        host = nil
        XCTAssertNil(
            weakHostProbe,
            "The local strong reference was released; the probe must witness deallocation"
        )
        XCTAssertNil(
            surfaceView.focusHost,
            "SurfaceView.focusHost must be declared `weak` so it auto-clears when the host deallocates"
        )

        // Act — also verify that an assigned, still-live conformer can be
        // invoked directly (covers the protocol method signature).
        let liveHost = RecordingFocusHost()
        surfaceView.focusHost = liveHost
        (surfaceView.focusHost as? SurfaceFocusHost)?.surfaceDidBecomeActive(surfaceView)
        XCTAssertEqual(
            liveHost.receivedSurfaces.count,
            1,
            "SurfaceFocusHost.surfaceDidBecomeActive must be callable on a stored focusHost"
        )
        XCTAssertTrue(
            liveHost.receivedSurfaces.first === surfaceView,
            "The host must receive the exact SurfaceView that invoked it"
        )
    }

    // MARK: - 7. onActiveLeafChange fires on a real focus transition
    //
    // Contract pinned by this test (Issue #29):
    //
    //   `SplitContainerView` must expose a settable public closure property
    //   `var onActiveLeafChange: ((UUID) -> Void)?` which is invoked from
    //   `surfaceDidBecomeActive(_:)` AFTER the existing
    //   `activeLeafID != id` guard short-circuits a no-op, with the
    //   newly-active leaf's UUID as its argument.
    //
    //   Rationale: the persistent `SplitTree.focusedLeafID` (Source of Truth)
    //   and the ephemeral `SplitContainerView.activeLeafID` (view state) fall
    //   out of sync when the user clicks a pane. The callback lets the window
    //   controller propagate the click into the tab's split-tree model so the
    //   next `restoreFocus()` reads a current value.
    //
    // Red-phase expectation: this test FAILS TO COMPILE because
    // `container.onActiveLeafChange` does not exist yet.

    /// Given: a 2-pane tree with `focusedLeafID = firstLeafID`, laid out in
    ///        the container, and `onActiveLeafChange` assigned.
    /// When:  `container.surfaceDidBecomeActive(secondSurface)` is invoked
    ///        (simulating the user clicking the second pane).
    /// Then:  the callback fires exactly once with `secondLeafID`.
    func testOnActiveLeafChangeFiresOnRealTransition() {
        // Arrange
        let fixture = makeFixture()
        let firstLeafID = UUID()
        let secondLeafID = UUID()
        let firstSurface = registerLeaf(firstLeafID, in: fixture.registry)
        let secondSurface = registerLeaf(secondLeafID, in: fixture.registry)
        let root = SplitNode.split(SplitData(
            direction: .horizontal,
            ratio: 0.5,
            first: .leaf(id: firstLeafID),
            second: .leaf(id: secondLeafID)
        ))
        fixture.container.updateLayout(tree: SplitTree(root: root, focusedLeafID: firstLeafID))
        _ = firstSurface // silence unused-variable warning; used only to seed the registry

        var received: [UUID] = []
        fixture.container.onActiveLeafChange = { leafID in
            received.append(leafID)
        }

        // Act — simulate the second pane gaining focus (user click).
        fixture.container.surfaceDidBecomeActive(secondSurface)

        // Assert — exactly one invocation, carrying the new leaf's UUID.
        XCTAssertEqual(
            received.count,
            1,
            "onActiveLeafChange must fire exactly once for a real focus transition"
        )
        XCTAssertEqual(
            received.first,
            secondLeafID,
            "onActiveLeafChange must receive the newly-active leaf's UUID"
        )
    }

    // MARK: - 8. onActiveLeafChange is NOT fired on a no-op reactivation

    /// Given: same two-pane layout as test 7, with the callback assigned, and
    ///        `surfaceDidBecomeActive(secondSurface)` already invoked once so
    ///        `activeLeafID == secondLeafID`.
    /// When:  `surfaceDidBecomeActive(secondSurface)` is invoked AGAIN with
    ///        the same surface.
    /// Then:  the callback does not fire a second time — the existing
    ///        `activeLeafID != id` guard short-circuits the method before
    ///        reaching the callback invocation. The recorded-invocations
    ///        array length stays at 1.
    func testOnActiveLeafChangeNotFiredOnNoOpReactivation() {
        // Arrange
        let fixture = makeFixture()
        let firstLeafID = UUID()
        let secondLeafID = UUID()
        registerLeaf(firstLeafID, in: fixture.registry)
        let secondSurface = registerLeaf(secondLeafID, in: fixture.registry)
        let root = SplitNode.split(SplitData(
            direction: .horizontal,
            ratio: 0.5,
            first: .leaf(id: firstLeafID),
            second: .leaf(id: secondLeafID)
        ))
        fixture.container.updateLayout(tree: SplitTree(root: root, focusedLeafID: firstLeafID))

        var received: [UUID] = []
        fixture.container.onActiveLeafChange = { leafID in
            received.append(leafID)
        }

        // Act — first activation establishes activeLeafID == secondLeafID.
        fixture.container.surfaceDidBecomeActive(secondSurface)
        XCTAssertEqual(
            received.count,
            1,
            "Precondition: the first call to surfaceDidBecomeActive must fire the callback once"
        )

        // Act — second activation with the same surface must be a no-op.
        fixture.container.surfaceDidBecomeActive(secondSurface)

        // Assert — invocation count did not increase.
        XCTAssertEqual(
            received.count,
            1,
            "onActiveLeafChange must NOT fire when surfaceDidBecomeActive is called with the already-active surface"
        )
    }

    // MARK: - 9. onActiveLeafChange is NOT fired for an unregistered surface

    /// Given: a two-pane layout with the callback assigned.
    /// When:  `surfaceDidBecomeActive(_:)` is invoked with a brand-new
    ///        `SurfaceView` that has NOT been registered in the registry, so
    ///        `registry.id(for: surfaceView)` returns nil.
    /// Then:  the method exits at the `guard let id = registry.id(for:)` line
    ///        and never invokes the callback.
    func testOnActiveLeafChangeNotFiredForUnregisteredSurface() {
        // Arrange
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
        fixture.container.updateLayout(tree: SplitTree(root: root, focusedLeafID: firstLeafID))

        var received: [UUID] = []
        fixture.container.onActiveLeafChange = { leafID in
            received.append(leafID)
        }

        // A brand-new SurfaceView never inserted into the registry.
        let unregisteredSurface = SurfaceView(frame: .zero)
        XCTAssertNil(
            fixture.registry.id(for: unregisteredSurface),
            "Precondition: the unregistered surface must not be resolvable in the registry"
        )

        // Act
        fixture.container.surfaceDidBecomeActive(unregisteredSurface)

        // Assert
        XCTAssertTrue(
            received.isEmpty,
            "onActiveLeafChange must NOT fire when the surface is not resolvable in the registry"
        )
    }

    // MARK: - 10. onActiveLeafChange fires after a registry swap
    //
    // Reviewer's note: the original intent was "first activation after
    // updateRegistry". However, after the fresh registry is installed and
    // `updateLayout(tree:)` is called with a new tree, SplitContainerView
    // reseeds `activeLeafID` from `tree.focusedLeafID` (lines 69-71). So if
    // we then call `surfaceDidBecomeActive(newFirstSurface)` with the same
    // leaf that was just reseeded, the `activeLeafID != id` guard will
    // short-circuit — no callback. To verify the callback is wired AFTER the
    // registry swap, we must transition to a *different* leaf than the one
    // the tree reseeded onto. Hence this test renames to reflect the actual
    // contract: "fires on transition to a different leaf in the fresh
    // registry".

    /// Given: an old 2-pane layout is replaced with a fresh registry, a new
    ///        pair of leaves is registered in that fresh registry, and a new
    ///        tree with `focusedLeafID = newFirstID` is laid out — so
    ///        `activeLeafID` is reseeded to `newFirstID`. The callback is
    ///        then assigned.
    /// When:  `surfaceDidBecomeActive(newSecondSurface)` is invoked to force
    ///        a real transition past the reseeded active leaf.
    /// Then:  the callback fires exactly once with `newSecondLeafID`.
    ///        (This proves the callback is still wired AFTER an
    ///        `updateRegistry` + `updateLayout` cycle.)
    func testOnActiveLeafChangeFiresOnTransitionToDifferentLeafInFreshRegistry() {
        // Arrange — start with an old tree/registry.
        let fixture = makeFixture()
        let oldFirstID = UUID()
        let oldSecondID = UUID()
        registerLeaf(oldFirstID, in: fixture.registry)
        registerLeaf(oldSecondID, in: fixture.registry)
        let oldRoot = SplitNode.split(SplitData(
            direction: .horizontal,
            ratio: 0.5,
            first: .leaf(id: oldFirstID),
            second: .leaf(id: oldSecondID)
        ))
        fixture.container.updateLayout(tree: SplitTree(root: oldRoot, focusedLeafID: oldFirstID))

        // Swap to a fresh registry — this nils `activeLeafID` inside the
        // container per `SplitContainerView.updateRegistry(_:)`.
        let freshRegistry = SurfaceRegistry()
        fixture.container.updateRegistry(freshRegistry)

        // Register two NEW leaves in the fresh registry and lay out a new
        // tree. `activeLeafID` is reseeded to `newFirstID` via lines 69-71.
        let newFirstID = UUID()
        let newSecondID = UUID()
        registerLeaf(newFirstID, in: freshRegistry)
        let newSecondSurface = registerLeaf(newSecondID, in: freshRegistry)
        let newRoot = SplitNode.split(SplitData(
            direction: .horizontal,
            ratio: 0.5,
            first: .leaf(id: newFirstID),
            second: .leaf(id: newSecondID)
        ))
        fixture.container.updateLayout(tree: SplitTree(root: newRoot, focusedLeafID: newFirstID))

        // Assign the callback AFTER the reseed so it can't fire during setup.
        var received: [UUID] = []
        fixture.container.onActiveLeafChange = { leafID in
            received.append(leafID)
        }

        // Act — transition to the OTHER leaf so the guard allows through.
        fixture.container.surfaceDidBecomeActive(newSecondSurface)

        // Assert
        XCTAssertEqual(
            received.count,
            1,
            "onActiveLeafChange must fire on a real transition in the fresh registry"
        )
        XCTAssertEqual(
            received.first,
            newSecondID,
            "onActiveLeafChange must carry the newly-active leaf's UUID after the registry swap"
        )
    }
}
