import AppKit
import SwiftUI

/// Hosts `AboutView` in a standard, borderless-titlebar window --
/// Calyx's replacement for `NSApp.orderFrontStandardAboutPanel`, which
/// could only ever show a name/version and had no room for the
/// Build/Commit rows or the Docs/GitHub buttons (Ghostty's own About
/// window, `macos/Sources/Features/About/AboutController.swift`, is the
/// model here).
///
/// Built programmatically rather than from a nib, matching
/// `SettingsWindowController`/`SessionBrowserWindowController` -- this
/// project has no xib/storyboard anywhere.
///
/// Consequence worth knowing when touching Cmd+W behavior (issue #45,
/// see `NSWindow+CalyxClose.swift`): this is a plain `NSWindow`, not the
/// old standard panel's `NSPanel`, so `canBecomeMain == true` and it
/// takes over as both key AND main while visible. `calyxPerformClose(_:)`
/// still resolves against its own responder chain first, so Cmd+W closes
/// About and nothing else.
@MainActor
final class AboutWindowController: NSWindowController, NSWindowDelegate {
    static let shared = AboutWindowController()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 172),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        // Titlebar shows only the traffic lights, as in Ghostty's About:
        // the window art already names the app. The title is still SET
        // (not empty) because it is the window's accessibility identity,
        // which `AuxiliaryWindowCloseE2ETests` locates the window by.
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "About Calyx"
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false

        super.init(window: window)

        window.delegate = self
        window.contentViewController = NSHostingController(rootView: AboutView())
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    func show() {
        // `center()` here as well as in `init`: a reopen after the user
        // dragged the window (it is `isMovableByWindowBackground`) should
        // come back centered, same as the standard About panel did.
        if window?.isVisible != true { window?.center() }
        window?.makeKeyAndOrderFront(nil)
    }

    func hide() {
        window?.close()
    }

    /// Escape closes the window -- AppKit sends `cancel(_:)` down the
    /// responder chain, which reaches this controller as the window's
    /// delegate/controller.
    @objc func cancel(_ sender: Any?) {
        hide()
    }
}
