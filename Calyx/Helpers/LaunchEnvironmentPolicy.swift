// LaunchEnvironmentPolicy.swift
// Calyx
//
// Decides whether this process is the CalyxTests unit-test host, so
// AppDelegate can gate its production launch body off of the developer's
// real ~/.calyx environment. Sibling to TestEnvironment.swift and reuses
// its isTestHost as the single source of truth for "is XCTest loaded"
// (do not add a second, independent NSClassFromString("XCTestCase") != nil
// check here -- TestEnvironment's own header documents two that had
// already drifted to opposite polarities before being unified).
//
// A unit-test host is XCTest loaded AND no "--uitesting" flag: UI tests
// run the app-under-test in a separate process with no XCTest loaded
// (CalyxUITests launches it with "--uitesting" instead), so that process
// always evaluates false here and keeps running the full launch.

import Foundation

enum LaunchEnvironmentPolicy {
    /// True iff `xcTestPresent` and `arguments` does not contain
    /// "--uitesting".
    static func isUnitTestHost(xcTestPresent: Bool, arguments: [String]) -> Bool {
        xcTestPresent && !arguments.contains("--uitesting")
    }

    /// Real-process convenience: evaluates the above against this
    /// process's own TestEnvironment.isTestHost and
    /// ProcessInfo.processInfo.arguments.
    static func isUnitTestHost() -> Bool {
        isUnitTestHost(
            xcTestPresent: TestEnvironment.isTestHost,
            arguments: ProcessInfo.processInfo.arguments
        )
    }
}
