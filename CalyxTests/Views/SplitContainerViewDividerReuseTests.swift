//
//  SplitContainerViewDividerReuseTests.swift
//  CalyxTests
//
//  Tests for the divider-reuse caching mechanism on `SplitContainerView`
//  introduced to fix the Cmd+D split-divider drag bug.
//
//  Background (Bug 3 of the fix plan):
//  -----------------------------------
//  Before the fix, `SplitContainerView` called `removeDividers()` from
//  `updateLayout(tree:)`, `resizeSubviews(withOldSize:)`, and `layout()`.
//  Every pass tore down all `SplitDividerView` subviews and rebuilt fresh
//  instances. That broke drag: AppKit's mouse-capture session was bound to
//  the original `NSView` instance, so when `mouseDragged` → `setRatio` →
//  `updateLayout` round-tripped synchronously, the old divider was removed
//  from its superview mid-drag and subsequent drag events never arrived.
//
//  The new contract this file pins:
//  --------------------------------
//
//    1. `SplitContainerView` maintains an internal cache keyed by the first
//       leaf ID of `splitData.first` so that a divider's NSView instance
//       survives any number of layout passes whose split *direction* matches
//       the cached entry's direction.
//
//    2. The divider callback shape is renamed from the old
//          `onRatioChange: ((UUID, Double, SplitDirection) -> Void)?`
//       (delta-style) to
//          `onTargetRatioChange: ((UUID, Double, SplitDirection) -> Void)?`
//       (absolute-ratio-style). The `Double` argument is an absolute target
//       ratio in [0, 1], measured along the splitting axis of the container.
//       Clamping is the responsibility of `SplitTree.setRatio(...)`.
//
//    3. `SplitDividerView` exposes a `#if DEBUG`-guarded test seam
//       `_testSimulateDrag(toSuperviewPoint: NSPoint)` that runs exactly the
//       same superview-coords → target-ratio math as `mouseDragged(with:)`,
//       without needing a real `NSEvent` (which requires a live `NSWindow`
//       context that unit tests cannot reliably construct). This seam is the
//       only sanctioned way to drive drag math from XCTest.
//
//  Red-phase expectation:
//  ----------------------
//  This file is expected to FAIL TO COMPILE against the pre-fix codebase
//  because:
//    • `SplitContainerView.onTargetRatioChange` does not exist
//    • `SplitDividerView._testSimulateDrag(toSuperviewPoint:)` does not exist
//  The compile failure is the RED phase.
//

import AppKit
import XCTest
@testable import Calyx

@MainActor
final class SplitContainerViewDividerReuseTests: XCTestCase {

    // MARK: - Constants

    /// Standard bounds used by tests that need non-zero layout geometry.
    private static let standardBounds = NSRect(x: 0, y: 0, width: 800, height: 600)

    // MARK: - Fixtures / Helpers

    /// Holds a freshly constructed registry + container pair. Built per-test
    /// to avoid main-actor isolation issues around XCTestCase
    /// `setUp`/`tearDown` under Swift 6.
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
    /// view so the caller can hold onto it.
    @discardableResult
    private func registerLeaf(_ id: UUID, in registry: SurfaceRegistry) -> SurfaceView {
        let view = SurfaceView(frame: .zero)
        registry._testInsert(view: view, id: id)
        return view
    }

    /// Return all `SplitDividerView` subviews currently installed on the
    /// container (Bug 3 regression-test plumbing).
    private func installedDividers(in container: SplitContainerView) -> [SplitDividerView] {
        container.subviews.compactMap { $0 as? SplitDividerView }
    }

    /// Build a horizontal 2-leaf split tree with the given ratio.
    private func makeTwoLeafHorizontalTree(
        firstLeafID: UUID,
        secondLeafID: UUID,
        ratio: Double = 0.5
    ) -> SplitTree {
        let root = SplitNode.split(SplitData(
            direction: .horizontal,
            ratio: ratio,
            first: .leaf(id: firstLeafID),
            second: .leaf(id: secondLeafID)
        ))
        return SplitTree(root: root, focusedLeafID: firstLeafID)
    }

