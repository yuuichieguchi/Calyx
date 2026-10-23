import AppKit
import Testing
import GhosttyKit
@testable import Calyx

extension GhosttySharedAppConfigTests {
    @MainActor
    @Suite("GhosttyThemeProvider foreground color Tests")
    struct GhosttyThemeProviderTests {

        private func expectForegroundIsA0B0C0() throws {
            let actual = try #require(GhosttyThemeProvider.shared.ghosttyForeground.usingColorSpace(.sRGB))
            #expect(abs(actual.redComponent - 0xa0 / 255.0) < 0.01)
            #expect(abs(actual.greenComponent - 0xb0 / 255.0) < 0.01)
            #expect(abs(actual.blueComponent - 0xc0 / 255.0) < 0.01)
        }

        @Test("ghosttyForeground property exists and returns an NSColor")
        func ghosttyForegroundPropertyExistsAndReturnsNSColor() {
            let provider = GhosttyThemeProvider.shared
            let foreground: NSColor = provider.ghosttyForeground
            #expect(foreground is NSColor,
                    "ghosttyForeground must be an NSColor instance")
        }

        @Test func foregroundFollowsConfigWithExplicitBackgroundAndForeground() throws {
            let original = try #require(GhosttyAppController.shared.configManager.cloneConfig())
            defer { GhosttyAppConfigFixture.restore(original) }
            _ = GhosttyThemeProvider.shared
            let passed = try GhosttyAppConfigFixture.makeConfig(contents: "background = #102030\nforeground = #a0b0c0\n")
            defer { GhosttyFFI.configFree(passed) }

            GhosttyAppConfigFixture.routeConfigChange(passed)
            GhosttyAppConfigFixture.settleMainRunLoop()

            try expectForegroundIsA0B0C0()
        }

        @Test func foregroundFollowsConfigWhenBackgroundIsLibghosttyDefault() throws {
            let original = try #require(GhosttyAppController.shared.configManager.cloneConfig())
            defer { GhosttyAppConfigFixture.restore(original) }
            _ = GhosttyThemeProvider.shared
            let passed = try GhosttyAppConfigFixture.makeConfig(contents: "foreground = #a0b0c0\n")
            defer { GhosttyFFI.configFree(passed) }

            GhosttyAppConfigFixture.routeConfigChange(passed)
            GhosttyAppConfigFixture.settleMainRunLoop()

            let background = try #require(GhosttyAppController.shared.configManager.getColor("background"))
            #expect(background.r == 0x28)
            #expect(background.g == 0x2c)
            #expect(background.b == 0x34)
            try expectForegroundIsA0B0C0()
        }
    }
}
