//
//  LSPSettingsBugSpecTests.swift
//  CalyxTests
//
//  Wave 1 RETROFIT — independent regression tests derived purely from the
//  bug specification for `LSPSettings.resolve(confirmationHandler:)`.
//
//  BUG SPEC:
//    When `autoInstallEnabled = false`, the pre-fix `confirmationMode(...)`
//    returned `.prompt(handler: { _ in false })` — a handler that refuses
//    every step. Downstream `LSPInstaller` then surfaced
//    `failed(reason: "user declined: <step>")` — misleading since no
//    actual user declined.
//    POST-FIX: introduce a `.disabled` resolution case (separate enum
//    `LSPSettingsResolution`) that callers route on directly to emit a
//    clear "auto-install disabled in Settings" message.
//
//  These tests are INDEPENDENT of LSPSettingsTests.swift — different test
//  class, derived purely from the bug spec above.
//

import XCTest
@testable import Calyx

final class LSPSettingsBugSpecTests: XCTestCase {

    // MARK: - .disabled resolution when auto-install is off

    func test_resolve_returnsDisabled_whenAutoInstallEnabledFalse() {
        defer { LSPSettings.resetToDefaults() }

        LSPSettings.autoInstallEnabled = false

        let resolution = LSPSettings.resolve(confirmationHandler: { _ in true })

        switch resolution {
        case .disabled:
            // Expected.
            break
        case .prompt:
            XCTFail("Expected .disabled but got .prompt — pre-fix behavior detected")
        case .silent:
            XCTFail("Expected .disabled but got .silent")
        }
    }

    // MARK: - .prompt resolution when auto-install is on AND confirmation required

    func test_resolve_returnsPrompt_whenAutoInstallEnabledAndConfirmationRequired() {
        defer { LSPSettings.resetToDefaults() }

        LSPSettings.autoInstallEnabled = true
        LSPSettings.requireInstallConfirmation = true

        let resolution = LSPSettings.resolve(confirmationHandler: { _ in true })

        switch resolution {
        case .prompt:
            // Expected.
            break
        case .disabled:
            XCTFail("Expected .prompt but got .disabled")
        case .silent:
            XCTFail("Expected .prompt but got .silent")
        }
    }

    // MARK: - .silent resolution when auto-install on AND confirmation NOT required

    func test_resolve_returnsSilent_whenAutoInstallEnabledAndConfirmationNotRequired() {
        defer { LSPSettings.resetToDefaults() }

        LSPSettings.autoInstallEnabled = true
        LSPSettings.requireInstallConfirmation = false

        let resolution = LSPSettings.resolve(confirmationHandler: { _ in true })

        switch resolution {
        case .silent:
            // Expected.
            break
        case .disabled:
            XCTFail("Expected .silent but got .disabled")
        case .prompt:
            XCTFail("Expected .silent but got .prompt")
        }
    }

    // MARK: - .disabled wins over .silent even when confirmation not required

    func test_resolve_disabledTakesPriorityOver_requireConfirmation() {
        defer { LSPSettings.resetToDefaults() }

        LSPSettings.autoInstallEnabled = false
        LSPSettings.requireInstallConfirmation = false

        let resolution = LSPSettings.resolve(confirmationHandler: { _ in true })

        switch resolution {
        case .disabled:
            // Expected — auto-install off must short-circuit before the
            // requireInstallConfirmation flag is considered.
            break
        case .silent:
            XCTFail("Expected .disabled but got .silent — disabled must take priority")
        case .prompt:
            XCTFail("Expected .disabled but got .prompt")
        }
    }
}
