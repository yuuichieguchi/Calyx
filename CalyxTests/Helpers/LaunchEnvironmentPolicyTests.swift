//
//  LaunchEnvironmentPolicyTests.swift
//  CalyxTests
//
//  The unit-test host isolation fix. ROOT CAUSE: the
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
//  Under test: LaunchEnvironmentPolicy.
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
//  - all 4 combinations of {--uitesting present, hasScopedPathRoot} for
//    mayPerformAgentIPCActivation(arguments:hasScopedPathRoot:), the
//    predicate gating real IPC activation on the launch path and both
//    Settings > Agents handlers
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

    // MARK: - mayPerformAgentIPCActivation(arguments:hasScopedPathRoot:) -- all 4 combinations

    func test_noUITesting_noPathRoot_mayActivate() {
        XCTAssertTrue(
            LaunchEnvironmentPolicy.mayPerformAgentIPCActivation(arguments: ["/path/to/Calyx"], hasScopedPathRoot: false),
            "a normal launch (no --uitesting) may always activate, scoped path root or not"
        )
    }

    func test_noUITesting_withPathRoot_mayActivate() {
        XCTAssertTrue(
            LaunchEnvironmentPolicy.mayPerformAgentIPCActivation(
                arguments: ["/path/to/Calyx"],
                hasScopedPathRoot: true
            ),
            "a normal launch may always activate, scoped path root or not"
        )
    }

    func test_uiTesting_withPathRoot_mayActivate() {
        XCTAssertTrue(
            LaunchEnvironmentPolicy.mayPerformAgentIPCActivation(
                arguments: ["/path/to/Calyx", "--uitesting", "--calyx-path-root=/tmp/scoped"],
                hasScopedPathRoot: true
            ),
            "--uitesting WITH a scoped path root confines every write to that root, so activation is safe"
        )
    }

    func test_uiTesting_noPathRoot_mayNotActivate() {
        XCTAssertFalse(
            LaunchEnvironmentPolicy.mayPerformAgentIPCActivation(
                arguments: ["/path/to/Calyx", "--uitesting"],
                hasScopedPathRoot: false
            ),
            "--uitesting with no scoped path root is a UI-test launch that forgot --calyx-path-root=, " +
            "so activation would touch the developer's real environment and must be refused"
        )
    }
}
