// GhosttyResourcesDirEnvironment.swift
// Calyx
//
// Applies a GhosttyResourcesDirResolver result to this process's own
// environment. GHOSTTY_RESOURCES_DIR is how ghostty's Exec
// (ghostty/src/termio/Exec.zig) decides whether to forward its
// shell-integration scripts to surface children; Calyx never set it
// before this fix (architecture.md §3's documented gap).

import Foundation

enum GhosttyResourcesDirEnvironment {
    static let variableName = "GHOSTTY_RESOURCES_DIR"

    /// Sets `variableName` to `resolvedPath`, if non-nil. Calyx's own
    /// bundled ghostty resources are version-matched to the embedded
    /// libghostty, unlike an inherited standalone-Ghostty path (e.g. one
    /// leaked in via `open` from a Ghostty-hosted shell during
    /// development), so a resolved path deliberately OVERWRITES (via
    /// `setenv`'s overwrite = 1) any existing value rather than deferring
    /// to it. `nil` is a strict no-op: it leaves any existing value (or
    /// absence of one) exactly as it was.
    static func apply(_ resolvedPath: String?) {
        guard let resolvedPath else {
            return
        }
        setenv(variableName, resolvedPath, 1)
    }
}
