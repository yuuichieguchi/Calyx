// DemoWindowFrameArgument.swift
// Calyx
//
// Parses the `--demo-window-frame=<W>x<H>` launch argument consumed by
// AppDelegate.applyDemoWindowFrameIfNeeded() for the scripted 90-second
// product-demo XCUITest scenario (CalyxUITests/DemoRecordingScenario.swift),
// which needs the main window forced to a fixed, screen-recording-friendly
// size and position instead of whatever this machine's screen size /
// CalyxWindowController's own 800x600-then-center() default would produce.
//
// Kept as a pure, AppKit-free parser -- mirrors LaunchEnvironmentPolicy
// .swift's own "pure decision function, real-process convenience left to
// the caller" split -- so CalyxTests can cover every malformed shape
// without booting AppKit or a real NSWindow. The `--uitesting` gate
// (production launches never receive this flag, and this parser is
// meaningless without a live NSScreen to center against anyway) lives at
// the AppDelegate call site, not here.

import Foundation

enum DemoWindowFrameArgument {
    private static let prefix = "--demo-window-frame="

    /// Finds a `--demo-window-frame=<W>x<H>` argument among `arguments`
    /// and parses its value into a `CGSize`. Returns `nil` when the flag
    /// is absent, or its value isn't exactly `<positive integer>x<positive
    /// integer>` -- never throws/crashes on malformed input, since a
    /// demo-only launch argument must never be able to bring down a real
    /// launch.
    ///
    /// Deliberately `Int(_:)`, not `Double(_:)`: `Double` would parse
    /// "inf"/"nan" (`Double("inf") == .infinity`, and `.infinity > 0` is
    /// true), producing a non-finite `NSWindow.setFrame(_:display:)`
    /// frame, and would also silently accept scientific notation like
    /// "1e3" as a width -- neither is a value this flag's `<W>x<H>` shape
    /// is meant to accept. `Int(_:)` rejects both outright. It DOES still
    /// accept a leading `+` (`Int("+1440") == 1440`, part of `Int`'s own
    /// string-conversion grammar) -- left as-is rather than special-cased
    /// out, since a `+`-prefixed positive integer is unambiguous and not
    /// worth extra parsing logic for a demo-only flag.
    ///
    /// Case-sensitive lowercase `x` separator only (`1440X900` does not
    /// match) -- the flag's own documented shape uses a lowercase `x`
    /// (matching common WxH size notation, e.g. display resolutions), and
    /// accepting both cases would silently paper over a typo in a script
    /// invoking this flag instead of surfacing it as "flag ignored".
    ///
    /// No upper bound / screen-size clamping here: this parser has no
    /// access to the real screen geometry (deliberately AppKit-free, see
    /// this file's header), so an oversized value (e.g. "9999x9999") is
    /// accepted as-is. `AppDelegate.applyDemoWindowFrameIfNeeded()`
    /// centers whatever size this returns on `NSScreen.main`'s own visible
    /// frame -- an oversized window simply extends off-screen, exactly
    /// like any other `NSWindow.setFrame(_:display:)` call would, rather
    /// than being silently rewritten to a different size than what was
    /// asked for.
    static func parse(_ arguments: [String]) -> CGSize? {
        guard let match = arguments.first(where: { $0.hasPrefix(prefix) }) else {
            return nil
        }
        let value = match.dropFirst(prefix.count)
        let parts = value.split(separator: "x", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let width = Int(parts[0]), width > 0,
              let height = Int(parts[1]), height > 0 else {
            return nil
        }
        return CGSize(width: CGFloat(width), height: CGFloat(height))
    }
}
