//
//  MCPConnectionState.swift
//  Calyx
//
//  The lifecycle state of one upstream MCP server connection.
//
//  Transitions:
//    - `disabled` -> `connecting` when enabled.
//    - `connecting` -> `ready` on success; -> `failed` on any failure
//      before `ready` (command not found, exit or timeout during the
//      handshake, permanent HTTP error); -> `needsAuthorization` on HTTP 401.
//    - `ready` -> `restarting` when the transport is lost; -> `disabled`
//      when disabled.
//    - `needsAuthorization` -> `authorizing` when the user signs in.
//    - `authorizing` -> `connecting` on completion; -> `needsAuthorization`
//      on cancellation.
//    - `restarting` -> `connecting` after the backoff delay; -> `failed`
//      after repeated crashes.
//    - `failed` -> `connecting` when the user retries.
//

import Foundation

enum MCPConnectionState: Sendable, Equatable {
    case disabled
    case connecting
    case ready(MCPServerInfo, toolCount: Int)
    case needsAuthorization
    case authorizing
    case restarting(attempt: Int, after: TimeInterval)
    case failed(MCPConnectionFailure)
}

/// What the handshake established about the server.
struct MCPServerInfo: Sendable, Equatable {
    let negotiatedEra: MCPProtocolVersion
    /// nil when the modern-era server did not report its identity.
    let serverInfo: MCPImplementation?
    /// Shown in Settings only. Never forwarded to downstream clients.
    let instructions: String?
}

/// Why a connection stopped trying.
struct MCPConnectionFailure: Sendable, Equatable {
    let reason: String
    /// The tail of the child's stderr, when the transport reported one.
    let stderrTail: String?
}
