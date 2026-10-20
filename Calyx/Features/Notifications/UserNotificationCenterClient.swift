import UserNotifications
import os

private let logger = Logger(subsystem: "com.calyx.terminal", category: "UserNotificationCenterClient")

@MainActor
protocol UserNotificationCenterClient {
    func add(_ request: UNNotificationRequest)
    func removePendingNotificationRequests(withIdentifiers identifiers: [String])
    func removeDeliveredNotifications(withIdentifiers identifiers: [String])
    func getAuthorizationStatus(_ completion: @escaping @MainActor (UNAuthorizationStatus) -> Void)
    func requestAuthorization(_ completion: @escaping @MainActor (Bool) -> Void)
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

    func getAuthorizationStatus(_ completion: @escaping @MainActor (UNAuthorizationStatus) -> Void) {
        guard Self.mayReachSystemCenter else {
            completion(.denied)
            return
        }
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let status = settings.authorizationStatus
            Task { @MainActor in
                completion(status)
            }
        }
    }

    func requestAuthorization(_ completion: @escaping @MainActor (Bool) -> Void) {
        guard Self.mayReachSystemCenter else {
            completion(false)
            return
        }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error {
                logger.error("Notification permission error: \(error.localizedDescription)")
            }
            Task { @MainActor in
                completion(granted)
            }
        }
    }

    private static var mayReachSystemCenter: Bool {
        !TestEnvironment.isTestHost && !ProcessInfo.processInfo.arguments.contains("--uitesting")
    }
}
