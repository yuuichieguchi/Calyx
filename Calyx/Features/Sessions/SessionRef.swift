// SessionRef.swift
// Calyx
//
// Reference to a calyx-session (persistent PTY session, see
// `calyx-session/`) attached to a terminal leaf surface. Stored per leaf
// UUID in `TabSnapshot.sessionRefs` (schema v6) so a restored tab can
// re-attach to the same session instead of spawning a fresh shell.

import Foundation

struct SessionRef: Codable, Equatable, Sendable {
    /// The calyx-session ULID (`SessionSpec.id` / `SessionInfo.id` on the
    /// Rust side), stable across ghostty surface re-creation.
    let sessionID: String
    /// `nil` for a local session; populated once P5 (remote sessions)
    /// lands.
    let host: String?
    /// Per-agent-CLI session identifiers keyed by `AgentEntry.kind`
    /// (e.g. `"claude-code"`), so a resumed calyx-session can also offer
    /// to resume the CLI agent conversation that was running inside it.
    /// `nil` until P4 wires agent resume.
    let agentSessions: [String: String]?

    init(sessionID: String, host: String? = nil, agentSessions: [String: String]? = nil) {
        self.sessionID = sessionID
        self.host = host
        self.agentSessions = agentSessions
    }
}

extension SessionRef {
    /// Validates that `sessionID` (an untrusted, disk-persisted value on
    /// the restore path) is shaped like a genuine ULID: exactly 26
    /// characters, every character drawn from Crockford's base32
    /// alphabet (`0-9`, `A-Z` minus `I`/`L`/`O`/`U`). A `SessionRef`
    /// whose `sessionID` fails this check must be rejected at restore
    /// rather than handed to `calyx-session attach`, which would
    /// otherwise run arbitrary daemon-side lookups keyed by
    /// attacker/corruption-controlled input.
    ///
    private static let crockfordAlphabet = Set("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    static func isValidULID(_ sessionID: String) -> Bool {
        sessionID.count == 26 && sessionID.allSatisfy { crockfordAlphabet.contains($0) }
    }
}
