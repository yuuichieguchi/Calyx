//
//  LaunchEnvironmentPolicyTests.swift
//  CalyxTests
//
//  TDD Red phase (unit-test host isolation fix). ROOT CAUSE: the
//  CalyxTests scheme uses Calyx.app as its test HOST, and
//  applicationDidFinishLaunching runs its full production launch body
//  against the developer's real ~/.calyx environment before any test
//  executes -- incrementing the real recovery counter, overwriting the
//  real sessions.json on terminate, and (with persistentSessionsEnabled
//  == true in real UserDefaults) spawning real persistent daemon
//  sessions from the host's initial window. Nothing gates any of this
//  today: grep confirms no XCTest detection anywhere in AppDelegate.
//
//  THE FIX: applicationDidFinishLaunching must early-return, performing
//  NONE of its side effects, whenever the process is a unit-test host --
//  XCTest runtime present AND the --uitesting flag absent. UI tests run
//  the app-under-test in a separate process with no XCTest loaded, so
//  they always evaluate false here and keep running the full launch.
//  This file pins the pure decision policy; the launch-site wiring
//  itself is covered by AppDelegateLaunchEnvironmentGateTests.
//
//  Held-out compile-RED (see SessionCommandSynthesizerRemoteAttachTests's
//  header for this codebase's convention): LaunchEnvironmentPolicy does
//  not exist yet anywhere in the codebase, so this file fails to compile
//  until the Green phase adds it. That compile failure IS this file's
//  RED evidence.
//
//  Proposed API (Calyx/Helpers/LaunchEnvironmentPolicy.swift), sibling to
//  TestEnvironment.swift and reusing its isTestHost as the single source
//  of truth for "is XCTest loaded" (do not add a third independent
//  NSClassFromString("XCTestCase") != nil check -- TestEnvironment's own
//  header already documents two that had drifted to opposite polarities):
//
//    enum LaunchEnvironmentPolicy {
//        /// True iff `xcTestPresent` and `arguments` does not contain
//        /// "--uitesting".
//        static func isUnitTestHost(xcTestPresent: Bool, arguments: [String]) -> Bool
//
//        /// Real-process convenience: evaluates the above against this
//        /// process's own TestEnvironment.isTestHost and
//        /// ProcessInfo.processInfo.arguments.
//        static func isUnitTestHost() -> Bool
//    }
//
//  Coverage:
//  - all 4 combinations of {xcTestPresent, --uitesting present} for the
//    parameterized form
//  - the no-arg real-process wrapper, evaluated against THIS test
//    process's own real environment (must be true here, since this
//    process IS a unit-test host)
//

import XCTest
@testable import Calyx

final class LaunchEnvironmentPolicyTests: XCTestCase {

    // MARK: - isUnitTestHost(xcTestPresent:arguments:) -- parameterized truth table

    func test_xcTestPresent_noUITestingFlag_isUnitTestHost() {
        XCTAssertTrue(
            LaunchEnvironmentPolicy.isUnitTestHost(xcTestPresent: true, arguments: ["/path/to/host"]),
            "XCTest loaded and no --uitesting flag is exactly the CalyxTests host shape"
        )
    }

    func test_xcTestPresent_withUITestingFlag_isNotUnitTestHost() {
        XCTAssertFalse(
            LaunchEnvironmentPolicy.isUnitTestHost(xcTestPresent: true, arguments: ["/path/to/host", "--uitesting"]),
            "--uitesting must win even if XCTest happens to be loaded in the same process"
        )
    }

    func test_noXCTest_noUITestingFlag_isNotUnitTestHost() {
        XCTAssertFalse(
            LaunchEnvironmentPolicy.isUnitTestHost(xcTestPresent: false, arguments: ["/path/to/Calyx"]),
            "a normal Finder/Dock launch (no XCTest, no --uitesting) must run the full launch"
        )
    }

    func test_noXCTest_withUITestingFlag_isNotUnitTestHost() {
        XCTAssertFalse(
            LaunchEnvironmentPolicy.isUnitTestHost(xcTestPresent: false, arguments: ["/path/to/Calyx", "--uitesting"]),
            "the real CalyxUITests app-under-test process shape (--uitesting, no XCTest loaded) must run the full launch"
        )
    }

    // MARK: - isUnitTestHost() -- real-process wrapper

    func test_realProcess_insideUnitTestHost_isUnitTestHost() {
        XCTAssertTrue(
            LaunchEnvironmentPolicy.isUnitTestHost(),
            "this very test process is a unit-test host: XCTest is loaded and the CalyxTests scheme never passes --uitesting"
        )
    }
}
