//
//  ReferenceParams.swift
//  Calyx
//
//  LSP 3.18 ReferenceParams + ReferenceContext. See:
//  https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocument_references
//

import Foundation

// MARK: - ReferenceContext

/// Context for a `textDocument/references` request.
struct ReferenceContext: Sendable, Codable, Equatable {
    /// Include the declaration of the current symbol in the results.
    let includeDeclaration: Bool

    init(includeDeclaration: Bool) {
        self.includeDeclaration = includeDeclaration
    }
}

// MARK: - ReferenceParams

/// Parameters for the `textDocument/references` request.
struct ReferenceParams: Sendable, Codable, Equatable {
    let textDocument: TextDocumentIdentifier
    let position: Position
    let context: ReferenceContext
    let workDoneToken: ProgressToken?
    let partialResultToken: ProgressToken?

    init(
        textDocument: TextDocumentIdentifier,
        position: Position,
        context: ReferenceContext,
        workDoneToken: ProgressToken? = nil,
        partialResultToken: ProgressToken? = nil
    ) {
        self.textDocument = textDocument
        self.position = position
        self.context = context
        self.workDoneToken = workDoneToken
        self.partialResultToken = partialResultToken
    }
}
