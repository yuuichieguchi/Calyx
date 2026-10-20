import Foundation
import UserNotifications

@MainActor
final class PaneNotificationLedger: NSObject {

    #if DEBUG
    static var shared = PaneNotificationLedger()
    #else
    static let shared = PaneNotificationLedger()
    #endif

    private struct AwaitingDelivery {
        let request: UNNotificationRequest
        let originSurfaceID: UUID?
        let admit: @MainActor () -> Bool
    }

    private let center: UserNotificationCenterClient
    private var identifiersBySurfaceID: [UUID: [String]] = [:]
    private var awaitingDeliveries: [UUID: AwaitingDelivery] = [:]
    private var tokensAwaitingAuthorization: [UUID] = []
    private var isRequestingAuthorization = false
    private var isObserving = false

    init(center: UserNotificationCenterClient = SystemUserNotificationCenterClient()) {
        self.center = center
        super.init()
    }

    func deliverIfAuthorized(
        _ request: UNNotificationRequest,
        originSurfaceID: UUID?,
        admit: @escaping @MainActor () -> Bool
    ) {
        let token = UUID()
        awaitingDeliveries[token] = AwaitingDelivery(request: request, originSurfaceID: originSurfaceID, admit: admit)
        center.getAuthorizationStatus { status in
            switch status {
            case .authorized, .provisional, .ephemeral:
                self.finishAwaitingDelivery(token, granted: true)
            case .notDetermined:
                self.awaitAuthorization(token)
            case .denied:
                self.finishAwaitingDelivery(token, granted: false)
            @unknown default:
                self.finishAwaitingDelivery(token, granted: false)
            }
        }
    }

    private func awaitAuthorization(_ token: UUID) {
        guard awaitingDeliveries[token] != nil else { return }
        tokensAwaitingAuthorization.append(token)
        guard !isRequestingAuthorization else { return }
        isRequestingAuthorization = true
        center.requestAuthorization { granted in
            self.isRequestingAuthorization = false
            let tokens = self.tokensAwaitingAuthorization
            self.tokensAwaitingAuthorization.removeAll()
            tokens.forEach { self.finishAwaitingDelivery($0, granted: granted) }
        }
    }

    private func finishAwaitingDelivery(_ token: UUID, granted: Bool) {
        guard let delivery = awaitingDeliveries.removeValue(forKey: token), granted, delivery.admit() else { return }
        if let originSurfaceID = delivery.originSurfaceID {
            identifiersBySurfaceID[originSurfaceID, default: []].append(delivery.request.identifier)
        }
        center.add(delivery.request)
    }

    func removeNotifications(originatingIn surfaceIDs: [UUID]) {
        let removedOrigins = Set(surfaceIDs)
        awaitingDeliveries = awaitingDeliveries.filter { _, delivery in
            delivery.originSurfaceID.map { !removedOrigins.contains($0) } ?? true
        }
        let identifiers = surfaceIDs.flatMap { identifiersBySurfaceID.removeValue(forKey: $0) ?? [] }
        removeFromCenter(identifiers)
    }

    func removeAllPaneNotifications() {
        let identifiers = identifiersBySurfaceID.values.flatMap { $0 }
        identifiersBySurfaceID.removeAll()
        awaitingDeliveries = awaitingDeliveries.filter { _, delivery in delivery.originSurfaceID == nil }
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
