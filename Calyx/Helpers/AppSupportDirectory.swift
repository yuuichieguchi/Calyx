// AppSupportDirectory.swift
// Calyx
//
// Resolves Calyx's `~/Library/Application Support/Calyx` directory.

import Foundation

enum AppSupportDirectory {
    /// `~/Library/Application Support/Calyx`. Falls back to a manually
    /// constructed path in the (practically unreachable on macOS) case
    /// where `FileManager` can't resolve the search path domain.
    ///
    /// Resolves beneath `CalyxPathRoot.testRoot` instead when it is
    /// non-nil, so a UI test scoped by `--calyx-path-root=` or a unit
    /// test host never touches the user's real Application Support
    /// directory. Production (`CalyxPathRoot.testRoot == nil`) resolves
    /// exactly as before.
    static func path(testRoot: String?) -> String {
        if let testRoot {
            return (testRoot as NSString).appendingPathComponent("Calyx")
        }
        let fm = FileManager.default
        let appSupport = fm
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first
            ?? fm.homeDirectoryForCurrentUser
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Application Support", isDirectory: true)
        return appSupport.appendingPathComponent("Calyx", isDirectory: true).path
    }

    static var path: String {
        path(testRoot: CalyxPathRoot.testRoot)
    }

    /// `<path>/locks`: the directory holding the per-config-path lock
    /// files that `ConfigFileUtils.atomicWrite` deliberately never
    /// deletes (see its doc comment for why they must persist).
    /// Carries `path`'s own `CalyxPathRoot.testRoot` redirect, since
    /// `path` now resolves beneath it directly -- this no longer needs
    /// a private redirect of its own.
    static var locksPath: String {
        (path as NSString).appendingPathComponent("locks")
    }
}
