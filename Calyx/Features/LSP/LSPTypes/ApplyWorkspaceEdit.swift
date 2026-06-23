//
//  ApplyWorkspaceEdit.swift
//  Calyx
//
//  LSP 3.18 ApplyWorkspaceEdit request and response types. See:
//  https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#workspace_applyEdit
//

import Foundation

/// Parameters of a `workspace/applyEdit` request, sent from server to
/// client to ask the client to apply a workspace edit.
struct ApplyWorkspaceEditParams: Sendable, Codable, Equatable {
    /// An optional label of the workspace edit. Used by the client UI for
    /// e.g. presenting the workspace edit in the user interface.
    let label: String?
    /// The edits to apply.
    let edit: WorkspaceEdit

    init(label: String? = nil, edit: WorkspaceEdit) {
        self.label = label
        self.edit = edit
    }
}

/// The result returned from the `workspace/applyEdit` request.
struct ApplyWorkspaceEditResult: Sendable, Codable, Equatable {
    /// Indicates whether the edit was applied or not.
    let applied: Bool
    /// An optional textual description for why the edit was not applied.
    /// Only used if `applied` is `false`.
    let failureReason: String?
    /// Depending on the client's failure handling strategy, `failedChange`
    /// might contain the index of the change that caused the failure.
    let failedChange: Int?

    init(
        applied: Bool,
        failureReason: String? = nil,
        failedChange: Int? = nil
    ) {
        self.applied = applied
        self.failureReason = failureReason
        self.failedChange = failedChange
    }
}
