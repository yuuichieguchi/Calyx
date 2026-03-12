import AppKit
import os
#if canImport(Sparkle)
import Sparkle
#endif

@MainActor
final class UpdateController: NSObject {
    static let shared = UpdateController()

    private let logger = Logger(subsystem: "com.calyx.terminal", category: "Update")
    private let installSource: InstallSource

    #if canImport(Sparkle)
    private var updaterController: SPUStandardUpdaterController?
    #endif

    var isHomebrew: Bool { installSource.isHomebrew }

    private override init() {
        self.installSource = InstallSource(bundleURL: Bundle.main.bundleURL)
        super.init()

        if !isHomebrew {
            setupSparkle()
        } else {
            logger.info("Homebrew installation detected — Sparkle updater disabled")
        }
    }

    private func setupSparkle() {
        #if canImport(Sparkle)
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
        logger.info("Sparkle updater initialized")
        #else
        logger.warning("Sparkle framework not available")
        #endif
    }

    func checkForUpdates() {
        #if canImport(Sparkle)
        updaterController?.checkForUpdates(nil)
        logger.info("Manual update check initiated")
        #else
        logger.warning("Cannot check for updates — Sparkle not available")
        #endif
    }

    var canCheckForUpdates: Bool {
        #if canImport(Sparkle)
        return updaterController?.updater.canCheckForUpdates ?? false
        #else
        return false
        #endif
    }
}

#if canImport(Sparkle)
extension UpdateController: SPUUpdaterDelegate {
    nonisolated func updater(_ updater: SPUUpdater, didFinishLoading appcast: SUAppcast) {
        let logger = Logger(subsystem: "com.calyx.terminal", category: "Update")
        logger.info("Appcast loaded: \(appcast.items.count) item(s)")
    }

    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let logger = Logger(subsystem: "com.calyx.terminal", category: "Update")
        logger.info("Update available: \(item.displayVersionString)")
    }

    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: any Error) {
        let logger = Logger(subsystem: "com.calyx.terminal", category: "Update")
        logger.info("No update found: \(error.localizedDescription)")
    }

    nonisolated func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        let logger = Logger(subsystem: "com.calyx.terminal", category: "Update")
        logger.error("Updater error: \(error.localizedDescription)")
    }
}
#endif
