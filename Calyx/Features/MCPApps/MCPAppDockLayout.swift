//
//  MCPAppDockLayout.swift
//  Calyx
//
//  Geometry of the inline dock and the container dimensions reported to
//  the view for each display mode. Rects are in a flipped coordinate space
//  (`SplitContainerView.isFlipped`): the terminal sits on the left, the
//  dock on the right, with a divider between them.
//

import CoreGraphics
import Foundation

enum MCPAppDockLayout {
    /// A dock nobody has dragged is this share of its leaf's width.
    static let defaultDockShare: CGFloat = 0.4
    /// The terminal keeps at least this many points, or `minTerminalColumns` columns if that is wider.
    static let minTerminalWidth: CGFloat = 120
    static let minTerminalColumns: CGFloat = 40
    /// The visible width of the divider between the terminal and the dock
    /// (the split divider's width).
    static let dividerThickness: CGFloat = 1
    static let defaultBorderWidth: CGFloat = 1
    /// A shown dock is at least this wide.
    static let minDockWidth: CGFloat = 120

    struct SplitResult: Sendable, Equatable {
        let terminalRect: CGRect
        let dividerRect: CGRect
        let dockRect: CGRect
    }

    /// The width of a dock nobody has dragged.
    static func defaultDockWidth(leafWidth: CGFloat) -> CGFloat {
        leafWidth * defaultDockShare
    }

    /// The dock widths a leaf can show: from `minDockWidth` to what leaves
    /// the terminal max(120pt, 40 columns). Nil when the leaf is too
    /// narrow for both minimums and the divider.
    static func dockWidthRange(leafWidth: CGFloat, cellWidth: CGFloat) -> ClosedRange<CGFloat>? {
        let terminalMinimum = max(minTerminalWidth, minTerminalColumns * cellWidth)
        let maxDock = leafWidth - dividerThickness - terminalMinimum
        guard maxDock >= minDockWidth else { return nil }
        return minDockWidth...maxDock
    }

    /// `dockWidth` clamped to `range`.
    static func clamp(_ dockWidth: CGFloat, to range: ClosedRange<CGFloat>) -> CGFloat {
        min(max(dockWidth, range.lowerBound), range.upperBound)
    }

    /// Terminal on the left, divider, dock on the right, each the leaf's
    /// full height. The dock gets `dockWidth` clamped to the leaf's
    /// `dockWidthRange`. Nil when the leaf is too narrow for a dock: the
    /// dock is hidden and the terminal takes the whole leaf.
    static func split(leafRect: CGRect, dockWidth: CGFloat, cellWidth: CGFloat) -> SplitResult? {
        guard let range = dockWidthRange(leafWidth: leafRect.width, cellWidth: cellWidth) else { return nil }
        return split(leafRect: leafRect, dockWidth: dockWidth, in: range)
    }

    /// The split for a leaf whose `dockWidthRange` is `range`: the dock
    /// gets `dockWidth` clamped to `range`.
    static func split(leafRect: CGRect, dockWidth: CGFloat, in range: ClosedRange<CGFloat>) -> SplitResult {
        let dock = clamp(dockWidth, to: range)
        let terminal = leafRect.width - dividerThickness - dock
        let dividerX = leafRect.minX + terminal
        return SplitResult(
            terminalRect: CGRect(x: leafRect.minX, y: leafRect.minY, width: terminal, height: leafRect.height),
            dividerRect: CGRect(x: dividerX, y: leafRect.minY, width: dividerThickness, height: leafRect.height),
            dockRect: CGRect(x: leafRect.maxX - dock, y: leafRect.minY, width: dock, height: leafRect.height)
        )
    }

    /// The dock width a divider drag asks for: the dock's left edge sits
    /// under the cursor. `ratio` is the cursor's position across the leaf,
    /// as `SplitDividerView` reports it, and is not limited to 0...1 (a
    /// cursor past the leaf's right edge gives a negative width), so the
    /// result goes through `clamp(_:to:)`.
    static func dockWidth(forDividerRatio ratio: Double, leafWidth: CGFloat) -> CGFloat {
        leafWidth * (1 - CGFloat(ratio))
    }

    /// `McpUiHostContext.containerDimensions`.
    struct ContainerDimensions: Sendable, Equatable {
        let width: Double?
        let height: Double?
        let maxWidth: Double?
        let maxHeight: Double?
    }

    /// Unknown modes are reported like "inline". Inline is the fixed size
    /// of the card area in the dock below `contentTopInset` (at least 0):
    /// the view fills it, and the host does not resize it on
    /// `ui/notifications/size-changed`. `contentTopInset` is the card's
    /// height above its content area (`MCPAppViewPane.contentTopInset`:
    /// the header, and the prompt while it shows).
    static func containerDimensions(
        mode: String,
        dockSize: CGSize,
        windowSize: CGSize,
        tabTerminalRect: CGRect,
        contentTopInset: CGFloat
    ) -> ContainerDimensions {
        switch mode {
        case "fullscreen":
            let width = Double(tabTerminalRect.width)
            let height = Double(tabTerminalRect.height - contentTopInset)
            return ContainerDimensions(width: width, height: height, maxWidth: width, maxHeight: height)
        case "pip":
            let width = Double(min(480, windowSize.width / 2))
            let height = Double(min(360, windowSize.height / 2))
            return ContainerDimensions(width: width, height: height, maxWidth: width, maxHeight: height)
        default:
            return ContainerDimensions(
                width: Double(dockSize.width),
                height: Double(max(0, dockSize.height - contentTopInset)),
                maxWidth: nil,
                maxHeight: nil
            )
        }
    }

    /// `_meta.ui.prefersBorder`; omitted means the Calyx border.
    static func borderWidth(prefersBorder: Bool?) -> CGFloat {
        (prefersBorder ?? true) ? defaultBorderWidth : 0
    }
}
