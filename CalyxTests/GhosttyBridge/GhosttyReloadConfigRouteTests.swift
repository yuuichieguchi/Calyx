import Foundation
import Testing
import GhosttyKit
@testable import Calyx

@MainActor
@Suite("Ghostty Reload Config Route Tests")
struct GhosttyReloadConfigRouteTests {

    private let dummyApp: ghostty_app_t = UnsafeMutableRawPointer(bitPattern: 1)!

    @Test func appSoftReappliesApp() {
        #expect(GhosttyReloadConfigRoute.route(targetTag: GHOSTTY_TARGET_APP, soft: true) == .reapplyApp)
    }

    @Test func appHardReloadsAppFromDisk() {
        #expect(GhosttyReloadConfigRoute.route(targetTag: GHOSTTY_TARGET_APP, soft: false) == .reloadAppFromDisk)
    }

    @Test func surfaceSoftReappliesSurface() {
        #expect(GhosttyReloadConfigRoute.route(targetTag: GHOSTTY_TARGET_SURFACE, soft: true) == .reapplySurface)
    }

    @Test func surfaceHardReloadsSurfaceFromDisk() {
        #expect(GhosttyReloadConfigRoute.route(targetTag: GHOSTTY_TARGET_SURFACE, soft: false) == .reloadSurfaceFromDisk)
    }

    @Test func unresolvedSurfaceReloadKeepsAppConfigManager() {
        let before = ObjectIdentifier(GhosttyAppController.shared.configManager)
        var target = ghostty_target_s()
        target.tag = GHOSTTY_TARGET_SURFACE
        var action = ghostty_action_s()
        action.tag = GHOSTTY_ACTION_RELOAD_CONFIG
        action.action.reload_config = ghostty_action_reload_config_s(soft: true)

        _ = GhosttyActionRouter.handleAction(app: dummyApp, target: target, action: action)

        #expect(ObjectIdentifier(GhosttyAppController.shared.configManager) == before)
    }
}
