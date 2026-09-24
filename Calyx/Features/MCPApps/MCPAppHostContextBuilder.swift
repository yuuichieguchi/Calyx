//
//  MCPAppHostContextBuilder.swift
//  Calyx
//
//  Builds `McpUiHostContext` for `ui/initialize` and the partial updates
//  sent as `ui/notifications/host-context-changed`. The 76 style
//  variables are derived from `MCPAppThemeInputs` (Calyx's theme and the
//  ghostty colors and font) by one pure function.
//

import Foundation

/// Calyx's theme and the ghostty config, as the composition root reads
/// them.
struct MCPAppThemeInputs: Sendable, Equatable {
    let lightBackground: MCPAppHexColor
    let lightForeground: MCPAppHexColor
    let darkBackground: MCPAppHexColor
    let darkForeground: MCPAppHexColor
    /// Calyx's accent (glass) color.
    let accent: MCPAppHexColor
    /// ghostty's font-family, or the system monospaced font's name.
    let fontFamily: String
    /// ghostty's font-size, in points.
    let fontSize: Double
}

enum MCPAppHostContextBuilder {
    struct Environment: Sendable, Equatable {
        let toolRequestID: JSONRPCId?
        let tool: MCPToolDefinition
        let isDarkTheme: Bool
        let displayMode: String
        let availableDisplayModes: [String]
        let containerDimensions: MCPAppDockLayout.ContainerDimensions
        let locale: String
        let timeZone: String
        let appVersion: String
        let theme: MCPAppThemeInputs
    }

    /// Every `McpUiStyleVariableKey` of ext-apps spec.types.ts v2.0.0 (76).
    static let styleVariableKeys: [String] = [
        "--color-background-primary",
        "--color-background-secondary",
        "--color-background-tertiary",
        "--color-background-inverse",
        "--color-background-ghost",
        "--color-background-info",
        "--color-background-danger",
        "--color-background-success",
        "--color-background-warning",
        "--color-background-disabled",
        "--color-text-primary",
        "--color-text-secondary",
        "--color-text-tertiary",
        "--color-text-inverse",
        "--color-text-ghost",
        "--color-text-info",
        "--color-text-danger",
        "--color-text-success",
        "--color-text-warning",
        "--color-text-disabled",
        "--color-border-primary",
        "--color-border-secondary",
        "--color-border-tertiary",
        "--color-border-inverse",
        "--color-border-ghost",
        "--color-border-info",
        "--color-border-danger",
        "--color-border-success",
        "--color-border-warning",
        "--color-border-disabled",
        "--color-ring-primary",
        "--color-ring-secondary",
        "--color-ring-inverse",
        "--color-ring-info",
        "--color-ring-danger",
        "--color-ring-success",
        "--color-ring-warning",
        "--font-sans",
        "--font-mono",
        "--font-weight-normal",
        "--font-weight-medium",
        "--font-weight-semibold",
        "--font-weight-bold",
        "--font-text-xs-size",
        "--font-text-sm-size",
        "--font-text-md-size",
        "--font-text-lg-size",
        "--font-heading-xs-size",
        "--font-heading-sm-size",
        "--font-heading-md-size",
        "--font-heading-lg-size",
        "--font-heading-xl-size",
        "--font-heading-2xl-size",
        "--font-heading-3xl-size",
        "--font-text-xs-line-height",
        "--font-text-sm-line-height",
        "--font-text-md-line-height",
        "--font-text-lg-line-height",
        "--font-heading-xs-line-height",
        "--font-heading-sm-line-height",
        "--font-heading-md-line-height",
        "--font-heading-lg-line-height",
        "--font-heading-xl-line-height",
        "--font-heading-2xl-line-height",
        "--font-heading-3xl-line-height",
        "--border-radius-xs",
        "--border-radius-sm",
        "--border-radius-md",
        "--border-radius-lg",
        "--border-radius-xl",
        "--border-radius-full",
        "--border-width-regular",
        "--shadow-hairline",
        "--shadow-sm",
        "--shadow-md",
        "--shadow-lg",
    ]

