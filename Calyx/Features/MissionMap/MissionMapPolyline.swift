// MissionMapPolyline.swift
// Calyx
//
// Geometry over a routed Mission Map line (an orthogonal polyline from
// `MissionMapRouter`): its length, the point a given fraction of the way
// along it (where the pulse dot is drawn), and where its label sits.

import CoreGraphics
import Foundation

enum MissionMapPolyline {

    /// The total length of `points`' consecutive segments; 0 for fewer
    /// than two points.
    static func length(_ points: [CGPoint]) -> CGFloat {
        guard points.count > 1 else { return 0 }
        var total: CGFloat = 0
        for index in 1..<points.count {
            total += distance(points[index - 1], points[index])
        }
        return total
    }

    /// The point `t` of the way along `points` by arc length (`t` clamped
    /// to 0...1), so the pulse dot moves at a constant speed whatever the
    /// segment lengths. A single-point path returns that point; `points`
    /// must not be empty.
    static func point(along points: [CGPoint], t: CGFloat) -> CGPoint {
        precondition(!points.isEmpty, "A polyline needs at least one point")
        let first = points[0]
        let last = points[points.count - 1]
        let total = length(points)
        guard total > 0 else { return first }
        let clamped = min(max(t, 0), 1)
        var remaining = clamped * total
        for index in 1..<points.count {
            let a = points[index - 1]
            let b = points[index]
            let segment = distance(a, b)
            if remaining <= segment, segment > 0 {
                let fraction = remaining / segment
                return CGPoint(x: a.x + (b.x - a.x) * fraction, y: a.y + (b.y - a.y) * fraction)
            }
            remaining -= segment
        }
        return last
    }

    /// Where a line's label (popover, conflict file name) is anchored: the
    /// midpoint of its longest segment, the first one on a tie. A
    /// single-point path returns that point; `points` must not be empty.
    static func labelAnchor(_ points: [CGPoint]) -> CGPoint {
        precondition(!points.isEmpty, "A polyline needs at least one point")
        guard points.count > 1 else { return points[0] }
        let (a, b) = longestSegment(points)
        return CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
    }

    /// Where a label beside the line goes: `labelAnchor`, plus the unit
    /// direction perpendicular to that longest segment pointing to the
    /// side with more free space -- away from the nearer of the
    /// `obstacles` beside the segment (up / left on a tie or when neither
    /// side has one). The caller moves the label that way by half its
    /// perpendicular extent plus a gap, so it sits next to the line
    /// instead of on it. A segment that is not axis-aligned (the router's
    /// straight fallback) gets its upward perpendicular.
    static func labelPlacement(_ points: [CGPoint], obstacles: [CGRect]) -> (anchor: CGPoint, normal: CGVector) {
        precondition(!points.isEmpty, "A polyline needs at least one point")
        let anchor = labelAnchor(points)
        guard points.count > 1 else { return (anchor, CGVector(dx: 0, dy: -1)) }
        let (a, b) = longestSegment(points)
        let tol: CGFloat = 0.001
        let horizontal = abs(a.y - b.y) <= tol
        let vertical = abs(a.x - b.x) <= tol
        guard horizontal || vertical else {
            let length = distance(a, b)
            guard length > 0 else { return (anchor, CGVector(dx: 0, dy: -1)) }
            var normal = CGVector(dx: -(b.y - a.y) / length, dy: (b.x - a.x) / length)
            if normal.dy > 0 || (normal.dy == 0 && normal.dx > 0) {
                normal = CGVector(dx: -normal.dx, dy: -normal.dy)
            }
            return (anchor, normal)
        }
        let coord = horizontal ? a.y : a.x
        let lo = horizontal ? min(a.x, b.x) : min(a.y, b.y)
        let hi = horizontal ? max(a.x, b.x) : max(a.y, b.y)
        var spaceBefore = CGFloat.infinity // toward smaller coordinates
        var spaceAfter = CGFloat.infinity
        for rect in obstacles {
            let alongMin = horizontal ? rect.minX : rect.minY
            let alongMax = horizontal ? rect.maxX : rect.maxY
            guard alongMin < hi - tol, alongMax > lo + tol else { continue }
            let perpMin = horizontal ? rect.minY : rect.minX
            let perpMax = horizontal ? rect.maxY : rect.maxX
            if perpMax <= coord + tol {
                spaceBefore = min(spaceBefore, coord - perpMax)
            } else if perpMin >= coord - tol {
                spaceAfter = min(spaceAfter, perpMin - coord)
            }
        }
        let sign: CGFloat = spaceBefore >= spaceAfter ? -1 : 1
        return (anchor, horizontal ? CGVector(dx: 0, dy: sign) : CGVector(dx: sign, dy: 0))
    }

    /// The longest segment's endpoints, the first one on a tie; `points`
    /// has at least 2 points.
    private static func longestSegment(_ points: [CGPoint]) -> (CGPoint, CGPoint) {
        var bestIndex = 1
        var bestLength = -CGFloat.infinity
        for index in 1..<points.count {
            let segment = distance(points[index - 1], points[index])
            if segment > bestLength {
                bestLength = segment
                bestIndex = index
            }
        }
        return (points[bestIndex - 1], points[bestIndex])
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(b.x - a.x, b.y - a.y)
    }
}
