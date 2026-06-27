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

/// Typed error a server-initiated request handler can throw to control
/// which JSON-RPC error code the dispatcher writes back to the server.
///
/// Without this, the dispatcher can only special-case Swift's literal
/// `DecodingError` and treats every other error as `-32603 InternalError`,
/// even when the handler knows the parameters were malformed
/// (`-32602 InvalidParams`) or the method is dynamically unsupported
/// (`-32601 MethodNotFound`). Handlers should prefer raising
/// `LSPHandlerError` so the wire response code matches semantics
/// regardless of any wrapped underlying Swift type.
enum LSPHandlerError: Error, Equatable, Sendable {
    /// JSON-RPC `-32602`. Parameters did not match the handler's schema.
    case invalidParams(String)

    /// JSON-RPC `-32601`. Handler determined at runtime that it cannot
    /// service the method (e.g. dynamic capability gone).
    case methodNotFound(String)

    /// JSON-RPC `-32603`. Catch-all for handler-internal failures.
    case internalError(String)
}
