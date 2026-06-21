//
//  TextDocumentEdit.swift
//  Calyx
//
//  LSP 3.18 TextDocumentEdit type. See:
//  https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocumentEdit
//
//  `edits` is the union `(TextEdit | AnnotatedTextEdit)[]` in the spec. The
//  AnnotatedTextEdit variant is structurally a TextEdit with an extra
//  `annotationId` discriminator key. We model the union as
//  `TextDocumentEditOperation` and discriminate on the presence of
//  `annotationId` during decode.
//

import Foundation

/// One element of a `TextDocumentEdit.edits` array. Either a plain `TextEdit`
/// or an `AnnotatedTextEdit` carrying a change annotation identifier.
enum TextDocumentEditOperation: Sendable, Codable, Equatable, Hashable {
    case plain(TextEdit)
    case annotated(AnnotatedTextEdit)

    private enum DiscriminatorKey: String, CodingKey {
        case annotationId
    }

    init(from decoder: any Decoder) throws {
        let probe = try decoder.container(keyedBy: DiscriminatorKey.self)
        if probe.contains(.annotationId) {
            self = .annotated(try AnnotatedTextEdit(from: decoder))
        } else {
            self = .plain(try TextEdit(from: decoder))
        }
    }

    func encode(to encoder: any Encoder) throws {
        switch self {
        case .plain(let edit):
            try edit.encode(to: encoder)
        case .annotated(let edit):
            try edit.encode(to: encoder)
        }
    }
}

/// Describes textual changes on a single text document. The text document is
/// referred to as a `OptionalVersionedTextDocumentIdentifier` to allow clients
/// to check the text document version before an edit is applied.
struct TextDocumentEdit: Sendable, Codable, Equatable, Hashable {
    let textDocument: OptionalVersionedTextDocumentIdentifier
    let edits: [TextDocumentEditOperation]

    init(
        textDocument: OptionalVersionedTextDocumentIdentifier,
        edits: [TextDocumentEditOperation]
    ) {
        self.textDocument = textDocument
        self.edits = edits
    }
}
