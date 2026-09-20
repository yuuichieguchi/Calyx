// NSWindow+CalyxClose.swift
// Calyx
//
// Issue #45: Cmd+W is silently inert on the About panel / Settings /
// Session Browser (any non-`CalyxWindow` panel) and, worse, closes a
// TERMINAL window's active tab out from under the user while one of
// those panels is key.
//
// Root cause: the File menu's only Cmd+W item has a nil target and
// `action: #selector(CalyxWindowController.closeTab(_:))`. AppKit's
// `-[NSApplication targetForAction:]` resolves a nil-target action by
// walking, in order: (1) the KEY window's extended responder chain
// (first responder -> ... -> window -> window delegate -> window
// controller), (2) the MAIN window's extended responder chain, (3)
// NSApp, (4) NSApp's delegate. Step (1) always fails to resolve
// `closeTab(_:)` against a non-`CalyxWindow` panel's own chain (no
// `CalyxWindowController` anywhere in it), so AppKit falls through to
// step (2) — but what step (2) finds next, and therefore the
// user-visible symptom, differs by panel:
//   - An `NSPanel` that reports `canBecomeMain == false` (at the time
//     this was written, About: `AppDelegate.showAboutPanel()` then went
//     through `NSApp.orderFrontStandardAboutPanel`) leaves
//     `NSApp.mainWindow` pinned to whichever `CalyxWindow` was main
//     before the panel opened. Step (2) then hits THAT terminal
//     window's `CalyxWindowController` instead — closing the wrong
//     window's active tab while the panel the user is actually looking
//     at does nothing.
//   - A plain `NSWindow`, not an `NSPanel` — About
//     (`AboutWindowController.swift`, which replaced the standard panel
//     with Calyx's own SwiftUI About window), Settings
//     (`SettingsWindowController.swift`) and Session Browser
//     (`SessionBrowserWindowController.swift`) — has `canBecomeMain`
//     defaulting to `true`, so the panel becomes main itself the moment
//     it becomes key. Step (2) then walks that SAME panel's chain a
//     second time and still finds no `CalyxWindowController`, so the
//     nil-target action resolves to nothing anywhere and AppKit
//     auto-disables the menu item instead — no misrouted close, but no
//     response either.
// Both shapes are documented, not just the one this app ships today:
// the `canBecomeMain == false` case is still live for any future
// `NSPanel` (and `SurfaceView.swift`'s own Edit-action gate cites it).
// Either way the menu item is broken — destructively misrouted in the
// first shape, silently inert in the second.
//
// Fix: give `NSWindow` ITSELF a method with a stable selector,
// `calyxPerformClose(_:)`. Since every window (a plain `NSWindow`/
// `NSPanel` -- About, Settings, Session Browser -- and this app's own
// `CalyxWindow`/`QuickTerminalWindow` subclasses) can answer this
// selector directly, step (1) above (the KEY window's own chain)
// always resolves it, so resolution never needs to fall through to
// step (2)'s main-window fallback -- structurally eliminating the
// misrouting, not just special-casing About.
//
// This must NOT be `performClose:` overridden on `CalyxWindow`/
// `QuickTerminalWindow`: `CalyxWindowController.processCloseWindow()`
// (the sole receiver of ghostty's `close_window` action, Cmd+Shift+W)
// calls `window?.performClose(nil)` directly, and every subclass must
// keep AppKit's own, unmodified `performClose:` implementation for
// that to keep working.
//
// `@objc` is required for two independent reasons: (1) it is what lets
// `-validateMenuItem:`/`-targetForAction:` resolve this selector via
// the Objective-C runtime at all, and (2) since `NSWindow` lives in
// AppKit (a different module from this extension), only a member that
// dispatches through the Objective-C runtime -- which `@objc` confers
// on any `NSObject` subclass -- can be `override`n by a subclass
// declared in THIS module (`CalyxWindow`/`QuickTerminalWindow`); a
// plain, non-`@objc` Swift extension method on an imported class cannot
// be overridden at all (no vtable slot exists for it outside the
// module that defined the base class).
import AppKit

@MainActor
extension NSWindow {
    /// Default `calyxPerformClose(_:)` for any window that doesn't
    /// override it (About, Settings, Session Browser — every plain
    /// `NSWindow`/`NSPanel` in this app). A sheet must only ever
    /// close via its own presenting controller's explicit button/
    /// `endSheet` call: `ClipboardConfirmationController`'s sheet holds
    /// an in-flight libghostty clipboard request that only its own code
    /// resolves, and skipping straight to `performClose`/`close` here
    /// would leave that surface waiting forever. Checked BEFORE
    /// `performClose(sender)` runs at all — see this file's own header
    /// comment for why this ordering, not `performClose`'s own
    /// (AppKit-version-dependent) sheet handling, is what this method
    /// relies on.
    @objc func calyxPerformClose(_ sender: Any?) {
        guard sheetParent == nil else {
            NSSound.beep()
            return
        }
        performClose(sender)
    }
}
