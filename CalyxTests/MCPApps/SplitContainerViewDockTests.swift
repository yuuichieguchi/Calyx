//
//  SplitContainerViewDockTests.swift
//  CalyxTests
//
//  Inline MCP Apps placement (plan §7) attaches a dock NSView to a
//  specific split leaf, alongside its terminal SurfaceScrollView wrapper.
//  Mirrors SplitContainerViewZoomTests.swift's fixture shape
//  (Fixture / makeFixture() / registerLeaf(_:in:)) rather than sharing
//  code cross-file, matching this codebase's established per-file
//  fixture-duplication convention.
//
//  Coverage: the dock survives a tab switch (updateRegistry), is hidden
//  (not destroyed) while a DIFFERENT leaf is zoomed, is reaped (detached,
//  the same NSView instance retained) when its leaf temporarily leaves
//  the tree, and fullscreen hides the terminal wrapper without zeroing
//  its frame (so un-fullscreening doesn't need a relayout to recover
//  geometry).
//

import AppKit
import XCTest
@testable import Calyx

@MainActor
final class SplitContainerViewDockTests: XCTestCase {

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

    private func singleLeafTree(_ id: UUID) -> SplitTree {
        SplitTree(root: .leaf(id: id), focusedLeafID: id, zoomedLeafID: nil)
    }

    private func twoLeafTree(first: UUID, second: UUID, zoomed: UUID?) -> SplitTree {
        let root = SplitNode.split(SplitData(
            direction: .horizontal, ratio: 0.5, first: .leaf(id: first), second: .leaf(id: second)
        ))
        return SplitTree(root: root, focusedLeafID: first, zoomedLeafID: zoomed)
    }

    // MARK: - Basic attach

    func test_attachDock_installsDockViewAsSubview() {
        let fixture = makeFixture()
        let leafID = UUID()
        registerLeaf(leafID, in: fixture.registry)
        fixture.container.updateLayout(tree: singleLeafTree(leafID))

        let dock = NSView()
        fixture.container.attachDock(dock, toLeaf: leafID)

        XCTAssertTrue(dock.isDescendant(of: fixture.container))
        XCTAssertEqual(fixture.container.dockView(forLeaf: leafID), dock)
    }

    // MARK: - Re-attached after updateRegistry (tab switch)

    func test_dockReattached_afterUpdateRegistry_survivesTabSwitch() {
        let fixture = makeFixture()
        let leafID = UUID()
        registerLeaf(leafID, in: fixture.registry)
        fixture.container.updateLayout(tree: singleLeafTree(leafID))
        let dock = NSView()
        fixture.container.attachDock(dock, toLeaf: leafID)

        // Tab switch: a fresh registry for the same leaf id.
        let newRegistry = SurfaceRegistry()
        let newView = SurfaceView(frame: .zero)
        newRegistry._testInsert(view: newView, id: leafID)
        fixture.container.updateRegistry(newRegistry)
        fixture.container.updateLayout(tree: singleLeafTree(leafID))

        XCTAssertEqual(fixture.container.dockView(forLeaf: leafID), dock,
            "the same dock NSView instance must still be attached to its leaf after a tab switch")
        XCTAssertTrue(dock.isDescendant(of: fixture.container))
    }

    // MARK: - Hidden (not destroyed) when another leaf is zoomed

    func test_dockHidden_whenAnotherLeafIsZoomed() {
        let fixture = makeFixture()
        let leafA = UUID()
        let leafB = UUID()
        registerLeaf(leafA, in: fixture.registry)
        registerLeaf(leafB, in: fixture.registry)
        fixture.container.updateLayout(tree: twoLeafTree(first: leafA, second: leafB, zoomed: nil))
        let dock = NSView()
        fixture.container.attachDock(dock, toLeaf: leafA)

        fixture.container.updateLayout(tree: twoLeafTree(first: leafA, second: leafB, zoomed: leafB))

        XCTAssertTrue(dock.isHidden, "leaf A's dock must hide while leaf B is zoomed")
        XCTAssertEqual(fixture.container.dockView(forLeaf: leafA), dock, "the dock must not be destroyed, only hidden")
    }

