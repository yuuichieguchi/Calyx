import XCTest
import UserNotifications
@testable import Calyx

@MainActor
final class NotificationClickRouterTests: XCTestCase {

    func test_notificationOrigin_roundTrip_returnsSameSurfaceID() {
        let id = UUID()

        let userInfo = NotificationOrigin.userInfo(surfaceID: id)

        XCTAssertEqual(userInfo[NotificationOrigin.userInfoKey] as? String, id.uuidString)
        XCTAssertEqual(NotificationOrigin.surfaceID(in: userInfo), id)
    }

    func test_notificationOrigin_missingKey_returnsNil() {
        XCTAssertNil(NotificationOrigin.surfaceID(in: [:]))
    }

    func test_notificationOrigin_invalidString_returnsNil() {
        XCTAssertNil(NotificationOrigin.surfaceID(in: [NotificationOrigin.userInfoKey: "not-a-uuid"]))
    }

    func test_surfaceIDToFocus_defaultActionWithOrigin_returnsOriginSurfaceID() {
        let id = UUID()

        let result = NotificationClickRouter.surfaceIDToFocus(
            actionIdentifier: UNNotificationDefaultActionIdentifier,
            userInfo: NotificationOrigin.userInfo(surfaceID: id)
        )

        XCTAssertEqual(result, id)
    }

    func test_surfaceIDToFocus_dismissActionWithOrigin_returnsNil() {
        let result = NotificationClickRouter.surfaceIDToFocus(
            actionIdentifier: UNNotificationDismissActionIdentifier,
            userInfo: NotificationOrigin.userInfo(surfaceID: UUID())
        )

        XCTAssertNil(result)
    }

    func test_surfaceIDToFocus_customActionWithOrigin_returnsNil() {
        let result = NotificationClickRouter.surfaceIDToFocus(
            actionIdentifier: "com.calyx.custom-action",
            userInfo: NotificationOrigin.userInfo(surfaceID: UUID())
        )

        XCTAssertNil(result)
    }

    func test_surfaceIDToFocus_defaultActionWithEmptyUserInfo_returnsNil() {
        let result = NotificationClickRouter.surfaceIDToFocus(
            actionIdentifier: UNNotificationDefaultActionIdentifier,
            userInfo: [:]
        )

        XCTAssertNil(result)
    }

    func test_surfaceIDToFocus_defaultActionWithInvalidOrigin_returnsNil() {
        let result = NotificationClickRouter.surfaceIDToFocus(
            actionIdentifier: UNNotificationDefaultActionIdentifier,
            userInfo: [NotificationOrigin.userInfoKey: "not-a-uuid"]
        )

        XCTAssertNil(result)
    }
}
