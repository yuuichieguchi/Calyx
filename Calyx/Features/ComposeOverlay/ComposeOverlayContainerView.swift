// ComposeOverlayContainerView.swift
// Calyx
//
// NSViewRepresentable wrapper for the compose overlay.

import SwiftUI
import AppKit

struct ComposeOverlayContainerView: NSViewRepresentable {
    var onSend: ((String) -> Void)?
    var onDismiss: (() -> Void)?

    func makeNSView(context: Context) -> ComposeOverlayView {
        let view = ComposeOverlayView()
        view.onSend = onSend
        view.onDismiss = onDismiss
        return view
    }

    func updateNSView(_ nsView: ComposeOverlayView, context: Context) {
        nsView.onSend = onSend
        nsView.onDismiss = onDismiss
    }
}

struct ComposeResizeHandle: View {
    let currentHeight: CGFloat
    let onHeightChanged: (CGFloat) -> Void

    @State private var isHovering = false
    @State private var isDragging = false

    var body: some View {
        Color.clear
            .frame(height: 16)
            .contentShape(Rectangle())
            .onHover { hovering in
                guard !isDragging else { return }
                if hovering && !isHovering {
                    NSCursor.resizeUpDown.push()
                    isHovering = true
                } else if !hovering && isHovering {
                    NSCursor.pop()
                    isHovering = false
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        isDragging = true
                        NSCursor.resizeUpDown.set()
                        let newHeight = max(
                            WindowSession.composeMinHeight,
                            min(WindowSession.composeMaxHeight, currentHeight - value.translation.height)
                        )
                        onHeightChanged(newHeight)
                    }
                    .onEnded { value in
                        let newHeight = max(
                            WindowSession.composeMinHeight,
                            min(WindowSession.composeMaxHeight, currentHeight - value.translation.height)
                        )
                        onHeightChanged(newHeight)
                        isDragging = false
                        NSCursor.arrow.set()
                    }
            )
            .onDisappear {
                if isHovering || isDragging {
                    NSCursor.pop()
                    isHovering = false
                    isDragging = false
                }
            }
    }
}