    func test_dockVisible_whenItsOwnLeafIsZoomed() {
        let fixture = makeFixture()
        let leafA = UUID()
        let leafB = UUID()
        registerLeaf(leafA, in: fixture.registry)
        registerLeaf(leafB, in: fixture.registry)
        fixture.container.updateLayout(tree: twoLeafTree(first: leafA, second: leafB, zoomed: nil))
        let dock = NSView()
        fixture.container.attachDock(dock, toLeaf: leafA)

        fixture.container.updateLayout(tree: twoLeafTree(first: leafA, second: leafB, zoomed: leafA))

        XCTAssertFalse(dock.isHidden)
    }

    // MARK: - Reaped (detached, not destroyed) when its leaf leaves the tree

    func test_dockReaped_notDestroyed_whenLeafLeavesTree() {
        let fixture = makeFixture()
        let leafA = UUID()
        let leafB = UUID()
        registerLeaf(leafA, in: fixture.registry)
        registerLeaf(leafB, in: fixture.registry)
        fixture.container.updateLayout(tree: twoLeafTree(first: leafA, second: leafB, zoomed: nil))
        let dock = NSView()
        fixture.container.attachDock(dock, toLeaf: leafA)

        // leafA leaves the tree (e.g. its split closed).
        fixture.container.updateLayout(tree: singleLeafTree(leafB))

        XCTAssertNil(fixture.container.dockView(forLeaf: leafA))
        XCTAssertFalse(dock.isDescendant(of: fixture.container), "a reaped dock must be detached from the view hierarchy")

        // The SAME NSView instance is still usable: re-attaching it to a
        // leaf that returns to the tree must not require constructing a
        // new WKWebView-backed dock.
        registerLeaf(leafA, in: fixture.registry)
        fixture.container.updateLayout(tree: twoLeafTree(first: leafA, second: leafB, zoomed: nil))
        fixture.container.attachDock(dock, toLeaf: leafA)

        XCTAssertEqual(fixture.container.dockView(forLeaf: leafA), dock)
        XCTAssertTrue(dock.isDescendant(of: fixture.container))
    }

    // MARK: - Fullscreen hides wrappers without zeroing frames

    func test_fullscreen_hidesTerminalWrapper_withoutZeroingItsFrame() {
        let fixture = makeFixture()
        let leafID = UUID()
        registerLeaf(leafID, in: fixture.registry)
        fixture.container.updateLayout(tree: singleLeafTree(leafID))
        let wrapperBefore = fixture.registry.view(for: leafID).flatMap { view -> SurfaceScrollView? in
            fixture.container.subviews.compactMap { $0 as? SurfaceScrollView }.first { $0.surfaceView === view }
        }
        let frameBefore = wrapperBefore?.frame ?? .zero
        XCTAssertNotEqual(frameBefore, .zero, "precondition: the wrapper has a real, non-zero frame before fullscreen")

        fixture.container.setFullscreen(true, forLeaf: leafID)

        let wrapperAfter = fixture.registry.view(for: leafID).flatMap { view -> SurfaceScrollView? in
            fixture.container.subviews.compactMap { $0 as? SurfaceScrollView }.first { $0.surfaceView === view }
        }
        XCTAssertTrue(wrapperAfter?.isHidden ?? false, "entering fullscreen must hide the terminal wrapper")
        XCTAssertEqual(wrapperAfter?.frame, frameBefore, "fullscreen must hide the wrapper WITHOUT zeroing its frame")
    }

    func test_exitingFullscreen_unhidesTerminalWrapper() {
        let fixture = makeFixture()
        let leafID = UUID()
        registerLeaf(leafID, in: fixture.registry)
        fixture.container.updateLayout(tree: singleLeafTree(leafID))
        fixture.container.setFullscreen(true, forLeaf: leafID)

        fixture.container.setFullscreen(false, forLeaf: leafID)

        let wrapper = fixture.registry.view(for: leafID).flatMap { view -> SurfaceScrollView? in
            fixture.container.subviews.compactMap { $0 as? SurfaceScrollView }.first { $0.surfaceView === view }
        }
        XCTAssertFalse(wrapper?.isHidden ?? true)
    }
}
