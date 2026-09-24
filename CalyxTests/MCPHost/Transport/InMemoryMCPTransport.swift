//
//  InMemoryMCPTransport.swift
//  CalyxTests
//
//  In-memory MCPMessageTransport test double, mirroring
//  InMemoryLSPTransport. Captures every whole JSON-RPC message payload
//  passed to send (post-framing: exactly one message per call) and lets
//  tests inject server-originated messages via simulateServerMessage.
//
//  A crash (unsolicited child/connection loss) is distinct from a
//  graceful close(): only the former must be observable by
//  MCPUpstreamConnection as "the transport went away without me asking
//  it to," so it is a separate test API (simulateCrash(reason:)) rather
//  than reusing close().
//
//  Per the API contract section 2.4, simulateCrash takes only a reason
//  string; the closed(reason:exit:stderrTail:) it yields always carries
//  exit: nil, stderrTail: nil. Exit-status and stderr-tail detail is
//  exercised at the StdioMCPTransport layer instead, via the byte
//  transport it wraps.
//

import Foundation
@testable import Calyx

actor InMemoryMCPTransport: MCPMessageTransport {

    // MARK: - State

    private var captured: [(data: Data, kind: MCPOutboundKind)] = []
    private var cancelledIDs: [JSONRPCId] = []
    private var negotiatedVersions: [(version: MCPProtocolVersion, sentBefore: Int)] = []
    private let continuation: AsyncStream<MCPInbound>.Continuation
    nonisolated let inbound: AsyncStream<MCPInbound>
    private var isClosed = false

    // MARK: - Init

    init() {
        var capturedContinuation: AsyncStream<MCPInbound>.Continuation!
        self.inbound = AsyncStream<MCPInbound> { continuation in
            capturedContinuation = continuation
        }
        self.continuation = capturedContinuation
    }

    // MARK: - MCPMessageTransport

    func send(_ data: Data, kind: MCPOutboundKind) async throws {
        guard !isClosed else { throw MCPTransportError.closed }
        captured.append((data, kind))
    }

    /// Record a cancellation request for requestID. What (if anything)
    /// this produces on the wire is entirely the concrete transport's
    /// decision -- this in-memory double only records the call so tests
    /// can assert on cancelledRequestIDs() directly. A no-op once closed.
    func cancel(requestID: JSONRPCId, reason: String?) async {
        guard !isClosed else { return }
        cancelledIDs.append(requestID)
    }

    /// Records the version, and how many messages had been sent before
    /// it, so tests can assert on negotiatedProtocolVersions() and
    /// negotiatedProtocolVersionLog(). Has no effect on the wire.
    func setNegotiatedProtocolVersion(_ version: MCPProtocolVersion) async {
        negotiatedVersions.append((version, captured.count))
    }

    /// Graceful close, initiated by the caller. Finishes inbound without
    /// ever yielding a closed(reason:) element: a caller-initiated close
    /// must never be mistaken for an unsolicited crash. Idempotent, and
    /// suppresses any crash report that has not yet been observed.
    func close() async {
        guard !isClosed else { return }
        isClosed = true
        continuation.finish()
    }

    // MARK: - Test API

    /// Push a whole JSON-RPC message through inbound as .frame(_:), as
    /// if the server had sent it.
    func simulateServerMessage(_ message: Data) async {
        guard !isClosed else { return }
        continuation.yield(.frame(message))
    }

    /// Simulate an unsolicited transport failure (e.g. the child process
    /// exiting on its own): yields closed(reason:exit:stderrTail:) on
    /// inbound WITHOUT the transport itself having been asked to close,
    /// then marks the transport closed so a subsequent send is dropped.
    /// Distinct from close(), which is the graceful, caller-initiated
    /// path and must never be observed as a crash.
    func simulateCrash(reason: String = "child exited") async {
        guard !isClosed else { return }
        isClosed = true
        continuation.yield(.closed(reason: reason, exit: nil, stderrTail: nil))
        continuation.finish()
    }

    /// Simulate a transport-level error signal (malformed frame, I/O
    /// failure) that does not by itself close the transport.
    func simulateTransportError(_ signal: MCPTransportSignal) async {
        guard !isClosed else { return }
        continuation.yield(.error(signal))
    }

    /// Snapshot of every payload send has received, in order.
    func sentMessages() async -> [Data] {
        captured.map(\.data)
    }

    /// Snapshot of every (payload, kind) pair send has received, in
    /// order -- lets tests pin that a given JSON-RPC method went out as
    /// .request, .notification, or .response.
    func sentFrames() async -> [(data: Data, kind: MCPOutboundKind)] {
        captured
    }

    /// Every request id passed to cancel(requestID:reason:), in order.
    func cancelledRequestIDs() async -> [JSONRPCId] {
        cancelledIDs
    }

    /// Every version passed to setNegotiatedProtocolVersion(_:), in order.
    func negotiatedProtocolVersions() async -> [MCPProtocolVersion] {
        negotiatedVersions.map(\.version)
    }

    /// Every version passed to setNegotiatedProtocolVersion(_:), in order,
    /// with the number of messages send had received before that call.
    func negotiatedProtocolVersionLog() async -> [(version: MCPProtocolVersion, sentBefore: Int)] {
        negotiatedVersions
    }
}
