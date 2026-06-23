//
//  WorkspaceEdit.swift
//  Calyx
//
//  LSP 3.18 WorkspaceEdit type. See:
//  https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#workspaceEdit
//

import Foundation

/// A workspace edit represents changes to many resources managed in the
/// workspace. The edit should either provide `changes` or `documentChanges`.
struct WorkspaceEdit: Sendable, Codable, Equatable, Hashable {
    /// Holds changes to existing resources keyed by document URI.
    let changes: [DocumentUri: [TextEdit]]?

    /// Versioned document changes. If a client neither supports
    /// `documentChanges` nor `workspace.workspaceEdit.resourceOperations`,
    /// only plain `TextEdit`s using `changes` are supported.
    let documentChanges: [DocumentChange]?

    /// A map of change annotations that can be referenced in
    /// `AnnotatedTextEdit`s or resource operation kinds. Server must use
    /// these annotations only if the client signals annotation support.
    let changeAnnotations: [ChangeAnnotationIdentifier: ChangeAnnotation]?

    init(
        changes: [DocumentUri: [TextEdit]]? = nil,
        documentChanges: [DocumentChange]? = nil,
        changeAnnotations: [ChangeAnnotationIdentifier: ChangeAnnotation]? = nil
    ) {
        self.changes = changes
        self.documentChanges = documentChanges
        self.changeAnnotations = changeAnnotations
    }
}
