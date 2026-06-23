//
//  TextDocumentItem.swift
//  Calyx
//
//  LSP 3.18 TextDocumentItem type. See:
//  https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocumentItem
//

import Foundation

/// An item to transfer a text document from the client to the server.
struct TextDocumentItem: Sendable, Codable, Equatable, Hashable {
    let uri: DocumentUri
    let languageId: String
    let version: Int
    let text: String

    init(uri: DocumentUri, languageId: String, version: Int, text: String) {
        self.uri = uri
        self.languageId = languageId
        self.version = version
        self.text = text
    }
}
