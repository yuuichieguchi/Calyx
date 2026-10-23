import Foundation
import Testing
import GhosttyKit
@testable import Calyx

@MainActor
@Suite("Ghostty Bundled Themes Tests", .serialized)
struct GhosttyBundledThemesTests {

    private var bundledGhosttyDir: URL {
        Bundle.main.resourceURL!.appendingPathComponent("ghostty", isDirectory: true)
    }

    private func isRegularFile(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && !isDirectory.boolValue
    }

    @Test func bundleContainsCatppuccinMochaTheme() {
        let url = bundledGhosttyDir.appendingPathComponent("themes/Catppuccin Mocha")
        #expect(isRegularFile(url), "missing bundled theme at \(url.path)")
    }

    @Test func bundleContainsCatppuccinLatteTheme() {
        let url = bundledGhosttyDir.appendingPathComponent("themes/Catppuccin Latte")
        #expect(isRegularFile(url), "missing bundled theme at \(url.path)")
    }

    @Test func bundleHasNoNestedGhosttyDirectory() {
        let nested = bundledGhosttyDir.appendingPathComponent("ghostty")
        #expect(!FileManager.default.fileExists(atPath: nested.path), "nested resources directory exists at \(nested.path)")
    }

    private func requireNoForeignResourcesDir() throws {
        guard let inherited = ProcessInfo.processInfo.environment["GHOSTTY_RESOURCES_DIR"] else { return }
        let inheritedPath = URL(fileURLWithPath: inherited).standardizedFileURL.path
        let ownPath = bundledGhosttyDir.standardizedFileURL.path
        if inheritedPath != ownPath {
            throw ForeignResourcesDirError(message: "GHOSTTY_RESOURCES_DIR=\(inherited) was inherited by the test host and differs from the host's own \(ownPath); ghostty would resolve themes from it, making this test meaningless. Run with `env -u GHOSTTY_RESOURCES_DIR`.")
        }
    }

    private struct ForeignResourcesDirError: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    private struct LoadedTheme {
        let background: ghostty_config_color_s?
        let diagnostics: [String]
    }

    private func loadConfig(contents: String) throws -> LoadedTheme {
        _ = GhosttyAppController.shared
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("calyx-bundled-theme-\(UUID().uuidString).conf")
        try contents.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }

        let raw = try #require(GhosttyFFI.configNew())
        defer { GhosttyFFI.configFree(raw) }
        GhosttyFFI.configLoadFile(raw, path: file.path)
        GhosttyFFI.configFinalize(raw)

        var diagnostics: [String] = []
        for index in 0..<GhosttyFFI.configDiagnosticsCount(raw) {
            diagnostics.append(String(cString: GhosttyFFI.configGetDiagnostic(raw, index: index).message))
        }
        let manager = GhosttyConfigManager(clone: raw)
        return LoadedTheme(background: manager.getColor("background"), diagnostics: diagnostics)
    }

    @Test func singleThemeResolvesFromBundle() throws {
        try requireNoForeignResourcesDir()
        let loaded = try loadConfig(contents: "theme = Catppuccin Mocha\n")
        #expect(loaded.diagnostics.filter { $0.localizedCaseInsensitiveContains("theme") || $0.contains("Catppuccin") }.isEmpty,
                "diagnostics: \(loaded.diagnostics)")
        let background = try #require(loaded.background)
        #expect(background.r == 0x1e)
        #expect(background.g == 0x1e)
        #expect(background.b == 0x2e)
    }

    @Test func conditionalThemeAppliesLightByDefault() throws {
        try requireNoForeignResourcesDir()
        let loaded = try loadConfig(contents: "theme = light:Catppuccin Latte,dark:Catppuccin Mocha\n")
        #expect(loaded.diagnostics.filter { $0.localizedCaseInsensitiveContains("theme") || $0.contains("Catppuccin") }.isEmpty,
                "diagnostics: \(loaded.diagnostics)")
        let background = try #require(loaded.background)
        #expect(background.r == 0xef)
        #expect(background.g == 0xf1)
        #expect(background.b == 0xf5)
    }
}
