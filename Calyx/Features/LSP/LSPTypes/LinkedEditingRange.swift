//
//  LinkedEditingRange.swift
//  Calyx
//
//  LSP 3.18 textDocument/linkedEditingRange request and response types. See:
//  https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocument_linkedEditingRange
//

import Foundation

// MARK: - LinkedEditingRangeParams

/// Parameters for the `textDocument/linkedEditingRange` request.
struct LinkedEditingRangeParams: Sendable, Codable, Equatable {
    let textDocument: TextDocumentIdentifier
    let position: Position
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

// MARK: - LinkedEditingRanges

/// The result of a `textDocument/linkedEditingRange` request. Contains a list
/// of ranges that the client should keep in sync while the user types, plus
/// an optional regular-expression pattern that matches identifiers the
/// feature applies to.
struct LinkedEditingRanges: Sendable, Codable, Equatable {
    /// A list of ranges that can be edited together. The ranges must have
    /// identical length and contain identical text content. The ranges
    /// cannot overlap.
    let ranges: [LSPRange]
    /// An optional word pattern (regular expression) that describes valid
    /// contents for the given ranges. If no pattern is provided, the client
    /// configuration's word pattern will be used.
    let wordPattern: String?

    init(ranges: [LSPRange], wordPattern: String? = nil) {
        self.ranges = ranges
        self.wordPattern = wordPattern
    }
}
