import XCTest
import UserNotifications
@testable import Calyx

@MainActor
final class NotificationManagerAuthorizationTests: XCTestCase {

    private var center: RecordingUserNotificationCenterClient!
    private var originalLedger: PaneNotificationLedger!

    override func setUp() async throws {
        try await super.setUp()
        center = RecordingUserNotificationCenterClient()
        originalLedger = PaneNotificationLedger.shared
        PaneNotificationLedger.shared = PaneNotificationLedger(center: center)
    }

    override func tearDown() async throws {
        PaneNotificationLedger.shared = originalLedger
        center = nil
        try await super.tearDown()
    }

    func test_firstSendFromFreshManager_authorized_isAdded() {
        center.authorizationStatus = .authorized
        let origin = UUID()

        NotificationManager().sendNotification(title: "t", body: "b", originSurfaceID: origin)

        XCTAssertEqual(center.addedRequests.count, 1)
        XCTAssertEqual(NotificationOrigin.surfaceID(in: center.addedRequests.first?.content.userInfo ?? [:]), origin)
        XCTAssertEqual(center.authorizationRequestCount, 0)
    }

    func test_send_denied_nothingAddedAndNoRequest() {
        center.authorizationStatus = .denied

        NotificationManager().sendNotification(title: "t", body: "b", originSurfaceID: UUID())

        XCTAssertEqual(center.addedRequests.count, 0)
        XCTAssertEqual(center.authorizationRequestCount, 0)
    }

    func test_send_statusChangesBetweenSends_eachSendFollowsCurrentStatus() {
        let manager = NotificationManager()
        center.authorizationStatus = .denied
        manager.sendNotification(title: "first", body: "b", originSurfaceID: nil)

        center.authorizationStatus = .authorized
        manager.sendNotification(title: "second", body: "b", originSurfaceID: nil)

        center.authorizationStatus = .denied
        manager.sendNotification(title: "third", body: "b", originSurfaceID: nil)

        XCTAssertEqual(center.addedRequests.map(\.content.title), ["second"])
    }

    func test_send_notDetermined_notAddedUntilGranted() {
        center.authorizationStatus = .notDetermined
        let origin = UUID()

        NotificationManager().sendNotification(title: "t", body: "b", originSurfaceID: origin)

        XCTAssertEqual(center.authorizationRequestCount, 1)
        XCTAssertEqual(center.addedRequests.count, 0)

        center.resolvePendingAuthorization(granted: true)

        XCTAssertEqual(center.addedRequests.count, 1)
        XCTAssertEqual(NotificationOrigin.surfaceID(in: center.addedRequests.first?.content.userInfo ?? [:]), origin)
    }

    func test_send_notDeterminedThenDenied_nothingAdded() {
        center.authorizationStatus = .notDetermined

        NotificationManager().sendNotification(title: "t", body: "b", originSurfaceID: UUID())
        center.resolvePendingAuthorization(granted: false)

        XCTAssertEqual(center.authorizationRequestCount, 1)
        XCTAssertEqual(center.addedRequests.count, 0)
    }

    func test_send_originRemovedWhilePending_notAddedAfterGrant() {
        center.authorizationStatus = .notDetermined
        let origin = UUID()

        NotificationManager().sendNotification(title: "t", body: "b", originSurfaceID: origin)
        PaneNotificationLedger.shared.removeNotifications(originatingIn: [origin])
        center.resolvePendingAuthorization(granted: true)

        XCTAssertEqual(center.authorizationRequestCount, 1)
        XCTAssertEqual(center.addedRequests.count, 0)
    }

    func test_send_otherOriginRemovedWhilePending_stillAddedAfterGrant() {
        center.authorizationStatus = .notDetermined
        let origin = UUID()

        NotificationManager().sendNotification(title: "t", body: "b", originSurfaceID: origin)
        PaneNotificationLedger.shared.removeNotifications(originatingIn: [UUID()])
        center.resolvePendingAuthorization(granted: true)

        XCTAssertEqual(center.addedRequests.count, 1)
        XCTAssertEqual(NotificationOrigin.surfaceID(in: center.addedRequests.first?.content.userInfo ?? [:]), origin)
    }

