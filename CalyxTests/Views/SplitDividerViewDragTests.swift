//
//  SplitDividerViewDragTests.swift
//  CalyxTests
//
//  Focused unit test for `SplitDividerView`'s drag math after the absolute-
//  position rewrite (see fix plan, section B).
//
//  Background:
//  -----------
//  The pre-fix `mouseDragged(with:)` implementation accumulated pixel deltas
//  from `dragStartPoint` (stored in the divider's own local coordinates),
//  divided by `superview.bounds` to get a "ratio delta", and pushed that
//  through `onRatioChange?` — which `SplitTree.resize` then divided AGAIN
//  by `totalSize`. The result: every drag was scaled by ~1/bounds (off by
//  hundreds of pixels in normal window sizes).
//
//  The new contract pinned by this test:
//  -------------------------------------
//
//    `SplitDividerView` reads the cursor's superview-space coordinate, divides
//    by the relevant superview-axis extent, and fires `onTargetRatioChange?`
//    with the resulting absolute ratio in [0, 1]. Specifically, for a
//    horizontal divider whose superview is 800pt wide, dragging the cursor to
//    superview x = 600 must produce a target ratio of exactly 0.75 (= 600/800).
//
//    Because synthesizing `NSEvent`s with valid `locationInWindow` requires a
//    live `NSWindow` (which is fragile to construct in XCTest), the divider
//    exposes a `#if DEBUG`-guarded test seam:
//
//      func _testSimulateDrag(toSuperviewPoint: NSPoint)
//
//    that runs the same superview-coords → ratio math without requiring a
//    real event. This test exercises that seam.
//
//  Red-phase expectation:
//  ----------------------
//  Fails to compile against pre-fix code because neither
//  `SplitDividerView.onTargetRatioChange` nor
//  `SplitDividerView._testSimulateDrag(toSuperviewPoint:)` exists.
//

import AppKit
import XCTest
@testable import Calyx

@MainActor
final class SplitDividerViewDragTests: XCTestCase {

    // MARK: - Helpers

    /// Build an 800×600 superview NSView with a 1pt-wide horizontal
    /// `SplitDividerView` installed at the midpoint, mimicking the geometry
    /// `SplitContainerView` produces for a 2-leaf horizontal split at ratio 0.5.
    private func makeHorizontalDividerFixture() -> (superview: NSView, divider: SplitDividerView) {
        let superview = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let divider = SplitDividerView(direction: .horizontal)
        divider.frame = NSRect(x: 400, y: 0, width: 1, height: 600)
        superview.addSubview(divider)
        return (superview, divider)
    }

    // MARK: - Tests

    /// Given: an 800×600 superview hosting a horizontal SplitDividerView at
    ///        (400, 0, 1, 600), with `onTargetRatioChange` wired up.
    /// When:  the divider is asked (via `_testSimulateDrag`) to interpret a
    ///        cursor position of superview-space (600, 300).
    /// Then:  the callback fires with target ratio ≈ 0.75 (= 600 / 800).
    ///        This pins the absolute-ratio semantics required by the fix.
    func testMouseDragInSuperviewCoordsProducesTargetRatio() {
        // `divider.superview` is a weak back-pointer; `withExtendedLifetime`
        // anchors `superview` past the simulated-drag call so ARC doesn't
        // release it as soon as the binding's last syntactic use is reached.
        let (superview, divider) = makeHorizontalDividerFixture()
        var captured: [Double] = []
        divider.onTargetRatioChange = { ratio in
            captured.append(ratio)
        }

        withExtendedLifetime(superview) {
            // Act — simulate a drag to superview-space (600, 300).
            divider._testSimulateDrag(toSuperviewPoint: NSPoint(x: 600, y: 300))
        }

        // Assert
        XCTAssertEqual(captured.count, 1,
                       "Exactly one callback invocation must result from one simulated drag")
        guard let ratio = captured.first else { return }
        XCTAssertEqual(
            ratio,
            0.75,
            accuracy: 0.001,
            "Target ratio must equal cursor x / superview width (600 / 800 = 0.75)"
        )
    }
}
