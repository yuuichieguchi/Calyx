import SwiftUI
import AppKit

struct QuickTerminalContentView: View {
    let splitContainerView: SplitContainerView

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @AppStorage("terminalGlassOpacity") private var glassOpacity = 0.7
    @AppStorage("themeColorPreset") private var themePreset = "original"
    @AppStorage("themeColorCustomHex") private var customHex = "#050D1C"
    @State private var ghosttyProvider = GhosttyThemeProvider.shared

    private var themeColor: NSColor {
        ThemeColorPreset.resolve(
            preset: themePreset,
            customHex: customHex,
            ghosttyBackground: ghosttyProvider.ghosttyBackground
        )
    }

    var body: some View {
        GlassEffectContainer {
            TerminalContainerView(
                splitContainerView: splitContainerView,
                reduceTransparency: reduceTransparency,
                glassOpacity: glassOpacity
            )
            .padding(.top, -1)
            .padding(.leading, 8)
            .stableGlassTint(Color(nsColor: GlassTheme.chromeTint(for: themeColor, glassOpacity: glassOpacity)))
        }
        .environment(\.controlActiveState, .key)
        .background {
            if !reduceTransparency {
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [Color(nsColor: GlassTheme.atmosphereTop(for: themeColor, glassOpacity: glassOpacity)), Color(nsColor: GlassTheme.atmosphereBottom(for: themeColor, glassOpacity: glassOpacity))],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(
                        RadialGradient(
                            colors: [Color(nsColor: GlassTheme.accentGradient(for: themeColor)), Color.clear],
                            center: .bottomTrailing,
                            startRadius: 20,
                            endRadius: 420
                        )
                    )
                    .ignoresSafeArea()
            }
        }
    }
}
