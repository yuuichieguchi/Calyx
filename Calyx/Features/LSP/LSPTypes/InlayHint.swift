//
//  InlayHint.swift
//  Calyx
//
//  LSP 3.18 textDocument/inlayHint parameter & response types. See:
//  https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocument_inlayHint
//  https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#inlayHint
//  https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#inlayHintKind
//  https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#inlayHintLabelPart
//

import Foundation

// MARK: - InlayHintParams

/// Parameters for the `textDocument/inlayHint` request.
struct InlayHintParams: Sendable, Codable, Equatable {
    let textDocument: TextDocumentIdentifier
    /// The visible document range for which inlay hints should be computed.
    let range: LSPRange
    let workDoneToken: ProgressToken?

    init(
        textDocument: TextDocumentIdentifier,
        range: LSPRange,
        workDoneToken: ProgressToken? = nil
    ) {
        self.textDocument = textDocument
        self.range = range
        self.workDoneToken = workDoneToken
    }
}

// MARK: - InlayHintKind

/// Inlay hint kinds.
enum InlayHintKind: Int, Sendable, Codable, Equatable, Hashable {
    /// An inlay hint that is for a type annotation.
    case type = 1
    /// An inlay hint that is for a parameter.
    case parameter = 2
}

// MARK: - InlayHintLabelPart

/// An inlay hint label part allows for interactive and composite labels of
/// inlay hints.
struct InlayHintLabelPart: Sendable, Codable, Equatable {
    /// The value of this label part.
    let value: String
    /// The tooltip text when the user hovers over this label part. Either a
    /// plain string or a `MarkupContent`.
    let tooltip: StringOrMarkupContent?
    /// An optional source code location that represents this label part.
    /// The editor will use this location for the definition / goto-definition
    /// action on the label part.
    let location: Location?
    /// An optional command for this label part.
    let command: Command?

    init(
        value: String,
        tooltip: StringOrMarkupContent? = nil,
        location: Location? = nil,
        command: Command? = nil
    ) {
        self.value = value
        self.tooltip = tooltip
        self.location = location
        self.command = command
    }
}

// MARK: - InlayHintLabel
//
// Union: `String | InlayHintLabelPart[]`. The spec lets servers ship a single
// concatenated label string or a structured array of parts for interactive
// hints.

/// The label of an inlay hint.
enum InlayHintLabel: Sendable, Codable, Equatable {
    case string(String)
    case parts([InlayHintLabelPart])

    init(from decoder: any Decoder) throws {
        // Try the string variant first via a single-value container.
        if let container = try? decoder.singleValueContainer(),
           let s = try? container.decode(String.self) {
            self = .string(s)
            return
        }
        // Otherwise decode as an array of `InlayHintLabelPart`.
        var unkeyed = try decoder.unkeyedContainer()
        var parts: [InlayHintLabelPart] = []
        if let count = unkeyed.count {
            parts.reserveCapacity(count)
        }
        while !unkeyed.isAtEnd {
            parts.append(try unkeyed.decode(InlayHintLabelPart.self))
        }
        self = .parts(parts)
    }

    func encode(to encoder: any Encoder) throws {
        switch self {
        case .string(let s):
            var container = encoder.singleValueContainer()
            try container.encode(s)
        case .parts(let parts):
            var unkeyed = encoder.unkeyedContainer()
            for part in parts {
                try unkeyed.encode(part)
            }
        }
    }
}

// MARK: - InlayHint
//
// `data` is an opaque server-defined JSON payload. We model it with
// `AnyCodable?` so it round-trips losslessly. Because `AnyCodable` is only
// `Equatable` (not `Hashable`), `InlayHint` cannot conform to `Hashable`.

/// Inlay hint information.
struct InlayHint: Sendable, Codable, Equatable {
    /// The position of this hint.
    let position: Position
    /// The label of this hint. Either a plain string or an array of label
    /// parts for interactive hints.
    let label: InlayHintLabel
    /// The kind of this hint.
    let kind: InlayHintKind?
    /// Optional text edits performed when accepting this inlay hint.
    let textEdits: [TextEdit]?
    /// The tooltip shown when the user hovers over this hint.
    let tooltip: StringOrMarkupContent?
    /// Render padding before the hint.
    let paddingLeft: Bool?
    /// Render padding after the hint.
    let paddingRight: Bool?
    /// A data entry the server can attach for `inlayHint/resolve`.
    let data: AnyCodable?

    init(
        position: Position,
        label: InlayHintLabel,
        kind: InlayHintKind? = nil,
        textEdits: [TextEdit]? = nil,
        tooltip: StringOrMarkupContent? = nil,
        paddingLeft: Bool? = nil,
        paddingRight: Bool? = nil,
        data: AnyCodable? = nil
    ) {
        self.position = position
        self.label = label
        self.kind = kind
        self.textEdits = textEdits
        self.tooltip = tooltip
        self.paddingLeft = paddingLeft
        self.paddingRight = paddingRight
        self.data = data
    }
}