    /// The value of every style variable. Colors are `light-dark()` pairs,
    /// the light value from the light inputs and the dark value from the
    /// dark inputs. Colors the inputs lack are mixed from them: surfaces
    /// and borders from background toward foreground, secondary text from
    /// foreground toward background, and the status colors (info, danger,
    /// success, warning) from the accent turned to that status's hue.
    static func styleVariables(for theme: MCPAppThemeInputs) -> [String: String] {
        let light = Palette(background: MCPAppColor(theme.lightBackground), foreground: MCPAppColor(theme.lightForeground),
                            accent: MCPAppColor(theme.accent))
        let dark = Palette(background: MCPAppColor(theme.darkBackground), foreground: MCPAppColor(theme.darkForeground),
                           accent: MCPAppColor(theme.accent))
        func pair(_ pick: (Palette) -> String) -> String { "light-dark(\(pick(light)), \(pick(dark)))" }

        var values: [String: String] = [:]
        values["--color-background-primary"] = pair { $0.background.hex }
        values["--color-background-secondary"] = pair { $0.surface(0.04) }
        values["--color-background-tertiary"] = pair { $0.surface(0.08) }
        values["--color-background-inverse"] = pair { $0.foreground.hex }
        values["--color-background-ghost"] = "transparent"
        values["--color-background-disabled"] = pair { $0.surface(0.06) }
        values["--color-text-primary"] = pair { $0.foreground.hex }
        values["--color-text-secondary"] = pair { $0.text(0.3) }
        values["--color-text-tertiary"] = pair { $0.text(0.5) }
        values["--color-text-inverse"] = pair { $0.background.hex }
        values["--color-text-ghost"] = pair { $0.text(0.5) }
        values["--color-text-disabled"] = pair { $0.text(0.6) }
        values["--color-border-primary"] = pair { $0.surface(0.2) }
        values["--color-border-secondary"] = pair { $0.surface(0.12) }
        values["--color-border-tertiary"] = pair { $0.surface(0.06) }
        values["--color-border-inverse"] = pair { $0.foreground.mixed(with: $0.background, 0.2).hex }
        values["--color-border-ghost"] = "transparent"
        values["--color-border-disabled"] = pair { $0.surface(0.1) }
        values["--color-ring-primary"] = pair { $0.accent.hex }
        values["--color-ring-secondary"] = pair { $0.text(0.5) }
        values["--color-ring-inverse"] = pair { $0.background.hex }
        for status in Status.allCases {
            values["--color-background-\(status.rawValue)"] = pair { $0.background.mixed(with: $0.status(status), 0.12).hex }
            values["--color-text-\(status.rawValue)"] = pair { $0.status(status).hex }
            values["--color-border-\(status.rawValue)"] = pair { $0.status(status).hex }
            values["--color-ring-\(status.rawValue)"] = pair { $0.status(status).hex }
        }

        let family = theme.fontFamily.filter { $0 != "\"" && $0 != "\\" && $0 != ";" }
        values["--font-sans"] = "-apple-system, BlinkMacSystemFont, system-ui, sans-serif"
        values["--font-mono"] = "\"\(family)\", ui-monospace, monospace"
        values["--font-weight-normal"] = "400"
        values["--font-weight-medium"] = "500"
        values["--font-weight-semibold"] = "600"
        values["--font-weight-bold"] = "700"
        let sizes: [(String, Double, String)] = [
            ("text-xs", 0.85, "1.4"), ("text-sm", 0.92, "1.4"), ("text-md", 1.0, "1.45"), ("text-lg", 1.15, "1.45"),
            ("heading-xs", 1.0, "1.3"), ("heading-sm", 1.15, "1.3"), ("heading-md", 1.3, "1.25"),
            ("heading-lg", 1.5, "1.25"), ("heading-xl", 1.8, "1.2"), ("heading-2xl", 2.1, "1.15"),
            ("heading-3xl", 2.6, "1.1"),
        ]
        for (name, scale, lineHeight) in sizes {
            values["--font-\(name)-size"] = cssPixels(theme.fontSize * scale)
            values["--font-\(name)-line-height"] = lineHeight
        }
        values["--border-radius-xs"] = "2px"
        values["--border-radius-sm"] = "4px"
        values["--border-radius-md"] = "6px"
        values["--border-radius-lg"] = "10px"
        values["--border-radius-xl"] = "14px"
        values["--border-radius-full"] = "9999px"
        values["--border-width-regular"] = "1px"
        values["--shadow-hairline"] = "0 0 0 1px " + pair { $0.shadow(0.08) }
        values["--shadow-sm"] = "0 1px 2px " + pair { $0.shadow(0.10) }
        values["--shadow-md"] = "0 4px 12px " + pair { $0.shadow(0.14) }
        values["--shadow-lg"] = "0 12px 32px " + pair { $0.shadow(0.18) }
        return values
    }

    static func buildHostContext(_ env: Environment) -> [String: AnyCodable] {
        var toolInfo: [String: AnyCodable] = ["tool": AnyCodable(env.tool.raw)]
        if let id = env.toolRequestID {
            switch id {
            case .int(let value): toolInfo["id"] = AnyCodable(value)
            case .string(let value): toolInfo["id"] = AnyCodable(value)
            }
        }

        var dimensions: [String: AnyCodable] = [:]
        if let width = env.containerDimensions.width { dimensions["width"] = AnyCodable(width) }
        if let height = env.containerDimensions.height { dimensions["height"] = AnyCodable(height) }
        if let maxWidth = env.containerDimensions.maxWidth { dimensions["maxWidth"] = AnyCodable(maxWidth) }
        if let maxHeight = env.containerDimensions.maxHeight { dimensions["maxHeight"] = AnyCodable(maxHeight) }

        let variables = styleVariables(for: env.theme).mapValues { AnyCodable($0) }

        return [
            "toolInfo": AnyCodable(toolInfo),
            "theme": AnyCodable(env.isDarkTheme ? "dark" : "light"),
            "styles": AnyCodable(["variables": AnyCodable(variables)]),
            "displayMode": AnyCodable(env.displayMode),
            "availableDisplayModes": AnyCodable(env.availableDisplayModes.map { AnyCodable($0) }),
            "containerDimensions": AnyCodable(dimensions),
            "locale": AnyCodable(env.locale),
            "timeZone": AnyCodable(env.timeZone),
            "userAgent": AnyCodable("Calyx/\(env.appVersion)"),
            "platform": AnyCodable("desktop"),
            "deviceCapabilities": AnyCodable(["touch": AnyCodable(false), "hover": AnyCodable(true)]),
        ]
    }

