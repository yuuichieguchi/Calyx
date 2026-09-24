//
//  MCPMessageTransport.swift
//  Calyx
//
//  Message-level transport between the MCP host and one upstream MCP
//  server. Each `send` carries exactly one whole JSON-RPC message;
//  framing (NDJSON on stdio, HTTP bodies and SSE on HTTP) belongs to the
//  concrete transport.
//

import Foundation

/// What an outbound message is, so a transport can pick the wire
/// behavior that fits it (HTTP distinguishes a streamed reply from a
/// 202 Accepted; stdio frames every kind identically).
enum MCPOutboundKind: Sendable, Equatable {
    case request(headerMirrors: [MCPHTTPHeaderMirror] = [])
    case notification
    /// A reply to a server-originated request (legacy `ping`,
    /// `elicitation/create`).
    case response
}

/// One element of a transport's inbound stream.
enum MCPInbound: Sendable, Equatable {
    case frame(Data)
    /// A transport-level error signal. Carries the HTTP status when there
    /// is one; the era detector uses it as input.
    case error(MCPTransportSignal)
    /// The transport was lost without `close()` having been called. A
    /// caller-initiated `close()` never yields this element.
    case closed(reason: String, exit: MCPTransportExitInfo?, stderrTail: Data?)
}

/// A transport error that does not by itself close the transport.
struct MCPTransportSignal: Sendable, Equatable {
    /// Always nil on stdio.
    let httpStatus: Int?
    let message: String
    /// The `WWW-Authenticate` header value on a 401 or 403 response.
    var wwwAuthenticate: String? = nil
}

/// How a child process ended.
enum MCPTransportExitInfo: Sendable, Equatable {
    case exited(Int32)
    case signaled(Int32)
}

enum MCPTransportError: Error, Equatable {
    /// `send` after `close()`, or after the transport was lost.
    case closed
}

/// A message transport to one upstream MCP server.
///
/// `inbound` is a single-consumer stream. It finishes directly on
/// `close()`, and yields `.closed(reason:exit:stderrTail:)` before
/// finishing only when the transport was lost without `close()`.
protocol MCPMessageTransport: Sendable {
    /// Sends one whole JSON-RPC message. Throws `MCPTransportError.closed`
    /// once the transport is closed.
    func send(_ data: Data, kind: MCPOutboundKind) async throws
    nonisolated var inbound: AsyncStream<MCPInbound> { get }
    /// Cancels an in-flight request in the way the transport defines. Does
    /// nothing once the transport is closed.
    func cancel(requestID: JSONRPCId, reason: String?) async
    func close() async
    /// The protocol version the following messages speak. The client sets
    /// it before each handshake probe and once more after the handshake.
    /// Only a transport whose wire behavior depends on the version acts on
    /// it.
    func setNegotiatedProtocolVersion(_ version: MCPProtocolVersion) async
}

extension MCPMessageTransport {
    /// Transports whose wire behavior does not depend on the version
    /// ignore it.
    func setNegotiatedProtocolVersion(_ version: MCPProtocolVersion) async {}
}
