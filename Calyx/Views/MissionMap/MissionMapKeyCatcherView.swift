// MissionMapKeyCatcherView.swift
// Calyx
//
// Mission Map is pure SwiftUI with no text input, so nothing in it would
// otherwise become first responder: keys would keep flowing to the
// terminal hidden underneath. This invisible view takes first responder
// while the map is shown (the window controller makes it so) and turns
// Escape into a dismiss.

import AppKit
import SwiftUI

struct MissionMapKeyCatcherView: NSViewRepresentable {
    let onEscape: () -> Void
    /// Receives the backing view each time it enters a window, so the
    /// window controller can make it first responder.
    let onViewReady: (NSView) -> Void

    func makeNSView(context: Context) -> MissionMapKeyCatcherNSView {
        let view = MissionMapKeyCatcherNSView(frame: .zero)
        view.onEscape = onEscape
        view.onMovedToWindow = onViewReady
        return view
    }

    func updateNSView(_ nsView: MissionMapKeyCatcherNSView, context: Context) {
        nsView.onEscape = onEscape
        nsView.onMovedToWindow = onViewReady
    }
}

@MainActor
final class MissionMapKeyCatcherNSView: NSView {
    /// kVK_Escape.
    private static let escapeKeyCode: UInt16 = 0x35

    var onEscape: (() -> Void)?
    var onMovedToWindow: ((NSView) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        onMovedToWindow?(self)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == Self.escapeKeyCode {
            onEscape?()
        } else {
            super.keyDown(with: event)
        }
    }
}
