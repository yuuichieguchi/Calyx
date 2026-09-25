// MissionMapChromeModifier.swift
// Calyx
//
// Mission Map's backdrop and color scheme. Same chrome-scheme rule as the
// sidebar's `SidebarBackgroundModifier`: the backdrop is the theme's
// chrome tint, so text picks light or dark from that tint's luminance.
// With Reduce Transparency the backdrop is the opaque window background,
// matching `MainContentView`'s own root sheet.

import AppKit
import SwiftUI

struct MissionMapChromeModifier: ViewModifier {
    let reduceTransparency: Bool
    @AppStorage("terminalGlassOpacity") private var glassOpacity = 0.7
    @AppStorage("themeColorPreset") private var themePreset = "original"
    @AppStorage("themeColorCustomHex") private var customHex = "#050D1C"
    @State private var ghosttyProvider = GhosttyThemeProvider.shared

    /// Backdrop alpha: opaque enough that cards read cleanly over the
    /// terminal, translucent enough that the window underneath still
    /// shows through.
    private static let backdropAlpha: CGFloat = 0.88

    private var themeColor: NSColor {
        ThemeColorPreset.resolve(
            preset: themePreset,
            customHex: customHex,
            ghosttyBackground: ghosttyProvider.ghosttyBackground
        )
    }

    private var chromeTint: NSColor {
        GlassTheme.chromeTint(for: themeColor, glassOpacity: glassOpacity)
    }

    private var chromeScheme: ColorScheme {
        ColorLuminance.prefersDarkText(for: chromeTint) ? .light : .dark
    }

    func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(Color(nsColor: .windowBackgroundColor))
        } else {
            content
                .background(Color(nsColor: chromeTint.withAlphaComponent(Self.backdropAlpha)))
                .environment(\.colorScheme, chromeScheme)
                .foregroundStyle(themePreset == "ghostty"
                    ? AnyShapeStyle(Color(nsColor: ghosttyProvider.ghosttyForeground))
                    : AnyShapeStyle(.primary))
        }
    }
}
