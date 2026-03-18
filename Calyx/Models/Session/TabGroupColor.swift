// TabGroupColor.swift
// Calyx
//
// 10-color preset enum for tab group color identification.

import AppKit

enum TabGroupColor: String, CaseIterable, Codable, Sendable {
    case red, orange, yellow, green, mint, teal, cyan, blue, indigo, purple

    var nsColor: NSColor {
        switch self {
        case .red: return .systemRed
        case .orange: return .systemOrange
        case .yellow: return .systemYellow
        case .green: return .systemGreen
        case .mint: return .systemMint
        case .teal: return .systemTeal
        case .cyan: return .systemCyan
        case .blue: return .systemBlue
        case .indigo: return .systemIndigo
        case .purple: return .systemPurple
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        self = TabGroupColor(rawValue: raw) ?? .blue
    }

    /// Returns the next color that avoids duplicating existing group colors.
    /// If an unused color exists, returns the first one in allCases order.
    /// If all colors are used, returns the least frequently used color.
    static func nextColor(excluding usedColors: [TabGroupColor]) -> TabGroupColor {
        let usedSet = Set(usedColors)
        if let available = allCases.first(where: { !usedSet.contains($0) }) {
            return available
        }
        let counts = Dictionary(usedColors.map { ($0, 1) }, uniquingKeysWith: +)
        let minCount = counts.values.min() ?? 0
        return allCases.first(where: { counts[$0, default: 0] == minCount }) ?? .blue
    }
}
