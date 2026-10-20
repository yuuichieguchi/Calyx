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

    private let center = UNUserNotificationCenter.current()
    private var rateLimiter = RateLimiter(maxPerSecond: 5)
    private var permissionGranted = false

    #if DEBUG
    init() {
        requestPermission()
    }
    #else
    private init() {
        requestPermission()
    }
    #endif

    #if DEBUG
    func _setPermissionGrantedForTesting(_ granted: Bool) {
        permissionGranted = granted
    }
    #endif

    private func requestPermission() {
        guard !TestEnvironment.isTestHost,
              !ProcessInfo.processInfo.arguments.contains("--uitesting") else { return }
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            Task { @MainActor in
                self.permissionGranted = granted
                if let error {
                    logger.error("Notification permission error: \(error.localizedDescription)")
                }
            }
        }
    }

    func sendNotification(title: String, body: String, originSurfaceID: UUID?) {
        guard permissionGranted else { return }

        if let originSurfaceID, !rateLimiter.allow(key: originSurfaceID) {
            logger.debug("Rate limited notification for surface \(originSurfaceID)")
            return
        }

        let content = UNMutableNotificationContent()
        content.title = NotificationSanitizer.sanitize(title)
        content.body = NotificationSanitizer.sanitize(body)
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

        PaneNotificationLedger.shared.deliver(request, originSurfaceID: originSurfaceID)
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
