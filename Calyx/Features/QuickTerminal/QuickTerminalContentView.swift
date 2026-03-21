import SwiftUI
import AppKit

struct QuickTerminalContentView: View {
    let splitContainerView: SplitContainerView

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @AppStorage("terminalGlassOpacity") private var glassOpacity = 0.7
    @AppStorage("themeColorPreset") private var themePreset = "original"
    @AppStorage("themeColorCustomHex") private var customHex = "#050D1C"

    private var themeColor: NSColor {
        ThemeColorPreset.resolve(preset: themePreset, customHex: customHex)
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
            .glassEffect(.clear.tint(Color(nsColor: GlassTheme.chromeTint(for: themeColor, glassOpacity: glassOpacity))), in: .rect)
        }
        .background {
            if !reduceTransparency {
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [Color(nsColor: GlassTheme.atmosphereTop(for: themeColor)), Color(nsColor: GlassTheme.atmosphereBottom(for: themeColor))],
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
