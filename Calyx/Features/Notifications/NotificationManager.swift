import AppKit
import UserNotifications
import os

private let logger = Logger(subsystem: "com.calyx.terminal", category: "NotificationManager")

@MainActor
class NotificationManager {

    #if DEBUG
    static var shared = NotificationManager()
    #else
    static let shared = NotificationManager()
    #endif

    private var rateLimiter = RateLimiter(maxPerSecond: 5)

    #if DEBUG
    init() {}
    #else
    private init() {}
    #endif

    func sendNotification(title: String, body: String, originSurfaceID: UUID?) {
        deliverNotification(title: title, cleanedBody: NotificationSanitizer.sanitize(body), originSurfaceID: originSurfaceID)
    }

    func sendNotification(title: String, redactingSecretsIn body: String, originSurfaceID: UUID?) {
        deliverNotification(
            title: title,
            cleanedBody: NotificationSanitizer.sanitizeRedactingSecrets(body),
            originSurfaceID: originSurfaceID
        )
    }

    private func deliverNotification(title: String, cleanedBody: String, originSurfaceID: UUID?) {
        let content = UNMutableNotificationContent()
        content.title = NotificationSanitizer.sanitize(title)
        content.body = cleanedBody
        content.subtitle = paneSubtitle(for: originSurfaceID)
        content.sound = .default
        if let originSurfaceID {
            content.userInfo = NotificationOrigin.userInfo(surfaceID: originSurfaceID)
        }

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )

        PaneNotificationLedger.shared.deliverIfAuthorized(request, originSurfaceID: originSurfaceID) {
            self.spendRateBudget(for: originSurfaceID)
        }
    }

    private func spendRateBudget(for originSurfaceID: UUID?) -> Bool {
        guard let originSurfaceID else { return true }
        guard rateLimiter.allow(key: originSurfaceID) else {
            logger.debug("Rate limited notification for surface \(originSurfaceID)")
            return false
        }
        return true
    }

    private func paneSubtitle(for originSurfaceID: UUID?) -> String {
        guard let originSurfaceID,
              let paneTitle = SurfacePropertyStore.shared.title(for: originSurfaceID) else { return "" }
        return NotificationSanitizer.sanitizeRedactingSecrets(paneTitle).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func bounceDockIcon() {
        NSApp.requestUserAttention(.informationalRequest)
    }
}

struct RateLimiter {
    let maxPerSecond: Int
    private var windows: [UUID: [Date]]

    init(maxPerSecond: Int) {
        self.maxPerSecond = maxPerSecond
        self.windows = [:]
    }

    mutating func allow(key: UUID) -> Bool {
        let now = Date()
        let cutoff = now.addingTimeInterval(-1)

        var recent = windows[key, default: []]
        recent = recent.filter { $0 > cutoff }

        if recent.count >= maxPerSecond {
            windows[key] = recent
            return false
        }

        recent.append(now)
        windows[key] = recent
        return true
    }
}