    /// Build a vertical 2-leaf split tree with the given ratio.
    private func makeTwoLeafVerticalTree(
        firstLeafID: UUID,
        secondLeafID: UUID,
        ratio: Double = 0.5
    ) -> SplitTree {
        let root = SplitNode.split(SplitData(
            direction: .vertical,
            ratio: ratio,
            first: .leaf(id: firstLeafID),
            second: .leaf(id: secondLeafID)
        ))
        return SplitTree(root: root, focusedLeafID: firstLeafID)
    }

    // MARK: - 1. Divider NSView identity preserved across ratio-only updateLayout
    //
    // CRITICAL Bug-3 regression test. If `updateLayout` ever destroys the
    // divider when only `data.ratio` changed, this test catches it.

    /// Given: a 2-leaf horizontal split laid out once.
    /// When:  `updateLayout` is invoked with the SAME shape but a different
    ///        ratio (0.5 → 0.7).
    /// Then:  the `SplitDividerView` in the container is the EXACT same
    ///        NSView instance (`===`), and its frame's x reflects the new
    ///        ratio (≈ 0.7 * 800 within ±1pt).
    func testDividerNSViewIdentityPreservedAcrossRatioOnlyUpdateLayout() {
        // Arrange
        let fixture = makeFixture()
        let firstLeafID = UUID()
        let secondLeafID = UUID()
        registerLeaf(firstLeafID, in: fixture.registry)
        registerLeaf(secondLeafID, in: fixture.registry)
        let initialTree = makeTwoLeafHorizontalTree(
            firstLeafID: firstLeafID,
            secondLeafID: secondLeafID,
            ratio: 0.5
        )
        fixture.container.updateLayout(tree: initialTree)

        let initialDividers = installedDividers(in: fixture.container)
        XCTAssertEqual(initialDividers.count, 1,
                       "Precondition: exactly one SplitDividerView must be installed after the first layout pass")
        guard let originalDivider = initialDividers.first else {
            XCTFail("Precondition: container must hold a SplitDividerView after the first layout pass")
            return
        }

        // Act — re-layout with the SAME shape and a different ratio.
        let updatedTree = makeTwoLeafHorizontalTree(
            firstLeafID: firstLeafID,
            secondLeafID: secondLeafID,
            ratio: 0.7
        )
        fixture.container.updateLayout(tree: updatedTree)

        // Assert — divider INSTANCE identity is preserved.
        let postDividers = installedDividers(in: fixture.container)
        XCTAssertEqual(postDividers.count, 1,
                       "After ratio-only update there must still be exactly one SplitDividerView")
        XCTAssertTrue(
            postDividers.first === originalDivider,
            "Bug 3 regression: the SplitDividerView NSView instance must be reused across ratio-only updateLayout passes"
        )

        // Assert — divider's frame moved to reflect the new ratio.
        let expectedX = 0.7 * Self.standardBounds.width
        XCTAssertEqual(
            originalDivider.frame.midX,
            expectedX,
            accuracy: 1.0,
            "Divider frame midX must move to ≈ ratio * containerWidth (0.7 * 800 = 560) after re-layout"
        )
    }

    // MARK: - 2. Divider NSView identity preserved across resizeSubviews

    /// Given: a 2-leaf horizontal split laid out at 800×600.
    /// When:  the container is resized to 1000×600 (triggers `resizeSubviews`).
    /// Then:  the SplitDividerView is still the same instance, and the frame
    ///        has moved with the new bounds (height matches the new height).
    func testDividerNSViewIdentityPreservedAcrossResizeSubviews() {
        // Arrange
        let fixture = makeFixture()
        let firstLeafID = UUID()
        let secondLeafID = UUID()
        registerLeaf(firstLeafID, in: fixture.registry)
        registerLeaf(secondLeafID, in: fixture.registry)
        let tree = makeTwoLeafHorizontalTree(
            firstLeafID: firstLeafID,
            secondLeafID: secondLeafID,
            ratio: 0.5
        )
        fixture.container.updateLayout(tree: tree)

        guard let originalDivider = installedDividers(in: fixture.container).first else {
            XCTFail("Precondition: container must hold a SplitDividerView after the first layout pass")
            return
        }

        // Act — resize the container. This calls `resizeSubviews(withOldSize:)`.
        fixture.container.setFrameSize(NSSize(width: 1000, height: 600))
        fixture.container.layoutSubtreeIfNeeded()

        // Assert — same instance, and height tracks the new bounds.
        let postDividers = installedDividers(in: fixture.container)
        XCTAssertEqual(postDividers.count, 1,
                       "After resizeSubviews there must still be exactly one SplitDividerView")
        XCTAssertTrue(
            postDividers.first === originalDivider,
            "Bug 3 regression: the SplitDividerView NSView instance must be reused across resizeSubviews passes"
        )
        XCTAssertEqual(
            originalDivider.frame.height,
            600,
            accuracy: 1.0,
            "After resizeSubviews, the (horizontal) divider's frame height must match the new container height"
        )
    }

