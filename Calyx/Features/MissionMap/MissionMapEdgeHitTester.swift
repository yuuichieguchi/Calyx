// MissionMapEdgeHitTester.swift
// Calyx
//
// Hit testing for Mission Map's lines. They are all drawn into one
// Canvas, which has no per-element hit testing, so a tap is matched
// against the line segments here instead.

import CoreGraphics
import Foundation

enum MissionMapEdgeHitTester {

    /// The id of the segment closest to `point`, if that distance is at
    /// most `tolerance`; `nil` when every segment is farther away. The
    /// distance is to the segment itself, not the infinite line through
    /// it, so a tap past a line's end does not select it.
    static func nearest(
        point: CGPoint, edges: [(id: UUID, a: CGPoint, b: CGPoint)], tolerance: CGFloat = 6
    ) -> UUID? {
        var best: (id: UUID, distance: CGFloat)?
        for edge in edges {
            let distance = distanceFrom(point, toSegment: edge.a, edge.b)
            guard distance <= tolerance else { continue }
            if let current = best, current.distance <= distance { continue }
            best = (edge.id, distance)
        }
        return best?.id
    }

    static func distanceFrom(_ p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = min(max(((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared, 0), 1)
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }
}
