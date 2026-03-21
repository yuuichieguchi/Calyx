import AppKit

enum ThemeColorPreset: String, CaseIterable, Codable, Sendable {
    case original, ghostty, red, blue, yellow, purple, black, gray, custom

    /// Default custom hex value (matches Original preset).
    static let defaultCustomHex = "#050D1C"

    var displayName: String {
        switch self {
        case .original: "Original"
        case .ghostty: "Ghostty"
        case .red: "Red"
        case .blue: "Blue"
        case .yellow: "Yellow"
        case .purple: "Purple"
        case .black: "Black"
        case .gray: "Gray"
        case .custom: "Custom"
        }
    }

    /// The base color for this preset
    var color: NSColor {
        switch self {
        case .original: NSColor(red: 0.02, green: 0.05, blue: 0.11, alpha: 1.0)  // #050D1C dark navy
        case .ghostty: NSColor(red: 0.16, green: 0.16, blue: 0.16, alpha: 1.0)    // #282828 Ghostty dark gray
        case .red: NSColor(red: 0.11, green: 0.02, blue: 0.02, alpha: 1.0)        // #1C0505
        case .blue: NSColor(red: 0.02, green: 0.02, blue: 0.11, alpha: 1.0)       // #05051C
        case .yellow: NSColor(red: 0.11, green: 0.10, blue: 0.02, alpha: 1.0)     // #1C1A05
        case .purple: NSColor(red: 0.06, green: 0.02, blue: 0.11, alpha: 1.0)     // #0F051C
        case .black: NSColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 1.0)         // #000000
        case .gray: NSColor(red: 0.05, green: 0.05, blue: 0.05, alpha: 1.0)       // #0D0D0D
        case .custom: NSColor(red: 0.02, green: 0.05, blue: 0.11, alpha: 1.0)     // Falls back to original
        }
    }
}

extension ThemeColorPreset {
    /// Resolve the current theme color from preset name and custom hex.
    /// When the ghostty preset is active and a live background color is available,
    /// that color is used instead of the hardcoded fallback.
    static func resolve(preset: String, customHex: String, ghosttyBackground: NSColor? = nil) -> NSColor {
        if let p = ThemeColorPreset(rawValue: preset), p != .custom {
            if p == .ghostty, let bg = ghosttyBackground {
                return bg
            }
            return p.color
        }
        return HexColor.parse(customHex) ?? ThemeColorPreset.original.color
    }
}

enum HexColor {
    /// Parse a hex string like "#FF0000" or "FF0000" into NSColor.
    /// Returns nil for invalid hex (not exactly 6 hex digits after optional #).
    static func parse(_ hex: String) -> NSColor? {
        var hexString = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if hexString.hasPrefix("#") {
            hexString.removeFirst()
        }
        guard hexString.count == 6 else { return nil }
        var rgb: UInt64 = 0
        guard Scanner(string: hexString).scanHexInt64(&rgb) else { return nil }
        let r = CGFloat((rgb >> 16) & 0xFF) / 255.0
        let g = CGFloat((rgb >> 8) & 0xFF) / 255.0
        let b = CGFloat(rgb & 0xFF) / 255.0
        return NSColor(red: r, green: g, blue: b, alpha: 1.0)
    }

    /// Convert NSColor to "#RRGGBB" hex string.
    static func toHex(_ color: NSColor) -> String {
        let converted = color.usingColorSpace(.sRGB) ?? color
        let r = Int(round(converted.redComponent * 255))
        let g = Int(round(converted.greenComponent * 255))
        let b = Int(round(converted.blueComponent * 255))
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
