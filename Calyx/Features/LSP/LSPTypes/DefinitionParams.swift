//
//  DefinitionParams.swift
//  Calyx
//
//  LSP 3.18 DefinitionParams + DefinitionResult. See:
//  https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocument_definition
//

import Foundation

// MARK: - DefinitionParams

/// Parameters for the `textDocument/definition` request.
struct DefinitionParams: Sendable, Codable, Equatable {
    /// The text document.
    let textDocument: TextDocumentIdentifier
    /// The position inside the text document.
    let position: Position
    /// An optional token that a server can use to report work-done progress.
    let workDoneToken: ProgressToken?
    /// An optional token that a server can use to report partial results.
    let partialResultToken: ProgressToken?

    init(
        textDocument: TextDocumentIdentifier,
        position: Position,
        workDoneToken: ProgressToken? = nil,
        partialResultToken: ProgressToken? = nil
    ) {
        self.textDocument = textDocument
        self.position = position
        self.workDoneToken = workDoneToken
        self.partialResultToken = partialResultToken
    }
}
