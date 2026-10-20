import XCTest
import UserNotifications
@testable import Calyx

@MainActor
final class PaneNotificationLedgerTests: XCTestCase {

    private var center: RecordingUserNotificationCenterClient!
    private var ledger: PaneNotificationLedger!
    private let paneA = UUID()
    private let paneB = UUID()

    override func setUp() {
        super.setUp()
        center = RecordingUserNotificationCenterClient()
        center.authorizationStatus = .authorized
        ledger = PaneNotificationLedger(center: center)
        ledger.deliverIfAuthorized(makeNotificationRequest(identifier: "a1"), originSurfaceID: paneA, admit: { true })
        ledger.deliverIfAuthorized(makeNotificationRequest(identifier: "a2"), originSurfaceID: paneA, admit: { true })
        ledger.deliverIfAuthorized(makeNotificationRequest(identifier: "b1"), originSurfaceID: paneB, admit: { true })
        ledger.deliverIfAuthorized(makeNotificationRequest(identifier: "n1"), originSurfaceID: nil, admit: { true })
    }

    override func tearDown() {
        ledger = nil
        center = nil
        super.tearDown()
    }

    func test_deliver_everyRequest_isAddedToCenter() {
        XCTAssertEqual(center.addedIdentifiers, ["a1", "a2", "b1", "n1"])
    }

    func test_removeNotifications_paneA_removesExactlyItsPendingAndDelivered() {
        ledger.removeNotifications(originatingIn: [paneA])

        XCTAssertEqual(center.removedPendingIdentifiers, ["a1", "a2"])
        XCTAssertEqual(center.removedDeliveredIdentifiers, ["a1", "a2"])
    }

    func test_removeNotifications_paneAAgain_makesNoCenterCall() {
        ledger.removeNotifications(originatingIn: [paneA])
        center.resetRemovals()

        ledger.removeNotifications(originatingIn: [paneA])

        XCTAssertEqual(center.removalCallCount, 0)
    }

    func test_removeNotifications_unknownPane_makesNoCenterCall() {
        ledger.removeNotifications(originatingIn: [UUID()])

        XCTAssertEqual(center.removalCallCount, 0)
    }

    func test_removeAllPaneNotifications_removesPaneOriginsButNotNilOrigin() {
        ledger.removeAllPaneNotifications()

        XCTAssertEqual(center.removedPendingIdentifiers, ["a1", "a2", "b1"])
        XCTAssertEqual(center.removedDeliveredIdentifiers, ["a1", "a2", "b1"])
    }

    func test_startObserving_surfaceDestroyed_removesThatPanesNotifications() {
        ledger.startObserving()
        ledger.startObserving()

        NotificationCenter.default.post(name: .calyxSurfaceDestroyed, object: nil, userInfo: ["surfaceID": paneA])

        XCTAssertEqual(center.removedPendingIdentifiers, ["a1", "a2"])
        XCTAssertEqual(center.removedDeliveredIdentifiers, ["a1", "a2"])
        XCTAssertEqual(center.removedPendingCalls.count, 1)
    }
}
