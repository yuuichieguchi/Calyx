//
//  TextDocumentIdentifier.swift
//  Calyx
//
//  LSP 3.18 TextDocumentIdentifier type. See:
//  https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocumentIdentifier
//

import Foundation

/// Text documents are identified using a URI.
struct TextDocumentIdentifier: Sendable, Codable, Equatable, Hashable {
    let uri: DocumentUri

    init(uri: DocumentUri) {
        self.uri = uri
    }
}
