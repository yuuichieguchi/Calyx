//
//  ChangeAnnotation.swift
//  Calyx
//
//  LSP 3.18 ChangeAnnotation type. See:
//  https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#changeAnnotation
//

import Foundation

/// Additional information that describes document changes within a
/// `WorkspaceEdit`. Allows clients to render changes with a confirmation UI.
struct ChangeAnnotation: Sendable, Codable, Equatable, Hashable {
    /// A human-readable string describing the actual change.
    let label: String
    /// Whether the user needs to confirm the change before applying it.
    let needsConfirmation: Bool?
    /// A human-readable string which is rendered less prominent in the UI.
    let description: String?

    init(label: String, needsConfirmation: Bool? = nil, description: String? = nil) {
        self.label = label
        self.needsConfirmation = needsConfirmation
        self.description = description
    }
}