    // MARK: - 3. Divider is replaced when split direction changes

    /// Given: a 2-leaf horizontal split laid out, divider captured.
    /// When:  the tree is replaced with a 2-leaf VERTICAL split (same leaf IDs).
    /// Then:  the new SplitDividerView is a DIFFERENT instance from the
    ///        original, and only ONE SplitDividerView exists (no leaks from
    ///        the prior horizontal divider).
    func testDividerReplacedWhenSplitDirectionChanges() {
        // Arrange
        let fixture = makeFixture()
        let firstLeafID = UUID()
        let secondLeafID = UUID()
        registerLeaf(firstLeafID, in: fixture.registry)
        registerLeaf(secondLeafID, in: fixture.registry)
        let horizontalTree = makeTwoLeafHorizontalTree(
            firstLeafID: firstLeafID,
            secondLeafID: secondLeafID,
            ratio: 0.5
        )
        fixture.container.updateLayout(tree: horizontalTree)

        guard let originalDivider = installedDividers(in: fixture.container).first else {
            XCTFail("Precondition: container must hold a SplitDividerView after the first layout pass")
            return
        }
        XCTAssertEqual(originalDivider.direction, .horizontal,
                       "Precondition: original divider must be horizontal")

        // Act — swap to a vertical split with the same leaf IDs.
        let verticalTree = makeTwoLeafVerticalTree(
            firstLeafID: firstLeafID,
            secondLeafID: secondLeafID,
            ratio: 0.5
        )
        fixture.container.updateLayout(tree: verticalTree)

        // Assert — new divider is a DIFFERENT instance, and there's exactly one.
        let postDividers = installedDividers(in: fixture.container)
        XCTAssertEqual(postDividers.count, 1,
                       "After a direction swap there must be exactly one SplitDividerView (the old one was discarded)")
        guard let newDivider = postDividers.first else {
            XCTFail("Container must hold a SplitDividerView after the direction swap")
            return
        }
        XCTAssertFalse(
            newDivider === originalDivider,
            "When split direction changes the divider must be REPLACED, not reused, because the cursor/hit math is direction-specific"
        )
        XCTAssertEqual(newDivider.direction, .vertical,
                       "The new divider must reflect the tree's new direction")
    }

    // MARK: - 4. Dividers removed when split collapses to a single leaf

    /// Given: a 2-leaf horizontal split laid out (one SplitDividerView present).
    /// When:  `updateLayout` is invoked with a single-leaf tree.
    /// Then:  no SplitDividerView subviews remain — the cache reaper purged
    ///        the unused entry.
    func testDividersRemovedWhenSplitCollapsesToSingleLeaf() {
        // Arrange
        let fixture = makeFixture()
        let firstLeafID = UUID()
        let secondLeafID = UUID()
        registerLeaf(firstLeafID, in: fixture.registry)
        registerLeaf(secondLeafID, in: fixture.registry)
        let splitTree = makeTwoLeafHorizontalTree(
            firstLeafID: firstLeafID,
            secondLeafID: secondLeafID,
            ratio: 0.5
        )
        fixture.container.updateLayout(tree: splitTree)
        XCTAssertEqual(
            installedDividers(in: fixture.container).count,
            1,
            "Precondition: split tree must install one divider"
        )

        // Act — collapse to a single leaf.
        let collapsedTree = SplitTree(leafID: firstLeafID)
        fixture.container.updateLayout(tree: collapsedTree)

        // Assert — no dividers remain.
        XCTAssertTrue(
            installedDividers(in: fixture.container).isEmpty,
            "After collapsing to a single-leaf tree, no SplitDividerView may remain in the container"
        )
    }

