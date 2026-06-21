//
//  LSPSettings.swift
//  Calyx
//
//  UserDefaults-backed store for the two user-facing LSP installer knobs
//  surfaced in the Settings UI:
//
//    1. `autoInstallEnabled`         — try to install missing servers at all?
//    2. `requireInstallConfirmation` — prompt before each install step?
//
//  The two booleans collapse into the `ConfirmationMode` already used by
//  `LSPInstaller.install(...)` through `confirmationMode(confirmationHandler:)`:
//
//    autoInstallEnabled  requireConfirmation   confirmationMode(handler:)
//    ------------------  -------------------   ---------------------------------
//          false               (ignored)       .prompt with a handler that
//                                              UNCONDITIONALLY returns `false`
//                                              (effectively refuses any install)
//          true                  true          .prompt with the caller-supplied
//                                              handler (UI surfaces the prompt)
//          true                  false         .silent
//
//  Both knobs default to `true` on first launch: Calyx attempts auto-install
//  by default, but asks the user before running `brew` / `npm` / etc.
//
//  The type is a `Sendable` namespace struct — all access is through static
//  members. `resetToDefaults()` strips the persisted keys so callers (tests,
//  Settings UI "Restore Defaults") observe the initial defaults again.
//

import Foundation

struct LSPSettings: Sendable {

    // MARK: - UserDefaults keys

    static let autoInstallEnabledKey = "calyx.lsp.autoInstallEnabled"
    static let requireInstallConfirmationKey = "calyx.lsp.requireInstallConfirmation"

    // MARK: - Knobs

    /// Master switch: when `false`, the installer must never run a command
    /// regardless of the confirmation handler the caller supplies.
    static var autoInstallEnabled: Bool {
        get {
            // `object(forKey:)` distinguishes "never written" from "written false".
            // We treat unset as the documented default (true).
            if UserDefaults.standard.object(forKey: autoInstallEnabledKey) == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: autoInstallEnabledKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: autoInstallEnabledKey)
        }
    }

    /// When `true`, each install step is gated on a user prompt; when
    /// `false`, the installer runs straight through (silent mode).
    /// Ignored when `autoInstallEnabled == false`.
    static var requireInstallConfirmation: Bool {
        get {
            if UserDefaults.standard.object(forKey: requireInstallConfirmationKey) == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: requireInstallConfirmationKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: requireInstallConfirmationKey)
        }
    }

    // MARK: - Mapping into ConfirmationMode

    /// Collapse the two knobs into the `ConfirmationMode` expected by
    /// `LSPInstaller.install(...)`. Callers supply the handler they would
    /// like to be consulted in "prompt" mode (typically a UI bridge); when
    /// auto-install is disabled the supplied handler is OVERRIDDEN by a
    /// closure that unconditionally refuses, so no install command ever
    /// runs.
    static func confirmationMode(
        confirmationHandler: @Sendable @escaping (String) async -> Bool
    ) -> ConfirmationMode {
        if !autoInstallEnabled {
            // Master switch off: refuse every step regardless of what the
            // caller-supplied handler would have done.
            return .prompt(handler: { @Sendable _ in false })
        }
        if requireInstallConfirmation {
            return .prompt(handler: confirmationHandler)
        }
        return .silent
    }

    // MARK: - Reset

    /// Strip both persisted keys so subsequent reads return the documented
    /// defaults. Used by tests for isolation, and intended for a future
    /// Settings UI "Restore Defaults" action.
    static func resetToDefaults() {
        UserDefaults.standard.removeObject(forKey: autoInstallEnabledKey)
        UserDefaults.standard.removeObject(forKey: requireInstallConfirmationKey)
    }
}
