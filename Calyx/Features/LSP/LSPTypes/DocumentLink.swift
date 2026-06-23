//
//  DocumentLink.swift
//  Calyx
//
//  LSP 3.18 textDocument/documentLink parameter & response types. See:
//  https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocument_documentLink
//  https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#documentLink
//

import Foundation

// MARK: - DocumentLinkParams

/// Parameters for the `textDocument/documentLink` request.
struct DocumentLinkParams: Sendable, Codable, Equatable {
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

// MARK: - DocumentLink

/// A document link is a range in a text document that links to an internal
/// or external resource (like another text document or a web site). Unresolved
/// links may be returned with just a `range` and later filled in via
/// `documentLink/resolve`.
struct DocumentLink: Sendable, Codable, Equatable {
    /// The range this link applies to.
    let range: LSPRange
    /// The URI this link points to. If missing a resolve request is sent later.
    let target: DocumentUri?
    /// The tooltip text displayed when the user hovers over the link.
    let tooltip: String?
    /// A data entry field preserved between `textDocument/documentLink` and
    /// `documentLink/resolve`.
    let data: AnyCodable?

    init(
        range: LSPRange,
        target: DocumentUri? = nil,
        tooltip: String? = nil,
        data: AnyCodable? = nil
    ) {
        self.range = range
        self.target = target
        self.tooltip = tooltip
        self.data = data
    }
}