    // MARK: - 5. Divider callback fires with the absolute target ratio
    //
    // Contract pinned: `SplitContainerView.onTargetRatioChange` is a settable
    // closure that receives:
    //   • `firstChildFirstLeafID`  — leftmost leaf of splitData.first
    //   • `secondChildFirstLeafID` — leftmost leaf of splitData.second
    //   • `targetRatio` — absolute ratio in [0, 1]
    //   • `direction`   — direction the divider lives in
    //   • `splitRect`   — rect (in container coords) the SPLIT occupies
    //
    // The two leaf IDs together with `direction` form a unique key per split,
    // which lets the controller call `setRatio(firstChildFirstLeafID:secondChildFirstLeafID:...)`
    // to disambiguate nested same-direction splits (Bug B). The rect is
    // needed so the controller can pass the LOCAL size to setRatio (Bug C).

    /// Given: a 2-leaf horizontal split laid out, with `onTargetRatioChange`
    ///        wired to capture invocations.
    /// When:  the divider is asked to simulate a drag to superview point
    ///        (600, 300) — i.e. 75% of the way across the 800-wide container.
    /// Then:  the callback fires exactly once carrying:
    ///          • firstChildID  == the first leaf of splitData.first  (firstLeafID)
    ///          • secondChildID == the first leaf of splitData.second (secondLeafID)
    ///          • a target ratio in [0, 1]
    ///          • direction == .horizontal
    ///          • splitRect == the container's bounds (root-level split)
    func testDividerCallbackFiresWithTargetRatio() {
        // Arrange
        let fixture = makeFixture()
        let firstLeafID = UUID()
        let secondLeafID = UUID()
        registerLeaf(firstLeafID, in: fixture.registry)
        registerLeaf(secondLeafID, in: fixture.registry)
        let tree = makeTwoLeafHorizontalTree(
            firstLeafID: firstLeafID,
            secondLeafID: secondLeafID,
            ratio: 0.5
        )
        fixture.container.updateLayout(tree: tree)

        var captured: [(UUID, UUID, Double, SplitDirection, CGRect)] = []
        fixture.container.onTargetRatioChange = { firstChildID, secondChildID, ratio, direction, rect in
            captured.append((firstChildID, secondChildID, ratio, direction, rect))
        }

        guard let divider = installedDividers(in: fixture.container).first else {
            XCTFail("Precondition: container must hold a SplitDividerView after the first layout pass")
            return
        }

        // Act — simulate a drag to superview point (600, 300). Using the
        // documented `#if DEBUG` test seam to avoid needing a live NSWindow
        // for `event.locationInWindow ↔ convert(...)`.
        divider._testSimulateDrag(toSuperviewPoint: NSPoint(x: 600, y: 300))

        // Assert
        XCTAssertEqual(captured.count, 1,
                       "Exactly one onTargetRatioChange invocation must result from one simulated drag")
        guard let (firstChildID, secondChildID, ratio, direction, rect) = captured.first else { return }
        XCTAssertEqual(firstChildID, firstLeafID,
                       "Callback firstChildFirstLeafID must be the leftmost leaf of splitData.first")
        XCTAssertEqual(secondChildID, secondLeafID,
                       "Callback secondChildFirstLeafID must be the leftmost leaf of splitData.second")
        XCTAssertGreaterThanOrEqual(ratio, 0.0,
                                    "Callback ratio must be a normalized value in [0, 1]")
        XCTAssertLessThanOrEqual(ratio, 1.0,
                                 "Callback ratio must be a normalized value in [0, 1]")
        XCTAssertEqual(direction, .horizontal,
                       "Callback direction must match the divider's direction")
        XCTAssertEqual(rect, fixture.container.bounds,
                       "For a root-level split the callback's splitRect must equal the container's bounds")
    }

