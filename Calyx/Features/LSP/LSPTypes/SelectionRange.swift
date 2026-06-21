//
//  SelectionRange.swift
//  Calyx
//
//  LSP 3.18 textDocument/selectionRange parameter & response types. See:
//  https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocument_selectionRange
//  https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#selectionRange
//

import Foundation

// MARK: - SelectionRangeParams

/// Parameters for the `textDocument/selectionRange` request.
struct SelectionRangeParams: Sendable, Codable, Equatable {
    let textDocument: TextDocumentIdentifier
    /// The positions inside the text document for which selection ranges
    /// should be computed.
    let positions: [Position]
    let workDoneToken: ProgressToken?
    let partialResultToken: ProgressToken?

    init(
        textDocument: TextDocumentIdentifier,
        positions: [Position],
        workDoneToken: ProgressToken? = nil,
        partialResultToken: ProgressToken? = nil
    ) {
        self.textDocument = textDocument
        self.positions = positions
        self.workDoneToken = workDoneToken
        self.partialResultToken = partialResultToken
    }
}

// MARK: - SelectionRange
//
// SelectionRange is a RECURSIVE structure: each node has an optional `parent`
// pointing to a surrounding selection range. Swift cannot express recursion
// in a `struct` without indirection, so we box it in a `final class`.
//
// `@unchecked Sendable`: Swift does not auto-derive `Sendable` for classes,
// even `final` ones with only immutable `let` stored properties. Because
// every stored property here is `let` and transitively `Sendable`
// (`LSPRange` is a `Sendable` struct, `SelectionRange?` is `Sendable` once
// we promise it), the type is in fact thread-safe by construction. We make
// the conformance unchecked to communicate this to the compiler without
// introducing any synchronization primitives.

final class SelectionRange: @unchecked Sendable, Codable, Equatable {
    /// The range of this selection range.
    let range: LSPRange
    /// The parent selection range containing this range. Therefore
    /// `parent.range` must contain `this.range`.
    let parent: SelectionRange?

    init(range: LSPRange, parent: SelectionRange? = nil) {
        self.range = range
        self.parent = parent
    }

    static func == (lhs: SelectionRange, rhs: SelectionRange) -> Bool {
        lhs.range == rhs.range && lhs.parent == rhs.parent
    }

    // Codable is synthesised. For a class with `let` stored properties of
    // Codable types Swift generates the keyed-container encode/decode pair
    // that matches the JSON shape { "range": ..., "parent": { ... } }.
}
