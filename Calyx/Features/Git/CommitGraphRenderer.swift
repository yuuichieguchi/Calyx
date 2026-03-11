// CommitGraphRenderer.swift
// Calyx
//
// Parses git log --graph prefix strings and renders colored attributed strings.

import AppKit

enum GraphElement: Sendable {
    case pipe       // |
    case star       // *
    case slash      // /
    case backslash  // \
    case space      // " "
    case dash       // -
    case dot        // .
}

enum CommitGraphRenderer {
    private static let laneColors: [NSColor] = [
        .systemBlue,
        .systemGreen,
        .systemOrange,
        .systemPurple,
        .systemRed,
        .systemTeal,
        .systemYellow,
        .systemPink,
    ]

    static func parse(_ prefix: String) -> [GraphElement] {
        prefix.map { char -> GraphElement in
            switch char {
            case "|": .pipe
            case "*": .star
            case "/": .slash
            case "\\": .backslash
            case " ": .space
            case "-": .dash
            case ".": .dot
            default: .space
            }
        }
    }

    static func attributedString(from elements: [GraphElement]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let boldFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .bold)

        var laneIndex = 0

        for element in elements {
            let char: String
            let color: NSColor?
            let useBold: Bool
            var advanceLane = false

            switch element {
            case .space:
                char = " "
                color = nil
                useBold = false
            case .pipe:
                char = "│"
                color = laneColors[laneIndex % laneColors.count]
                useBold = false
                advanceLane = true
            case .star:
                char = "●"
                color = laneColors[laneIndex % laneColors.count]
                useBold = true
                advanceLane = true
            case .slash:
                char = "/"
                color = laneColors[laneIndex % laneColors.count]
                useBold = false
                advanceLane = true
            case .backslash:
                char = "\\"
                color = laneColors[laneIndex % laneColors.count]
                useBold = false
                advanceLane = true
            case .dash:
                char = "─"
                color = laneColors[max(0, laneIndex - 1) % laneColors.count]
                useBold = false
            case .dot:
                char = "·"
                color = NSColor.secondaryLabelColor
                useBold = false
            }

            var attrs: [NSAttributedString.Key: Any] = [.font: useBold ? boldFont : font]
            if let color {
                attrs[.foregroundColor] = color
            }
            result.append(NSAttributedString(string: char, attributes: attrs))

            if advanceLane {
                laneIndex += 1
            }
        }

        return result
    }
}