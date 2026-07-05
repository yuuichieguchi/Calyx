// SessionRootResolver.swift
// Calyx
//
// Resolves the on-disk session root ($HOME/.calyx: run/sessiond.sock,
// state/) that the Rust calyx-session daemon/CLI derives from the
// literal HOME env var at process start (see
// calyx-session/crates/daemon/src/session.rs's default_home_subdir).
// This is THE single definition of that root on the Swift side —
// mirroring SessionBinaryResolver's own role of being the one place
// SessionSpawnPlanner and SessionDaemonClient agree on the
// calyx-session binary path — so every consumer must receive its
// resolved value explicitly (SessionCommandSynthesizer's synthesized
// attach command, SessionDaemonClient's query environment) rather than
// re-deriving home independently. In particular, never substitute
// FileManager.homeDirectoryForCurrentUser here — that API ignores HOME
// entirely, which is exactly the mismatch this type exists to close.

import Foundation

protocol SessionRootResolverProtocol: Sendable {
    /// The session root every consumer must agree on.
    func resolve() -> String
}

/// Production resolver: the injected environment's `HOME` value when
/// present and non-empty, else `NSHomeDirectory()` — mirroring
/// `SessionBinaryResolver`'s own present-but-empty-string handling for
/// `CALYX_SESSION_BIN`.
struct SessionRootResolver: SessionRootResolverProtocol {
    private let environment: [String: String]

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.environment = environment
    }

    func resolve() -> String {
        if let home = environment["HOME"], !home.isEmpty {
            return home
        }
        return NSHomeDirectory()
    }
}
