//
//  TextEdit.swift
//  Calyx
//
//  LSP 3.18 TextEdit + AnnotatedTextEdit types. See:
//  https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textEdit
//  https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#annotatedTextEdit
//

import Foundation

/// A text edit applicable to a text document.
struct TextEdit: Sendable, Codable, Equatable, Hashable {
    /// The range of the text document to be manipulated. To insert text into
    /// a document create a range where `start == end`.
    let range: LSPRange
    /// The string to be inserted. For delete operations use an empty string.
    let newText: String

    init(range: LSPRange, newText: String) {
        self.range = range
        self.newText = newText
    }
}

/// A special text edit with an additional change annotation reference.
struct AnnotatedTextEdit: Sendable, Codable, Equatable, Hashable {
    let range: LSPRange
    let newText: String
    /// The actual change annotation identifier referenced from a
    /// `WorkspaceEdit.changeAnnotations` table.
    let annotationId: ChangeAnnotationIdentifier

    init(range: LSPRange, newText: String, annotationId: ChangeAnnotationIdentifier) {
        self.range = range
        self.newText = newText
        self.annotationId = annotationId
    }
}

/// An identifier referring to a change annotation managed by a workspace edit.
typealias ChangeAnnotationIdentifier = String
