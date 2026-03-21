// FloatingGlassModifier.swift
// Calyx
//
// Shared modifier for floating Liquid Glass styling on tab/group items.

import SwiftUI
import AppKit

enum GlassTheme {
    static func chromeTintOpacity(for glassOpacity: Double) -> Double {
        let clamped = max(0.0, min(1.0, glassOpacity))
        return 0.20 + (clamped * 0.80)
    }

    /// Derive chrome tint from theme color.
    static func chromeTint(for themeColor: NSColor, glassOpacity: Double) -> NSColor {
        let hsb = toHSB(themeColor)
        let opacity = chromeTintOpacity(for: glassOpacity)
        if hsb.saturation < 0.05 {
            // Neutral: use brightness only
            return NSColor(hue: 0, saturation: 0, brightness: hsb.brightness, alpha: opacity)
        }
        return NSColor(hue: hsb.hue, saturation: hsb.saturation, brightness: hsb.brightness, alpha: opacity)
    }

    /// Derive atmosphere top gradient color from theme color.
    static func atmosphereTop(for themeColor: NSColor, glassOpacity: Double) -> NSColor {
        let hsb = toHSB(themeColor)
        if hsb.saturation < 0.05 {
            let alpha = 0.28 + (max(0, min(1, glassOpacity)) * 0.64)
            return NSColor(hue: 0, saturation: 0, brightness: hsb.brightness, alpha: alpha)
        }
        return NSColor(hue: hsb.hue, saturation: hsb.saturation * 0.6, brightness: 0.84, alpha: 0.28)
    }

    /// Derive atmosphere bottom gradient color from theme color.
    static func atmosphereBottom(for themeColor: NSColor, glassOpacity: Double) -> NSColor {
        let hsb = toHSB(themeColor)
        if hsb.saturation < 0.05 {
            let alpha = 0.34 + (max(0, min(1, glassOpacity)) * 0.58)
            return NSColor(hue: 0, saturation: 0, brightness: hsb.brightness, alpha: alpha)
        }
        return NSColor(hue: hsb.hue, saturation: hsb.saturation * 0.8, brightness: 0.05, alpha: 0.34)
    }

    /// Derive accent gradient color from theme color.
    static func accentGradient(for themeColor: NSColor) -> NSColor {
        let hsb = toHSB(themeColor)
        if hsb.saturation < 0.05 {
            return NSColor(hue: 0, saturation: 0, brightness: 0, alpha: 0.0)
        }
        return NSColor(hue: hsb.hue, saturation: max(0.6, hsb.saturation), brightness: 0.8, alpha: 0.18)
    }

    static var specularStroke: Color {
        Color.white.opacity(0.24)
    }

    // HSB extraction helper
    private static func toHSB(_ color: NSColor) -> (hue: CGFloat, saturation: CGFloat, brightness: CGFloat) {
        let converted = color.usingColorSpace(.sRGB) ?? color
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        converted.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return (h, s, b)
    }
}

struct TabChromeModifier: ViewModifier {
    let isActive: Bool
    let cornerRadius: CGFloat
    let reduceTransparency: Bool
    @Environment(\.controlActiveState) private var controlActiveState

    func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.gray.opacity(isActive ? 0.15 : 0.05))
            )
        } else {
            if isActive {
                content
                    .background(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(Color.black.opacity(0.2))
                    )
                    .opacity(controlActiveState == .key ? 1.0 : 0.5)
            } else {
                content
                    .opacity(controlActiveState == .key ? 1.0 : 0.5)
            }
        }
    }
}
