
import XCTest
@testable import Calyx

@MainActor
final class GhosttyAppControllerConfigReloadOrderingTests: XCTestCase {

    func test_reloadConfig_configChangeObserver_seesFreshConfigManagerNotStaleOne() {
        let controller = GhosttyAppController.shared
        let beforeReload = ObjectIdentifier(controller.configManager)

        var configManagerSeenByObserver: ObjectIdentifier?
        let observer = NotificationCenter.default.addObserver(
            forName: .ghosttyConfigChange, object: nil, queue: nil
        ) { _ in
            MainActor.assumeIsolated {
                configManagerSeenByObserver = ObjectIdentifier(controller.configManager)
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        controller.reloadConfig()

        XCTAssertNotNil(
            configManagerSeenByObserver,
            "Precondition: reloadConfig must actually deliver .ghosttyConfigChange synchronously for this test to " +
            "mean anything (requires GhosttyAppController.shared.app to be non-nil in this test host)"
        )
        XCTAssertNotEqual(
            configManagerSeenByObserver,
            beforeReload,
            ".ghosttyConfigChange observers must already see the FRESH configManager, not the stale pre-reload " +
            "one, while the notification is being delivered mid-reload"
        )
    }

    func test_reloadConfig_afterReturning_configManagerIsFreshInstance() {
        let controller = GhosttyAppController.shared
        let beforeReload = ObjectIdentifier(controller.configManager)

        controller.reloadConfig()

        XCTAssertNotEqual(
            ObjectIdentifier(controller.configManager),
            beforeReload,
            "reloadConfig must swap configManager to a freshly loaded instance"
        )
    }
}
