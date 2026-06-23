//
//  LSPClientError.swift
//  Calyx
//
//  Typed errors surfaced by `LSPClient` and the LSP transport stack.
//
//  These cases cover both transport-level failures (closed, malformed
//  framing) and JSON-RPC level failures (server error responses, decoding
//  failures, MethodNotFound) so callers can route them in `catch` arms.
//

import Foundation

/// Errors raised by `LSPClient` (and its transport implementations) at
/// the LSP/JSON-RPC layer.
enum LSPClientError: Error, Equatable, Sendable {
    /// The underlying transport has been closed (either explicitly via
    /// `close()` or because the spawned process exited).
    case transportClosed

    /// A wall-clock budget elapsed waiting for a server response.
    case timeout

    /// The server emitted bytes that we could not interpret as a valid
    /// LSP Content-Length framed message.
    case malformedFraming(reason: String)

    /// A response arrived but failed to decode into the requested
    /// `Result` type.
    case responseDecodingFailed(reason: String)

    /// The server replied with a JSON-RPC error object.
    case serverError(code: Int, message: String)

    /// The local handler registry does not contain an entry for the
    /// server-initiated method (`-32601 MethodNotFound`).
    case methodNotFound(String)

    /// `start()` was invoked more than once on the same client.
    case alreadyStarted

    /// A `sendRequest` / `sendNotification` was issued before
    /// `start()`.
    case notStarted
}
