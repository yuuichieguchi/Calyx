//
//  GhosttyResourcesDirEnvironmentTests.swift
//  CalyxTests
//
//  TDD Red phase (persistent-session shell-integration fix): the process-
//  environment application half of the GHOSTTY_RESOURCES_DIR fix (see
//  GhosttyResourcesDirResolverTests's header for the resolver half this
//  pairs with, and this codebase's known gap noted in architecture.md
//  §3). Calyx's own bundled ghostty resources are version-matched to the
//  embedded libghostty, so a resolved path must OVERWRITE any inherited
//  value (e.g. a standalone Ghostty.app's own GHOSTTY_RESOURCES_DIR,
//  leaked in via `open` from a Ghostty-hosted shell during development,
//  the only reason the variable is present at all in today's dev
//  sessions) rather than deferring to it -- an inherited path may not
//  match the libghostty version Calyx actually embeds.
//
//  Held-out compile-RED (see SessionCommandSynthesizerRemoteAttachTests's
//  header for this codebase's convention): GhosttyResourcesDirEnvironment
//  does not exist yet anywhere in the codebase, so this file fails to
//  compile until the Green phase adds it. That compile failure IS this
//  file's RED evidence.
//
//  Proposed API (Calyx/GhosttyBridge/GhosttyResourcesDirEnvironment.swift):
//
//    enum GhosttyResourcesDirEnvironment {
//        static let variableName: String   // "GHOSTTY_RESOURCES_DIR"
//        static func apply(_ resolvedPath: String?)
//            // resolvedPath != nil: setenv(variableName, resolvedPath, 1)
//            //   (overwrite = 1, deliberate -- see header above)
//            // resolvedPath == nil: no-op, leaves any existing value
//            //   (or absence of one) exactly as it was
//    }
//
//  Coverage:
//  - apply(_:) with a valid resolved path overwrites a pre-existing
//    (bogus) value
//  - apply(_:) with a valid resolved path sets the variable when nothing
//    was set before
//  - apply(nil) leaves a pre-existing value completely untouched
//  - apply(nil) leaves an unset variable unset
//
//  Environment save/restore mirrors the CALYX_SESSION_BIN idiom already
//  established by AppDelegateRestoreRemoteSessionTests/
//  CalyxWindowControllerRemoteReconnectCommandTests (save the original
//  value in setUp, setenv it back or unsetenv in tearDown), so this test
//  host's real process environment is never left polluted for later
//  tests.
//

import XCTest
@testable import Calyx

final class GhosttyResourcesDirEnvironmentTests: XCTestCase {

    private let variableName = "GHOSTTY_RESOURCES_DIR"
    private var originalValue: String?

    override func setUp() {
        super.setUp()
        originalValue = ProcessInfo.processInfo.environment[variableName]
    }

    override func tearDown() {
        if let originalValue {
            setenv(variableName, originalValue, 1)
        } else {
            unsetenv(variableName)
        }
        super.tearDown()
    }

    private func currentValue() -> String? {
        getenv(variableName).map { String(cString: $0) }
    }

    // MARK: - apply(_:)

    func test_apply_withResolvedPath_overwritesPreExistingBogusValue() {
        setenv(variableName, "/bogus/inherited/path", 1)

        GhosttyResourcesDirEnvironment.apply("/opt/calyx-fixture/Resources/ghostty")

        XCTAssertEqual(
            currentValue(), "/opt/calyx-fixture/Resources/ghostty",
            "a resolved bundled path must overwrite an inherited value, since Calyx's bundled scripts are version-matched to the embedded libghostty and an inherited path may not be"
        )
    }

    func test_apply_withResolvedPath_setsVariableWhenNoneWasSetBefore() {
        unsetenv(variableName)

        GhosttyResourcesDirEnvironment.apply("/opt/calyx-fixture/Resources/ghostty")

        XCTAssertEqual(currentValue(), "/opt/calyx-fixture/Resources/ghostty")
    }

    func test_apply_withNilResolution_leavesPreExistingValueUntouched() {
        setenv(variableName, "/bogus/inherited/path", 1)

        GhosttyResourcesDirEnvironment.apply(nil)

        XCTAssertEqual(
            currentValue(), "/bogus/inherited/path",
            "when the bundle check failed (nil resolution), an already-present value must be left untouched rather than cleared"
        )
    }

    func test_apply_withNilResolution_leavesVariableUnset() {
        unsetenv(variableName)

        GhosttyResourcesDirEnvironment.apply(nil)

        XCTAssertNil(
            currentValue(),
            "when the bundle check failed and nothing was set before, apply(nil) must not set the variable"
        )
    }
}
