// CalyxShellIntegrationEnvironment.swift
// Calyx
//
// Applies ShellIntegrationInstaller's installed script tree to this
// process's own environment -- mirrors GhosttyResourcesDirEnvironment's
// direct setenv/getenv shape (see that file), rather than an injected
// seam: GhosttyResourcesDirEnvironmentTests, the established precedent
// for this exact kind of process-environment mutation in this codebase,
// itself saves/restores the real environment around each test rather
// than injecting a closure, so this follows the same convention.
//
// Injection point: setting ZDOTDIR/XDG_DATA_DIRS in THIS process's own
// environment (not a surface's per-surface config.env_vars) is
// deliberate -- see the command-log plan's own "注入点の修正" note: a
// surface's individual env is applied AFTER ghostty's own shell
// integration setup, so setting ZDOTDIR there would stomp ghostty's
// setup instead of chaining after it. Process env is read fresh by every
// new surface, so a toggle change takes effect from the next new pane
// without an app restart.

import Foundation

enum CalyxShellIntegrationEnvironment {
    static let zdotdirVariableName = "ZDOTDIR"
    static let originalZdotdirVariableName = "CALYX_ZSH_ZDOTDIR"
    static let xdgDataDirsVariableName = "XDG_DATA_DIRS"

    /// fish's own documented default `XDG_DATA_DIRS` search path
    /// (without our own root prepended) -- both the value `apply()`
    /// initializes XDG_DATA_DIRS to when it was unset, and the value
    /// `remove()` compares its own post-removal result against to decide
    /// whether to unset the variable entirely (see `remove`'s own doc
    /// comment for that heuristic's known edge case).
    private static let fishDefaultDataDirs = "/usr/local/share:/usr/share"

    /// Points this process's ZDOTDIR at `<rootDirectory>/zsh` and
    /// appends `rootDirectory` to XDG_DATA_DIRS (fish's own vendor
    /// conf.d discovery path), initializing it to
    /// `"<rootDirectory>:/usr/local/share:/usr/share"` (fish's own
    /// documented default search path) when it was unset. Any
    /// PRE-EXISTING ZDOTDIR is preserved into CALYX_ZSH_ZDOTDIR first --
    /// but only when one was actually set (`${VAR+X}` existence
    /// semantics: unset and set-to-empty are distinguished, matching the
    /// zsh chain design's own `.zshenv` restore check) AND it doesn't
    /// already point at our own installed zsh dir (a re-`apply()` call --
    /// e.g. a second surface launching, or a Settings toggle flip after
    /// an earlier `apply()` already ran in this same process -- must NOT
    /// clobber the correctly-saved true original with our own path).
    /// XDG_DATA_DIRS gets the same re-`apply()` idempotency: `rootDirectory`
    /// is appended only when it isn't already one of the existing
    /// colon-separated entries, so calling `apply()` twice in the same
    /// process without an intervening `remove()` doesn't duplicate it.
    static func apply(rootDirectory: URL) {
        let zshDirectory = rootDirectory.appendingPathComponent("zsh").path

        if let currentZdotdir = getenv(zdotdirVariableName).map({ String(cString: $0) }),
           currentZdotdir != zshDirectory {
            setenv(originalZdotdirVariableName, currentZdotdir, 1)
        }
        setenv(zdotdirVariableName, zshDirectory, 1)

        if let currentXdgDataDirs = getenv(xdgDataDirsVariableName).map({ String(cString: $0) }) {
            let entries = currentXdgDataDirs.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            if !entries.contains(rootDirectory.path) {
                setenv(xdgDataDirsVariableName, "\(currentXdgDataDirs):\(rootDirectory.path)", 1)
            }
        } else {
            setenv(xdgDataDirsVariableName, "\(rootDirectory.path):\(fishDefaultDataDirs)", 1)
        }
    }

    /// Reverses `apply(rootDirectory:)`: restores ZDOTDIR from
    /// CALYX_ZSH_ZDOTDIR (or unsets it if none was saved) and removes
    /// `rootDirectory` from XDG_DATA_DIRS -- but ONLY when the current
    /// values still point at `rootDirectory`'s own installed paths, so a
    /// later, unrelated caller's own customization of either variable is
    /// never clobbered by an unconditional reverse. The two variables
    /// are gated independently (not on a single combined check): ZDOTDIR
    /// restores only if ZDOTDIR itself still points at our installed
    /// zsh dir; XDG_DATA_DIRS is stripped only if it still contains our
    /// root entry -- matching `apply`'s own independent handling of the
    /// two. CALYX_ZSH_ZDOTDIR itself is always cleared, regardless of
    /// either gate: it's purely our own internal bookkeeping variable
    /// (never meaningful to anything but this restore chain), so
    /// `remove()` clears it unconditionally as part of undoing
    /// everything `apply()` might have set.
    ///
    /// XDG_DATA_DIRS's own "was it initialized vs. appended" state isn't
    /// tracked anywhere durable (this is a static function, and even a
    /// stored flag wouldn't survive across process launches) -- so
    /// whether to unset XDG_DATA_DIRS entirely (matching a prior
    /// `apply()` that initialized it fresh) vs. leave a rejoined value
    /// (matching a prior `apply()` that appended to a pre-existing one)
    /// is approximated: if stripping our own root entry leaves EXACTLY
    /// `fishDefaultDataDirs`, that's treated as "we must have
    /// initialized it" and the variable is unset entirely. Known false
    /// positive: a user who legitimately had XDG_DATA_DIRS set to
    /// exactly `"/usr/local/share:/usr/share"` BEFORE `apply()` ever ran
    /// (with `apply()` then appending our root, and this `remove()` now
    /// stripping it back to that same original value) will have it
    /// unset instead of restored to that exact string -- a difference
    /// without an observable effect, since fish's own documented
    /// default IS exactly that string when the variable is unset.
    static func remove(rootDirectory: URL) {
        let zshDirectory = rootDirectory.appendingPathComponent("zsh").path

        if getenv(zdotdirVariableName).map({ String(cString: $0) }) == zshDirectory {
            if let original = getenv(originalZdotdirVariableName).map({ String(cString: $0) }) {
                setenv(zdotdirVariableName, original, 1)
            } else {
                unsetenv(zdotdirVariableName)
            }
        }
        unsetenv(originalZdotdirVariableName)

        if let currentXdgDataDirs = getenv(xdgDataDirsVariableName).map({ String(cString: $0) }) {
            let entries = currentXdgDataDirs.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            guard entries.contains(rootDirectory.path) else { return }
            let filtered = entries.filter { $0 != rootDirectory.path }
            let rejoined = filtered.joined(separator: ":")
            if rejoined == fishDefaultDataDirs {
                unsetenv(xdgDataDirsVariableName)
            } else {
                setenv(xdgDataDirsVariableName, rejoined, 1)
            }
        }
    }
}
