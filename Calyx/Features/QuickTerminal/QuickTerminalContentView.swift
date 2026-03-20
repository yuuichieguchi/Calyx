import SwiftUI

struct QuickTerminalContentView: View {
    let splitContainerView: SplitContainerView

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @AppStorage("terminalGlassOpacity") private var glassOpacity = 0.7

    var body: some View {
        GlassEffectContainer {
            TerminalContainerView(
                splitContainerView: splitContainerView,
                reduceTransparency: reduceTransparency,
                glassOpacity: glassOpacity
            )
            .padding(.top, -1)
            .padding(.leading, 8)
            .glassEffect(.clear.tint(GlassTheme.chromeTint(for: glassOpacity)), in: .rect)
        }
        .background {
            if !reduceTransparency {
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [GlassTheme.atmosphereTop, GlassTheme.atmosphereBottom],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(
                        RadialGradient(
                            colors: [Color.cyan.opacity(0.18), Color.clear],
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
