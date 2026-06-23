//
//  TextDocumentContentChangeEvent.swift
//  Calyx
//
//  LSP 3.18 TextDocumentContentChangeEvent. See:
//  https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocumentContentChangeEvent
//
//  A single entry inside `DidChangeTextDocumentParams.contentChanges`. The
//  spec models it as a discriminated union:
//
//    incremental:
//      { range: Range, rangeLength?: uinteger, text: string }
//
//    full (whole-document replace):
//      { text: string }
//
//  The discriminator is the *presence* of the `range` key. We surface the
//  two arms as Swift cases and implement Codable by hand so encoding omits
//  `range` (and `rangeLength`) for `.full`, and `rangeLength` is omitted
//  when nil.
//

import Foundation

/// Single textDocument/didChange entry. Either an incremental edit
/// addressed by `range`, or a full-document replacement.
enum TextDocumentContentChangeEvent: Sendable, Codable, Equatable {
    /// Incremental change: replace the text covered by `range` with `text`.
    /// `rangeLength` is the (deprecated, but still emitted by some servers)
    /// pre-edit length of the range and is optional on the wire.
    case incremental(range: LSPRange, rangeLength: Int?, text: String)
    /// Full-document replacement.
    case full(text: String)

    private enum CodingKeys: String, CodingKey {
        case range
        case rangeLength
        case text
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let text = try c.decode(String.self, forKey: .text)
        if c.contains(.range) {
            let range = try c.decode(LSPRange.self, forKey: .range)
            let rangeLength = try c.decodeIfPresent(Int.self, forKey: .rangeLength)
            self = .incremental(range: range, rangeLength: rangeLength, text: text)
        } else {
            self = .full(text: text)
        }
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .incremental(let range, let rangeLength, let text):
            try c.encode(range, forKey: .range)
            try c.encodeIfPresent(rangeLength, forKey: .rangeLength)
            try c.encode(text, forKey: .text)
        case .full(let text):
            try c.encode(text, forKey: .text)
        }
    }
}
