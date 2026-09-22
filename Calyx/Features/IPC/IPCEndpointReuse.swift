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

import Foundation

enum IPCEndpointReuse {

    /// The canonical scan start: `CalyxMCPServer.start(token:preferredPort:)`
    /// defaults its own `preferredPort` parameter to this value, so a
    /// caller with nothing to reuse (no on-disk `agent-endpoint.json`,
    /// or a port of `0` in it) always scans from the same port this file
    /// documents in one place.
    static let defaultPort = 41830

    struct Decision: Equatable {
        let token: String
        let port: Int
    }

    static func decide(existing: AgentEndpointFile.Endpoint?, freshToken: String) -> Decision {
        // An empty on-disk token can never be a real published token
        // (mirrors AgentEndpointFile.remove's own empty-token guard), so
        // it is never reusable regardless of the port decision below.
        let token: String
        if let existing, !existing.token.isEmpty {
            token = existing.token
        } else {
            token = freshToken
        }

        // Port 0 is never a real bind, so it falls back to the default
        // regardless of the token decision above.
        let port: Int
        if let existing, existing.port != 0 {
            port = existing.port
        } else {
            port = defaultPort
        }

        return Decision(token: token, port: port)
    }
}
