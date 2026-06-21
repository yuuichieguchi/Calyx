//
//  InMemoryLSPTransport.swift
//  Calyx
//
//  In-memory `LSPTransport` test double. Captures every byte the client
//  writes (so tests can inspect framing/JSON-RPC envelopes) and lets
//  tests inject server-originated bytes via `simulateServerMessage`.
//
//  This type is shipped with the production target intentionally — it is
//  also useful for ad-hoc local diagnostic harnesses — but it carries no
//  external I/O.
//

import Foundation

/// In-memory `LSPTransport` used by tests and offline diagnostics.
///
/// Thread-safety: actor-isolated. The `incoming` stream is `nonisolated`
/// but its yield site is the nonisolated continuation captured at init,
/// which `AsyncStream` makes safe to call from any context.
actor InMemoryLSPTransport: LSPTransport {

    // MARK: - State

    /// All payloads passed to `send`, in order.
    private var captured: [Data] = []

    /// Continuation for the `incoming` stream. Set in `init`.
    private let continuation: AsyncStream<Data>.Continuation

    /// Public stream for inbound bytes.
    nonisolated let incoming: AsyncStream<Data>

    private var isClosed = false

    // MARK: - Init

    init() {
        var capturedContinuation: AsyncStream<Data>.Continuation!
        self.incoming = AsyncStream<Data> { continuation in
            capturedContinuation = continuation
        }
        self.continuation = capturedContinuation
    }

    // MARK: - LSPTransport

    func send(_ data: Data) async throws {
        if isClosed {
            throw LSPClientError.transportClosed
        }
        captured.append(data)
    }

    func close() async {
        guard !isClosed else { return }
        isClosed = true
        continuation.finish()
    }

    // MARK: - Test API

    /// Push bytes through `incoming` as if the server had sent them.
    func simulateServerMessage(_ data: Data) {
        guard !isClosed else { return }
        continuation.yield(data)
    }

    /// Snapshot of every payload `send` has received, in order.
    func sentMessages() -> [Data] {
        captured
    }
}
