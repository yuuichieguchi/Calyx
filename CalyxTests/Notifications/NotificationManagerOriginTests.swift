import XCTest
import UserNotifications
@testable import Calyx

@MainActor
final class NotificationManagerOriginTests: XCTestCase {

    private var center: RecordingUserNotificationCenterClient!
    private var originalLedger: PaneNotificationLedger!
    private var manager: NotificationManager!

    override func setUp() async throws {
        try await super.setUp()
        center = RecordingUserNotificationCenterClient()
        originalLedger = PaneNotificationLedger.shared
        PaneNotificationLedger.shared = PaneNotificationLedger(center: center)
        manager = NotificationManager()
        manager._setPermissionGrantedForTesting(true)
    }

    override func tearDown() async throws {
        PaneNotificationLedger.shared = originalLedger
        manager = nil
        center = nil
        try await super.tearDown()
    }

    func test_sendNotification_withOrigin_userInfoDecodesToOrigin() {
        let origin = UUID()

        manager.sendNotification(title: "t", body: "b", originSurfaceID: origin)

        XCTAssertEqual(center.addedRequests.count, 1)
        let userInfo = center.addedRequests.first?.content.userInfo ?? [:]
        XCTAssertEqual(NotificationOrigin.surfaceID(in: userInfo), origin)
    }

    func test_sendNotification_nilOrigin_userInfoDecodesToNil() {
        manager.sendNotification(title: "t", body: "b", originSurfaceID: nil)

        XCTAssertEqual(center.addedRequests.count, 1)
        XCTAssertNil(NotificationOrigin.surfaceID(in: center.addedRequests.first?.content.userInfo ?? [:]))
    }

    func test_sendNotification_sixFromSameOrigin_onlyFiveAdded() {
        let origin = UUID()

        for _ in 0..<6 {
            manager.sendNotification(title: "t", body: "b", originSurfaceID: origin)
        }

        XCTAssertEqual(center.addedRequests.count, 5)
    }

    func test_sendNotification_differentOriginAfterLimit_isStillAdded() {
        let limited = UUID()
        let other = UUID()
        for _ in 0..<6 {
            manager.sendNotification(title: "t", body: "b", originSurfaceID: limited)
        }

        manager.sendNotification(title: "t", body: "b", originSurfaceID: other)

        XCTAssertEqual(center.addedRequests.count, 6)
        XCTAssertEqual(NotificationOrigin.surfaceID(in: center.addedRequests.last?.content.userInfo ?? [:]), other)
    }

    func test_sendNotification_sixNilOrigin_allAdded() {
        for _ in 0..<6 {
            manager.sendNotification(title: "t", body: "b", originSurfaceID: nil)
        }

        XCTAssertEqual(center.addedRequests.count, 6)
    }

    func test_sendNotification_withOrigin_isRecordedInSharedLedger() {
        let origin = UUID()
        manager.sendNotification(title: "t", body: "b", originSurfaceID: origin)
        let identifier = center.addedIdentifiers.first

        PaneNotificationLedger.shared.removeNotifications(originatingIn: [origin])

        XCTAssertNotNil(identifier)
        XCTAssertEqual(center.removedPendingIdentifiers, Set([identifier].compactMap { $0 }))
        XCTAssertEqual(center.removedDeliveredIdentifiers, Set([identifier].compactMap { $0 }))
    }
}
