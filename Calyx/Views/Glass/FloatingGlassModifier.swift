// FloatingGlassModifier.swift
// Calyx
//
// Shared modifier for floating Liquid Glass styling on tab/group items.

import SwiftUI

enum GlassTheme {
    static func chromeTintOpacity(for glassOpacity: Double) -> Double {
        let clamped = max(0.0, min(1.0, glassOpacity))
        return 0.20 + (clamped * 0.30)
    }

    static func chromeTint(for glassOpacity: Double) -> Color {
        Color(red: 0.02, green: 0.05, blue: 0.11).opacity(chromeTintOpacity(for: glassOpacity))
    }

    static var atmosphereTop: Color {
        Color(red: 0.66, green: 0.86, blue: 1.00).opacity(0.28)
    }

    static var atmosphereBottom: Color {
        Color(red: 0.02, green: 0.03, blue: 0.08).opacity(0.34)
    }

    static var specularStroke: Color {
        Color.white.opacity(0.24)
    }

}

struct TabChromeModifier: ViewModifier {
    let isActive: Bool
    let cornerRadius: CGFloat
    let reduceTransparency: Bool

    func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.gray.opacity(isActive ? 0.15 : 0.05))
            )
        } else {
            if isActive {
                content
                    .glassEffect(.regular.interactive(), in: .rect(cornerRadius: cornerRadius))
            } else {
                content
            }
        }
    }
}
