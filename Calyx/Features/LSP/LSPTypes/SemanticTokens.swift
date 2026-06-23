//
//  SemanticTokens.swift
//  Calyx
//
//  LSP 3.18 Semantic Tokens cluster. See:
//  https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocument_semanticTokens
//  https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#semanticTokensLegend
//  https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#semanticTokens
//  https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#semanticTokensDelta
//  https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#semanticTokens_rangeRequest
//  https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#semanticTokens_deltaRequest
//

import Foundation

// MARK: - SemanticTokensLegend

/// Describes the token type and modifier vocabulary the server uses inside
/// `SemanticTokens.data`.
struct SemanticTokensLegend: Sendable, Codable, Equatable, Hashable {
    /// The token types a server uses.
    let tokenTypes: [String]
    /// The token modifiers a server uses.
    let tokenModifiers: [String]

    init(tokenTypes: [String], tokenModifiers: [String]) {
        self.tokenTypes = tokenTypes
        self.tokenModifiers = tokenModifiers
    }
}

// MARK: - SemanticTokensParams

/// Parameters for the `textDocument/semanticTokens/full` request.
struct SemanticTokensParams: Sendable, Codable, Equatable {
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

// MARK: - SemanticTokensRangeParams

/// Parameters for the `textDocument/semanticTokens/range` request.
struct SemanticTokensRangeParams: Sendable, Codable, Equatable {
    let textDocument: TextDocumentIdentifier
    /// The range the client is interested in.
    let range: LSPRange
    let workDoneToken: ProgressToken?
    let partialResultToken: ProgressToken?

    init(
        textDocument: TextDocumentIdentifier,
        range: LSPRange,
        workDoneToken: ProgressToken? = nil,
        partialResultToken: ProgressToken? = nil
    ) {
        self.textDocument = textDocument
        self.range = range
        self.workDoneToken = workDoneToken
        self.partialResultToken = partialResultToken
    }
}

// MARK: - SemanticTokensDeltaParams

/// Parameters for the `textDocument/semanticTokens/full/delta` request.
struct SemanticTokensDeltaParams: Sendable, Codable, Equatable {
    let textDocument: TextDocumentIdentifier
    /// The result id of a previous `SemanticTokens` response. The server can
    /// use this to compute a delta to the previous tokens.
    let previousResultId: String
    let workDoneToken: ProgressToken?
    let partialResultToken: ProgressToken?

    init(
        textDocument: TextDocumentIdentifier,
        previousResultId: String,
        workDoneToken: ProgressToken? = nil,
        partialResultToken: ProgressToken? = nil
    ) {
        self.textDocument = textDocument
        self.previousResultId = previousResultId
        self.workDoneToken = workDoneToken
        self.partialResultToken = partialResultToken
    }
}

// MARK: - SemanticTokens

/// The full semantic tokens of a document. `data` is the flat, run-length-ish
/// encoded token stream: 5 integers per token —
/// `(deltaLine, deltaStart, length, tokenType, tokenModifierBitset)`.
struct SemanticTokens: Sendable, Codable, Equatable, Hashable {
    /// An optional id the server can attach to subsequent `delta` requests so
    /// it can compute differences against this snapshot.
    let resultId: String?
    /// The encoded token data.
    let data: [Int]

    init(resultId: String? = nil, data: [Int]) {
        self.resultId = resultId
        self.data = data
    }
}

// MARK: - SemanticTokensEdit

/// A single edit to a previously delivered `SemanticTokens.data` array.
struct SemanticTokensEdit: Sendable, Codable, Equatable, Hashable {
    /// The start offset of the edit.
    let start: Int
    /// The number of elements to remove.
    let deleteCount: Int
    /// The elements to insert. `nil` means delete only.
    let data: [Int]?

    init(start: Int, deleteCount: Int, data: [Int]? = nil) {
        self.start = start
        self.deleteCount = deleteCount
        self.data = data
    }
}

// MARK: - SemanticTokensDelta

/// The semantic tokens delta result of a
/// `textDocument/semanticTokens/full/delta` request.
struct SemanticTokensDelta: Sendable, Codable, Equatable, Hashable {
    /// Optional new result id for the next delta request.
    let resultId: String?
    /// The edits to transform the previous tokens result into the new one.
    let edits: [SemanticTokensEdit]

    init(resultId: String? = nil, edits: [SemanticTokensEdit]) {
        self.resultId = resultId
        self.edits = edits
    }
}

// MARK: - SemanticTokensDeltaResult
//
// Union: `SemanticTokens | SemanticTokensDelta`.
//
// Spec discriminator: presence of the `edits` key indicates the delta variant.
// Absence — i.e. the payload looks like a `SemanticTokens` with a `data`
// array — indicates the full variant.

/// The response payload of a `textDocument/semanticTokens/full/delta`
/// request, which the server may answer with either a full `SemanticTokens`
/// snapshot (no previous baseline / cache invalidated) or a `SemanticTokensDelta`
/// expressing edits against the previous result id.
enum SemanticTokensDeltaResult: Sendable, Codable, Equatable {
    case full(SemanticTokens)
    case delta(SemanticTokensDelta)

    private enum DiscriminatorKey: String, CodingKey {
        case edits
    }

    init(from decoder: any Decoder) throws {
        let keyed = try decoder.container(keyedBy: DiscriminatorKey.self)
        if keyed.contains(.edits) {
            self = .delta(try SemanticTokensDelta(from: decoder))
        } else {
            self = .full(try SemanticTokens(from: decoder))
        }
    }

    func encode(to encoder: any Encoder) throws {
        switch self {
        case .full(let tokens):
            try tokens.encode(to: encoder)
        case .delta(let delta):
            try delta.encode(to: encoder)
        }
    }
}