    /// The top-level keys whose value changed. A key missing from `next`
    /// is sent as null.
    static func diff(previous: [String: AnyCodable], next: [String: AnyCodable]) -> [String: AnyCodable] {
        var changed: [String: AnyCodable] = [:]
        for (key, value) in next where previous[key] != value {
            changed[key] = value
        }
        for key in previous.keys where next[key] == nil {
            changed[key] = .null
        }
        return changed
    }

    // MARK: - Derivation

    private enum Status: String, CaseIterable {
        case info, danger, success, warning

        /// The hue the accent is turned to, in degrees. Info keeps the accent's own hue.
        var hue: Double? {
            switch self {
            case .info: return nil
            case .danger: return 4
            case .success: return 135
            case .warning: return 38
            }
        }
    }

    private struct Palette {
        let background: MCPAppColor
        let foreground: MCPAppColor
        let accent: MCPAppColor

        func surface(_ amount: Double) -> String { background.mixed(with: foreground, amount).hex }
        func text(_ amount: Double) -> String { foreground.mixed(with: background, amount).hex }

        /// The accent at the status hue, pulled toward the foreground so it
        /// stays readable on this palette's background.
        func status(_ status: Status) -> MCPAppColor {
            let base = status.hue.map { accent.withHue($0) } ?? accent
            return base.mixed(with: foreground, 0.15)
        }

        func shadow(_ alpha: Double) -> String {
            let color = background.luminance > 0.5 ? foreground : MCPAppColor(red: 0, green: 0, blue: 0)
            return "rgba(\(color.red255), \(color.green255), \(color.blue255), \(alpha))"
        }
    }

    private static func cssPixels(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        return rounded == rounded.rounded() ? "\(Int(rounded))px" : "\(rounded)px"
    }
}

/// An sRGB color with components in 0...1.
struct MCPAppColor: Sendable, Equatable {
    let red: Double
    let green: Double
    let blue: Double

    init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    init(_ color: MCPAppHexColor) {
        let value = color.rgb
        red = Double((value >> 16) & 0xFF) / 255
        green = Double((value >> 8) & 0xFF) / 255
        blue = Double(value & 0xFF) / 255
    }

    var red255: Int { Int((red * 255).rounded()) }
    var green255: Int { Int((green * 255).rounded()) }
    var blue255: Int { Int((blue * 255).rounded()) }

    var hex: String {
        String(format: "#%02x%02x%02x", red255, green255, blue255)
    }

    /// Relative luminance (sRGB weights, no gamma), 0...1.
    var luminance: Double { 0.2126 * red + 0.7152 * green + 0.0722 * blue }

    /// `amount` of `other` mixed into this color.
    func mixed(with other: MCPAppColor, _ amount: Double) -> MCPAppColor {
        MCPAppColor(
            red: red + (other.red - red) * amount,
            green: green + (other.green - green) * amount,
            blue: blue + (other.blue - blue) * amount
        )
    }

    /// The same saturation and lightness at `hue` degrees (HSL).
    func withHue(_ hue: Double) -> MCPAppColor {
        let maxValue = max(red, green, blue)
        let minValue = min(red, green, blue)
        let lightness = (maxValue + minValue) / 2
        let delta = maxValue - minValue
        let saturation = delta == 0 ? 0 : delta / (1 - abs(2 * lightness - 1))
        let chroma = (1 - abs(2 * lightness - 1)) * saturation
        let sector = (hue.truncatingRemainder(dividingBy: 360)) / 60
        let x = chroma * (1 - abs(sector.truncatingRemainder(dividingBy: 2) - 1))
        let (r, g, b): (Double, Double, Double)
        switch sector {
        case 0..<1: (r, g, b) = (chroma, x, 0)
        case 1..<2: (r, g, b) = (x, chroma, 0)
        case 2..<3: (r, g, b) = (0, chroma, x)
        case 3..<4: (r, g, b) = (0, x, chroma)
        case 4..<5: (r, g, b) = (x, 0, chroma)
        default: (r, g, b) = (chroma, 0, x)
        }
        let m = lightness - chroma / 2
        return MCPAppColor(red: r + m, green: g + m, blue: b + m)
    }
}
