//
//  MCPUpstreamClientTypes.swift
//  Calyx
//
//  Values `MCPUpstreamClient` takes and returns: handshake inputs and
//  results, per-call context, call errors, and the events it forwards to
//  its owner.
//

import Foundation

/// Per-call inputs to `MCPUpstreamClient.callTool`.
struct MCPToolCallContext: Sendable {
    /// The pane that made the call. Copied into `MCPElicitationRequest.surfaceID`.
    var surfaceID: UUID?
    /// The caller's working directory. Declares `roots` on modern requests
    /// and answers MRTR `roots/list` input requests.
    var cwd: URL?
    /// Receives `notifications/progress` for this call. A non-nil handler
    /// adds `_meta.progressToken` to the request.
    var progress: MCPProgressHandler?
    /// Passed through unchanged as `MCPOutboundKind.request(headerMirrors:)`.
    var headerMirrors: [MCPHTTPHeaderMirror] = []

    static let none = MCPToolCallContext()
}

/// An event from the upstream server that the client does not consume
/// itself.
enum MCPClientServerEvent: Sendable, Equatable {
    /// A notification the client did not handle (for example
    /// `notifications/tools/list_changed`).
    case notification(method: String, params: [String: AnyCodable]?)
    /// The transport was lost without `close()`. Delivered at most once.
    case closed(reason: String, exit: MCPTransportExitInfo?, stderrTail: Data?)
}

/// Which handshake message `negotiate` sends first. stdio and legacy
/// HTTP+SSE use `.initializeFirst`; Streamable HTTP uses `.discoverFirst`.
enum MCPHandshakeOrder: Sendable, Equatable {
    case initializeFirst
    case discoverFirst
}

/// A protocol generation, as cached by the supervisor between connections.
enum MCPProtocolEra: Sendable, Equatable, Codable {
    case legacy(MCPProtocolVersion)
    case modern
}

enum MCPNegotiationError: Error, Equatable {
    /// Neither `initialize` nor `server/discover` succeeded. A nil side
    /// failed without a protocol error (its result did not decode, or it
    /// was not attempted).
    case handshakeFailed(initialize: MCPClientProtocolError?, discover: MCPClientProtocolError?)
    /// Streamable HTTP answered both `server/discover` and `initialize`
    /// with HTTP 400, 404, or 405. The caller switches to the legacy
    /// HTTP+SSE transport and negotiates again with `.initializeFirst`.
    case legacySSERequired
    /// The transport reported HTTP 401 during the handshake.
    case authorizationRequired(MCPTransportSignal)
}

typealias MCPProgressHandler = @Sendable (MCPProgressUpdate) async -> Void

/// One `notifications/progress` update for an in-flight call.
struct MCPProgressUpdate: Sendable, Equatable {
    let progress: Double
    let total: Double?
    let message: String?
}

/// The outcome of `negotiate`. `instructions` stays in the result for the
/// Settings display; it is never forwarded downstream.
enum MCPNegotiatedEra: Sendable, Equatable {
    case legacy(version: MCPProtocolVersion, result: MCPInitializeResult)
    case modern(result: MCPDiscoverResult)
}

/// Why a request to the upstream server failed. Thrown by
/// `readResource`, `listTools`, and `subscribeToSubscriptions`.
enum MCPClientProtocolError: Error, Sendable, Equatable {
    case timeout
    case transport(MCPTransportSignal)
    /// The transport yielded `.closed` while the call was in flight, or
    /// before it was made.
    case transportClosed(reason: String)
    case mrtrRoundLimitExceeded
    case serverError(JSONRPCError)
    /// A reply that does not fit the contract: a non-object `tools/call`
    /// result, an undecodable `input_required`, invalid MRTR elicitation
    /// params, or an unknown MRTR input method.
    case malformedReply(String)
    /// The request could not be encoded; nothing was sent.
    case encodingFailed(String)
}

enum MCPCancellationReason: Sendable, Equatable {
    /// The Task awaiting the call was cancelled.
    case agentCancelled
    /// The transport was closed by its owner while the call was in flight.
    case hostShutdown
}
