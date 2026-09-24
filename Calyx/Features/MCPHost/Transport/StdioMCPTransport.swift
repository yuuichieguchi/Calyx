//
//  StdioMCPTransport.swift
//  Calyx
//
//  MCP stdio transport: newline-delimited JSON over a child process's
//  stdin and stdout, carried by an `MCPByteTransport`.
//
//  Lifecycle:
//    - `init` starts the read loop over `byteTransport.incoming`. Every
//      complete line is yielded as `.frame`.
//    - `close()` closes the byte layer with `closeGracefully` and
//      finishes `inbound` without yielding `.closed`.
//    - When `incoming` finishes without `close()`, the child went away
//      on its own: `inbound` yields `.closed` with the exit status and
//      the stderr tail, then finishes.
//    - A line longer than `maxLineBytes` yields `.error` and then closes
//      through the same procedure as `close()`. Lines completed earlier
//      in the same chunk are yielded as `.frame` first.
//

import Foundation

actor StdioMCPTransport: MCPMessageTransport {

    /// Stdin grace `close()` passes to `closeGracefully`.
    static let stdinGrace: TimeInterval = 2
    /// SIGTERM grace `close()` passes to `closeGracefully`.
    static let termGrace: TimeInterval = 2

    /// `notifications/cancelled` as sent by `cancel(requestID:reason:)`.
    private struct CancelledNotification: Encodable {
        let jsonrpc = "2.0"
        let method = "notifications/cancelled"
        let params: MCPCancelledNotificationParams
    }

    private let byteTransport: any MCPByteTransport
    private var framer: NDJSONFramer
    /// Set by `close()`. A lost byte layer is reported as `.closed` only
    /// while this is false.
    private var isCloseRequested = false
    /// Set by `close()` or by loss of the byte layer. `send` throws once set.
    private var isClosed = false

    nonisolated let inbound: AsyncStream<MCPInbound>
    private let continuation: AsyncStream<MCPInbound>.Continuation

    // MARK: - Init

    /// `maxLineBytes` exists so tests can inject a small cap.
    init(byteTransport: any MCPByteTransport, maxLineBytes: Int = NDJSONFramer.maxLineBytes) {
        self.byteTransport = byteTransport
        self.framer = NDJSONFramer(maxLineBytes: maxLineBytes)
        let (stream, continuation) = AsyncStream<MCPInbound>.makeStream()
        self.inbound = stream
        self.continuation = continuation

        // The loop holds the actor weakly and the byte stream directly, so
        // dropping the transport releases the byte layer.
        let incoming = byteTransport.incoming
        Task { [weak self] in
            for await chunk in incoming {
                guard let self else { return }
                let keepReading = await self.receive(chunk)
                if !keepReading { return }
            }
            await self?.incomingFinished()
        }
    }

    // MARK: - MCPMessageTransport

    /// Frames every kind identically: stdio has no per-kind wire behavior.
    func send(_ data: Data, kind: MCPOutboundKind) async throws {
        guard !isClosed else { throw MCPTransportError.closed }
        try await byteTransport.send(framer.encode(data))
    }

    /// Sends one `notifications/cancelled` frame. A failure to encode or
    /// write it is dropped: a dead child is reported through `.closed`,
    /// and an `.error` here would read as a failure of an unrelated
    /// request.
    func cancel(requestID: JSONRPCId, reason: String?) async {
        guard !isClosed else { return }
        let notification = CancelledNotification(
            params: MCPCancelledNotificationParams(requestId: requestID, reason: reason)
        )
        do {
            let payload = try JSONEncoder().encode(notification)
            try await send(payload, kind: .notification)
        } catch {
            return
        }
    }

    /// Finishes `inbound` directly, then closes the byte layer gracefully.
    /// Idempotent.
    func close() async {
        guard !isCloseRequested else { return }
        isCloseRequested = true
        isClosed = true
        continuation.finish()
        await byteTransport.closeGracefully(stdinGrace: Self.stdinGrace, termGrace: Self.termGrace)
    }

    // MARK: - Private

    /// Feeds one chunk to the framer and yields the lines it completed,
    /// then reports a framing failure recorded in the same chunk. Returns
    /// false when reading must stop.
    private func receive(_ chunk: Data) async -> Bool {
        guard !isCloseRequested else { return false }
        let lines: [Data]
        do {
            lines = try framer.feed(chunk)
        } catch {
            await failFraming(error)
            return false
        }
        for line in lines {
            continuation.yield(.frame(line))
        }
        do {
            try framer.checkPending()
        } catch {
            await failFraming(error)
            return false
        }
        return true
    }

    /// Yields `.error` for a framing failure, then closes like `close()`.
    private func failFraming(_ error: any Error) async {
        continuation.yield(.error(MCPTransportSignal(
            httpStatus: nil,
            message: "stdio framing failed: \(error)"
        )))
        await close()
    }

    /// `incoming` finished. Unless `close()` was called, the child exited
    /// on its own and `inbound` reports it as `.closed`.
    private func incomingFinished() async {
        guard !isCloseRequested else { return }
        isClosed = true
        let exit = await byteTransport.waitForExit()
        let stderrTail = await byteTransport.recentStderr()
        guard !isCloseRequested else { return }
        continuation.yield(.closed(
            reason: Self.describe(exit),
            exit: exit,
            stderrTail: stderrTail
        ))
        continuation.finish()
    }

    private static func describe(_ exit: MCPTransportExitInfo) -> String {
        switch exit {
        case .exited(let status):
            return "child exited with status \(status)"
        case .signaled(let signal):
            return "child terminated by signal \(signal)"
        }
    }
}
