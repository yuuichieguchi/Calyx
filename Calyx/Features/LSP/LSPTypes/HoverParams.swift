//
//  HoverParams.swift
//  Calyx
//
//  LSP 3.18 HoverParams. See:
//  https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocument_hover
//

import Foundation

/// Parameters for the `textDocument/hover` request.
struct HoverParams: Sendable, Codable, Equatable {
    /// The text document.
    let textDocument: TextDocumentIdentifier
    /// The position inside the text document.
    let position: Position
    /// An optional token that a server can use to report work-done progress.
    let workDoneToken: ProgressToken?

    init(
        textDocument: TextDocumentIdentifier,
        position: Position,
        workDoneToken: ProgressToken? = nil
    ) {
        self.textDocument = textDocument
        self.position = position
        self.workDoneToken = workDoneToken
    }
}
