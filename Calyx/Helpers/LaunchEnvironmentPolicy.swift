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
//
// Also decides whether this process may perform a REAL IPC activation
// (start CalyxMCPServer, write an agent CLI config file, install agent
// hooks) -- a distinct question from isUnitTestHost() above, since a
// `--uitesting` launch is not caught by isUnitTestHost() at all (it has
// no XCTest loaded). Without this predicate, a `--uitesting` launch that
// omitted `--calyx-path-root=` would activate against the developer's
// real `~/.claude.json`, `~/.codex/config.toml`, `~/.grok/config.toml`
// and OpenCode config, and bind a real loopback port -- every entry
// point that can trigger activation (the launch path and both Settings
// handlers) must consult this same predicate rather than each carrying
// its own copy of the condition.

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

    /// True iff this process may perform a real IPC activation. False
    /// only for a `--uitesting` launch that has no scoped path root: that
    /// combination is a UI-test launch that forgot `--calyx-path-root=`,
    /// so every Calyx-owned and agent-owned config path would still
    /// resolve to the developer's real home directory
    /// (`CalyxPathRoot.testRoot`'s own doc comment). Every other
    /// combination -- not `--uitesting` at all, or `--uitesting` WITH a
    /// scoped path root -- is safe to activate: a scoped path root
    /// confines every write this activation performs to that root.
    static func mayPerformAgentIPCActivation(arguments: [String], hasScopedPathRoot: Bool) -> Bool {
        !(arguments.contains("--uitesting") && !hasScopedPathRoot)
    }

    /// Real-process convenience: evaluates the above against this
    /// process's own ProcessInfo.processInfo.arguments and
    /// CalyxPathRoot.testRoot.
    static func mayPerformAgentIPCActivation() -> Bool {
        mayPerformAgentIPCActivation(
            arguments: ProcessInfo.processInfo.arguments,
            hasScopedPathRoot: CalyxPathRoot.testRoot != nil
        )
    }
}
