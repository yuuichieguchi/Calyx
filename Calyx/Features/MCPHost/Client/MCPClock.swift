//
//  MCPClock.swift
//  Calyx
//
//  The clock shared by every MCP host timer: request timeouts in
//  `MCPUpstreamClient`, reconnect backoff in `MCPUpstreamConnection`,
//  and the legacy SSE reconnect delay in `StreamableHTTPMCPTransport`.
//

import Foundation

/// Time source for MCP host timers. Injected so tests control when a
/// timeout or backoff elapses.
protocol MCPClock: Sendable {
    func now() -> Date
    /// Suspends for `seconds`. Returns early when the calling Task is
    /// cancelled.
    func sleep(for seconds: TimeInterval) async
}

/// Wall-clock `MCPClock`.
struct SystemMCPClock: MCPClock {
    func now() -> Date { Date() }

    func sleep(for seconds: TimeInterval) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}
