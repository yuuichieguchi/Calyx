//
//  TextDocumentPositionParams.swift
//  Calyx
//
//  LSP 3.18 TextDocumentPositionParams. See:
//  https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocumentPositionParams
//
//  A parameter literal used in requests to pass a text document and a
//  position inside that document. Forms the shared base for hover,
//  definition, declaration, type definition, implementation, references,
//  document highlight, signature help, and many other request types.
//

import Foundation

/// Parameter literal carrying a text document identifier and a position
/// within that document.
struct TextDocumentPositionParams: Sendable, Codable, Equatable {
    /// The text document.
    let textDocument: TextDocumentIdentifier
    /// The position inside the text document.
    let position: Position

    init(textDocument: TextDocumentIdentifier, position: Position) {
        self.textDocument = textDocument
        self.position = position
    }
}
