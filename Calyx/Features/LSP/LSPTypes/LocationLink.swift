//
//  LocationLink.swift
//  Calyx
//
//  LSP 3.18 LocationLink type. See:
//  https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#locationLink
//

import Foundation

/// Represents a link between a source and a target location. Returned by
/// language servers from requests such as `textDocument/definition` when the
/// client advertises `linkSupport`.
struct LocationLink: Sendable, Codable, Equatable, Hashable {
    /// Span of the origin of this link. Used as the underlined span for mouse
    /// interaction. Defaults to the word range at the mouse position when nil.
    let originSelectionRange: LSPRange?
    /// The target resource identifier of this link.
    let targetUri: DocumentUri
    /// The full target range of this link.
    let targetRange: LSPRange
    /// The span that should be revealed when this link is being followed.
    /// Must be contained by `targetRange`.
    let targetSelectionRange: LSPRange

    init(
        originSelectionRange: LSPRange? = nil,
        targetUri: DocumentUri,
        targetRange: LSPRange,
        targetSelectionRange: LSPRange
    ) {
        self.originSelectionRange = originSelectionRange
        self.targetUri = targetUri
        self.targetRange = targetRange
        self.targetSelectionRange = targetSelectionRange
    }
}
