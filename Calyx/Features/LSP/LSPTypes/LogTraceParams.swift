//
//  LogTraceParams.swift
//  Calyx
//
//  LSP 3.18 LogTraceParams. See:
//  https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#logTrace
//
//  Sent from server to client to log a trace message. `verbose` is populated
//  only when the negotiated trace level is `"verbose"`.
//

import Foundation

/// Params for the `$/logTrace` notification.
struct LogTraceParams: Sendable, Codable, Equatable, Hashable {
    /// The message to be logged.
    let message: String
    /// Additional information that can be computed if the `trace`
    /// configuration is set to `'verbose'`.
    let verbose: String?

    init(message: String, verbose: String? = nil) {
        self.message = message
        self.verbose = verbose
    }
}
