import XCTest
import UserNotifications
@testable import Calyx

@MainActor
final class NotificationManagerRedactedBodyTests: XCTestCase {

    private var center: RecordingUserNotificationCenterClient!
    private var originalLedger: PaneNotificationLedger!
    private var manager: NotificationManager!

    override func setUp() async throws {
        try await super.setUp()
        center = RecordingUserNotificationCenterClient()
        center.authorizationStatus = .authorized
        originalLedger = PaneNotificationLedger.shared
        PaneNotificationLedger.shared = PaneNotificationLedger(center: center)
        manager = NotificationManager()
    }

    override func tearDown() async throws {
        PaneNotificationLedger.shared = originalLedger
        manager = nil
        center = nil
        try await super.tearDown()
    }

    func test_sendNotificationRedacting_plainSecret_bodyRedacted() {
        manager.sendNotification(title: "t", redactingSecretsIn: "export API_KEY=abc123", originSurfaceID: nil)

        XCTAssertEqual(center.addedRequests.count, 1)
        XCTAssertEqual(center.addedRequests.first?.content.body, "export API_KEY=[redacted]")
    }

    func test_sendNotificationRedacting_zeroWidthSplitSecret_bodyRedacted() {
        manager.sendNotification(title: "t", redactingSecretsIn: "export API_\u{200B}KEY=abc123", originSurfaceID: nil)

        XCTAssertEqual(center.addedRequests.count, 1)
        XCTAssertEqual(center.addedRequests.first?.content.body, "export API_KEY=[redacted]")
    }

    func test_sendNotificationRedacting_githubTokenStraddlingCap_tokenBodyAbsentAndCapped() {
        let tokenBody = "iK2ZWeqhFWCEPyYngFb51yBMWXaSCrUZoL8g"
        let input = String(repeating: "x", count: 230) + " ghp_" + tokenBody

        manager.sendNotification(title: "t", redactingSecretsIn: input, originSurfaceID: nil)

        let body = center.addedRequests.first?.content.body ?? tokenBody
        XCTAssertFalse(body.contains(String(tokenBody.prefix(12))), body)
        XCTAssertLessThanOrEqual(body.count, 256)
    }

    func test_sendNotificationRedacting_withOrigin_userInfoDecodesToOrigin() {
        let origin = UUID()

        manager.sendNotification(title: "t", redactingSecretsIn: "b", originSurfaceID: origin)

        XCTAssertEqual(center.addedRequests.count, 1)
        XCTAssertEqual(NotificationOrigin.surfaceID(in: center.addedRequests.first?.content.userInfo ?? [:]), origin)
    }

    func test_sendNotificationRedacting_titleWithBidiOverride_titleSanitized() {
        manager.sendNotification(title: "ab\u{202E}cd", redactingSecretsIn: "b", originSurfaceID: nil)

        XCTAssertEqual(center.addedRequests.first?.content.title, "abcd")
    }

    func test_sendNotificationRedacting_sharesRateLimitWithPlainVariant_onlyFiveAdded() {
        let origin = UUID()

        for _ in 0..<3 {
            manager.sendNotification(title: "t", body: "b", originSurfaceID: origin)
        }
        for _ in 0..<3 {
            manager.sendNotification(title: "t", redactingSecretsIn: "b", originSurfaceID: origin)
        }

        XCTAssertEqual(center.addedRequests.count, 5)
    }

    func test_sendNotificationRedacting_authorizationDenied_nothingAdded() {
        center.authorizationStatus = .denied

        manager.sendNotification(title: "t", redactingSecretsIn: "b", originSurfaceID: nil)

        XCTAssertEqual(center.addedRequests.count, 0)
    }

    func test_sendNotificationPlain_secretShapedText_deliveredUnredacted() {
        manager.sendNotification(title: "t", body: "export API_KEY=abc123", originSurfaceID: nil)

        XCTAssertEqual(center.addedRequests.first?.content.body, "export API_KEY=abc123")
    }
}
