//
//  DocumentHighlight.swift
//  Calyx
//
//  LSP 3.18 DocumentHighlightParams + DocumentHighlight + DocumentHighlightKind. See:
//  https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocument_documentHighlight
//

import Foundation

// MARK: - DocumentHighlightParams

/// Parameters for the `textDocument/documentHighlight` request.
struct DocumentHighlightParams: Sendable, Codable, Equatable {
    let textDocument: TextDocumentIdentifier
    let position: Position
    let workDoneToken: ProgressToken?
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

// MARK: - DocumentHighlightKind

/// A document highlight kind.
enum DocumentHighlightKind: Int, Sendable, Codable, Equatable, Hashable {
    /// A textual occurrence.
    case text = 1
    /// Read access of a symbol, like reading a variable.
    case read = 2
    /// Write access of a symbol, like writing to a variable.
    case write = 3
}

// MARK: - DocumentHighlight

/// A document highlight is a range inside a text document which deserves
/// special attention. Usually a document highlight is visualised by
/// changing the background colour of its range.
struct DocumentHighlight: Sendable, Codable, Equatable {
    /// The range this highlight applies to.
    let range: LSPRange
    /// The highlight kind. Defaults to `.text` when not provided.
    let kind: DocumentHighlightKind?

    init(range: LSPRange, kind: DocumentHighlightKind? = nil) {
        self.range = range
        self.kind = kind
    }
}
