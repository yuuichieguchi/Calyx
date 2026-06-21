//
//  DidOpenTextDocumentParams.swift
//  Calyx
//
//  LSP 3.18 DidOpenTextDocumentParams. See:
//  https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocument_didOpen
//
//  Sent by the client to inform the server that a text document has been
//  opened. The wire payload is a single `textDocument: TextDocumentItem`
//  carrying URI, languageId, version, and the full initial content.
//

import Foundation

/// Parameters for the `textDocument/didOpen` notification.
struct DidOpenTextDocumentParams: Sendable, Codable, Equatable {
    /// The document that was opened.
    let textDocument: TextDocumentItem

    init(textDocument: TextDocumentItem) {
        self.textDocument = textDocument
    }
}
