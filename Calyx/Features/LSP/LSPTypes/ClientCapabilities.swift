//
//  ClientCapabilities.swift
//  Calyx
//
//  LSP 3.18 ClientCapabilities — outer shell only. See:
//  https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#clientCapabilities
//
//  This is the top-level container of all client capability declarations.
//  Each sub-tree (workspace, textDocument, notebookDocument, window, general)
//  has a rich nested schema that will be modelled in subsequent batches
//  (B2 / B3). For now they are typed as `AnyCodable?` so that arbitrary
//  capability JSON round-trips losslessly through `initialize`.
//

import Foundation

/// Outer shell of the LSP `ClientCapabilities` object. Sub-trees are typed
/// as `AnyCodable?` placeholders pending fine-grained modelling.
struct ClientCapabilities: Sendable, Codable, Equatable {
    /// Workspace-specific client capabilities.
    let workspace: AnyCodable?
    /// Text-document-specific client capabilities.
    let textDocument: AnyCodable?
    /// Notebook-document-specific client capabilities (LSP 3.17+).
    let notebookDocument: AnyCodable?
    /// Window-specific client capabilities.
    let window: AnyCodable?
    /// General client capabilities (LSP 3.16+).
    let general: AnyCodable?
    /// Experimental client capabilities. Servers must treat this as opaque.
    let experimental: AnyCodable?

    init(
        workspace: AnyCodable? = nil,
        textDocument: AnyCodable? = nil,
        notebookDocument: AnyCodable? = nil,
        window: AnyCodable? = nil,
        general: AnyCodable? = nil,
        experimental: AnyCodable? = nil
    ) {
        self.workspace = workspace
        self.textDocument = textDocument
        self.notebookDocument = notebookDocument
        self.window = window
        self.general = general
        self.experimental = experimental
    }
}
