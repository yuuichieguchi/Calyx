// MissionMapCanvasLayer.swift
// Calyx
//
// Every Mission Map line, drawn into one Canvas. Lines come and go --
// an IPC line lives up to `MissionMapView.ipcEdgeLifetime` (2 minutes),
// fading out after its own full-opacity window -- so drawing them
// immediate-mode avoids giving each its own view identity and
// animation lifetime. The layer takes no hits: `MissionMapView` matches
// taps against the segments with `MissionMapEdgeHitTester`.

import SwiftUI

/// One edge with the on-screen segment it is drawn along.
struct MissionMapEdgeSegment: Identifiable {
    let edge: MissionMapEdge
    let a: CGPoint
    let b: CGPoint

    var id: UUID { edge.id }

    var midpoint: CGPoint {
        CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
    }
}

struct MissionMapCanvasLayer: View {
    let segments: [MissionMapEdgeSegment]
    let ipcEdgeLifetime: TimeInterval
    /// The leading slice of `ipcEdgeLifetime` an IPC line draws at full
    /// opacity before `draw(_:in:at:)` starts fading it linearly across
    /// the remainder -- see `MissionMapView.ipcEdgeFullOpacityDuration`'s
    /// own doc comment.
    let ipcEdgeFullOpacityDuration: TimeInterval
    let selectedEdgeID: UUID?

    /// Seconds for a pulse dot to travel the length of an IPC line.
    private static let pulseTravelTime: TimeInterval = 1.2

    /// Only IPC lines move; conflict lines are static, so the timeline
    /// idles when there is nothing to animate.
    private var hasAnimatedEdges: Bool {
        segments.contains { if case .ipc = $0.edge.kind { true } else { false } }
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !hasAnimatedEdges)) { timeline in
            Canvas { context, _ in
                for segment in segments {
                    draw(segment, in: &context, at: timeline.date)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityIdentifier(AccessibilityID.MissionMap.edgeCanvas)
    }

    private func draw(_ segment: MissionMapEdgeSegment, in context: inout GraphicsContext, at date: Date) {
        let isSelected = segment.id == selectedEdgeID
        var line = Path()
        line.move(to: segment.a)
        line.addLine(to: segment.b)

        switch segment.edge.kind {
        case .ipc(let event):
            let age = date.timeIntervalSince(event.sentAt)
            // Full opacity for the leading `ipcEdgeFullOpacityDuration`,
            // then a linear fade across the remainder of `ipcEdgeLifetime`
            // -- a line that just appeared must not already look half
            // gone, but it still needs to visibly age out rather than
            // vanish abruptly at the cutoff.
            let alpha: Double
            if age <= ipcEdgeFullOpacityDuration {
                alpha = 1
            } else {
                let fadeWindow = ipcEdgeLifetime - ipcEdgeFullOpacityDuration
                let fadeProgress = fadeWindow > 0 ? (age - ipcEdgeFullOpacityDuration) / fadeWindow : 1
                alpha = max(0, 1 - fadeProgress)
            }
            guard alpha > 0 else { return }
            context.stroke(
                line,
                with: .color(Color.accentColor.opacity(alpha)),
                lineWidth: isSelected ? 3 : 2
            )
            let progress = max(0, age).truncatingRemainder(dividingBy: Self.pulseTravelTime) / Self.pulseTravelTime
            let dot = CGPoint(
                x: segment.a.x + (segment.b.x - segment.a.x) * progress,
                y: segment.a.y + (segment.b.y - segment.a.y) * progress
            )
            context.fill(
                Path(ellipseIn: CGRect(x: dot.x - 4, y: dot.y - 4, width: 8, height: 8)),
                with: .color(Color.accentColor.opacity(alpha))
            )

        case .conflict(let file, _):
            context.stroke(line, with: .color(.red), lineWidth: isSelected ? 3 : 2)
            let label = context.resolve(
                Text(file).font(.caption2.weight(.semibold)).foregroundStyle(.white)
            )
            let size = label.measure(in: CGSize(width: 200, height: 40))
            let mid = segment.midpoint
            let box = CGRect(
                x: mid.x - size.width / 2 - 5, y: mid.y - size.height / 2 - 2,
                width: size.width + 10, height: size.height + 4
            )
            context.fill(Path(roundedRect: box, cornerRadius: box.height / 2), with: .color(.red))
            context.draw(label, at: mid)
        }
    }
}
