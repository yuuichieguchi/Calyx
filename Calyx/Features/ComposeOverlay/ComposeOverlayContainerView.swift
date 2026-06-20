// ComposeOverlayContainerView.swift
// Calyx
//
// NSViewRepresentable wrapper for the compose overlay.

import SwiftUI
import AppKit

struct ComposeOverlayContainerView: NSViewRepresentable {
    @Binding var text: String
    var onSend: ((String) -> Bool)?
    var onDismiss: (() -> Void)?
    var onEscapePressed: (() -> Void)?

    func makeNSView(context: Context) -> ComposeOverlayView {
        let view = ComposeOverlayView()
        view.text = text
        view.onSend = onSend
        view.onDismiss = onDismiss
        view.onEscapePressed = onEscapePressed
        view.onTextChanged = { newText in
            if newText != text { text = newText }
        }
        return view
    }

    func updateNSView(_ nsView: ComposeOverlayView, context: Context) {
        if nsView.textView.string != text {
            nsView.text = text
        }
        nsView.onSend = onSend
        nsView.onDismiss = onDismiss
        nsView.onEscapePressed = onEscapePressed
        nsView.onTextChanged = { newText in
            if newText != text { text = newText }
        }
    }
}

struct ComposeResizeHandle: View {
    let currentHeight: CGFloat
    let onHeightChanged: (CGFloat) -> Void

    @State private var isHovering = false
    @State private var isDragging = false

    var body: some View {
        Color.clear
            .frame(height: 12)
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
