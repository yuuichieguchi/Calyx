//
//  DidCloseTextDocumentParams.swift
//  Calyx
//
//  LSP 3.18 DidCloseTextDocumentParams. See:
//  https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocument_didClose
//
//  Sent by the client to inform the server that a previously opened
//  document has been closed. After this notification the server must
//  treat the document as if it no longer exists from the client's
//  perspective (using the on-disk version if it still needs to reason
//  about the file).
//

import Foundation

/// Parameters for the `textDocument/didClose` notification.
struct DidCloseTextDocumentParams: Sendable, Codable, Equatable {
    /// The document that was closed.
    let textDocument: TextDocumentIdentifier

    init(textDocument: TextDocumentIdentifier) {
        self.textDocument = textDocument
    }
}
