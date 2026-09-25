// MissionMapEdgeHitTester.swift
// Calyx
//
// Hit testing for Mission Map's lines. They are all drawn into one
// Canvas, which has no per-element hit testing, so a tap is matched
// against the lines' geometry here instead: the orthogonal polylines
// `MissionMapRouter` produces, or plain segments.

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
        nearest(point: point, polylines: edges.map { (id: $0.id, points: [$0.a, $0.b]) }, tolerance: tolerance)
    }

    /// The id of the polyline closest to `point`, if that distance is at
    /// most `tolerance`; `nil` when every polyline is farther away. A
    /// polyline's distance is the minimum over its consecutive segments
    /// (a single-point polyline is measured to that point), so a routed
    /// line is hit along its actual path, not along the chord between its
    /// endpoints.
    static func nearest(
        point: CGPoint, polylines: [(id: UUID, points: [CGPoint])], tolerance: CGFloat = 6
    ) -> UUID? {
        var best: (id: UUID, distance: CGFloat)?
        for polyline in polylines {
            guard let distance = distanceFrom(point, toPolyline: polyline.points) else { continue }
            guard distance <= tolerance else { continue }
            if let current = best, current.distance <= distance { continue }
            best = (polyline.id, distance)
        }
        return best?.id
    }

    /// Distance from `p` to the nearest segment of `points`; `nil` for an
    /// empty polyline, which has no geometry to measure against.
    static func distanceFrom(_ p: CGPoint, toPolyline points: [CGPoint]) -> CGFloat? {
        guard let first = points.first else { return nil }
        guard points.count > 1 else { return hypot(p.x - first.x, p.y - first.y) }
        return zip(points, points.dropFirst())
            .map { distanceFrom(p, toSegment: $0, $1) }
            .min()
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