    private var ledger: PaneNotificationLedger { PaneNotificationLedger.shared }

    private func sendFrom(_ origin: UUID?, title: String = "t") {
        ledger.deliverIfAuthorized(makeNotificationRequest(identifier: title), originSurfaceID: origin, admit: { true })
    }

    func test_originRemovedWhileStatusQueryPending_authorized_notAddedAndLeavesNothing() {
        center.authorizationStatus = .authorized
        center.defersAuthorizationStatus = true
        let origin = UUID()

        sendFrom(origin)
        ledger.removeNotifications(originatingIn: [origin])
        center.resolvePendingAuthorizationStatus()
        ledger.removeNotifications(originatingIn: [origin])

        XCTAssertEqual(center.addedRequests.count, 0)
        XCTAssertEqual(center.removalCallCount, 0)
    }

    func test_removeAllWhileStatusQueryPending_authorized_notAddedAndLeavesNothing() {
        center.authorizationStatus = .authorized
        center.defersAuthorizationStatus = true
        let origin = UUID()

        sendFrom(origin)
        ledger.removeAllPaneNotifications()
        center.resolvePendingAuthorizationStatus()
        ledger.removeNotifications(originatingIn: [origin])

        XCTAssertEqual(center.addedRequests.count, 0)
        XCTAssertEqual(center.removalCallCount, 0)
    }

    func test_surfaceDestroyedWhileStatusQueryPending_authorized_notAddedAndLeavesNothing() {
        center.authorizationStatus = .authorized
        center.defersAuthorizationStatus = true
        ledger.startObserving()
        let origin = UUID()

        sendFrom(origin)
        NotificationCenter.default.post(name: .calyxSurfaceDestroyed, object: nil, userInfo: ["surfaceID": origin])
        center.resolvePendingAuthorizationStatus()
        ledger.removeNotifications(originatingIn: [origin])

        XCTAssertEqual(center.addedRequests.count, 0)
        XCTAssertEqual(center.removalCallCount, 0)
    }

    func test_otherOriginRemovedWhileStatusQueryPending_authorized_isAdded() {
        center.authorizationStatus = .authorized
        center.defersAuthorizationStatus = true
        let origin = UUID()

        sendFrom(origin, title: "kept")
        ledger.removeNotifications(originatingIn: [UUID()])
        center.resolvePendingAuthorizationStatus()

        XCTAssertEqual(center.addedIdentifiers, ["kept"])
    }

    func test_originRemovedWhileStatusQueryThenAuthorizationPending_notAddedAndLeavesNothing() {
        center.authorizationStatus = .notDetermined
        center.defersAuthorizationStatus = true
        let origin = UUID()

        sendFrom(origin)
        center.resolvePendingAuthorizationStatus()
        ledger.removeNotifications(originatingIn: [origin])
        center.resolvePendingAuthorization(granted: true)
        ledger.removeNotifications(originatingIn: [origin])

        XCTAssertEqual(center.addedRequests.count, 0)
        XCTAssertEqual(center.removalCallCount, 0)
    }

    func test_originRemovedWhileAuthorizationPending_leavesNothing() {
        center.authorizationStatus = .notDetermined
        let origin = UUID()

        sendFrom(origin)
        ledger.removeNotifications(originatingIn: [origin])
        center.resolvePendingAuthorization(granted: true)
        ledger.removeNotifications(originatingIn: [origin])

        XCTAssertEqual(center.addedRequests.count, 0)
        XCTAssertEqual(center.removalCallCount, 0)
    }

    func test_twoOriginsWhileAuthorizationPending_bothAddedAfterOneGrant() {
        center.authorizationStatus = .notDetermined

        sendFrom(UUID(), title: "first")
        sendFrom(UUID(), title: "second")
        center.resolvePendingAuthorization(granted: true)

        XCTAssertEqual(Set(center.addedIdentifiers), ["first", "second"])
        XCTAssertEqual(center.addedRequests.count, 2)
    }

