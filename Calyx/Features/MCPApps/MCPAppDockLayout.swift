//
//  MCPAppDockLayout.swift
//  Calyx
//
//  Geometry of the inline dock and the container dimensions reported to
//  the view for each display mode. Rects are in a flipped coordinate space
//  (`SplitContainerView.isFlipped`): the terminal sits on top, the dock
//  below it.
//

import CoreGraphics
import Foundation

enum MCPAppDockLayout {
    /// The dock never takes more than this share of its leaf's height.
    static let maxDockShare: CGFloat = 0.6
    /// The terminal keeps at least this many points, or `minTerminalRows` rows if that is taller.
    static let minTerminalHeight: CGFloat = 120
    static let minTerminalRows: CGFloat = 6
    static let defaultBorderWidth: CGFloat = 1

    struct SplitResult: Sendable, Equatable {
        let terminalRect: CGRect
        let dockRect: CGRect
    }

    /// The terminal keeps at least max(120pt, 6 rows); the dock gets at
    /// most 60% of the leaf height.
    static func split(leafRect: CGRect, dockHeight: CGFloat, rowHeight: CGFloat) -> SplitResult {
        let terminalMinimum = max(minTerminalHeight, minTerminalRows * rowHeight)
        let dock = max(0, min(dockHeight, leafRect.height * maxDockShare, leafRect.height - terminalMinimum))
        let terminal = leafRect.height - dock
        return SplitResult(
            terminalRect: CGRect(x: leafRect.minX, y: leafRect.minY, width: leafRect.width, height: terminal),
            dockRect: CGRect(x: leafRect.minX, y: leafRect.minY + terminal, width: leafRect.width, height: dock)
        )
    }

    /// `McpUiHostContext.containerDimensions`.
    struct ContainerDimensions: Sendable, Equatable {
        let width: Double?
        let height: Double?
        let maxWidth: Double?
        let maxHeight: Double?
    }

    /// Unknown modes are reported like "inline".
    static func containerDimensions(
        mode: String,
        leafRect: CGRect,
        windowSize: CGSize,
        tabTerminalRect: CGRect,
        headerHeight: CGFloat
    ) -> ContainerDimensions {
        switch mode {
        case "fullscreen":
            let width = Double(tabTerminalRect.width)
            let height = Double(tabTerminalRect.height - headerHeight)
            return ContainerDimensions(width: width, height: height, maxWidth: width, maxHeight: height)
        case "pip":
            let width = Double(min(480, windowSize.width / 2))
            let height = Double(min(360, windowSize.height / 2))
            return ContainerDimensions(width: width, height: height, maxWidth: width, maxHeight: height)
        default:
            return ContainerDimensions(
                width: Double(leafRect.width),
                height: nil,
                maxWidth: Double(leafRect.width),
                maxHeight: Double(leafRect.height * maxDockShare)
            )
        }
    }

    /// `ui/notifications/size-changed` height, clamped to [0, 60% of the leaf].
    static func clampSizeChanged(requestedHeight: CGFloat, leafHeight: CGFloat) -> CGFloat {
        min(max(0, requestedHeight), leafHeight * maxDockShare)
    }

    /// `_meta.ui.prefersBorder`; omitted means the Calyx border.
    static func borderWidth(prefersBorder: Bool?) -> CGFloat {
        (prefersBorder ?? true) ? defaultBorderWidth : 0
    }
}
