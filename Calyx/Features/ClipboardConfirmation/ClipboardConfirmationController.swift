import AppKit
import SwiftUI
import GhosttyKit

@MainActor
class ClipboardConfirmationController: NSWindowController, NSWindowDelegate {
    let surface: ghostty_surface_t
    let contents: String
    let request: ClipboardRequest
    let state: UnsafeMutableRawPointer?
    private var didComplete = false

    init(surface: ghostty_surface_t, contents: String, request: ClipboardRequest, state: UnsafeMutableRawPointer?) {
        self.surface = surface
        self.contents = contents
        self.request = request
        self.state = state

        let title: String
        switch request {
        case .paste:
            title = "Warning: Potentially Unsafe Paste"
        case .osc52Read, .osc52Write:
            title = "Authorize Clipboard Access"
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = title

        super.init(window: window)

        window.delegate = self
        window.contentView = NSHostingView(rootView: ClipboardConfirmationView(
            contents: contents,
            request: request,
            onConfirm: { [weak self] in self?.complete(confirmed: true) },
            onCancel: { [weak self] in self?.complete(confirmed: false) }
        ))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: - Private

    private func complete(confirmed: Bool) {
        guard !didComplete else { return }
        didComplete = true

        contents.withCString { ptr in
            GhosttyFFI.surfaceCompleteClipboardRequest(surface, data: ptr, state: state, confirmed: confirmed)
        }

        if let parentWindow = window?.sheetParent {
            parentWindow.endSheet(window!)
        } else {
            window?.close()
        }
    }

    // Handle window close button as cancel
    func windowWillClose(_ notification: Notification) {
        if !didComplete {
            complete(confirmed: false)
        }
    }
}
