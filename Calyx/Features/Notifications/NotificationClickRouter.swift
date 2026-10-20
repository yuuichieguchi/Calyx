import Foundation
import UserNotifications

final class NotificationClickRouter: NSObject, UNUserNotificationCenterDelegate {

    nonisolated static func surfaceIDToFocus(actionIdentifier: String, userInfo: [AnyHashable: Any]) -> UUID? {
        guard actionIdentifier == UNNotificationDefaultActionIdentifier else { return nil }
        return NotificationOrigin.surfaceID(in: userInfo)
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let surfaceID = Self.surfaceIDToFocus(
            actionIdentifier: response.actionIdentifier,
            userInfo: response.notification.request.content.userInfo
        )
        if let surfaceID {
            Task { @MainActor in
                Self.postFocusSurface(surfaceID)
            }
        }
        completionHandler()
    }

    @MainActor
    private static func postFocusSurface(_ surfaceID: UUID) {
        NotificationCenter.default.post(name: .calyxFocusSurface, object: nil, userInfo: ["surfaceID": surfaceID])
    }
}
