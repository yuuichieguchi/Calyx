// GiveUpOverlayView.swift
// Calyx
//
// Persistent in-pane indication shown over a persistent-session surface
// whose reconnect attempts were exhausted but whose pane could not be
// closed because it is the last pane app-wide (R6-B, r6-fix-spec.md,
// r5-verdicts.md V6). Ghostty's own child-exited text is suppressed for
// every surface, and the child process is dead, so sendText goes
// nowhere, this overlay is the only remaining in-app signal.

import AppKit

@MainActor
final class GiveUpOverlayView: NSView {
    private let label = NSTextField(wrappingLabelWithString:
        "Session unreachable. It may still be running; reattach from the session browser. " +
        "Press any key to close this pane.")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.75).cgColor

        label.alignment = .center
        label.textColor = .white
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.backgroundColor = .clear
        label.drawsBackground = false
        label.isBezeled = false
        label.isEditable = false
        label.isSelectable = false
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isOpaque: Bool { false }
}
