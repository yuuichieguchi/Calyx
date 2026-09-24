//
//  MCPElicitation.swift
//  Calyx
//
//  The seam through which `MCPUpstreamClient` shows an upstream server's
//  elicitation (`elicitation/create`, legacy or MRTR) to the user.
//

import Foundation

/// Presents elicitations to the user.
///
/// URL mode (2025-11-25): `present` returns `.accept` once the user agrees
/// to open the URL. When the server later sends
/// `notifications/elicitation/complete`, the client calls `dismiss(_:)`
/// for that presentation. The 2026-07-28 URL mode has no completion
/// notification, so that presentation stays up until the user closes it.
@MainActor
protocol MCPElicitationPresenting: AnyObject, Sendable {
    func present(_ request: MCPElicitationRequest) async -> MCPElicitationResponse
    func dismiss(_ id: MCPElicitationID)
}

/// Identifies one presented elicitation so the presenter can dismiss it
/// individually. Independent of `MCPServerID`.
///
/// Not `RawRepresentable`: that protocol requires a failable
/// `init?(rawValue:)`, which the defaulted non-failable initializer does
/// not satisfy.
struct MCPElicitationID: Sendable, Equatable, Hashable {
    let rawValue: UUID

    init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

/// One elicitation to show to the user.
struct MCPElicitationRequest: Sendable, Equatable, Identifiable {
    typealias ID = MCPElicitationID

    enum Mode: Sendable, Equatable {
        case form(message: String, requestedSchema: MCPElicitRequestedSchema?)
        case url(message: String, url: String)
    }

    /// Which server is asking, for display. Carries no `MCPServerID`.
    struct ServerContext: Sendable, Equatable {
        let displayName: String
    }

    let id: ID
    let serverContext: ServerContext
    /// The pane whose tool call triggered the elicitation, when known.
    let surfaceID: UUID?
    let mode: Mode
}

/// The user's decision on an elicitation.
enum MCPElicitationResponse: Sendable, Equatable {
    case accept(content: [String: AnyCodable])
    case decline
    case cancel
}
