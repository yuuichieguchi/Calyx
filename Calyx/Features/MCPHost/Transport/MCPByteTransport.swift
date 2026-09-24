//
//  MCPByteTransport.swift
//  Calyx
//
//  Byte layer under `StdioMCPTransport`. `StdioLSPTransport` is the
//  production conformer.
//

import Foundation

/// A child process's stdio as a byte transport.
///
/// `incoming` is a single-consumer stream that finishes when the
/// transport is closed or the child exits.
protocol MCPByteTransport: Sendable {
    /// Starts the child. Idempotent.
    func spawn() async throws
    nonisolated var incoming: AsyncStream<Data> { get }
    func send(_ data: Data) async throws
    /// Suspends until the child has exited and returns how it ended.
    func waitForExit() async -> MCPTransportExitInfo
    /// Closes stdin, waits `stdinGrace`, sends SIGTERM, waits
    /// `termGrace`, then sends SIGKILL, returning as soon as the child
    /// has exited. Idempotent.
    func closeGracefully(stdinGrace: TimeInterval, termGrace: TimeInterval) async
    /// The most recent bytes the child wrote to stderr.
    func recentStderr() async -> Data
    /// Immediate SIGTERM, escalated to SIGKILL after 2 seconds.
    func close() async
}
