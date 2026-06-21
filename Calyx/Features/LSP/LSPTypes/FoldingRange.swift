//
//  FoldingRange.swift
//  Calyx
//
//  LSP 3.18 textDocument/foldingRange parameter & response types. See:
//  https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocument_foldingRange
//  https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#foldingRange
//  https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#foldingRangeKind
//

import Foundation

// MARK: - FoldingRangeParams

/// Parameters for the `textDocument/foldingRange` request.
struct FoldingRangeParams: Sendable, Codable, Equatable {
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

// MARK: - FoldingRangeKind

/// A set of predefined `FoldingRange` kinds. The spec defines this as an
/// open string enum but enumerates only `comment`, `imports`, and `region`.
/// We keep the closed `String`-raw enum for now to match the test contract;
/// extend to a `RawRepresentable` wrapper if servers ever ship custom values.
enum FoldingRangeKind: String, Sendable, Codable, Equatable, Hashable {
    case comment
    case imports
    case region
}

// MARK: - FoldingRange

/// Represents a folding range. Only `startLine` and `endLine` are required.
/// Character positions are optional; if not provided the folding range is
/// interpreted as line-only.
struct FoldingRange: Sendable, Codable, Equatable {
    /// The zero-based start line of the range to fold.
    let startLine: Int
    /// The zero-based character offset from where the folded range starts.
    let startCharacter: Int?
    /// The zero-based end line of the range to fold.
    let endLine: Int
    /// The zero-based character offset before the folded range ends.
    let endCharacter: Int?
    /// Describes the kind of the folding range.
    let kind: FoldingRangeKind?
    /// The text the client should show when the specified range is collapsed.
    /// If not defined or not supported by the client a default value
    /// shall be chosen by the client.
    let collapsedText: String?

    init(
        startLine: Int,
        startCharacter: Int? = nil,
        endLine: Int,
        endCharacter: Int? = nil,
        kind: FoldingRangeKind? = nil,
        collapsedText: String? = nil
    ) {
        self.startLine = startLine
        self.startCharacter = startCharacter
        self.endLine = endLine
        self.endCharacter = endCharacter
        self.kind = kind
        self.collapsedText = collapsedText
    }
}
