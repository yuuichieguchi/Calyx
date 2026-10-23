import Foundation
import Testing
import GhosttyKit
@testable import Calyx

@MainActor
@Suite("Ghostty Shared App Config Tests", .serialized)
struct GhosttySharedAppConfigTests {}

@MainActor
enum GhosttyAppConfigFixture {

    static let dummyApp: ghostty_app_t = UnsafeMutableRawPointer(bitPattern: 1)!

    static func makeConfig(contents: String) throws -> ghostty_config_t {
        _ = GhosttyAppController.shared
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GhosttyAppConfigFixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("config")
        try contents.write(to: file, atomically: true, encoding: .utf8)
        let config = try #require(GhosttyFFI.configNew())
        GhosttyFFI.configLoadFile(config, path: file.path)
        GhosttyFFI.configFinalize(config)
        return config
    }

    static func routeConfigChange(_ config: ghostty_config_t, targetTag: ghostty_target_tag_e = GHOSTTY_TARGET_APP) {
        var target = ghostty_target_s()
        target.tag = targetTag
        var action = ghostty_action_s()
        action.tag = GHOSTTY_ACTION_CONFIG_CHANGE
        action.action.config_change = ghostty_action_config_change_s(config: config)
        _ = GhosttyActionRouter.handleAction(app: dummyApp, target: target, action: action)
    }

    static func settleMainRunLoop() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    }

    static func restore(_ original: ghostty_config_t) {
        routeConfigChange(original)
        GhosttyFFI.configFree(original)
        settleMainRunLoop()
    }
}
