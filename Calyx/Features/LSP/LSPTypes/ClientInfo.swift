//
//  ClientInfo.swift
//  Calyx
//
//  LSP 3.18 ClientInfo (sent inside InitializeParams). See:
//  https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#initialize
//

import Foundation

/// Information about the client used by the server e.g. for telemetry. Both
/// fields are exposed verbatim on the wire; `version` is omitted when nil
/// rather than encoded as JSON null.
struct ClientInfo: Sendable, Codable, Equatable, Hashable {
    /// The name of the client as defined by the client.
    let name: String
    /// The client's version as defined by the client.
    let version: String?

    init(name: String, version: String? = nil) {
        self.name = name
        self.version = version
    }
}
