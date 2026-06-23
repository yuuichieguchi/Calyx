//
//  LSPSettingsTests.swift
//  CalyxTests
//
//  Tests for `LSPSettings` — a `UserDefaults`-backed store for the two
//  user-facing LSP knobs surfaced in the Settings UI:
//
//    1. `autoInstallEnabled`         — try to install missing servers at all?
//    2. `requireInstallConfirmation` — prompt before each install step?
//
//  The two booleans collapse into the `ConfirmationMode` already used by
//  `LSPInstaller.install(...)`. Truth table the implementation MUST honor:
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
//  TDD phase: RED. `LSPSettings` does not exist yet. This file is expected
//  to fail to compile until the swift-specialist creates
//  `Calyx/Features/LSP/LSPSettings.swift`. The `ConfirmationMode` enum is
//  already defined in `Calyx/Features/LSP/LSPInstaller.swift`; the
//  implementation MUST reuse it (do not redeclare).
//
//  Test isolation:
//    - Each test starts with `LSPSettings.resetToDefaults()` via `setUp()`,
//      and again clears state in `tearDown()`. UserDefaults is a process-
//      global mutable singleton, so this is non-negotiable for repeat-runs.
//

import XCTest
@testable import Calyx

@MainActor
final class LSPSettingsTests: XCTestCase {

    // ====================================================================
    // MARK: - Lifecycle
    // ====================================================================

    override func setUp() {
        super.setUp()
        // Each test must observe pristine defaults. Calling reset before
        // and after defends against pollution from prior runs as well as
        // sibling test classes that may have written the same keys.
        LSPSettings.resetToDefaults()
    }

    override func tearDown() {
        LSPSettings.resetToDefaults()
        super.tearDown()
    }

    // ====================================================================
    // MARK: - 1. Defaults
    // ====================================================================

    /// After a fresh reset, `autoInstallEnabled` must be `true`.
    /// Calyx's product decision: when a language server is missing we
    /// attempt to install it by default (the user opted into LSP at all).
    func test_default_autoInstallEnabled_isTrue() {
        XCTAssertTrue(
            LSPSettings.autoInstallEnabled,
            "autoInstallEnabled must default to true (auto-install ON)"
        )
    }

    /// After a fresh reset, `requireInstallConfirmation` must be `true`.
    /// We err on the side of asking the user before running brew/npm/etc.
    func test_default_requireInstallConfirmation_isTrue() {
        XCTAssertTrue(
            LSPSettings.requireInstallConfirmation,
            "requireInstallConfirmation must default to true (ask before install)"
        )
    }

    // ====================================================================
    // MARK: - 2. Persistence
    // ====================================================================

    /// Writes to `autoInstallEnabled` must round-trip through UserDefaults.
    /// We toggle both ways to make sure neither value is hard-coded.
    func test_autoInstallEnabled_persists() {
        LSPSettings.autoInstallEnabled = false
        XCTAssertFalse(
            LSPSettings.autoInstallEnabled,
            "Setting autoInstallEnabled = false must be observable on read"
        )

        LSPSettings.autoInstallEnabled = true
        XCTAssertTrue(
            LSPSettings.autoInstallEnabled,
            "Setting autoInstallEnabled = true must be observable on read"
        )
    }

    /// Writes to `requireInstallConfirmation` must round-trip through
    /// UserDefaults. Both directions are exercised.
    func test_requireInstallConfirmation_persists() {
        LSPSettings.requireInstallConfirmation = false
        XCTAssertFalse(
            LSPSettings.requireInstallConfirmation,
            "Setting requireInstallConfirmation = false must be observable on read"
        )

        LSPSettings.requireInstallConfirmation = true
        XCTAssertTrue(
            LSPSettings.requireInstallConfirmation,
            "Setting requireInstallConfirmation = true must be observable on read"
        )
    }

    // ====================================================================
    // MARK: - 3. ConfirmationMode mapping
    // ====================================================================

    /// When auto-install is OFF the installer must never actually run a
    /// command. The mode is `.prompt`, but the returned handler MUST
    /// answer `false` no matter what the caller-supplied handler would
    /// have done. (We pass a handler that would answer `true` to prove
    /// the override is in effect.)
    func test_confirmationMode_autoInstallOff_returnsPromptWithRejectingHandler() async {
        LSPSettings.autoInstallEnabled = false
        // requireInstallConfirmation is irrelevant in this branch; set it
        // to both values across other tests — here we leave it at default.

        let mode = LSPSettings.confirmationMode { _ in
            // Caller-supplied handler would APPROVE — implementation must
            // override this and refuse.
            true
        }

        guard case .prompt(let handler) = mode else {
            XCTFail("Expected .prompt when autoInstallEnabled == false (got \(mode))")
            return
        }

        let decision = await handler("Install rust-analyzer via brew install rust-analyzer")
        XCTAssertFalse(
            decision,
            "When autoInstallEnabled == false, the returned handler must reject"
        )
    }

