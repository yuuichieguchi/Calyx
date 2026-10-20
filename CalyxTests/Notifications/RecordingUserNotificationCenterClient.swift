import UserNotifications
@testable import Calyx

@MainActor
final class RecordingUserNotificationCenterClient: UserNotificationCenterClient {
    private(set) var addedRequests: [UNNotificationRequest] = []
    private(set) var removedPendingCalls: [[String]] = []
    private(set) var removedDeliveredCalls: [[String]] = []

    var addedIdentifiers: [String] { addedRequests.map(\.identifier) }
    var removedPendingIdentifiers: Set<String> { Set(removedPendingCalls.flatMap { $0 }) }
    var removedDeliveredIdentifiers: Set<String> { Set(removedDeliveredCalls.flatMap { $0 }) }
    var removalCallCount: Int { removedPendingCalls.count + removedDeliveredCalls.count }

    func add(_ request: UNNotificationRequest) {
        addedRequests.append(request)
    }

    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
        removedPendingCalls.append(identifiers)
    }

    func removeDeliveredNotifications(withIdentifiers identifiers: [String]) {
        removedDeliveredCalls.append(identifiers)
    }

    func resetRemovals() {
        removedPendingCalls.removeAll()
        removedDeliveredCalls.removeAll()
    }
}

func makeNotificationRequest(identifier: String = UUID().uuidString) -> UNNotificationRequest {
    let content = UNMutableNotificationContent()
    content.title = "t"
    return UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
}
