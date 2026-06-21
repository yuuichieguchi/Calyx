//
//  ServerInfo.swift
//  Calyx
//
//  LSP 3.18 ServerInfo (returned inside InitializeResult). See:
//  https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#initialize
//

import Foundation

/// Information about the server. Returned by `initialize` so the client can
/// display the running server in its UI / telemetry.
struct ServerInfo: Sendable, Codable, Equatable, Hashable {
    /// The name of the server as defined by the server.
    let name: String
    /// The server's version as defined by the server.
    let version: String?

    init(name: String, version: String? = nil) {
        self.name = name
        self.version = version
    }
}
