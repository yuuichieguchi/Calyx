import XCTest
import AppKit
import UserNotifications
@testable import Calyx

@MainActor
final class CalyxWindowControllerNotificationOriginTests: XCTestCase {

    private final class OriginSpy: NotificationManager {
        private(set) var origins: [UUID?] = []

        override func sendNotification(title: String, body: String, originSurfaceID: UUID?) {
            origins.append(originSurfaceID)
        }

        override func bounceDockIcon() {}
    }

    private struct Fixture {
        let controller: CalyxWindowController
        let group: TabGroup
        let backgroundTab: Tab
        let backgroundLeafID: UUID
        let backgroundView: SurfaceView
    }

    private var windows: [NSWindow] = []

    override func tearDown() {
        windows.forEach { $0.close() }
        windows.removeAll()
        super.tearDown()
    }

    private func makeFixture() -> Fixture {
        let foregroundRegistry = SurfaceRegistry()
        let foregroundLeafID = UUID()
        foregroundRegistry._testInsert(view: SurfaceView(frame: .zero), id: foregroundLeafID)
        let foregroundTab = Tab(title: "Foreground", splitTree: SplitTree(leafID: foregroundLeafID), registry: foregroundRegistry)

        let registry = SurfaceRegistry()
        let otherLeafID = UUID()
        let backgroundLeafID = UUID()
        let backgroundView = SurfaceView(frame: .zero)
        registry._testInsert(view: SurfaceView(frame: .zero), id: otherLeafID)
        registry._testInsert(view: backgroundView, id: backgroundLeafID)
        let root = SplitNode.split(SplitData(
            direction: .horizontal,
            ratio: 0.5,
            first: .leaf(id: otherLeafID),
            second: .leaf(id: backgroundLeafID)
        ))
        let backgroundTab = Tab(
            title: "Background",
            splitTree: SplitTree(root: root, focusedLeafID: otherLeafID),
            registry: registry
        )

        let group = TabGroup(name: "Default", tabs: [foregroundTab, backgroundTab], activeTabID: foregroundTab.id)
        let session = WindowSession(groups: [group], activeGroupID: group.id)
        let window = CalyxWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        windows.append(window)
        let controller = CalyxWindowController(window: window, windowSession: session, restoring: true)
        return Fixture(
            controller: controller, group: group, backgroundTab: backgroundTab,
            backgroundLeafID: backgroundLeafID, backgroundView: backgroundView
        )
    }

    func test_desktopNotification_fromPane_sendsWithThatPanesSurfaceID() {
        let fixture = makeFixture()
        let spy = OriginSpy()
        let original = NotificationManager.shared
        NotificationManager.shared = spy
        defer { NotificationManager.shared = original }

        NotificationCenter.default.post(
            name: .ghosttyDesktopNotification,
            object: fixture.backgroundView,
            userInfo: ["title": "t", "body": "b"]
        )

        XCTAssertEqual(spy.origins, [fixture.backgroundLeafID])
    }

    func test_processRendererHealth_unhealthy_sendsWithThatPanesSurfaceID() {
        let fixture = makeFixture()
        let spy = OriginSpy()
        let original = NotificationManager.shared
        NotificationManager.shared = spy
        defer { NotificationManager.shared = original }

        fixture.controller.processRendererHealth(surfaceView: fixture.backgroundView, healthy: false)

        XCTAssertEqual(spy.origins, [fixture.backgroundLeafID])
    }

    func test_tabRead_switchingToTab_removesItsPanesNotifications() {
        let fixture = makeFixture()
        let center = RecordingUserNotificationCenterClient()
        let originalLedger = PaneNotificationLedger.shared
        PaneNotificationLedger.shared = PaneNotificationLedger(center: center)
        defer { PaneNotificationLedger.shared = originalLedger }
        PaneNotificationLedger.shared.deliver(makeNotificationRequest(identifier: "pane-note"), originSurfaceID: fixture.backgroundLeafID)
        PaneNotificationLedger.shared.deliver(makeNotificationRequest(identifier: "unrelated"), originSurfaceID: UUID())
        fixture.backgroundTab.unreadNotifications = 1

        fixture.controller.activateTabContaining(surfaceID: fixture.backgroundLeafID)

        XCTAssertEqual(fixture.group.activeTabID, fixture.backgroundTab.id)
        XCTAssertEqual(fixture.backgroundTab.unreadNotifications, 0)
        XCTAssertEqual(center.removedPendingIdentifiers, ["pane-note"])
        XCTAssertEqual(center.removedDeliveredIdentifiers, ["pane-note"])
    }
}
