//
//  VersionedTextDocumentIdentifier.swift
//  Calyx
//
//  LSP 3.18 VersionedTextDocumentIdentifier type. See:
//  https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#versionedTextDocumentIdentifier
//

import Foundation

/// An identifier to denote a specific version of a text document. The version
/// is increasing with each change including undo/redo so the server can detect
/// out-of-order updates.
struct VersionedTextDocumentIdentifier: Sendable, Codable, Equatable, Hashable {
    let uri: DocumentUri
    let version: Int

    init(uri: DocumentUri, version: Int) {
        self.uri = uri
        self.version = version
    }
}
