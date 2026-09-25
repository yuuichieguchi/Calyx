// MissionMapCanvasLayer.swift
// Calyx
//
// Every Mission Map line, drawn into one Canvas. Lines come and go --
// an IPC line lives up to `MissionMapView.ipcEdgeLifetime` (2 minutes)
// past its newest message, fading out after its own full-opacity window,
// with one pulse dot per message -- so drawing them
// immediate-mode avoids giving each its own view identity and
// animation lifetime. The layer takes no hits: `MissionMapView` matches
// taps against the routed polylines with `MissionMapEdgeHitTester`.

import SwiftUI

/// One edge with the routed polyline it is drawn along.
struct MissionMapEdgeSegment: Identifiable {
    let edge: MissionMapEdge
    /// The route from `MissionMapRouter`: at least 2 points.
    let points: [CGPoint]

    var id: UUID { edge.id }

    /// Where the line's popover and conflict label sit: beside the middle
    /// of its longest segment, on the side with more room among
    /// `obstacles`. `extent` is the label's size; it is moved
    /// perpendicular to the segment by half its extent that way plus
    /// `labelGap`, so it does not cover the line.
    func labelCenter(extent: CGSize, obstacles: [CGRect]) -> CGPoint {
        let (anchor, normal) = MissionMapPolyline.labelPlacement(points, obstacles: obstacles)
        let halfExtent = abs(normal.dx) * extent.width / 2 + abs(normal.dy) * extent.height / 2
        let distance = halfExtent + Self.labelGap
        return CGPoint(x: anchor.x + normal.dx * distance, y: anchor.y + normal.dy * distance)
    }

    static let labelGap: CGFloat = 4
}

struct MissionMapCanvasLayer: View {
    let segments: [MissionMapEdgeSegment]
    let ipcEdgeLifetime: TimeInterval
    /// The leading slice of `ipcEdgeLifetime` an IPC line draws at full
    /// opacity before `alpha(forAge:)` starts fading it linearly across
    /// the remainder -- see `MissionMapView.ipcEdgeFullOpacityDuration`'s
    /// own doc comment.
    let ipcEdgeFullOpacityDuration: TimeInterval
    let selectedEdgeID: UUID?
    /// Cards and band headers, for placing labels beside the lines.
    let obstacles: [CGRect]
    /// `nil` animates the lines on a timeline (the live map); a date draws
    /// them once, as they look at that instant (static rendering).
    let frozenDate: Date?

    /// Seconds for a pulse dot to travel the length of an IPC line.
    private static let pulseTravelTime: TimeInterval = 1.2

    /// Only IPC lines move; conflict lines are static, so the timeline
    /// idles when there is nothing to animate.
    private var hasAnimatedEdges: Bool {
        segments.contains { if case .ipc = $0.edge.kind { true } else { false } }
    }

    var body: some View {
        Group {
            if let frozenDate {
                canvas(at: frozenDate)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !hasAnimatedEdges)) { timeline in
                    canvas(at: timeline.date)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityIdentifier(AccessibilityID.MissionMap.edgeCanvas)
    }

    private func canvas(at date: Date) -> some View {
        Canvas { context, _ in
            for segment in segments {
                draw(segment, in: &context, at: date)
            }
        }
    }

    private func draw(_ segment: MissionMapEdgeSegment, in context: inout GraphicsContext, at date: Date) {
        let isSelected = segment.id == selectedEdgeID
        var line = Path()
        line.addLines(segment.points)
        let lineWidth: CGFloat = isSelected ? 3 : 2
        let stroke = StrokeStyle(lineWidth: lineWidth, lineJoin: .round)

        switch segment.edge.kind {
        case .ipc(let messages):
            // The line itself ages with its newest message: it stays solid
            // while messages keep arriving.
            guard let newest = messages.first else { return }
            let lineAlpha = alpha(forAge: date.timeIntervalSince(newest.sentAt))
            guard lineAlpha > 0 else { return }
            context.stroke(line, with: .color(Color.accentColor.opacity(lineAlpha)), style: stroke)
            // One dot per message, each travelling and fading on its own
            // clock; `messages` is newest first, so the cap keeps the
            // newest.
            for message in messages.prefix(MissionMapSnapshot.maxShownIPCMessages) {
                let age = date.timeIntervalSince(message.sentAt)
                let dotAlpha = alpha(forAge: age)
                guard dotAlpha > 0 else { continue }
                let progress = max(0, age).truncatingRemainder(dividingBy: Self.pulseTravelTime) / Self.pulseTravelTime
                let dot = MissionMapPolyline.point(along: segment.points, t: progress)
                context.fill(
                    Path(ellipseIn: CGRect(x: dot.x - 4, y: dot.y - 4, width: 8, height: 8)),
                    with: .color(Color.accentColor.opacity(dotAlpha))
                )
            }

        case .conflict(let file, _):
            context.stroke(line, with: .color(.red), style: stroke)
            let label = context.resolve(
                Text(file).font(.caption2.weight(.semibold)).foregroundStyle(.white)
            )
            let size = label.measure(in: CGSize(width: 200, height: 40))
            let boxSize = CGSize(width: size.width + 10, height: size.height + 4)
            let mid = segment.labelCenter(extent: boxSize, obstacles: obstacles)
            let box = CGRect(
                x: mid.x - boxSize.width / 2, y: mid.y - boxSize.height / 2,
                width: boxSize.width, height: boxSize.height
            )
            context.fill(Path(roundedRect: box, cornerRadius: box.height / 2), with: .color(.red))
            context.draw(label, at: mid)
        }
    }

    /// Opacity for something `age` seconds after its message was sent:
    /// full for the leading `ipcEdgeFullOpacityDuration`, then a linear
    /// fade across the remainder of `ipcEdgeLifetime` -- a line that just
    /// appeared must not already look half gone, but it still needs to
    /// visibly age out rather than vanish abruptly at the cutoff.
    private func alpha(forAge age: TimeInterval) -> Double {
        guard age > ipcEdgeFullOpacityDuration else { return 1 }
        let fadeWindow = ipcEdgeLifetime - ipcEdgeFullOpacityDuration
        let fadeProgress = fadeWindow > 0 ? (age - ipcEdgeFullOpacityDuration) / fadeWindow : 1
        return max(0, 1 - fadeProgress)
    }
}
