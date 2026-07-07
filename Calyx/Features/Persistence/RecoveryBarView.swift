// RecoveryBarView.swift
// Calyx
//
// Chrome-style in-app "your previous session was preserved" bar,
// shown at the top of a window's content when `model.showRecoveryBar`
// is true (see RecoveryBarModel's own file header for the full
// design-decision writeup). Hosted via `MainContentView.body`'s
// `mainContent.safeAreaInset(edge: .top)`, above the tab bar/pane
// content -- never intercepts first responder/keyboard focus, since
// neither the bar nor its buttons are ever made first responder by any
// code path.

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
/// bottom-edge-separated from what follows it) -- ties this bar's
/// look to the user's theme color + glass opacity instead of a fixed
/// `.thinMaterial`, so it reads as part of the window chrome rather
/// than a foreign overlay.
///
/// Deliberately does NOT apply its own `.glassEffect(...)` tint pass
/// (unlike `TabBarBackgroundModifier`/`SidebarBackgroundModifier`,
/// which do): this bar is hosted via `mainContent.safeAreaInset(edge:
/// .top)` in `MainContentView`, and `mainContent`'s own titlebar-glass
/// overlay (the `GeometryReader`-sized rect further down in that file)
/// sizes itself from `geo.safeAreaInsets.top`, which now spans BOTH the
/// real titlebar height AND this bar's own height while it's shown --
/// so that overlay's single glassEffect tint pass already paints
/// straight through this bar's strip with the exact same
/// `GlassTheme.chromeTint(...)` formula used below. Adding a second
/// `.glassEffect` here stacked two passes of the identical tint in this
/// one strip, reading visibly darker than the single-pass chrome above
/// and below it (user-reported). This modifier now only supplies
/// text/button legibility handling; the glass surface itself is
/// inherited from `mainContent`.
///
/// Also deliberately has no bottom stroke in the glass path (unlike
/// TabBarBackgroundModifier's own bottom stroke, which sits between the
/// tab strip and the pane content below it): since this bar shares one
/// continuous glass surface with the titlebar above AND the tab strip
/// below (see above), a stroke on only one of its two edges read as an
/// inconsistency (user-reported) -- the titlebar side already connects
/// seamlessly, so the bar's own bottom edge should too. The
/// reduceTransparency path keeps its plain `Divider()`: that flat,
/// non-glass mode has no shared surface to stay seamless with, so it
/// still needs an explicit separator.
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
                .environment(\.colorScheme, chromeScheme)
                .foregroundStyle(themePreset == "ghostty"
                    ? AnyShapeStyle(Color(nsColor: ghosttyProvider.ghosttyForeground))
                    : AnyShapeStyle(.primary))
        }
    }
}
