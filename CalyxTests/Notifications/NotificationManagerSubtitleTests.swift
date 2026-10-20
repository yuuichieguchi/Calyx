import XCTest
import UserNotifications
@testable import Calyx

@MainActor
final class NotificationManagerSubtitleTests: XCTestCase {

    private var center: RecordingUserNotificationCenterClient!
    private var originalLedger: PaneNotificationLedger!
    private var manager: NotificationManager!
    private var registry: SurfaceRegistry!

    override func setUp() async throws {
        try await super.setUp()
        center = RecordingUserNotificationCenterClient()
        originalLedger = PaneNotificationLedger.shared
        PaneNotificationLedger.shared = PaneNotificationLedger(center: center)
        manager = NotificationManager()
        manager._setPermissionGrantedForTesting(true)
        registry = SurfaceRegistry()
        SurfacePropertyStore.shared.startObserving()
    }

    override func tearDown() async throws {
        SurfacePropertyStore.shared._testReset()
        SurfaceLocator.shared._testReset()
        registry = nil
        PaneNotificationLedger.shared = originalLedger
        manager = nil
        center = nil
        try await super.tearDown()
    }

    private func registerPane() -> (UUID, SurfaceView) {
        let paneID = UUID()
        let view = SurfaceView(frame: .zero)
        registry._testInsert(view: view, id: paneID)
        return (paneID, view)
    }

    private func setTitle(_ title: String, on view: SurfaceView) {
        NotificationCenter.default.post(name: .ghosttySetTitle, object: view, userInfo: ["title": title])
    }

    private var lastContent: UNNotificationContent? {
        center.addedRequests.last?.content
    }

    func test_sendNotification_originPaneWithTitle_subtitleIsPaneTitle() {
        let (paneID, view) = registerPane()
        setTitle("✳ Fix login tests", on: view)

        manager.sendNotification(title: "t", body: "b", originSurfaceID: paneID)

        XCTAssertEqual(center.addedRequests.count, 1)
        XCTAssertEqual(lastContent?.subtitle, "✳ Fix login tests")
    }

    func test_sendNotification_titleWithSecret_subtitleIsRedacted() {
        let (paneID, view) = registerPane()
        let paneTitle = "export API_KEY=abc123"
        setTitle(paneTitle, on: view)

        manager.sendNotification(title: "t", body: "b", originSurfaceID: paneID)

        let subtitle = lastContent?.subtitle ?? ""
        XCTAssertFalse(subtitle.contains("abc123"))
        XCTAssertEqual(subtitle, "export API_KEY=[redacted]")
    }

    func test_sendNotification_titleWithBidiOverride_subtitleStripsBidi() {
        let (paneID, view) = registerPane()
        setTitle("build\u{202E}gnp.exe\u{202C} done", on: view)

        manager.sendNotification(title: "t", body: "b", originSurfaceID: paneID)

        let subtitle = lastContent?.subtitle ?? ""
        XCTAssertFalse(subtitle.unicodeScalars.contains("\u{202E}"))
        XCTAssertFalse(subtitle.unicodeScalars.contains("\u{202C}"))
        XCTAssertTrue(subtitle.contains("build"))
        XCTAssertTrue(subtitle.contains("done"))
    }

    func test_sendNotification_originPaneWithoutTitle_subtitleIsEmpty() {
        let (paneID, _) = registerPane()

        manager.sendNotification(title: "t", body: "b", originSurfaceID: paneID)

        XCTAssertEqual(center.addedRequests.count, 1)
        XCTAssertEqual(lastContent?.subtitle, "")
    }

    func test_sendNotification_nilOrigin_subtitleIsEmpty() {
        let (_, view) = registerPane()
        setTitle("some pane", on: view)

        manager.sendNotification(title: "t", body: "b", originSurfaceID: nil)

        XCTAssertEqual(center.addedRequests.count, 1)
        XCTAssertEqual(lastContent?.subtitle, "")
    }

    func test_sendNotification_titleChangesBetweenSends_secondSubtitleIsNewTitle() {
        let (paneID, view) = registerPane()
        setTitle("first title", on: view)
        manager.sendNotification(title: "t", body: "b", originSurfaceID: paneID)

        setTitle("second title", on: view)
        manager.sendNotification(title: "t", body: "b", originSurfaceID: paneID)

        XCTAssertEqual(center.addedRequests.count, 2)
        XCTAssertEqual(center.addedRequests.first?.content.subtitle, "first title")
        XCTAssertEqual(center.addedRequests.last?.content.subtitle, "second title")
    }

    func test_sendNotification_originPaneWithTitle_titleAndBodyUnchanged() {
        let (paneID, view) = registerPane()
        setTitle("pane title", on: view)
        let title = "Build\u{202E} finished"
        let body = "All 42 tests passed"

        manager.sendNotification(title: title, body: body, originSurfaceID: paneID)

        XCTAssertEqual(lastContent?.title, NotificationSanitizer.sanitize(title))
        XCTAssertEqual(lastContent?.body, NotificationSanitizer.sanitize(body))
        XCTAssertEqual(lastContent?.title, "Build finished")
        XCTAssertEqual(lastContent?.body, "All 42 tests passed")
    }

    func test_sendNotification_whitespaceOnlyTitle_subtitleIsEmpty() {
        let (paneID, view) = registerPane()
        setTitle("   \t  ", on: view)

        manager.sendNotification(title: "t", body: "b", originSurfaceID: paneID)

        XCTAssertEqual(center.addedRequests.count, 1)
        XCTAssertEqual(lastContent?.subtitle, "")
    }

    func test_sendNotification_titleWithSurroundingSpaces_subtitleIsTrimmed() {
        let (paneID, view) = registerPane()
        setTitle("  ✳ Fix login tests  ", on: view)

        manager.sendNotification(title: "t", body: "b", originSurfaceID: paneID)

        XCTAssertEqual(lastContent?.subtitle, "✳ Fix login tests")
    }

    func test_sendNotification_secretSplitByZeroWidthSpace_subtitleIsRedacted() {
        let (paneID, view) = registerPane()
        setTitle("export API_\u{200B}KEY=abc123", on: view)

        manager.sendNotification(title: "t", body: "b", originSurfaceID: paneID)

        let subtitle = lastContent?.subtitle ?? ""
        XCTAssertFalse(subtitle.contains("abc123"))
        XCTAssertEqual(subtitle, "export API_KEY=[redacted]")
    }

    func test_sendNotification_githubTokenStraddlingGraphemeCap_subtitleHasNoTokenBodyAndIsCapped() {
        let (paneID, view) = registerPane()
        let tokenBody = "iK2ZWeqhFWCEPyYngFb51yBMWXaSCrUZoL8g"
        setTitle(String(repeating: "x", count: 230) + " ghp_" + tokenBody, on: view)

        manager.sendNotification(title: "t", body: "b", originSurfaceID: paneID)

        let subtitle = lastContent?.subtitle ?? ""
        XCTAssertFalse(subtitle.contains(String(tokenBody.prefix(12))))
        XCTAssertLessThanOrEqual(subtitle.count, 256)
    }
}
