// AssumeInsideHover.swift
// Calyx
//
// NSTrackingArea-based hover that detects cursor already inside on view creation.
// Fixes SwiftUI .onHover not firing when a view appears under a stationary cursor.

import AppKit
import SwiftUI

struct AssumeInsideHover: NSViewRepresentable {
    @Binding var isHovering: Bool

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.onHoverChanged = { [self] hovering in
            DispatchQueue.main.async { isHovering = hovering }
        }
        return view
    }

    func updateNSView(_ nsView: TrackingView, context: Context) {}

    final class TrackingView: NSView {
        var onHoverChanged: ((Bool) -> Void)?

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            for area in trackingAreas { removeTrackingArea(area) }
            let area = NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                owner: self
            )
            addTrackingArea(area)

            // Explicitly check if cursor is already inside this view
            if let window = self.window {
                let mouseInWindow = window.mouseLocationOutsideOfEventStream
                let mouseInView = convert(mouseInWindow, from: nil)
                let inside = bounds.contains(mouseInView)
                onHoverChanged?(inside)
            }
        }

        override func mouseEntered(with event: NSEvent) {
            onHoverChanged?(true)
        }

        override func mouseExited(with event: NSEvent) {
            onHoverChanged?(false)
        }
    }
}

extension View {
    func onAssumeInsideHover(_ isHovering: Binding<Bool>) -> some View {
        background(AssumeInsideHover(isHovering: isHovering))
    }
}
