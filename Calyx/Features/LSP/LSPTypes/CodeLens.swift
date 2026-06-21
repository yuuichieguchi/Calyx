//
//  CodeLens.swift
//  Calyx
//
//  LSP 3.18 textDocument/codeLens parameter & response types. See:
//  https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocument_codeLens
//  https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#codeLens
//

import Foundation

// MARK: - CodeLensParams

/// Parameters for the `textDocument/codeLens` request.
struct CodeLensParams: Sendable, Codable, Equatable {
    let textDocument: TextDocumentIdentifier
    let workDoneToken: ProgressToken?
    let partialResultToken: ProgressToken?

    init(
        textDocument: TextDocumentIdentifier,
        workDoneToken: ProgressToken? = nil,
        partialResultToken: ProgressToken? = nil
    ) {
        self.textDocument = textDocument
        self.workDoneToken = workDoneToken
        self.partialResultToken = partialResultToken
    }
}

// MARK: - CodeLens

/// A code lens represents a command that should be shown along with source
/// text, like the number of references, a way to run tests, etc. A code lens
/// is _unresolved_ when no command is associated to it. The server is then
/// expected to resolve it via `codeLens/resolve`.
struct CodeLens: Sendable, Codable, Equatable {
    /// The range in which this code lens is valid. Should only span a single
    /// line.
    let range: LSPRange
    /// The command this code lens represents.
    let command: Command?
    /// A data entry field preserved between `textDocument/codeLens` and
    /// `codeLens/resolve`.
    let data: AnyCodable?

    init(
        range: LSPRange,
        command: Command? = nil,
        data: AnyCodable? = nil
    ) {
        self.range = range
        self.command = command
        self.data = data
    }
}
