//
//  CalyxWindowControllerFocusSyncTests.swift
//  CalyxTests
//
//  Controller-level integration tests for Issue #29 — focus-sync bug fix.
//
//  Bug summary:
//    `SplitTree.focusedLeafID` (persistent Source of Truth) and
//    `SplitContainerView.activeLeafID` (ephemeral view state) fall out of
//    sync when the user clicks a pane. When the app regains key,
//    `CalyxWindowController.restoreFocus()` reads the stale
//    `tab.splitTree.focusedLeafID` and focuses the wrong pane.
//
//  Fix (not yet implemented — these tests are Red phase):
//    • Add `var onActiveLeafChange: ((UUID) -> Void)?` on
//      `SplitContainerView`.
//    • Fire it from `surfaceDidBecomeActive(_:)` AFTER the existing
//      `activeLeafID != id` guard, with the newly active leaf's UUID.
//    • Wire `CalyxWindowController` to update
//      `activeTab?.splitTree.focusedLeafID` through the callback.
//
//  Approach:
//    These tests DO NOT instantiate `CalyxWindowController` (which requires
//    a live `ghostty_app_t` and `NSWindow`). Instead they reconstruct the
//    exact production closure verbatim:
//
//      container.onActiveLeafChange = { [weak tab] leafID in
//          tab?.splitTree.focusedLeafID = leafID
//      }
//
//    against a real `Tab` and `SplitContainerView`, and verify the
//    read/write semantics that `restoreFocus()` depends on.
//
//  Red-phase expectation:
//    All 5 tests in this file FAIL TO COMPILE because
//    `SplitContainerView.onActiveLeafChange` does not exist yet.
//

import AppKit
import XCTest
@testable import Calyx

@MainActor
final class CalyxWindowControllerFocusSyncTests: XCTestCase {

    // MARK: - Fixture

    /// Two-pane fixture that mirrors the production wiring between a `Tab`
    /// and its `SplitContainerView` via the `onActiveLeafChange` callback.
    private struct Fixture {
        let tab: Tab
        let container: SplitContainerView
        let firstLeafID: UUID
        let secondLeafID: UUID
        let firstSurface: SurfaceView
        let secondSurface: SurfaceView
    }

    private enum SplitContainerViewFocus {
        case first
        case second
    }

    /// Build a fresh 2-pane fixture: two registered surfaces, a horizontal
    /// split tree with the requested initial focus, and a container wired to
    /// the tab through the EXACT production closure that
    /// `CalyxWindowController` is expected to install.
    private func makeTwoPaneFixture(initialFocus: SplitContainerViewFocus = .first) -> Fixture {
        let registry = SurfaceRegistry()
        let firstLeafID = UUID()
        let secondLeafID = UUID()
        let firstSurface = SurfaceView(frame: .zero)
        let secondSurface = SurfaceView(frame: .zero)
        registry._testInsert(view: firstSurface, id: firstLeafID)
        registry._testInsert(view: secondSurface, id: secondLeafID)

        let root = SplitNode.split(SplitData(
            direction: .horizontal,
            ratio: 0.5,
            first: .leaf(id: firstLeafID),
            second: .leaf(id: secondLeafID)
        ))
        let initialFocusID = (initialFocus == .first) ? firstLeafID : secondLeafID
        let tab = Tab(
            splitTree: SplitTree(root: root, focusedLeafID: initialFocusID),
            registry: registry
        )

        let container = SplitContainerView(registry: registry)
        container.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        container.layoutSubtreeIfNeeded()
        container.updateLayout(tree: tab.splitTree)

        // Install the production closure verbatim. The `[weak tab]` capture
        // mirrors the `CalyxWindowController` wiring so the closure does not
        // retain the Tab model.
        container.onActiveLeafChange = { [weak tab] leafID in
            tab?.splitTree.focusedLeafID = leafID
        }

        return Fixture(
            tab: tab,
            container: container,
            firstLeafID: firstLeafID,
            secondLeafID: secondLeafID,
            firstSurface: firstSurface,
            secondSurface: secondSurface
        )
    }

