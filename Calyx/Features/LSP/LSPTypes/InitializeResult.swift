//
//  InitializeResult.swift
//  Calyx
//
//  LSP 3.18 InitializeResult. See:
//  https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#initializeResult
//
//  Returned by the server in response to the `initialize` request. The
//  `capabilities` field is required. `serverInfo` is optional and omitted
//  from the wire form when nil.
//

import Foundation

/// Result returned by the server from the `initialize` request.
struct InitializeResult: Sendable, Codable, Equatable {
    /// The capabilities the server provides.
    let capabilities: ServerCapabilities
    /// Information about the server.
    let serverInfo: ServerInfo?

    init(capabilities: ServerCapabilities, serverInfo: ServerInfo? = nil) {
        self.capabilities = capabilities
        self.serverInfo = serverInfo
    }
}
