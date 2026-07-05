// SSHHostCandidateProvider.swift
// Calyx
//
// Turns `SSHConfigParser.hostCandidates(from:)` (pure string parsing)
// into an actual list of remote-host candidates for the "New Remote
// Session…" picker, by reading `~/.ssh/config`'s content through an
// injectable loader. The config path is derived from
// `SessionRootResolverProtocol` — never re-derived independently via
// `NSHomeDirectory()`/`ProcessInfo` directly — mirroring
// `SessionRootResolver`'s own HOME-resolution discipline.

import Foundation

struct SSHHostCandidateProvider {
    private let rootResolver: SessionRootResolverProtocol
    private let loadConfig: (String) -> String?

    init(
        rootResolver: SessionRootResolverProtocol = SessionRootResolver(),
        loadConfig: @escaping (String) -> String? = { path in
            try? String(contentsOfFile: path, encoding: .utf8)
        }
    ) {
        self.rootResolver = rootResolver
        self.loadConfig = loadConfig
    }

    /// Reads `<rootResolver.resolve()>/.ssh/config`, delegates parsing
    /// to `SSHConfigParser.hostCandidates(from:)`, and deduplicates
    /// repeated aliases, preserving first-seen declaration order —
    /// a contract `SSHConfigParser.hostCandidates(from:)` itself
    /// deliberately does not provide (see that function's own doc
    /// comment). A missing/unreadable config (`loadConfig` returns
    /// `nil`) yields an empty list, never a crash or thrown error.
    func hostCandidates() -> [String] {
        let configPath = rootResolver.resolve() + "/.ssh/config"
        guard let configText = loadConfig(configPath) else { return [] }

        var seen = Set<String>()
        var candidates: [String] = []
        for candidate in SSHConfigParser.hostCandidates(from: configText) where !seen.contains(candidate) {
            seen.insert(candidate)
            candidates.append(candidate)
        }
        return candidates
    }
}