    // MARK: - 1. Core bug fix: clicking an inactive pane updates focusedLeafID

    /// Given: A tab whose `splitTree.focusedLeafID == secondLeafID` (this
    ///        simulates the just-created split state right after Cmd+D,
    ///        where pane B has just been created and focused).
    /// When:  The user clicks pane A — surfaced by
    ///        `container.surfaceDidBecomeActive(firstSurface)`.
    /// Then:  `tab.splitTree.focusedLeafID` must be updated to
    ///        `firstLeafID`. Without the fix, the closure property does not
    ///        exist on `SplitContainerView`, so the assignment never fires,
    ///        and `focusedLeafID` remains at the stale `secondLeafID`.
    ///
    /// This is the core bug-fix test for Issue #29.
    func testClickOnInactivePaneUpdatesTabFocusedLeafID() {
        // Arrange
        let fixture = makeTwoPaneFixture(initialFocus: .second)
        XCTAssertEqual(
            fixture.tab.splitTree.focusedLeafID,
            fixture.secondLeafID,
            "Precondition: the tab's focusedLeafID starts on secondLeafID"
        )

        // Act — user clicks pane A.
        fixture.container.surfaceDidBecomeActive(fixture.firstSurface)

        // Assert — the click must have propagated into the model.
        XCTAssertEqual(
            fixture.tab.splitTree.focusedLeafID,
            fixture.firstLeafID,
            "Clicking an inactive pane must update tab.splitTree.focusedLeafID via onActiveLeafChange"
        )
    }

    // MARK: - 2. `restoreFocus()` read-path resolves to the clicked pane

    /// Given: The same click-then-rehome scenario as test 1.
    /// When:  We mirror the EXACT read path used by
    ///        `CalyxWindowController.attemptFocusRestore` (see
    ///        `CalyxWindowController.swift:1022-1024`):
    ///        `tab.splitTree.focusedLeafID` → `tab.registry.view(for: id)`.
    /// Then:  The resolved `SurfaceView` must be `firstSurface` by identity.
    ///
    /// Proves that after the fix, `restoreFocus()` will correctly target the
    /// clicked pane when the app regains key.
    func testFocusedReadPathReflectsClick() {
        // Arrange
        let fixture = makeTwoPaneFixture(initialFocus: .second)
        fixture.container.surfaceDidBecomeActive(fixture.firstSurface)

        // Act — mirror the production read path verbatim.
        guard let focusedID = fixture.tab.splitTree.focusedLeafID else {
            XCTFail("tab.splitTree.focusedLeafID must be non-nil after the click")
            return
        }
        let resolved = fixture.tab.registry.view(for: focusedID)

        // Assert — read path resolves to the clicked pane's surface.
        XCTAssertTrue(
            resolved === fixture.firstSurface,
            "The CalyxWindowController restore-focus read path must resolve to the clicked pane's SurfaceView"
        )
    }

    // MARK: - 3. Programmatic `makeFirstResponder` also syncs focusedLeafID

    /// Context: `handleNewSplitNotification` and similar code paths reach the
    ///          focus change via `window?.makeFirstResponder(newView)`, which
    ///          ultimately triggers the SurfaceView's
    ///          `focusHost?.surfaceDidBecomeActive(self)` hook (see
    ///          `SurfaceView.swift:313`). The callback must not be
    ///          click-specific — it fires regardless of whether the focus
    ///          change came from a mouse click, `makeFirstResponder`, or
    ///          keyboard navigation.
    ///
    /// Given: A tab with `focusedLeafID = firstLeafID`.
    /// When:  `surfaceDidBecomeActive(secondSurface)` is invoked — simulating
    ///        any code path that culminates in the focus-host hook firing.
    /// Then:  `tab.splitTree.focusedLeafID == secondLeafID`.
    func testProgrammaticMakeFirstResponderAlsoSyncsFocusedLeafID() {
        // Arrange
        let fixture = makeTwoPaneFixture(initialFocus: .first)
        XCTAssertEqual(
            fixture.tab.splitTree.focusedLeafID,
            fixture.firstLeafID,
            "Precondition: the tab's focusedLeafID starts on firstLeafID"
        )

        // Act — mimic the path taken by makeFirstResponder → SurfaceView
        // becomeFirstResponder → focusHost.surfaceDidBecomeActive.
        fixture.container.surfaceDidBecomeActive(fixture.secondSurface)

        // Assert
        XCTAssertEqual(
            fixture.tab.splitTree.focusedLeafID,
            fixture.secondLeafID,
            "onActiveLeafChange must be non-click-specific: any focus transition syncs focusedLeafID"
        )
    }

