// IPCEndpointReuse.swift
// Calyx
//
// Pure decision behind endpoint reuse across a restart: a persistent-
// session CLI already holds an old token and URL from a previously
// published agent-endpoint.json, so a fresh server start should keep both
// working when possible. Token and port are decided INDEPENDENTLY of each
// other -- an empty on-disk token must not disqualify reusing a still-
// valid on-disk port, and a port of 0 (never a real bind) must not
// disqualify reusing a still-valid on-disk token.
//
// The caller (LiveIPCServerControl, IPCServerControlling's live adapter)
// reads AgentEndpointFile.read(directory:) once and hands the result plus
// a freshly generated token to decide(existing:freshToken:).
//
// Rotation policy (G2, J4): under `.onLostPort` (shipped) a reused token
// comes with `tokenIfPortLost = freshToken`, and CalyxMCPServer switches
// to it only when it cannot bind the previous port. A process can rebind
// its own just-closed port, so that failure means another process holds
// the port -- the one moment the old token may have been seen by someone
// else. `.everyStart` always uses the fresh token.
// C-D2: rotate only on evidence. A "clean shutdown" marker is not used:
// it tells a crash from Cmd-Q, which says nothing about whether the token
// leaked while Calyx was stopped. Switching to `.everyStart` is one
// constant (`policy`).
// C-D13 residual of `.onLostPort`: an intruder that collected the token
// baked into the Codex/OpenCode/Hermes/Grok configs while Calyx was
// stopped, and releases the port before Calyx restarts, leaves the old
// token valid. `.everyStart` closes that.
// C-D14: a second Calyx (e.g. a Debug build next to the release app)
// finds the previous port held by the first, treats it as lost, rotates,
// and rewrites the five agent configs.

import Foundation

enum IPCEndpointReuse {

    /// The canonical scan start: `CalyxMCPServer.start(token:preferredPort:)`
    /// defaults its own `preferredPort` parameter to this value, so a
    /// caller with nothing to reuse (no on-disk `agent-endpoint.json`,
    /// or a port of `0` in it) always scans from the same port this file
    /// documents in one place.
    static let defaultPort = 41830

    enum Policy: Sendable, Equatable {
        /// Reuse the previous token; rotate only when the previous port
        /// is lost to another process.
        case onLostPort
        /// Use a fresh token on every start.
        case everyStart
    }

    /// The shipped rotation policy (C-D2).
    static let policy: Policy = .onLostPort

    struct Decision: Equatable {
        let token: String
        let port: Int
        /// The token the server switches to when it cannot bind `port`
        /// itself; nil when `token` is already fresh.
        let tokenIfPortLost: String?
    }

    static func decide(
        existing: AgentEndpointFile.Endpoint?,
        freshToken: String,
        policy: Policy = policy
    ) -> Decision {
        // An empty on-disk token can never be a real published token
        // (mirrors AgentEndpointFile.remove's own empty-token guard), so
        // it is never reusable regardless of the port decision below.
        let token: String
        let tokenIfPortLost: String?
        switch policy {
        case .onLostPort:
            if let existing, !existing.token.isEmpty {
                token = existing.token
                tokenIfPortLost = freshToken
            } else {
                token = freshToken
                tokenIfPortLost = nil
            }
        case .everyStart:
            token = freshToken
            tokenIfPortLost = nil
        }

        // Port 0 is never a real bind, so it falls back to the default
        // regardless of the token decision above.
        let port: Int
        if let existing, existing.port != 0 {
            port = existing.port
        } else {
            port = defaultPort
        }

        return Decision(token: token, port: port, tokenIfPortLost: tokenIfPortLost)
    }
}
