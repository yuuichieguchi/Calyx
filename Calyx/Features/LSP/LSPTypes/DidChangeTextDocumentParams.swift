//
//  DidChangeTextDocumentParams.swift
//  Calyx
//
//  LSP 3.18 DidChangeTextDocumentParams. See:
//  https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocument_didChange
//
//  Sent by the client when an open document changes. The
//  `contentChanges` array may legally mix incremental edits with a
//  full-document replacement; see `TextDocumentContentChangeEvent`.
//

import Foundation

/// Parameters for the `textDocument/didChange` notification.
struct DidChangeTextDocumentParams: Sendable, Codable, Equatable {
    /// The document that was changed, with the new version number after
    /// the edits in `contentChanges` have been applied.
    let textDocument: VersionedTextDocumentIdentifier
    /// The actual content changes. The order matters: changes are applied
    /// in array order, each against the document state produced by the
    /// previous entry.
    let contentChanges: [TextDocumentContentChangeEvent]

    init(
        textDocument: VersionedTextDocumentIdentifier,
        contentChanges: [TextDocumentContentChangeEvent]
    ) {
        self.textDocument = textDocument
        self.contentChanges = contentChanges
    }
}
