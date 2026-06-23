//
//  PublishDiagnosticsParams.swift
//  Calyx
//
//  LSP 3.18 `textDocument/publishDiagnostics` notification params. See:
//  https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#publishDiagnosticsParams
//
//  Wire shape:
//      {
//        "uri":          DocumentUri,
//        "version"?:     integer,
//        "diagnostics":  Diagnostic[]
//      }
//
//  The spec types `version` as `integer | null`. In practice servers omit the
//  field rather than transmit explicit `null`, so we model it as a plain
//  optional `Int?` — both an absent key and a present integer round-trip
//  losslessly, and writing it back never emits `null`.
//

import Foundation

/// Parameters for the `textDocument/publishDiagnostics` notification.
struct PublishDiagnosticsParams: Sendable, Codable, Equatable {
    /// The URI for which diagnostic information is reported.
    let uri: DocumentUri
    /// Optional document version number these diagnostics were computed
    /// against. Clients should ignore notifications older than the version
    /// they currently consider authoritative for `uri`.
    let version: Int?
    /// The absolute set of diagnostics for `uri`. An empty array clears
    /// any previous diagnostics for that URI.
    let diagnostics: [Diagnostic]

    init(uri: DocumentUri, version: Int? = nil, diagnostics: [Diagnostic]) {
        self.uri = uri
        self.version = version
        self.diagnostics = diagnostics
    }
}