    // MARK: - 6. Multiple drags keep the same divider instance (Bug 3 end-to-end)
    //
    // CRITICAL — proves Bug 3 is fixed end-to-end. Wires the callback to
    // `setRatio` + `updateLayout` (the same flow the production controller
    // uses) and simulates 5 sequential drags. The divider's NSView instance
    // must survive every iteration — otherwise mid-drag mouse capture is
    // broken in the real app.

    /// Given: a 2-leaf horizontal split, with `onTargetRatioChange` wired to
    ///        the canonical `setRatio + updateLayout` pipeline.
    /// When:  5 sequential drags are simulated at increasing x positions.
    /// Then:  the SplitDividerView still installed in the container after
    ///        all 5 drags is the EXACT same instance captured at the start.
    func testMultipleDragsKeepSameDividerInstanceWhenWiredToUpdateLayout() {
        // Arrange
        let fixture = makeFixture()
        let firstLeafID = UUID()
        let secondLeafID = UUID()
        registerLeaf(firstLeafID, in: fixture.registry)
        registerLeaf(secondLeafID, in: fixture.registry)
        var tree = makeTwoLeafHorizontalTree(
            firstLeafID: firstLeafID,
            secondLeafID: secondLeafID,
            ratio: 0.5
        )
        fixture.container.updateLayout(tree: tree)

        guard let originalDivider = installedDividers(in: fixture.container).first else {
            XCTFail("Precondition: container must hold a SplitDividerView after the first layout pass")
            return
        }

        let container = fixture.container
        fixture.container.onTargetRatioChange = { firstChildID, secondChildID, ratio, direction, splitRect in
            tree = tree.setRatio(
                firstChildFirstLeafID: firstChildID,
                secondChildFirstLeafID: secondChildID,
                direction: direction,
                to: ratio,
                bounds: splitRect.size,
                minSize: 50.0
            )
            container.updateLayout(tree: tree)
        }

        // Act — five drags at monotonically increasing x positions.
        let dragXPositions: [CGFloat] = [200, 300, 400, 500, 600]
        for x in dragXPositions {
            originalDivider._testSimulateDrag(toSuperviewPoint: NSPoint(x: x, y: 300))
        }

        // Assert — same NSView instance throughout. This is what Bug 3
        // historically broke: mid-drag updateLayout would tear down the
        // divider and re-create a fresh instance, severing AppKit's mouse
        // capture session. The divider being identical proves the divider
        // cache survives the round-trip.
        let postDividers = installedDividers(in: fixture.container)
        XCTAssertEqual(postDividers.count, 1,
                       "Exactly one SplitDividerView must remain installed after a sequence of drags")
        XCTAssertTrue(
            postDividers.first === originalDivider,
            "Bug 3 end-to-end regression: the SplitDividerView instance must survive a setRatio + updateLayout drag round-trip — that's the entire point of the cache"
        )
    }

    // MARK: - 7. Bug A regression: cache key must NOT collide for nested same-leftmost-leaf splits
    //
    // Bug A scenario:
    //   For a tree like V(H(A,C), B), both the OUTER vertical split and the
    //   INNER horizontal split compute `firstLeafID(splitData.first) == A`
    //   because `firstLeafID` recursively walks the leftmost path. Under the
    //   buggy single-UUID cache key, the outer split clobbers the inner
    //   divider entry (or vice versa) and only ONE SplitDividerView gets
    //   installed instead of two. The user then can't drag the inner H
    //   boundary because it doesn't exist as an NSView.
    //
    // The fix uses a composite key — `(firstLeafID(first), firstLeafID(second), direction)`
    // — which uniquely identifies the split since two distinct splits in a
    // binary tree cannot share both children's leftmost leaves AND direction.

