import XCTest
import AppKit
@testable import Calyx

@MainActor
final class CalyxWindowControllerFocusPaneTests: XCTestCase {

    private struct Fixture {
        let controller: CalyxWindowController
        let group: TabGroup
        let foregroundTab: Tab
        let splitTab: Tab
        let firstLeafID: UUID
        let secondLeafID: UUID
    }

    private final class MinimizedWindow: CalyxWindow {
        private(set) var deminiaturizeCallCount = 0

        override var isMiniaturized: Bool { deminiaturizeCallCount == 0 }

        override func deminiaturize(_ sender: Any?) {
            deminiaturizeCallCount += 1
        }
    }

    private var windows: [NSWindow] = []

    override func tearDown() {
        windows.forEach { $0.close() }
        windows.removeAll()
        super.tearDown()
    }

    private func makeWindow(
        _ make: (NSRect, NSWindow.StyleMask, NSWindow.BackingStoreType, Bool) -> CalyxWindow = {
            CalyxWindow(contentRect: $0, styleMask: $1, backing: $2, defer: $3)
        }
    ) -> CalyxWindow {
        let window = make(
            NSRect(x: 0, y: 0, width: 800, height: 600),
            [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            .buffered,
            false
        )
        windows.append(window)
        return window
    }

    private func makeFixture(
        focused: SplitFocus = .first,
        zoomed: SplitFocus? = nil,
        minimized: Bool = false
    ) -> Fixture {
        let foregroundRegistry = SurfaceRegistry()
        let foregroundLeafID = UUID()
        foregroundRegistry._testInsert(view: SurfaceView(frame: .zero), id: foregroundLeafID)
        let foregroundTab = Tab(title: "Foreground", splitTree: SplitTree(leafID: foregroundLeafID), registry: foregroundRegistry)

        let registry = SurfaceRegistry()
        let firstLeafID = UUID()
        let secondLeafID = UUID()
        registry._testInsert(view: SurfaceView(frame: .zero), id: firstLeafID)
        registry._testInsert(view: SurfaceView(frame: .zero), id: secondLeafID)
        let root = SplitNode.split(SplitData(
            direction: .horizontal,
            ratio: 0.5,
            first: .leaf(id: firstLeafID),
            second: .leaf(id: secondLeafID)
        ))
        let pick: (SplitFocus) -> UUID = { $0 == .first ? firstLeafID : secondLeafID }
        let splitTab = Tab(
            title: "Split",
            splitTree: SplitTree(root: root, focusedLeafID: pick(focused), zoomedLeafID: zoomed.map(pick)),
            registry: registry
        )

        let group = TabGroup(name: "Default", tabs: [foregroundTab, splitTab], activeTabID: foregroundTab.id)
        let session = WindowSession(groups: [group], activeGroupID: group.id)
        let window: CalyxWindow = minimized
            ? makeWindow { MinimizedWindow(contentRect: $0, styleMask: $1, backing: $2, defer: $3) }
            : makeWindow()
        let controller = CalyxWindowController(window: window, windowSession: session, restoring: true)
        return Fixture(
            controller: controller, group: group, foregroundTab: foregroundTab, splitTab: splitTab,
            firstLeafID: firstLeafID, secondLeafID: secondLeafID
        )
    }

    private enum SplitFocus { case first, second }

    private func postFocusSurface(_ id: UUID) {
        NotificationCenter.default.post(name: .calyxFocusSurface, object: nil, userInfo: ["surfaceID": id])
    }

    func test_focusSurface_nonFocusedPaneInBackgroundTab_activatesTabAndFocusesPane() {
        let fixture = makeFixture(focused: .first)

        postFocusSurface(fixture.secondLeafID)

        XCTAssertEqual(fixture.group.activeTabID, fixture.splitTab.id)
        XCTAssertEqual(fixture.splitTab.splitTree.focusedLeafID, fixture.secondLeafID)
    }

    func test_focusSurface_otherPaneZoomed_clearsZoomAndFocusesTarget() {
        let fixture = makeFixture(focused: .first, zoomed: .first)

        postFocusSurface(fixture.secondLeafID)

        XCTAssertNil(fixture.splitTab.splitTree.zoomedLeafID)
        XCTAssertEqual(fixture.splitTab.splitTree.focusedLeafID, fixture.secondLeafID)
    }

    func test_focusSurface_targetAlreadyFocusedAndZoomed_keepsZoom() {
        let fixture = makeFixture(focused: .second, zoomed: .second)

        postFocusSurface(fixture.secondLeafID)

        XCTAssertEqual(fixture.group.activeTabID, fixture.splitTab.id)
        XCTAssertEqual(fixture.splitTab.splitTree.zoomedLeafID, fixture.secondLeafID)
        XCTAssertEqual(fixture.splitTab.splitTree.focusedLeafID, fixture.secondLeafID)
    }

    func test_focusSurface_missionMapShownInOwningWindow_dismissesMissionMap() {
        let fixture = makeFixture()
        fixture.controller.showMissionMap()
        XCTAssertTrue(fixture.controller.windowSession.showMissionMap)

        postFocusSurface(fixture.secondLeafID)

        XCTAssertFalse(fixture.controller.windowSession.showMissionMap)
        XCTAssertEqual(fixture.splitTab.splitTree.focusedLeafID, fixture.secondLeafID)
    }

    func test_focusSurface_missionMapShownInNonOwningWindow_staysShown() {
        let owner = makeFixture()
        let bystander = makeFixture()
        bystander.controller.showMissionMap()
        XCTAssertTrue(bystander.controller.windowSession.showMissionMap)

        postFocusSurface(owner.secondLeafID)

        XCTAssertTrue(bystander.controller.windowSession.showMissionMap)
        XCTAssertEqual(bystander.group.activeTabID, bystander.foregroundTab.id)
        XCTAssertEqual(owner.splitTab.splitTree.focusedLeafID, owner.secondLeafID)
    }

    func test_focusSurface_paneInTabOfOtherGroup_switchesGroupTabAndFocus() {
        let foregroundRegistry = SurfaceRegistry()
        let foregroundLeafID = UUID()
        foregroundRegistry._testInsert(view: SurfaceView(frame: .zero), id: foregroundLeafID)
        let foregroundTab = Tab(title: "Foreground", splitTree: SplitTree(leafID: foregroundLeafID), registry: foregroundRegistry)
        let activeGroup = TabGroup(name: "Active", tabs: [foregroundTab], activeTabID: foregroundTab.id)

        let otherRegistry = SurfaceRegistry()
        let decoyLeafID = UUID()
        let targetLeafID = UUID()
        otherRegistry._testInsert(view: SurfaceView(frame: .zero), id: decoyLeafID)
        otherRegistry._testInsert(view: SurfaceView(frame: .zero), id: targetLeafID)
        let decoyTab = Tab(title: "Decoy", splitTree: SplitTree(leafID: decoyLeafID), registry: otherRegistry)
        let targetTab = Tab(title: "Target", splitTree: SplitTree(leafID: targetLeafID), registry: otherRegistry)
        let otherGroup = TabGroup(name: "Other", tabs: [decoyTab, targetTab], activeTabID: decoyTab.id)

        let session = WindowSession(groups: [activeGroup, otherGroup], activeGroupID: activeGroup.id)
        let controller = CalyxWindowController(window: makeWindow(), windowSession: session, restoring: true)

        postFocusSurface(targetLeafID)

        XCTAssertEqual(controller.windowSession.activeGroupID, otherGroup.id)
        XCTAssertEqual(otherGroup.activeTabID, targetTab.id)
        XCTAssertEqual(targetTab.splitTree.focusedLeafID, targetLeafID)
    }

    func test_focusSurface_nonFocusedPane_makesTargetViewFirstResponder() throws {
        let fixture = makeFixture(focused: .first)
        fixture.controller.recreateHostingView()
        fixture.controller.window?.contentView?.layoutSubtreeIfNeeded()
        let targetView = try XCTUnwrap(fixture.splitTab.registry.view(for: fixture.secondLeafID))

        postFocusSurface(fixture.secondLeafID)
        fixture.controller.window?.contentView?.layoutSubtreeIfNeeded()

        XCTAssertNotNil(targetView.window)
        XCTAssertTrue(fixture.controller.window?.firstResponder === targetView)
    }

    func test_focusSurface_owningWindowMinimized_deminiaturizesOnce() throws {
        let fixture = makeFixture(focused: .first, minimized: true)
        let window = try XCTUnwrap(fixture.controller.window as? MinimizedWindow)
        XCTAssertTrue(window.isMiniaturized)

        postFocusSurface(fixture.secondLeafID)

        XCTAssertEqual(window.deminiaturizeCallCount, 1)
        XCTAssertEqual(fixture.splitTab.splitTree.focusedLeafID, fixture.secondLeafID)
    }

    func test_missionMapCardDoubleClicked_paneInOtherWindow_dismissesOwnMapAndOwnerFocusesPane() {
        let owner = makeFixture(focused: .first)
        let bystander = makeFixture()
        bystander.controller.showMissionMap()
        XCTAssertTrue(bystander.controller.windowSession.showMissionMap)

        bystander.controller.missionMapCardDoubleClicked(surfaceID: owner.secondLeafID)

        XCTAssertFalse(bystander.controller.windowSession.showMissionMap)
        XCTAssertEqual(bystander.group.activeTabID, bystander.foregroundTab.id)
        XCTAssertEqual(owner.group.activeTabID, owner.splitTab.id)
        XCTAssertEqual(owner.splitTab.splitTree.focusedLeafID, owner.secondLeafID)
    }
}