    /// When auto-install is ON and the user wants confirmation, the mode
    /// must be `.prompt`. We only assert the case here — the associated
    /// handler behavior is delegated to the caller and is covered by
    /// installer-level tests.
    func test_confirmationMode_autoInstallOnRequireConfirmation_returnsPrompt() {
        LSPSettings.autoInstallEnabled = true
        LSPSettings.requireInstallConfirmation = true

        let mode = LSPSettings.confirmationMode { _ in false }

        guard case .prompt = mode else {
            XCTFail(
                "Expected .prompt when autoInstall ON && requireConfirmation ON (got \(mode))"
            )
            return
        }
    }

    /// When auto-install is ON and the user opted out of confirmations,
    /// the mode must be `.silent` (no handler, runs straight through).
    func test_confirmationMode_autoInstallOnSilent_returnsSilent() {
        LSPSettings.autoInstallEnabled = true
        LSPSettings.requireInstallConfirmation = false

        let mode = LSPSettings.confirmationMode { _ in false }

        guard case .silent = mode else {
            XCTFail(
                "Expected .silent when autoInstall ON && requireConfirmation OFF (got \(mode))"
            )
            return
        }
    }

    // ====================================================================
    // MARK: - 3b. LSPSettingsResolution (resolve)
    // ====================================================================

    /// When the master switch is off, `resolve(...)` must return `.disabled`
    /// — a distinct case the caller can route on. We pass a handler that
    /// would answer `true` to prove the resolution does not silently fall
    /// through to `.prompt`.
    func test_resolve_autoInstallDisabled_returnsDisabled() {
        defer { LSPSettings.resetToDefaults() }
        LSPSettings.autoInstallEnabled = false
        // `requireInstallConfirmation` must be ignored in this branch — flip
        // it both ways to make sure neither leaks through.
        LSPSettings.requireInstallConfirmation = true

        let resolution = LSPSettings.resolve { _ in true }
        guard case .disabled = resolution else {
            XCTFail(
                "Expected .disabled when autoInstallEnabled == false (got \(resolution))"
            )
            return
        }

        LSPSettings.requireInstallConfirmation = false
        let resolution2 = LSPSettings.resolve { _ in true }
        guard case .disabled = resolution2 else {
            XCTFail(
                "Expected .disabled when autoInstallEnabled == false (got \(resolution2))"
            )
            return
        }
    }

    /// When auto-install is ON and confirmation is required, `resolve(...)`
    /// must return `.prompt` carrying the caller-supplied handler verbatim.
    /// We assert the handler identity by routing a marker string through it.
    func test_resolve_promptWhenAutoInstallEnabledAndConfirmationRequired() async {
        defer { LSPSettings.resetToDefaults() }
        LSPSettings.autoInstallEnabled = true
        LSPSettings.requireInstallConfirmation = true

        let resolution = LSPSettings.resolve { step in
            // Caller-supplied handler answers true only for one specific
            // step — proves the resolver did not substitute its own.
            step == "approve-me"
        }

        guard case .prompt(let handler) = resolution else {
            XCTFail(
                "Expected .prompt when autoInstall ON && requireConfirmation ON (got \(resolution))"
            )
            return
        }

        let approved = await handler("approve-me")
        let rejected = await handler("something-else")
        XCTAssertTrue(approved, "resolve must forward the caller-supplied handler verbatim")
        XCTAssertFalse(rejected, "resolve must forward the caller-supplied handler verbatim")
    }

    /// When auto-install is ON and the user opted out of confirmations,
    /// `resolve(...)` must return `.silent`.
    func test_resolve_silentWhenAutoInstallEnabledAndNoConfirmation() {
        defer { LSPSettings.resetToDefaults() }
        LSPSettings.autoInstallEnabled = true
        LSPSettings.requireInstallConfirmation = false

        let resolution = LSPSettings.resolve { _ in false }

        guard case .silent = resolution else {
            XCTFail(
                "Expected .silent when autoInstall ON && requireConfirmation OFF (got \(resolution))"
            )
            return
        }
    }

    // ====================================================================
    // MARK: - 4. resetToDefaults
    // ====================================================================

    /// `resetToDefaults()` must restore both knobs to their initial values
    /// regardless of what was written previously.
    func test_resetToDefaults_restoresInitialValues() {
        // Flip both away from defaults.
        LSPSettings.autoInstallEnabled = false
        LSPSettings.requireInstallConfirmation = false
        XCTAssertFalse(LSPSettings.autoInstallEnabled, "Precondition: flipped off")
        XCTAssertFalse(LSPSettings.requireInstallConfirmation, "Precondition: flipped off")

        // Reset and confirm both are back to their documented defaults.
        LSPSettings.resetToDefaults()

        XCTAssertTrue(
            LSPSettings.autoInstallEnabled,
            "resetToDefaults() must restore autoInstallEnabled to true"
        )
        XCTAssertTrue(
            LSPSettings.requireInstallConfirmation,
            "resetToDefaults() must restore requireInstallConfirmation to true"
        )
    }
}
