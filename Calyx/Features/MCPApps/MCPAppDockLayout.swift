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
    /// The visible width of the divider between the terminal and the dock
    /// (the split divider's width).
    static let dividerThickness: CGFloat = 1
    static let defaultBorderWidth: CGFloat = 1
    /// Each side keeps at least this many points when the leaf has room
    /// for it on both sides of the divider. The same value as the
    /// `minSize: 50` that `CalyxWindowController` passes to the split
    /// tree's ratio setters.
    static let minSideWidth: CGFloat = 50
    /// Each side keeps at least this share of the leaf's width. The lower
    /// bound of `SplitData.clampRatio` ([0.1, 0.9]).
    static let minSideShare: CGFloat = 0.1
    /// How far a divider's hit area reaches past each side of its visible
    /// frame (`SplitContainerView.placeDividerView`), for split and dock
    /// dividers alike.
    static let dividerHitExpansion: CGFloat = 3
    /// Each side keeps at least this many points when the leaf has room
    /// for it on both sides of the divider, so the dock divider's hit
    /// area does not overlap the hit area of a split divider at the
    /// leaf's edge (each reaches `dividerHitExpansion` into the side).
    static let minSideHitClearance: CGFloat = 2 * dividerHitExpansion

    struct SplitResult: Sendable, Equatable {
        let terminalRect: CGRect
        let dividerRect: CGRect
        let dockRect: CGRect
    }

    /// The width of a dock nobody has dragged.
    static func defaultDockWidth(leafWidth: CGFloat) -> CGFloat {
        leafWidth * defaultDockShare
    }

    /// `dockWidth` clamped the way a split pane's divider is clamped. Each
    /// side of the divider keeps at least max(`minSideWidth`,
    /// `minSideShare` * leaf width) when the leaf is at least
    /// 2 * `minSideWidth` + `dividerThickness` wide, and
    /// `minSideShare` * leaf width when it is narrower, raised to
    /// `minSideHitClearance` when the width left after the divider holds
    /// that on both sides. When the width left
    /// after the divider cannot hold both side minimums (a leaf narrower
    /// than 1.25 pt), the dock gets the side minimum capped to that width
    /// and the terminal the rest, so no part has a negative width. A
    /// negative leaf width is treated as 0, so the dock width is 0.
    static func clampedDockWidth(_ dockWidth: CGFloat, leafWidth: CGFloat) -> CGFloat {
        let leafWidth = max(0, leafWidth)
        let sides = max(0, leafWidth - dividerThickness)
        let proportional = minSideShare * leafWidth
        let splitMinimum = leafWidth >= 2 * minSideWidth + dividerThickness
            ? max(minSideWidth, proportional)
            : proportional
        let sideMinimum = sides >= 2 * minSideHitClearance
            ? max(minSideHitClearance, splitMinimum)
            : splitMinimum
        let lower = min(sideMinimum, sides)
        let upper = max(lower, sides - sideMinimum)
        return min(max(dockWidth, lower), upper)
    }

    /// Terminal on the left, divider, dock on the right, each the leaf's
    /// full height. The dock gets `clampedDockWidth(dockWidth, leafWidth:)`
    /// and the terminal the rest after the divider. Every leaf width gets
    /// a split.
    static func split(leafRect: CGRect, dockWidth: CGFloat) -> SplitResult {
        let dock = clampedDockWidth(dockWidth, leafWidth: leafRect.width)
        let terminal = max(0, leafRect.width - dividerThickness) - dock
        let dividerX = leafRect.minX + terminal
        return SplitResult(
            terminalRect: CGRect(x: leafRect.minX, y: leafRect.minY, width: terminal, height: leafRect.height),
            dividerRect: CGRect(x: dividerX, y: leafRect.minY, width: dividerThickness, height: leafRect.height),
            dockRect: CGRect(x: dividerX + dividerThickness, y: leafRect.minY, width: dock, height: leafRect.height)
        )
    }

    /// The dock width a divider drag asks for: the dock's left edge sits
    /// under the cursor. `ratio` is the cursor's position across the leaf,
    /// as `SplitDividerView` reports it, and is not limited to 0...1 (a
    /// cursor past the leaf's right edge gives a negative width), so the
    /// result goes through `clampedDockWidth(_:leafWidth:)`.
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
    /// the header).
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
