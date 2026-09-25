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
    @AppStorage("terminalGlassOpacity") private var glassOpacity = Self.defaultGlassOpacity
    @AppStorage("themeColorPreset") private var themePreset = Self.defaultThemePreset
    @AppStorage("themeColorCustomHex") private var customHex = Self.defaultCustomHex
    @State private var ghosttyProvider = GhosttyThemeProvider.shared

    /// Backdrop alpha: opaque enough that cards read cleanly over the
    /// terminal, translucent enough that the window underneath still
    /// shows through.
    private static let backdropAlpha: CGFloat = 0.88

    /// The `@AppStorage` defaults, shared with the other Mission Map
    /// surfaces that read the theme (`MissionMapEdgePopover`).
    static let defaultGlassOpacity = 0.7
    static let defaultThemePreset = "original"
    static let defaultCustomHex = "#050D1C"

    /// The theme's chrome tint: the backdrop's color here, and the
    /// emphasized popover's glass tint.
    static func chromeTint(
        themePreset: String, customHex: String, ghosttyBackground: NSColor, glassOpacity: Double
    ) -> NSColor {
        let themeColor = ThemeColorPreset.resolve(
            preset: themePreset,
            customHex: customHex,
            ghosttyBackground: ghosttyBackground
        )
        return GlassTheme.chromeTint(for: themeColor, glassOpacity: glassOpacity)
    }

    private var chromeTint: NSColor {
        Self.chromeTint(
            themePreset: themePreset, customHex: customHex,
            ghosttyBackground: ghosttyProvider.ghosttyBackground, glassOpacity: glassOpacity
        )
    }

    private var chromeScheme: ColorScheme {
        Self.chromeScheme(for: chromeTint)
    }

    /// The color scheme text over `tint` uses: light or dark from the
    /// tint's luminance.
    static func chromeScheme(for tint: NSColor) -> ColorScheme {
        ColorLuminance.prefersDarkText(for: tint) ? .light : .dark
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
