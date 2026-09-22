// CalyxPathRootArgument.swift
// Calyx
//
// Parses the `--calyx-path-root=<dir>` launch argument the UI-test runner
// uses to scope one app launch's config/app-support paths to a temporary
// directory (CalyxPathRoot consumes this to build its own testRoot).
//
// Kept as a pure, AppKit-free parser -- mirrors DemoWindowFrameArgument
// .swift's own "pure decision function, real-process convenience left to
// the caller" split, and its `--uitesting`-adjacent flags reach this
// parser through the same ProcessInfo.processInfo.arguments array -- so
// CalyxTests can cover every shape without touching the file system.

import Foundation

enum CalyxPathRootArgument {
    private static let prefix = "--calyx-path-root="

    /// Finds a `--calyx-path-root=<dir>` argument among `arguments` and
    /// returns its value. Returns `nil` when the flag is absent or its
    /// value is empty -- an empty value is never a usable directory path,
    /// and silently treating it as "no override" is safer than resolving
    /// paths against an empty string.
    static func parse(_ arguments: [String]) -> String? {
        guard let match = arguments.first(where: { $0.hasPrefix(prefix) }) else {
            return nil
        }
        let value = match.dropFirst(prefix.count)
        return value.isEmpty ? nil : String(value)
    }
}
