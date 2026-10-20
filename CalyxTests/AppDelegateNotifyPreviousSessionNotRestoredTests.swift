import XCTest
@testable import Calyx

@MainActor
final class AppDelegateNotifyPreviousSessionNotRestoredTests: XCTestCase {

    private final class NotifySpy: NotificationManager {
        private(set) var callCount = 0
        private(set) var lastTitle: String?
        private(set) var lastBody: String?
        private(set) var lastOriginSurfaceID: UUID??

        override func sendNotification(title: String, body: String, originSurfaceID: UUID?) {
            callCount += 1
            lastTitle = title
            lastBody = body
            lastOriginSurfaceID = .some(originSurfaceID)
        }
    }

    func test_notifyPreviousSessionNotRestored_sendsExactlyOneNotification() {
        let spy = NotifySpy()
        let originalManager = NotificationManager.shared
        NotificationManager.shared = spy
        defer { NotificationManager.shared = originalManager }

        let appDelegate = AppDelegate()
        appDelegate.notifyPreviousSessionNotRestored()

        XCTAssertEqual(spy.callCount, 1,
                       "a skipped/failed restore must notify the user exactly once")
        XCTAssertEqual(spy.lastOriginSurfaceID, .some(nil),
                       "an app-launch notification has no originating pane")
    }

    func test_notifyPreviousSessionNotRestored_doesNotClaimDataIsLost() {
        let spy = NotifySpy()
        let originalManager = NotificationManager.shared
        NotificationManager.shared = spy
        defer { NotificationManager.shared = originalManager }

        let appDelegate = AppDelegate()
        appDelegate.notifyPreviousSessionNotRestored()

        let body = spy.lastBody?.lowercased() ?? ""
        let title = spy.lastTitle?.lowercased() ?? ""
        XCTAssertFalse(body.contains("lost"),
                       "the notification must not claim the previous session's tabs/data are lost -- " +
                       "Bug 3a preserves them precisely so this is false")
        XCTAssertFalse(title.contains("lost"))
    }

    func test_notifyPreviousSessionNotRestored_mentionsThePaletteAsTheRecoveryPath() {
        let spy = NotifySpy()
        let originalManager = NotificationManager.shared
        NotificationManager.shared = spy
        defer { NotificationManager.shared = originalManager }

        let appDelegate = AppDelegate()
        appDelegate.notifyPreviousSessionNotRestored()

        let body = spy.lastBody?.lowercased() ?? ""
        XCTAssertTrue(body.contains("palette"),
                     "the notification must point the user at the command palette, where " +
                     "session.recoverPreviousSession (Bug 3c) actually performs the recovery")
    }
}