    // MARK: - 4. Weak tab capture does not retain the Tab

    /// Given: A container holding an `onActiveLeafChange` closure with a
    ///        `[weak tab]` capture (the production wiring).
    /// When:  The strong reference to the Tab is released while the
    ///        container remains alive.
    /// Then:  A weak probe pointing at the Tab becomes nil — the closure
    ///        did NOT retain the Tab. Subsequently firing the callback must
    ///        NOT crash: the `tab?.splitTree.focusedLeafID = leafID`
    ///        expression handles the nil receiver safely.
    ///
    /// Documents the memory-safety contract of the production wiring.
    func testWeakTabReferenceDoesNotRetain() {
        // We must control Tab's lifetime explicitly, so build the wiring in a
        // nested scope. Outside the scope we keep ONLY the container and a
        // weak probe — no strong tab reference can survive in test-local
        // scope.
        weak var weakTabProbe: Tab?
        var capturedContainer: SplitContainerView?
        var capturedFirstSurface: SurfaceView?

        do {
            let registry = SurfaceRegistry()
            let firstLeafID = UUID()
            let secondLeafID = UUID()
            let firstSurface = SurfaceView(frame: .zero)
            let secondSurface = SurfaceView(frame: .zero)
            registry._testInsert(view: firstSurface, id: firstLeafID)
            registry._testInsert(view: secondSurface, id: secondLeafID)

            let root = SplitNode.split(SplitData(
                direction: .horizontal,
                ratio: 0.5,
                first: .leaf(id: firstLeafID),
                second: .leaf(id: secondLeafID)
            ))
            let tab = Tab(
                splitTree: SplitTree(root: root, focusedLeafID: secondLeafID),
                registry: registry
            )
            weakTabProbe = tab

            let container = SplitContainerView(registry: registry)
            container.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
            container.layoutSubtreeIfNeeded()
            container.updateLayout(tree: tab.splitTree)

            // Install the production closure verbatim.
            container.onActiveLeafChange = { [weak tab] leafID in
                tab?.splitTree.focusedLeafID = leafID
            }

            capturedContainer = container
            capturedFirstSurface = firstSurface
            // `tab` is released when the `do` scope exits.
        }

        // Assert — the closure's [weak tab] capture did not retain the Tab.
        XCTAssertNil(
            weakTabProbe,
            "The onActiveLeafChange closure must capture Tab weakly — it must not retain"
        )

        // Act — the container is still alive and the closure is still
        // installed. Firing it with a valid surface must not crash, even
        // though the weak Tab capture has deallocated.
        guard let container = capturedContainer,
              let firstSurface = capturedFirstSurface else {
            XCTFail("Captured container / surface must be non-nil")
            return
        }
        container.surfaceDidBecomeActive(firstSurface)
        // If we reached this line without trapping, the closure safely
        // no-ops when the weak Tab capture is nil.
        XCTAssertTrue(
            true,
            "surfaceDidBecomeActive after Tab dealloc must not crash"
        )
    }

    // MARK: - 5. Repeated clicks on the same pane are idempotent

