import AppKit
import Testing
import GhosttyKit
@testable import Calyx

@MainActor
@Suite("Ghostty App Config Change Adoption Tests", .serialized)
struct GhosttyAppConfigChangeAdoptionTests {

    private let dummyApp: ghostty_app_t = UnsafeMutableRawPointer(bitPattern: 1)!

    private func makeBlackBackgroundConfig() throws -> ghostty_config_t {
        _ = GhosttyAppController.shared
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GhosttyAppConfigChangeAdoptionTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("config")
        try "background = #000000\n".write(to: file, atomically: true, encoding: .utf8)
        let config = try #require(GhosttyFFI.configNew())
        GhosttyFFI.configLoadFile(config, path: file.path)
        GhosttyFFI.configFinalize(config)
        return config
    }

    private func routeConfigChange(_ config: ghostty_config_t, targetTag: ghostty_target_tag_e) {
        var target = ghostty_target_s()
        target.tag = targetTag
        var action = ghostty_action_s()
        action.tag = GHOSTTY_ACTION_CONFIG_CHANGE
        action.action.config_change = ghostty_action_config_change_s(config: config)
        _ = GhosttyActionRouter.handleAction(app: dummyApp, target: target, action: action)
    }

    private func restore(_ original: ghostty_config_t) {
        routeConfigChange(original, targetTag: GHOSTTY_TARGET_APP)
        GhosttyFFI.configFree(original)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    }

    @Test func appTargetConfigChangeAdoptsCloneOfPassedConfig() throws {
        let original = try #require(GhosttyAppController.shared.configManager.cloneConfig())
        defer { restore(original) }
        _ = GhosttyThemeProvider.shared
        let before = ObjectIdentifier(GhosttyAppController.shared.configManager)
        let passed = try makeBlackBackgroundConfig()
        defer { GhosttyFFI.configFree(passed) }

        routeConfigChange(passed, targetTag: GHOSTTY_TARGET_APP)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        let manager = GhosttyAppController.shared.configManager
        #expect(ObjectIdentifier(manager) != before)
        #expect(manager.config != nil)
        #expect(manager.config != passed)
        let background = try #require(manager.getColor("background"))
        #expect(background.r == 0)
        #expect(background.g == 0)
        #expect(background.b == 0)
        let themeBackground = try #require(GhosttyThemeProvider.shared.ghosttyBackground.usingColorSpace(.sRGB))
        #expect(themeBackground.redComponent == 0)
        #expect(themeBackground.greenComponent == 0)
        #expect(themeBackground.blueComponent == 0)
    }

    @Test func surfaceTargetConfigChangeKeepsAppConfigManager() throws {
        let before = ObjectIdentifier(GhosttyAppController.shared.configManager)
        let passed = try makeBlackBackgroundConfig()
        defer { GhosttyFFI.configFree(passed) }

        routeConfigChange(passed, targetTag: GHOSTTY_TARGET_SURFACE)

        #expect(ObjectIdentifier(GhosttyAppController.shared.configManager) == before)
    }
}
