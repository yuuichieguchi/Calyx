// ShellIntegrationActivation.swift
// Calyx
//
// Shared install-then-apply sequencing for Calyx's own shell
// integration, used by both AppDelegate.applyCalyxShellIntegrationIfEnabled()
// (app launch) and SettingsWindowController.commandTrackingDidChange
// (toggle flipped ON) -- a single source of truth so both call sites
// share the same install-failure handling instead of two independently
// maintained (and, before this fix, divergently buggy) copies.

import Foundation
import OSLog

private let logger = Logger(subsystem: "com.calyx.terminal", category: "ShellIntegrationActivation")

enum ShellIntegrationActivation {

    /// Installs Calyx's own zsh/fish integration scripts into `root`,
    /// then -- ONLY if that install actually succeeded --
    /// points this process's environment at `root`
    /// (`CalyxShellIntegrationEnvironment.apply(rootDirectory:)`).
    ///
    /// CRITICAL fix (code review): the previous shape at both call sites
    /// was `try? install(...)` followed by an UNCONDITIONAL `apply(...)`.
    /// On an install failure (e.g. an unwritable App Support directory),
    /// that silently pointed ZDOTDIR at a directory tree with no
    /// `.zshenv` in it -- and command tracking defaults ON, so a fresh
    /// install with a permissions problem would silently break EVERY new
    /// terminal's shell startup (zsh finds no `.zshenv` and skips
    /// straight to `.zshrc`/`.zprofile` with no `$HOME` fallback, unlike
    /// the deliberate `.zshenv`-driven restore chain this whole feature
    /// depends on) with no diagnostic anywhere. Gating `apply` on a
    /// successful `install` means a failure instead leaves the
    /// environment untouched (ZDOTDIR keeps whatever it already was --
    /// unset, or ghostty's own bundled value), which degrades to "no
    /// command tracking" rather than "broken shell startup".
    ///
    /// Returns whether activation (both steps) succeeded, so a caller
    /// that wants to react (a future UI affordance, a test) can; neither
    /// current call site needs the value.
    @discardableResult
    static func activateIfPossible(root: URL) -> Bool {
        do {
            _ = try ShellIntegrationInstaller.install(toDirectory: root)
        } catch {
            logger.error("Failed to install shell integration into \(root.path, privacy: .public): \(error, privacy: .public)")
            return false
        }
        CalyxShellIntegrationEnvironment.apply(rootDirectory: root)
        return true
    }
}
