// GhosttyThemeProvider.swift
// Calyx
//
// Bridges Ghostty config background color to SwiftUI theme color system.

import AppKit
import GhosttyKit

@MainActor
@Observable
final class GhosttyThemeProvider {
    static let shared = GhosttyThemeProvider()

    private(set) var ghosttyBackground: NSColor = ThemeColorPreset.ghostty.color
    nonisolated(unsafe) private var observer: Any?

    private init() {
        refreshFromConfig()
        observer = NotificationCenter.default.addObserver(
            forName: .ghosttyConfigChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshFromConfig() }
        }
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func refreshFromConfig() {
        guard let raw = GhosttyAppController.shared.configManager.getColor("background") else {
            ghosttyBackground = ThemeColorPreset.ghostty.color
            return
        }
        ghosttyBackground = NSColor(
            red: CGFloat(raw.r) / 255.0,
            green: CGFloat(raw.g) / 255.0,
            blue: CGFloat(raw.b) / 255.0,
            alpha: 1.0
        )
    }
}