    func test_twoOriginsWhileAuthorizationPending_removingOneDropsOnlyThatOne() {
        center.authorizationStatus = .notDetermined
        let removedOrigin = UUID()

        sendFrom(removedOrigin, title: "dropped")
        sendFrom(UUID(), title: "kept")
        ledger.removeNotifications(originatingIn: [removedOrigin])
        center.resolvePendingAuthorization(granted: true)

        XCTAssertEqual(center.addedIdentifiers, ["kept"])
    }

    func test_removeAllWhileAuthorizationPending_dropsRequest() {
        center.authorizationStatus = .notDetermined

        sendFrom(UUID())
        ledger.removeAllPaneNotifications()
        center.resolvePendingAuthorization(granted: true)

        XCTAssertEqual(center.addedRequests.count, 0)
    }

    func test_surfaceDestroyedWhileAuthorizationPending_dropsRequest() {
        center.authorizationStatus = .notDetermined
        ledger.startObserving()
        let origin = UUID()

        sendFrom(origin)
        NotificationCenter.default.post(name: .calyxSurfaceDestroyed, object: nil, userInfo: ["surfaceID": origin])
        center.resolvePendingAuthorization(granted: true)

        XCTAssertEqual(center.addedRequests.count, 0)
    }

    func test_denied_laterRemovalOfOrigin_makesNoCenterCall() {
        center.authorizationStatus = .denied
        let origin = UUID()

        sendFrom(origin)
        ledger.removeNotifications(originatingIn: [origin])

        XCTAssertEqual(center.removalCallCount, 0)
    }

    func test_notGranted_laterRemovalOfOrigin_makesNoCenterCall() {
        center.authorizationStatus = .notDetermined
        let origin = UUID()

        sendFrom(origin)
        center.resolvePendingAuthorization(granted: false)
        ledger.removeNotifications(originatingIn: [origin])

        XCTAssertEqual(center.removalCallCount, 0)
    }

    func test_nilOriginWhileAuthorizationPending_isAddedAfterGrant() {
        center.authorizationStatus = .notDetermined

        sendFrom(nil, title: "global")
        center.resolvePendingAuthorization(granted: true)

        XCTAssertEqual(center.addedIdentifiers, ["global"])
    }

    func test_rateLimit_deniedSendsDoNotCount_authorizedSendWithinSameSecondIsAdded() {
        let manager = NotificationManager()
        let origin = UUID()
        center.authorizationStatus = .denied
        for _ in 0..<6 {
            manager.sendNotification(title: "denied", body: "b", originSurfaceID: origin)
        }

        center.authorizationStatus = .authorized
        manager.sendNotification(title: "shown", body: "b", originSurfaceID: origin)

        XCTAssertEqual(center.addedRequests.map(\.content.title), ["shown"])
    }

    func test_severalSendsWhileAuthorizationInFlight_requestAuthorizationOnce_allResolveWithThatAnswer() {
        center.authorizationStatus = .notDetermined

        sendFrom(UUID(), title: "one")
        sendFrom(UUID(), title: "two")
        sendFrom(nil, title: "three")
        center.resolvePendingAuthorization(granted: true)

        XCTAssertEqual(center.authorizationRequestCount, 1)
        XCTAssertEqual(Set(center.addedIdentifiers), ["one", "two", "three"])
        XCTAssertEqual(center.addedRequests.count, 3)
    }

    func test_severalSendsWhileAuthorizationInFlight_refusedOnce_noneAdded() {
        center.authorizationStatus = .notDetermined

        sendFrom(UUID())
        sendFrom(UUID())
        center.resolvePendingAuthorization(granted: false)

        XCTAssertEqual(center.authorizationRequestCount, 1)
        XCTAssertEqual(center.addedRequests.count, 0)
    }
}
