import UserNotifications
import os

private let logger = Logger(subsystem: "com.calyx.terminal", category: "UserNotificationCenterClient")

@MainActor
protocol UserNotificationCenterClient {
    func add(_ request: UNNotificationRequest)
    func removePendingNotificationRequests(withIdentifiers identifiers: [String])
    func removeDeliveredNotifications(withIdentifiers identifiers: [String])
}

@MainActor
struct SystemUserNotificationCenterClient: UserNotificationCenterClient {
    func add(_ request: UNNotificationRequest) {
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                logger.error("Failed to deliver notification: \(error.localizedDescription)")
            }
        }
    }

    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    func removeDeliveredNotifications(withIdentifiers identifiers: [String]) {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: identifiers)
    }
}
