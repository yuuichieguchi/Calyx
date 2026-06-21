//
//  DidSaveTextDocumentParams.swift
//  Calyx
//
//  LSP 3.18 DidSaveTextDocumentParams. See:
//  https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocument_didSave
//
//  Sent by the client after a document has been saved. The optional
//  `text` field is populated only when the server registered the
//  `textDocument/didSave` capability with `includeText: true`; when
//  absent it must NOT round-trip as JSON `null` (the spec defines the
//  field as `string?`, not `string | null`).
//

import Foundation

/// Parameters for the `textDocument/didSave` notification.
struct DidSaveTextDocumentParams: Sendable, Codable, Equatable {
    /// The document that was saved.
    let textDocument: TextDocumentIdentifier
    /// Optional full content of the document at the time of save. Encoded
    /// only when present; never serialised as JSON `null`.
    let text: String?

    init(textDocument: TextDocumentIdentifier, text: String? = nil) {
        self.textDocument = textDocument
        self.text = text
    }

    private enum CodingKeys: String, CodingKey {
        case textDocument
        case text
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.textDocument = try c.decode(TextDocumentIdentifier.self, forKey: .textDocument)
        self.text = try c.decodeIfPresent(String.self, forKey: .text)
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(textDocument, forKey: .textDocument)
        try c.encodeIfPresent(text, forKey: .text)
    }
}
