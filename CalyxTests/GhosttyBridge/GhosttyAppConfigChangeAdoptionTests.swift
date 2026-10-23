import AppKit
import Testing
import GhosttyKit
@testable import Calyx

extension GhosttySharedAppConfigTests {
    @MainActor
    @Suite("Ghostty App Config Change Adoption Tests")
    struct GhosttyAppConfigChangeAdoptionTests {

        @Test func appTargetConfigChangeAdoptsCloneOfPassedConfig() throws {
            let original = try #require(GhosttyAppController.shared.configManager.cloneConfig())
            defer { GhosttyAppConfigFixture.restore(original) }
            _ = GhosttyThemeProvider.shared
            let before = ObjectIdentifier(GhosttyAppController.shared.configManager)
            let passed = try GhosttyAppConfigFixture.makeConfig(contents: "background = #000000\n")
            defer { GhosttyFFI.configFree(passed) }

            GhosttyAppConfigFixture.routeConfigChange(passed)
            GhosttyAppConfigFixture.settleMainRunLoop()

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
            let passed = try GhosttyAppConfigFixture.makeConfig(contents: "background = #000000\n")
            defer { GhosttyFFI.configFree(passed) }

            GhosttyAppConfigFixture.routeConfigChange(passed, targetTag: GHOSTTY_TARGET_SURFACE)

            #expect(ObjectIdentifier(GhosttyAppController.shared.configManager) == before)
        }
    }
}