    /// Given: a 2-leaf-deep nested tree V(H(A,C), B), where A is the leftmost
    ///        leaf of BOTH the inner horizontal split and the outer vertical
    ///        split (because firstLeafID walks left-first recursively).
    /// When:  the container is asked to lay it out.
    /// Then:  there must be EXACTLY 2 SplitDividerView subviews — one for the
    ///        outer V and one for the inner H. Pre-fix, the cache collision
    ///        would drop one of them.
    func testDividerCacheKeyDoesNotCollideForNestedSameLeftmostLeafSplits() {
        // Arrange — V(H(A,C), B)
        let fixture = makeFixture()
        let idA = UUID()
        let idC = UUID()
        let idB = UUID()
        registerLeaf(idA, in: fixture.registry)
        registerLeaf(idC, in: fixture.registry)
        registerLeaf(idB, in: fixture.registry)

        let innerHorizontal = SplitNode.split(SplitData(
            direction: .horizontal,
            ratio: 0.5,
            first: .leaf(id: idA),
            second: .leaf(id: idC)
        ))
        let outerVertical = SplitNode.split(SplitData(
            direction: .vertical,
            ratio: 0.5,
            first: innerHorizontal,
            second: .leaf(id: idB)
        ))
        let tree = SplitTree(root: outerVertical, focusedLeafID: idA)

        // Act
        fixture.container.updateLayout(tree: tree)

        // Assert — exactly two dividers, one of each direction.
        let dividers = installedDividers(in: fixture.container)
        XCTAssertEqual(
            dividers.count,
            2,
            "Bug A regression: V(H(A,C), B) must install BOTH the outer vertical divider AND the inner horizontal divider — the cache key must not collide on shared leftmost leaf"
        )
        let directions = Set(dividers.map { $0.direction })
        XCTAssertEqual(
            directions,
            [.horizontal, .vertical],
            "Bug A regression: the two dividers must be of distinct directions (one horizontal, one vertical)"
        )
    }

    // MARK: - 8. Bug C regression: drag on a nested divider must compute the
    //             target ratio in the SUB-RECT, not the whole container.
    //
    // Bug C scenario:
    //   `SplitContainerView.placeDivider` does `addSubview(divider)` on `self`
    //   (the whole container), so the divider's `superview` is the container.
    //   But for a NESTED split that occupies a sub-rect (e.g. the right half
    //   of a 2-leaf outer split), dragging a divider inside that sub-rect
    //   must be interpreted RELATIVE to the sub-rect — otherwise the ratio
    //   the controller pins to the inner split corresponds to an absolute
    //   container coordinate, which produces a wildly wrong split position.
    //
    // The fix plumbs a `containingRect` onto each divider via
    // `SplitDividerView.containingRect` and uses that rect (not
    // `superview.bounds`) inside the drag math.

    /// Given: a horizontal SplitDividerView installed in a 800×600 container,
    ///        but the divider belongs to a nested split occupying sub-rect
    ///        (400, 0, 400, 600) — i.e. the right half of the container.
    /// When:  the divider's drag math is exercised with cursor at superview
    ///        (600, 300) — the midpoint of the sub-rect.
    /// Then:  the emitted ratio must be 0.5 (= (600-400)/400), reflecting the
    ///        cursor's position WITHIN the sub-rect. NOT 0.75 (= 600/800),
    ///        which would be the pre-fix container-relative value.
    func testDragOnNestedDividerComputesRatioInSubRectNotContainer() {
        // Arrange — install a divider whose containingRect is the right half
        // of the container. This mimics the geometry the inner H split would
        // see for an outer V(left, H(right1, right2)) layout.
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let divider = SplitDividerView(direction: .horizontal)
        divider.frame = NSRect(x: 600, y: 0, width: 1, height: 600)
        divider.containingRect = NSRect(x: 400, y: 0, width: 400, height: 600)
        container.addSubview(divider)

        var captured: [Double] = []
        divider.onTargetRatioChange = { ratio in
            captured.append(ratio)
        }

        // Act — simulate a drag to the midpoint of the sub-rect.
        withExtendedLifetime(container) {
            divider._testSimulateDrag(toSuperviewPoint: NSPoint(x: 600, y: 300))
        }

        // Assert
        XCTAssertEqual(captured.count, 1,
                       "Exactly one onTargetRatioChange invocation must result from one simulated drag")
        guard let ratio = captured.first else { return }
        XCTAssertEqual(
            ratio,
            0.5,
            accuracy: 0.001,
            "Bug C regression: ratio must be computed relative to containingRect ((600-400)/400 = 0.5), NOT to the whole container's bounds (which would give 0.75)"
        )
    }
}
