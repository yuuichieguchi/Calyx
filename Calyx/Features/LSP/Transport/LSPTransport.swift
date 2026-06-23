//
//  LSPTransport.swift
//  Calyx
//
//  Abstract bidirectional byte transport used by `LSPClient` to talk to
//  a language server. Production code uses `StdioLSPTransport` to spawn
//  a child process; tests use `InMemoryLSPTransport` to simulate one.
//
//  The transport speaks raw `Data` only; framing (Content-Length headers)
//  is handled by `LSPClient`.
//

import Foundation

/// Bidirectional byte transport that connects `LSPClient` to a language
/// server.
///
/// Implementations are responsible for moving bytes; they do not parse
/// LSP framing, JSON-RPC, or anything above the byte layer.
protocol LSPTransport: Sendable {
    /// Append outbound bytes for the server. Throws if the transport is
    /// already closed or the underlying writer failed.
    func send(_ data: Data) async throws

    /// Stream of raw inbound bytes from the server. The stream finishes
    /// when the transport is closed (either by `close()` or because the
    /// remote endpoint went away).
    nonisolated var incoming: AsyncStream<Data> { get }

    /// Idempotent shutdown. Subsequent `send` calls must throw and
    /// `incoming` must finish.
    func close() async
}
