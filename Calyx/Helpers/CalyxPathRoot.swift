// CalyxPathRoot.swift
// Calyx
//
// The single seam every Calyx-owned and agent-owned config path resolves
// against: AppSupportDirectory (agent-endpoint.json, config-write locks)
// and AgentToolPaths (~/.claude, ~/.codex, ~/.config/opencode, ~/.grok,
// ~/.pi/agent, ~/.hermes) both consult `testRoot` before falling back to
// the real Application Support directory / NSHomeDirectory(). Resolving
// every one of those paths through one seam, rather than each type
// carrying its own private redirect (as AppSupportDirectory.locksPath
// used to, and AgentToolPaths never did at all), is what lets a real UI
// test process scope a whole launch's file I/O to a temp directory: a UI
// test app process has XCTest unloaded, so LaunchEnvironmentPolicy
// .isUnitTestHost() never catches it, and NSHomeDirectory() ignores a
// HOME environment override entirely (see AppDelegate's own comment on
// this), so neither existing mechanism could scope it.
//
// Resolved exactly once into a `static let`: a lock file is named after
// a hash of the config path it guards, so two different answers within
// one process run would silently stop guarding anything for whichever
// config path crossed the change.

import Foundation

enum CalyxPathRoot {

    /// The directory every Calyx-owned and agent-owned config path is
    /// resolved against. `nil` in production, where those paths resolve
    /// against the real home and Application Support directories.
    ///
    /// Precedence:
    /// 1. `--calyx-path-root=<dir>`, parsed by CalyxPathRootArgument --
    ///    how the UI-test runner scopes one app launch.
    /// 2. A per-process temp directory when
    ///    `LaunchEnvironmentPolicy.isUnitTestHost()` is true, matching
    ///    what `AppSupportDirectory.unitTestHostRoot` used to do on its
    ///    own before this seam existed.
    /// 3. `nil` otherwise -- the real, production paths.
    static let testRoot: String? = {
        if let argumentRoot = CalyxPathRootArgument.parse(ProcessInfo.processInfo.arguments) {
            return argumentRoot
        }
        if LaunchEnvironmentPolicy.isUnitTestHost() {
            return unitTestHostRoot
        }
        return nil
    }()

    /// Stand-in root under the unit-test host, scoped to the process so
    /// concurrent hosts stay out of each other's way. Only ever read
    /// once, from `testRoot`'s own one-time initializer above.
    private static let unitTestHostRoot: String = (NSTemporaryDirectory() as NSString)
        .appendingPathComponent("Calyx-UnitTestHost-\(ProcessInfo.processInfo.processIdentifier)")
}
