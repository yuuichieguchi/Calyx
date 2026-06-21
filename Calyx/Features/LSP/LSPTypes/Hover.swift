//
//  Hover.swift
//  Calyx
//
//  LSP 3.18 Hover response + HoverContents union. See:
//  https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#hover
//
//  Hover.contents is a 3-way union:
//      MarkupContent | MarkedString | MarkedString[]
//
//  MarkedString itself is `string | { language, value }`. Decoding is
//  disambiguated by shape:
//    - JSON array       -> .markedStrings([MarkedString])
//    - JSON object with `kind` and `value` -> .markupContent(MarkupContent)
//    - JSON string OR object with `language` and `value` -> .markedString(MarkedString)
//

import Foundation

// MARK: - HoverContents

/// The contents of a `Hover` response. One of `MarkupContent`,
/// `MarkedString`, or `MarkedString[]`.
///
/// `MarkedString` is deprecated by the spec but still emitted by older
/// language servers, so all three variants must be supported.
enum HoverContents: Sendable, Codable, Equatable {
    case markupContent(MarkupContent)
    case markedString(MarkedString)
    case markedStrings([MarkedString])

    init(from decoder: any Decoder) throws {
        // Array form must be tried first; otherwise the single-element
        // MarkedString decode would consume the wrong shape.
        if let arr = try? [MarkedString](from: decoder) {
            self = .markedStrings(arr)
            return
        }
        // MarkupContent has required `kind` + `value`; this is disjoint
        // from MarkedString.codeBlock which has `language` + `value`.
        if let mc = try? MarkupContent(from: decoder) {
            self = .markupContent(mc)
            return
        }
        // Fall back to MarkedString (bare string or `{ language, value }`).
        let ms = try MarkedString(from: decoder)
        self = .markedString(ms)
    }

    func encode(to encoder: any Encoder) throws {
        switch self {
        case .markupContent(let mc):
            try mc.encode(to: encoder)
        case .markedString(let ms):
            try ms.encode(to: encoder)
        case .markedStrings(let arr):
            try arr.encode(to: encoder)
        }
    }
}

// MARK: - Hover

/// The result of a `textDocument/hover` request.
struct Hover: Sendable, Codable, Equatable {
    /// The hover's content.
    let contents: HoverContents
    /// An optional range inside the text document where the hover applies.
    /// Used by the client to visualise the hover.
    let range: LSPRange?

    init(contents: HoverContents, range: LSPRange? = nil) {
        self.contents = contents
        self.range = range
    }
}