    /// Given: A tab with `focusedLeafID = secondLeafID`.
    /// When:  `surfaceDidBecomeActive(firstSurface)` is invoked three times
    ///        in a row.
    /// Then:  `tab.splitTree.focusedLeafID == firstLeafID` and no crash
    ///        occurs. The second and third invocations are no-ops (guarded
    ///        by `activeLeafID != id`), but the model remains consistent.
    ///
    /// Guards against future regressions where repeated activation could
    /// cause unexpected state churn.
    func testRepeatedClicksAreIdempotent() {
        // Arrange
        let fixture = makeTwoPaneFixture(initialFocus: .second)

        // Act — fire three times in a row on the same surface.
        fixture.container.surfaceDidBecomeActive(fixture.firstSurface)
        fixture.container.surfaceDidBecomeActive(fixture.firstSurface)
        fixture.container.surfaceDidBecomeActive(fixture.firstSurface)

        // Assert — the model reflects the first (and only effective) call.
        XCTAssertEqual(
            fixture.tab.splitTree.focusedLeafID,
            fixture.firstLeafID,
            "Repeated activations on the same pane must leave focusedLeafID consistent"
        )
    }

    // MARK: - 6. Production closure must request a session save (cross-restart persistence)

    /// Pins that the production `onActiveLeafChange` closure (in
    /// `CalyxWindowController.setupUI()` and `rebuildSplitContainer()`)
    /// MUST call `self?.requestSave()` after updating `focusedLeafID`, so
    /// that the new focus survives an app restart.
    ///
    /// Background:
    ///   The earlier Issue #29 fix wired the callback to assign
    ///   `tab.splitTree.focusedLeafID` — that covers IN-SESSION restoration
    ///   (e.g. window deactivate/reactivate) but NOT cross-restart
    ///   persistence. If the user clicks pane A and quits with Cmd+Q before
    ///   any other save-triggering action fires, the on-disk session file
    ///   still records pane B's `focusedLeafID`, and next launch refocuses
    ///   the wrong pane. `SessionPersistenceActor.save(_:)` debounces 2s,
    ///   so calling `requestSave()` on every focus change is safe.
    ///
    /// Why this is a CONTRACT-PIN test, not a strict Red:
    ///   `CalyxWindowController` cannot be instantiated in a unit test
    ///   (it requires a live `ghostty_app_t` and `NSWindow`). The other
    ///   five tests in this file work around that by reconstructing the
    ///   production closure verbatim against a `Tab`. This test follows
    ///   the same pattern: it rebuilds the EXPECTED closure SHAPE
    ///   (focusedLeafID write + save request) and verifies BOTH steps
    ///   fire. The actual Red signal — confirming the production closure
    ///   is missing the save call — comes from code review and manual
    ///   E2E (click pane, Cmd+Q within 2s, relaunch, observe wrong pane
    ///   focused). The implementer (swift-specialist) MUST mirror this
    ///   pinned shape in BOTH production sites.
    func testActiveLeafChangeClosureWritesBothFocusedLeafIDAndTriggersSave() {
        // Arrange
        let fixture = makeTwoPaneFixture(initialFocus: .second)
        var saveRequestCount = 0

        // Replace the fixture's default closure with one that mirrors the
        // FULL expected production shape: write focusedLeafID, then request
        // a session save. `saveRequestCount` is a stand-in for
        // `self?.requestSave()` so the test can observe the save step.
        fixture.container.onActiveLeafChange = { [weak tab = fixture.tab] leafID in
            tab?.splitTree.focusedLeafID = leafID
            saveRequestCount += 1 // stand-in for self?.requestSave()
        }

        // Act — user clicks pane A.
        fixture.container.surfaceDidBecomeActive(fixture.firstSurface)

        // Assert — both the focusedLeafID write AND the save request fire.
        XCTAssertEqual(
            fixture.tab.splitTree.focusedLeafID,
            fixture.firstLeafID,
            "Focus transition must update tab.splitTree.focusedLeafID (existing invariant)"
        )
        XCTAssertEqual(
            saveRequestCount,
            1,
            "Every real focus transition must request a session save exactly once " +
            "so the new focus survives an app restart"
        )

        // Act — re-activate the same pane (no-op per the existing
        // `activeLeafID != id` guard in `surfaceDidBecomeActive`).
        fixture.container.surfaceDidBecomeActive(fixture.firstSurface)

        // Assert — no-op re-activation must NOT trigger a redundant save.
        XCTAssertEqual(
            saveRequestCount,
            1,
            "No-op re-activation on the already-active pane must NOT request another save"
        )
    }
}
