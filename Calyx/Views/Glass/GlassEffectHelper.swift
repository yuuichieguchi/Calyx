// GlassEffectHelper.swift
// Calyx
//
// Helper for Liquid Glass effects (AppKit layer).
// CommandPaletteView uses applyBackground(to:) — keep this public API stable.

import AppKit

enum GlassEffectHelper {

    static var isGlassAvailable: Bool {
        !reducedTransparency
    }

    static var reducedTransparency: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    }

    static func applyGlassBackground(to view: NSView) {
        guard !reducedTransparency else {
            applyFallbackBackground(to: view, color: .windowBackgroundColor)
            return
        }
        let effect = NSVisualEffectView(frame: view.bounds)
        effect.material = .headerView
        effect.blendingMode = .behindWindow
        effect.state = .followsWindowActiveState
        effect.autoresizingMask = [.width, .height]
        view.addSubview(effect, positioned: .below, relativeTo: nil)
    }

    static func applyFallbackBackground(to view: NSView, color: NSColor) {
        view.wantsLayer = true
        view.layer?.backgroundColor = color.cgColor
    }

    static func applyBackground(to view: NSView) {
        if isGlassAvailable {
            applyGlassBackground(to: view)
        } else {
            applyFallbackBackground(to: view, color: .windowBackgroundColor)
        }
    }

    /// Tint opacity for sidebar/tab bar glass effect.
    static func chromeTintOpacity(for glassOpacity: Double) -> Double {
        glassOpacity * 0.5
    }
}
