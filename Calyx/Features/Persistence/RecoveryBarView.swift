// RecoveryBarView.swift
// Calyx
//
// Chrome-style in-app "your previous session was preserved" bar,
// shown at the top of a window's content when `model.showRecoveryBar`
// is true (see RecoveryBarModel's own file header for the full
// design-decision writeup). Hosted as the first child of
// MainContentView's top-level VStack, above the tab bar/pane content --
// never intercepts first responder/keyboard focus, since neither the
// bar nor its buttons are ever made first responder by any code path.

import SwiftUI

struct RecoveryBarView: View {
    let model: RecoveryBarModel

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        HStack(spacing: 12) {
            Text("Your previous session was preserved.")
                .font(.callout)

            Spacer()

            Button("Restore") {
                model.restore()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .accessibilityIdentifier(AccessibilityID.RecoveryBar.restoreButton)

            Button("Dismiss") {
                model.dismiss()
            }
            .controlSize(.small)
            .accessibilityIdentifier(AccessibilityID.RecoveryBar.dismissButton)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .modifier(RecoveryBarBackgroundModifier(reduceTransparency: reduceTransparency))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.RecoveryBar.container)
    }
}

/// Same glass-chrome treatment as `TabBarContentView`'s own
/// `TabBarBackgroundModifier` (the closest existing precedent: another
/// horizontal bar sitting directly above/adjacent to the tab strip,
/// bottom-edge-separated from what follows it) -- ties this bar's tint
/// to the user's theme color + glass opacity instead of a fixed
/// `.thinMaterial`, so it reads as part of the window chrome rather
/// than a foreign overlay.
private struct RecoveryBarBackgroundModifier: ViewModifier {
    let reduceTransparency: Bool
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

    private var chromeScheme: ColorScheme {
        let tint = GlassTheme.chromeTint(for: themeColor, glassOpacity: glassOpacity)
        return ColorLuminance.prefersDarkText(for: tint) ? .light : .dark
    }

    func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .background(Color(nsColor: .windowBackgroundColor))
                .overlay(alignment: .bottom) { Divider() }
        } else {
            content
                .glassEffect(.clear.tint(Color(nsColor: GlassTheme.chromeTint(for: themeColor, glassOpacity: glassOpacity))), in: .rect)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(GlassTheme.specularStroke.opacity(0.28))
                        .frame(height: 1)
                }
                .environment(\.colorScheme, chromeScheme)
                .foregroundStyle(themePreset == "ghostty"
                    ? AnyShapeStyle(Color(nsColor: ghosttyProvider.ghosttyForeground))
                    : AnyShapeStyle(.primary))
        }
    }
}
