// MissionMapPopoverPlacement.swift
// Calyx
//
// Where the selected Mission Map line's popover goes. Eight candidate
// rects are tried around the line's anchor, in order: above, below,
// left and right (the bubble's near edge `gap` from the anchor, centered
// on it along the other axis), then the diagonals top-left, top-right,
// bottom-left and bottom-right (the bubble's near corner `gap` from the
// anchor on both axes). Each candidate is first translated into `bounds`,
// then scored by how much of the obstacles (cards, band headers) it
// covers; the lowest score wins, a tie going to the earlier candidate.
// Pure geometry.

import CoreGraphics

enum MissionMapPopoverPlacement {
    /// The default distance between the anchor and the bubble.
    static let defaultGap: CGFloat = 8

    /// The rect, `extent` in size and inside `bounds`, that covers the
    /// least of `obstacles` among the candidates around `anchor`.
    static func place(
        extent: CGSize, anchor: CGPoint, gap: CGFloat = defaultGap, obstacles: [CGRect], bounds: CGRect
    ) -> CGRect {
        let width = extent.width
        let height = extent.height
        let leftX = anchor.x - gap - width
        let rightX = anchor.x + gap
        let centerX = anchor.x - width / 2
        let aboveY = anchor.y - gap - height
        let belowY = anchor.y + gap
        let centerY = anchor.y - height / 2
        let origins = [
            CGPoint(x: centerX, y: aboveY),
            CGPoint(x: centerX, y: belowY),
            CGPoint(x: leftX, y: centerY),
            CGPoint(x: rightX, y: centerY),
            CGPoint(x: leftX, y: aboveY),
            CGPoint(x: rightX, y: aboveY),
            CGPoint(x: leftX, y: belowY),
            CGPoint(x: rightX, y: belowY),
        ]

        let candidates = origins.map { clamp(CGRect(origin: $0, size: extent), into: bounds) }
        var best = candidates[0]
        var bestScore = score(best, obstacles: obstacles)
        for candidate in candidates.dropFirst() {
            let candidateScore = score(candidate, obstacles: obstacles)
            if candidateScore < bestScore {
                best = candidate
                bestScore = candidateScore
            }
        }
        return best
    }

    /// The total area of `rect` covered by `obstacles`, each counted on
    /// its own (overlapping obstacles count twice).
    static func score(_ rect: CGRect, obstacles: [CGRect]) -> CGFloat {
        obstacles.reduce(0) { total, obstacle in
            let overlap = rect.intersection(obstacle)
            guard !overlap.isNull else { return total }
            return total + overlap.width * overlap.height
        }
    }

    /// `rect` translated (not resized) so it lies inside `bounds`; a rect
    /// larger than `bounds` keeps its top-left corner on `bounds`'.
    private static func clamp(_ rect: CGRect, into bounds: CGRect) -> CGRect {
        let x = max(bounds.minX, min(rect.minX, bounds.maxX - rect.width))
        let y = max(bounds.minY, min(rect.minY, bounds.maxY - rect.height))
        return CGRect(x: x, y: y, width: rect.width, height: rect.height)
    }
}

extension MissionMapPopoverPlacement {
    /// `contentRect` (in the map's scroll content) in the coordinate
    /// space `mapFrame` is measured in: the scroll content's origin sits
    /// at the map's origin minus the scroll offset.
    static func windowRect(contentRect: CGRect, scrollOffset: CGPoint, mapFrame: CGRect) -> CGRect {
        contentRect.offsetBy(dx: mapFrame.minX - scrollOffset.x, dy: mapFrame.minY - scrollOffset.y)
    }
}

/// Where the selected line's popover is drawn: the line's edge, the
/// placed rect (top-left origin; which coordinate space depends on the
/// reporter -- see `MissionMapContentView.onPopoverPlacementChange` and
/// `MissionMapView.onPopoverPlacementChange`), and whether that rect
/// covers a card or band header (`MissionMapPopoverPlacement.score > 0`).
struct MissionMapPopoverPlacementInfo: Sendable, Equatable {
    let edge: MissionMapEdge
    let rect: CGRect
    let emphasized: Bool
}
