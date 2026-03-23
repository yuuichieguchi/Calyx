import SwiftUI
import AppKit

struct QuickTerminalContentView: View {
    let splitContainerView: SplitContainerView

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @ObservedObject private var calyxConfig = CalyxConfig.shared
    @State private var ghosttyProvider = GhosttyThemeProvider.shared

    private var themeColor: NSColor {
        ThemeColorPreset.resolve(
            preset: calyxConfig.themeColorPreset,
            customHex: calyxConfig.themeColorCustomHex,
            ghosttyBackground: ghosttyProvider.ghosttyBackground
        )
    }

    var body: some View {
        GlassEffectContainer {
            TerminalContainerView(
                splitContainerView: splitContainerView,
                reduceTransparency: reduceTransparency,
                glassOpacity: calyxConfig.glassOpacity
            )
            .padding(.top, -1)
            .padding(.leading, 8)
            .glassEffect(.clear.tint(Color(nsColor: GlassTheme.chromeTint(for: themeColor, glassOpacity: calyxConfig.glassOpacity))), in: .rect)
        }
        .background {
            if !reduceTransparency {
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [Color(nsColor: GlassTheme.atmosphereTop(for: themeColor, glassOpacity: calyxConfig.glassOpacity)), Color(nsColor: GlassTheme.atmosphereBottom(for: themeColor, glassOpacity: calyxConfig.glassOpacity))],
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
