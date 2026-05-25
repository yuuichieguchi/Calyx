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
    private(set) var ghosttyForeground: NSColor = .white
    private(set) var splitDividerColor: NSColor? = nil
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
            ghosttyForeground = .white
            splitDividerColor = nil
            return
        }
        ghosttyBackground = NSColor(
            red: CGFloat(raw.r) / 255.0,
            green: CGFloat(raw.g) / 255.0,
            blue: CGFloat(raw.b) / 255.0,
            alpha: 1.0
        )

        if let fg = GhosttyAppController.shared.configManager.getColor("foreground") {
            ghosttyForeground = NSColor(
                red: CGFloat(fg.r) / 255.0,
                green: CGFloat(fg.g) / 255.0,
                blue: CGFloat(fg.b) / 255.0,
                alpha: 1.0
            )
        } else {
            ghosttyForeground = .white
        }

        if let div = GhosttyAppController.shared.configManager.getColor("split-divider-color") {
            splitDividerColor = NSColor(
                red: CGFloat(div.r) / 255.0,
                green: CGFloat(div.g) / 255.0,
                blue: CGFloat(div.b) / 255.0,
                alpha: 1.0
            )
        } else {
            splitDividerColor = nil
        }
    }
}
