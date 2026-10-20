import UserNotifications
@testable import Calyx

@MainActor
final class RecordingUserNotificationCenterClient: UserNotificationCenterClient {
    private(set) var addedRequests: [UNNotificationRequest] = []
    private(set) var removedPendingCalls: [[String]] = []
    private(set) var removedDeliveredCalls: [[String]] = []
    private(set) var authorizationStatusQueryCount = 0
    private(set) var authorizationRequestCount = 0
    private var pendingAuthorizationCompletions: [@MainActor (Bool) -> Void] = []
    private var pendingAuthorizationStatusCompletions: [@MainActor (UNAuthorizationStatus) -> Void] = []

    var authorizationStatus: UNAuthorizationStatus = .notDetermined
    var defersAuthorizationStatus = false

    var addedIdentifiers: [String] { addedRequests.map(\.identifier) }
    var removedPendingIdentifiers: Set<String> { Set(removedPendingCalls.flatMap { $0 }) }
    var removedDeliveredIdentifiers: Set<String> { Set(removedDeliveredCalls.flatMap { $0 }) }
    var removalCallCount: Int { removedPendingCalls.count + removedDeliveredCalls.count }

    func add(_ request: UNNotificationRequest) {
        addedRequests.append(request)
    }

    func getAuthorizationStatus(_ completion: @escaping @MainActor (UNAuthorizationStatus) -> Void) {
        authorizationStatusQueryCount += 1
        if defersAuthorizationStatus {
            pendingAuthorizationStatusCompletions.append(completion)
        } else {
            completion(authorizationStatus)
        }
    }

    func resolvePendingAuthorizationStatus() {
        let completions = pendingAuthorizationStatusCompletions
        pendingAuthorizationStatusCompletions.removeAll()
        completions.forEach { $0(authorizationStatus) }
    }

    func requestAuthorization(_ completion: @escaping @MainActor (Bool) -> Void) {
        authorizationRequestCount += 1
        pendingAuthorizationCompletions.append(completion)
    }

    func resolvePendingAuthorization(granted: Bool) {
        authorizationStatus = granted ? .authorized : .denied
        let completions = pendingAuthorizationCompletions
        pendingAuthorizationCompletions.removeAll()
        completions.forEach { $0(granted) }
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
