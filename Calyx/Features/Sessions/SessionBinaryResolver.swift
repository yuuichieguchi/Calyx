// SessionBinaryResolver.swift
// Calyx
//
// Resolves the bundled `calyx-session` binary's path, shared by both
// `SessionSpawnPlanner` (attach command synthesis) and
// `SessionDaemonClient` (daemon queries/kill) so both halves of the
// feature always agree on which binary they're talking about, and so
// tests can inject a fake resolver instead of poking global bundle/env
// state from two independent call sites.

import Foundation

protocol SessionBinaryResolverProtocol: Sendable {
    /// The bundled `calyx-session` binary's absolute path, or `nil` if
    /// none is available (e.g. a dev build without the bundled
    /// resource) — in which case every consumer must degrade
    /// gracefully: `SessionSpawnPlanner` falls back to `.passthrough`,
    /// `SessionDaemonClient` treats every query as `.unreachable`.
    func resolve() -> String?
}

/// Production resolver: `CALYX_SESSION_BIN` env override (dev workflow
/// / test injection), then the bundled `Resources/bin/calyx-session`
/// resource (see `project.yml`'s "Bundle Session Daemon"
/// postBuildScript), then `nil`. Deliberately has no third fallback to
/// a bare `"calyx-session"` literal resolved via `PATH` — a review
/// found that inconsistency reachable (planner assuming a PATH binary
/// while the daemon client reported `.unreachable` for the same
/// missing binary), so "no binary resolvable" now means every consumer
/// degrades identically: `SessionSpawnPlanner` falls back to
/// `.passthrough`, `SessionDaemonClient` treats every query as
/// `.unreachable`.
struct SessionBinaryResolver: SessionBinaryResolverProtocol {
    private let bundle: Bundle
    private let environment: [String: String]

    init(bundle: Bundle = .main, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.bundle = bundle
        self.environment = environment
    }

    func resolve() -> String? {
        if let override = environment["CALYX_SESSION_BIN"], !override.isEmpty {
            return override
        }
        return bundle.url(forResource: "calyx-session", withExtension: nil, subdirectory: "bin")?.path
    }
}
