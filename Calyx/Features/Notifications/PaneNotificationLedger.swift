import Foundation
import UserNotifications

@MainActor
final class PaneNotificationLedger: NSObject {

    #if DEBUG
    static var shared = PaneNotificationLedger()
    #else
    static let shared = PaneNotificationLedger()
    #endif

    private let center: UserNotificationCenterClient
    private var identifiersBySurfaceID: [UUID: [String]] = [:]
    private var isObserving = false

    init(center: UserNotificationCenterClient = SystemUserNotificationCenterClient()) {
        self.center = center
        super.init()
    }

    func deliver(_ request: UNNotificationRequest, originSurfaceID: UUID?) {
        if let originSurfaceID {
            identifiersBySurfaceID[originSurfaceID, default: []].append(request.identifier)
        }
        center.add(request)
    }

    func removeNotifications(originatingIn surfaceIDs: [UUID]) {
        let identifiers = surfaceIDs.flatMap { identifiersBySurfaceID.removeValue(forKey: $0) ?? [] }
        removeFromCenter(identifiers)
    }

    func removeAllPaneNotifications() {
        let identifiers = identifiersBySurfaceID.values.flatMap { $0 }
        identifiersBySurfaceID.removeAll()
        removeFromCenter(identifiers)
    }

    func startObserving() {
        guard !isObserving else { return }
        isObserving = true

        NotificationCenter.default.addObserver(
            self, selector: #selector(handleSurfaceDestroyed(_:)), name: .calyxSurfaceDestroyed, object: nil
        )
    }

    @objc private func handleSurfaceDestroyed(_ notification: Notification) {
        guard let id = notification.userInfo?["surfaceID"] as? UUID else { return }
        removeNotifications(originatingIn: [id])
    }

    private func removeFromCenter(_ identifiers: [String]) {
        guard !identifiers.isEmpty else { return }
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }
}
