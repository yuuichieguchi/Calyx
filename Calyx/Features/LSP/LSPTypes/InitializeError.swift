//
//  InitializeError.swift
//  Calyx
//
//  LSP 3.18 InitializeError (a.k.a. InitializeErrorData). See:
//  https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#initializeError
//
//  Servers attach this object to a JSON-RPC error response from `initialize`
//  via the `data` field. A `retry` of `true` instructs the client that
//  retrying the request after user intervention may succeed.
//

import Foundation

/// Error data attached to a failed `initialize` response.
struct InitializeError: Sendable, Codable, Equatable, Hashable {
    /// Indicates whether the client should retry to send the initialize
    /// request after showing the message provided in the `ResponseError`.
    let retry: Bool

    init(retry: Bool) {
        self.retry = retry
    }
}
