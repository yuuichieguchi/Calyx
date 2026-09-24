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
//  geometry). Fullscreen is kept while the leaf is out of the tree.
//
//  Side-by-side placement (K55): the dock sits to the right of its leaf's
//  terminal with a split divider between them. The default dock width is
//  40% of the leaf width; dragging the divider sets the leaf's dock width,
//  which is kept through re-layouts, tab switches, parking and view
//  changes, and dropped when the dock is detached.
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

    // MARK: - Fullscreen survives the leaf leaving and returning

    func test_fullscreen_isKept_whenTheLeafLeavesTheTreeAndReturns() {
        let fixture = makeFixture()
        let leafA = UUID()
        let leafB = UUID()
        registerLeaf(leafA, in: fixture.registry)
        registerLeaf(leafB, in: fixture.registry)
        fixture.container.updateLayout(tree: twoLeafTree(first: leafA, second: leafB, zoomed: nil))
        let dock = NSView()
        fixture.container.attachDock(dock, toLeaf: leafA)
        fixture.container.setFullscreen(true, forLeaf: leafA)

        fixture.container.updateLayout(tree: singleLeafTree(leafB))
        fixture.container.updateLayout(tree: twoLeafTree(first: leafA, second: leafB, zoomed: nil))

        XCTAssertEqual(fixture.container.dockView(forLeaf: leafA), dock)
        XCTAssertFalse(dock.isHidden)
        XCTAssertEqual(dock.frame, fixture.container.bounds, "the returning leaf's dock still covers the container")
        let wrappers = fixture.container.subviews.compactMap { $0 as? SurfaceScrollView }
        XCTAssertFalse(wrappers.isEmpty)
        XCTAssertTrue(wrappers.allSatisfy(\.isHidden), "the terminals stay hidden while the view is fullscreen")
    }

    // MARK: - Side by side (K55)

    private func wrapper(for leafID: UUID, in fixture: Fixture) -> SurfaceScrollView? {
        let view = fixture.registry.view(for: leafID)
        return fixture.container.subviews.compactMap { $0 as? SurfaceScrollView }.first { $0.surfaceView === view }
    }

    /// The split dividers whose hit frame covers the gap between `wrapper` and `dock`.
    private func dockDividers(in fixture: Fixture, wrapper: NSView, dock: NSView) -> [SplitDividerView] {
        fixture.container.subviews.compactMap { $0 as? SplitDividerView }.filter {
            !$0.isHidden && $0.frame.minX <= wrapper.frame.maxX && $0.frame.maxX >= dock.frame.minX
                && $0.frame.minY == dock.frame.minY && $0.frame.height == dock.frame.height
        }
    }

    private func dockDivider(in fixture: Fixture, leafID: UUID) throws -> SplitDividerView {
        let wrapper = try XCTUnwrap(wrapper(for: leafID, in: fixture))
        let dock = try XCTUnwrap(fixture.container.dockView(forLeaf: leafID))
        return try XCTUnwrap(dockDividers(in: fixture, wrapper: wrapper, dock: dock).first, "a divider sits between the terminal and the dock")
    }

    func test_dock_sitsRightOfTheTerminal_atTheDefault40PercentWidth() throws {
        let fixture = makeFixture()
        let leafID = UUID()
        registerLeaf(leafID, in: fixture.registry)
        fixture.container.updateLayout(tree: singleLeafTree(leafID))
        let dock = NSView()

        fixture.container.attachDock(dock, toLeaf: leafID)

        let wrapper = try XCTUnwrap(wrapper(for: leafID, in: fixture))
        XCTAssertEqual(dock.frame, CGRect(x: 480, y: 0, width: 320, height: 600), "40% of 800 on the right, full height")
        XCTAssertEqual(wrapper.frame, CGRect(x: 0, y: 0, width: 479, height: 600), "the terminal keeps the left side")
    }

    func test_dockDivider_isASplitDividerBetweenTheTerminalAndTheDock() throws {
        let fixture = makeFixture()
        let leafID = UUID()
        registerLeaf(leafID, in: fixture.registry)
        fixture.container.updateLayout(tree: singleLeafTree(leafID))
        fixture.container.attachDock(NSView(), toLeaf: leafID)

        let divider = try dockDivider(in: fixture, leafID: leafID)

        XCTAssertEqual(divider.direction, .horizontal, "the same left-right divider the side-by-side panes use")
        XCTAssertTrue(divider.frame.contains(NSPoint(x: 479.5, y: 300)), "the divider covers the 1pt gap")
        let subviews = fixture.container.subviews
        let dividerIndex = try XCTUnwrap(subviews.firstIndex(of: divider))
        let wrapperIndex = try XCTUnwrap(subviews.firstIndex { $0 === self.wrapper(for: leafID, in: fixture) })
        let dockIndex = try XCTUnwrap(subviews.firstIndex { $0 === fixture.container.dockView(forLeaf: leafID) })
        XCTAssertGreaterThan(dividerIndex, wrapperIndex, "the divider's hit area is above the terminal")
        XCTAssertGreaterThan(dividerIndex, dockIndex, "the divider's hit area is above the dock")
    }

    func test_noDockDivider_withoutADock() {
        let fixture = makeFixture()
        let leafID = UUID()
        registerLeaf(leafID, in: fixture.registry)
        fixture.container.updateLayout(tree: singleLeafTree(leafID))

        XCTAssertTrue(fixture.container.subviews.compactMap { $0 as? SplitDividerView }.isEmpty)
    }

    func test_dockInASideBySideSplit_staysInsideItsLeaf() throws {
        let fixture = makeFixture()
        let leafA = UUID()
        let leafB = UUID()
        registerLeaf(leafA, in: fixture.registry)
        registerLeaf(leafB, in: fixture.registry)
        fixture.container.updateLayout(tree: twoLeafTree(first: leafA, second: leafB, zoomed: nil))
        let dock = NSView()

        fixture.container.attachDock(dock, toLeaf: leafA)

        let wrapperA = try XCTUnwrap(wrapper(for: leafA, in: fixture))
        let wrapperB = try XCTUnwrap(wrapper(for: leafB, in: fixture))
        XCTAssertEqual(wrapperA.frame.minX, 0)
        XCTAssertEqual(dock.frame.width, 399.5 * 0.4, accuracy: 0.01, "40% of leaf A's 399.5pt")
        XCTAssertEqual(dock.frame.maxX, 399.5, accuracy: 0.01, "the dock ends where leaf A ends")
        XCTAssertEqual(wrapperB.frame.minX, 400.5, accuracy: 0.01, "leaf B is untouched")
    }

    func test_draggingTheDockDivider_setsTheDockWidth() throws {
        let fixture = makeFixture()
        let leafID = UUID()
        registerLeaf(leafID, in: fixture.registry)
        fixture.container.updateLayout(tree: singleLeafTree(leafID))
        let dock = NSView()
        fixture.container.attachDock(dock, toLeaf: leafID)

        try dockDivider(in: fixture, leafID: leafID)._testSimulateDrag(toSuperviewPoint: NSPoint(x: 600, y: 300))

        let wrapper = try XCTUnwrap(wrapper(for: leafID, in: fixture))
        XCTAssertEqual(dock.frame, CGRect(x: 600, y: 0, width: 200, height: 600), "the dock's left edge follows the cursor")
        XCTAssertEqual(wrapper.frame, CGRect(x: 0, y: 0, width: 599, height: 600))
    }

    func test_draggingTheDockDivider_isHonoredUpToTheTerminalMinimum() throws {
        let fixture = makeFixture()
        let leafID = UUID()
        registerLeaf(leafID, in: fixture.registry)
        fixture.container.updateLayout(tree: singleLeafTree(leafID))
        let dock = NSView()
        fixture.container.attachDock(dock, toLeaf: leafID)
        let divider = try dockDivider(in: fixture, leafID: leafID)

        divider._testSimulateDrag(toSuperviewPoint: NSPoint(x: 121, y: 300))
        XCTAssertEqual(dock.frame.minX, 121, accuracy: 0.01)
        XCTAssertEqual(dock.frame.width, 679, accuracy: 0.01, "the terminal keeps exactly its 120pt minimum")

        divider._testSimulateDrag(toSuperviewPoint: NSPoint(x: 50, y: 300))
        XCTAssertEqual(dock.frame.width, 679, accuracy: 0.01, "a drag past the terminal minimum stops there")
        let wrapper = try XCTUnwrap(wrapper(for: leafID, in: fixture))
        XCTAssertEqual(wrapper.frame.width, 120, accuracy: 0.01)
    }

    func test_draggedWidth_persistsAcrossTreeChangesAndContainerResizes() throws {
        let fixture = makeFixture()
        let leafA = UUID()
        let leafB = UUID()
        registerLeaf(leafA, in: fixture.registry)
        registerLeaf(leafB, in: fixture.registry)
        fixture.container.updateLayout(tree: singleLeafTree(leafA))
        let dock = NSView()
        fixture.container.attachDock(dock, toLeaf: leafA)
        try dockDivider(in: fixture, leafID: leafA)._testSimulateDrag(toSuperviewPoint: NSPoint(x: 600, y: 300))

        fixture.container.updateLayout(tree: twoLeafTree(first: leafB, second: leafA, zoomed: nil))
        XCTAssertEqual(dock.frame.width, 200, accuracy: 0.01, "the dragged width, not 40% of the narrower leaf")
        XCTAssertEqual(dock.frame.maxX, 800, accuracy: 0.01)

        fixture.container.updateLayout(tree: singleLeafTree(leafA))
        fixture.container.setFrameSize(NSSize(width: 1000, height: 600))
        XCTAssertEqual(dock.frame, CGRect(x: 800, y: 0, width: 200, height: 600), "a wider container keeps the dragged width")
    }

    func test_draggedWidth_isClampedToASmallerLeaf_andComesBackWhenTheLeafGrows() throws {
        let fixture = makeFixture()
        let leafID = UUID()
        registerLeaf(leafID, in: fixture.registry)
        fixture.container.updateLayout(tree: singleLeafTree(leafID))
        let dock = NSView()
        fixture.container.attachDock(dock, toLeaf: leafID)
        try dockDivider(in: fixture, leafID: leafID)._testSimulateDrag(toSuperviewPoint: NSPoint(x: 500, y: 300))
        XCTAssertEqual(dock.frame.width, 300, accuracy: 0.01)

        fixture.container.setFrameSize(NSSize(width: 400, height: 600))
        XCTAssertEqual(dock.frame.width, 279, accuracy: 0.01, "capped so the terminal keeps 120pt: 400 - 1 - 120")

        fixture.container.setFrameSize(NSSize(width: 800, height: 600))
        XCTAssertEqual(dock.frame.width, 300, accuracy: 0.01, "the dragged width returns")
    }

    func test_draggedWidth_persistsAcrossATabSwitch() throws {
        let fixture = makeFixture()
        let leafID = UUID()
        registerLeaf(leafID, in: fixture.registry)
        fixture.container.updateLayout(tree: singleLeafTree(leafID))
        let dock = NSView()
        fixture.container.attachDock(dock, toLeaf: leafID)
        try dockDivider(in: fixture, leafID: leafID)._testSimulateDrag(toSuperviewPoint: NSPoint(x: 600, y: 300))

        let newRegistry = SurfaceRegistry()
        newRegistry._testInsert(view: SurfaceView(frame: .zero), id: leafID)
        fixture.container.updateRegistry(newRegistry)
        fixture.container.updateLayout(tree: singleLeafTree(leafID))

        XCTAssertEqual(dock.frame, CGRect(x: 600, y: 0, width: 200, height: 600))
    }

    func test_draggedWidth_persistsWhileTheLeafIsParked() throws {
        let fixture = makeFixture()
        let leafA = UUID()
        let leafB = UUID()
        registerLeaf(leafA, in: fixture.registry)
        registerLeaf(leafB, in: fixture.registry)
        fixture.container.updateLayout(tree: singleLeafTree(leafA))
        let dock = NSView()
        fixture.container.attachDock(dock, toLeaf: leafA)
        try dockDivider(in: fixture, leafID: leafA)._testSimulateDrag(toSuperviewPoint: NSPoint(x: 600, y: 300))

        fixture.container.updateLayout(tree: singleLeafTree(leafB))
        fixture.container.updateLayout(tree: singleLeafTree(leafA))

        XCTAssertEqual(fixture.container.dockView(forLeaf: leafA), dock)
        XCTAssertEqual(dock.frame, CGRect(x: 600, y: 0, width: 200, height: 600))
    }

    func test_draggedWidth_isTheWidthWhenViewsAreAddedAndRemoved() throws {
        let fixture = makeFixture()
        let leafID = UUID()
        registerLeaf(leafID, in: fixture.registry)
        fixture.container.updateLayout(tree: singleLeafTree(leafID))
        let dock = MCPAppDockView(surfaceID: leafID)
        let first = MCPAppViewPane(viewID: UUID(), prefersBorder: nil)
        dock.add(first)
        fixture.container.attachDock(dock, toLeaf: leafID)
        try dockDivider(in: fixture, leafID: leafID)._testSimulateDrag(toSuperviewPoint: NSPoint(x: 600, y: 300))

        let second = MCPAppViewPane(viewID: UUID(), prefersBorder: nil)
        dock.add(second)
        XCTAssertEqual(dock.frame, CGRect(x: 600, y: 0, width: 200, height: 600), "adding a view keeps the dragged width")

        dock.remove(viewID: second.viewID)
        XCTAssertEqual(dock.frame, CGRect(x: 600, y: 0, width: 200, height: 600), "removing a view keeps the dragged width")
    }

    func test_addingAView_toAnUndraggedDock_keepsTheDefaultFullHeightDock() {
        let fixture = makeFixture()
        let leafID = UUID()
        registerLeaf(leafID, in: fixture.registry)
        fixture.container.updateLayout(tree: singleLeafTree(leafID))
        let dock = MCPAppDockView(surfaceID: leafID)
        fixture.container.attachDock(dock, toLeaf: leafID)

        dock.add(MCPAppViewPane(viewID: UUID(), prefersBorder: nil))

        XCTAssertEqual(dock.frame, CGRect(x: 480, y: 0, width: 320, height: 600))
    }

    func test_detachingTheDock_dropsTheDraggedWidth() throws {
        let fixture = makeFixture()
        let leafID = UUID()
        registerLeaf(leafID, in: fixture.registry)
        fixture.container.updateLayout(tree: singleLeafTree(leafID))
        fixture.container.attachDock(NSView(), toLeaf: leafID)
        try dockDivider(in: fixture, leafID: leafID)._testSimulateDrag(toSuperviewPoint: NSPoint(x: 600, y: 300))

        fixture.container.detachDock(fromLeaf: leafID)
        let next = NSView()
        fixture.container.attachDock(next, toLeaf: leafID)

        XCTAssertEqual(next.frame, CGRect(x: 480, y: 0, width: 320, height: 600), "a new dock starts at the default width")
        let wrapper = try XCTUnwrap(wrapper(for: leafID, in: fixture))
        XCTAssertEqual(wrapper.frame.width, 479)
    }

    func test_detachingTheDock_removesItsDivider_andGivesTheTerminalTheWholeLeaf() throws {
        let fixture = makeFixture()
        let leafID = UUID()
        registerLeaf(leafID, in: fixture.registry)
        fixture.container.updateLayout(tree: singleLeafTree(leafID))
        fixture.container.attachDock(NSView(), toLeaf: leafID)

        fixture.container.detachDock(fromLeaf: leafID)

        XCTAssertTrue(fixture.container.subviews.compactMap { $0 as? SplitDividerView }.isEmpty)
        XCTAssertEqual(try XCTUnwrap(wrapper(for: leafID, in: fixture)).frame, fixture.container.bounds)
    }

    // MARK: - Zoom and fullscreen with a side-by-side dock

    func test_zoomingAnotherLeaf_removesTheDockDivider() {
        let fixture = makeFixture()
        let leafA = UUID()
        let leafB = UUID()
        registerLeaf(leafA, in: fixture.registry)
        registerLeaf(leafB, in: fixture.registry)
        fixture.container.updateLayout(tree: twoLeafTree(first: leafA, second: leafB, zoomed: nil))
        fixture.container.attachDock(NSView(), toLeaf: leafA)

        fixture.container.updateLayout(tree: twoLeafTree(first: leafA, second: leafB, zoomed: leafB))

        XCTAssertTrue(fixture.container.subviews.compactMap { $0 as? SplitDividerView }.isEmpty,
            "neither the split divider nor leaf A's dock divider shows while leaf B is zoomed")
    }

    func test_zoomingTheDocksLeaf_laysTheDockOutRightOfTheTerminalAcrossTheContainer() throws {
        let fixture = makeFixture()
        let leafA = UUID()
        let leafB = UUID()
        registerLeaf(leafA, in: fixture.registry)
        registerLeaf(leafB, in: fixture.registry)
        fixture.container.updateLayout(tree: twoLeafTree(first: leafA, second: leafB, zoomed: nil))
        let dock = NSView()
        fixture.container.attachDock(dock, toLeaf: leafA)

        fixture.container.updateLayout(tree: twoLeafTree(first: leafA, second: leafB, zoomed: leafA))

        XCTAssertEqual(dock.frame, CGRect(x: 480, y: 0, width: 320, height: 600))
        XCTAssertEqual(fixture.container.subviews.compactMap { $0 as? SplitDividerView }.count, 1, "only the dock divider")
        XCTAssertNoThrow(try dockDivider(in: fixture, leafID: leafA))
    }

    func test_fullscreen_removesTheDockDivider_andRestoresTheDraggedWidthAfterwards() throws {
        let fixture = makeFixture()
        let leafID = UUID()
        registerLeaf(leafID, in: fixture.registry)
        fixture.container.updateLayout(tree: singleLeafTree(leafID))
        let dock = NSView()
        fixture.container.attachDock(dock, toLeaf: leafID)
        try dockDivider(in: fixture, leafID: leafID)._testSimulateDrag(toSuperviewPoint: NSPoint(x: 600, y: 300))

        fixture.container.setFullscreen(true, forLeaf: leafID)
        XCTAssertEqual(dock.frame, fixture.container.bounds)
        XCTAssertTrue(fixture.container.subviews.compactMap { $0 as? SplitDividerView }.isEmpty)

        fixture.container.setFullscreen(false, forLeaf: leafID)
        XCTAssertEqual(dock.frame, CGRect(x: 600, y: 0, width: 200, height: 600))
    }
}
