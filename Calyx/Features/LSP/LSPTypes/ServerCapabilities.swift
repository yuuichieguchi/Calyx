//
//  ServerCapabilities.swift
//  Calyx
//
//  LSP 3.18 ServerCapabilities — outer shell. See:
//  https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#serverCapabilities
//
//  Only `positionEncoding` is typed (`PositionEncodingKind?`); every other
//  provider / capability field is `AnyCodable?` in this batch. Many of these
//  fields have `boolean | Options` unions that will be typed individually
//  in later batches (B4+). Keeping them as `AnyCodable?` here lets arbitrary
//  server-advertised capabilities round-trip losslessly.
//

import Foundation

/// Outer shell of the LSP `ServerCapabilities` object.
struct ServerCapabilities: Sendable, Codable, Equatable {

    // MARK: Typed in this batch

    /// The position encoding the server picked from the encodings offered
    /// by the client via `general.positionEncodings`. Default is `utf-16`.
    let positionEncoding: PositionEncodingKind?

    // MARK: Provider fields (still AnyCodable in this batch)

    /// Defines how text documents are synced.
    let textDocumentSync: AnyCodable?
    /// Defines how notebook documents are synced.
    let notebookDocumentSync: AnyCodable?
    /// The server provides completion support.
    let completionProvider: AnyCodable?
    /// The server provides hover support.
    let hoverProvider: AnyCodable?
    /// The server provides signature help support.
    let signatureHelpProvider: AnyCodable?
    /// The server provides go to declaration support.
    let declarationProvider: AnyCodable?
    /// The server provides go to definition support.
    let definitionProvider: AnyCodable?
    /// The server provides go to type definition support.
    let typeDefinitionProvider: AnyCodable?
    /// The server provides go to implementation support.
    let implementationProvider: AnyCodable?
    /// The server provides find references support.
    let referencesProvider: AnyCodable?
    /// The server provides document highlight support.
    let documentHighlightProvider: AnyCodable?
    /// The server provides document symbol support.
    let documentSymbolProvider: AnyCodable?
    /// The server provides code actions.
    let codeActionProvider: AnyCodable?
    /// The server provides code lens.
    let codeLensProvider: AnyCodable?
    /// The server provides document link support.
    let documentLinkProvider: AnyCodable?
    /// The server provides color provider support.
    let colorProvider: AnyCodable?
    /// The server provides workspace symbol support.
    let workspaceSymbolProvider: AnyCodable?
    /// The server provides document formatting.
    let documentFormattingProvider: AnyCodable?
    /// The server provides document range formatting.
    let documentRangeFormattingProvider: AnyCodable?
    /// The server provides document formatting on typing.
    let documentOnTypeFormattingProvider: AnyCodable?
    /// The server provides rename support.
    let renameProvider: AnyCodable?
    /// The server provides folding-range support.
    let foldingRangeProvider: AnyCodable?
    /// The server provides selection-range support.
    let selectionRangeProvider: AnyCodable?
    /// The server provides execute-command support.
    let executeCommandProvider: AnyCodable?
    /// The server provides call hierarchy support (LSP 3.16+).
    let callHierarchyProvider: AnyCodable?
    /// The server provides linked editing range support (LSP 3.16+).
    let linkedEditingRangeProvider: AnyCodable?
    /// The server provides semantic tokens support (LSP 3.16+).
    let semanticTokensProvider: AnyCodable?
    /// The server provides moniker support (LSP 3.16+).
    let monikerProvider: AnyCodable?
    /// The server provides type hierarchy support (LSP 3.17+).
    let typeHierarchyProvider: AnyCodable?
    /// The server provides inline values (LSP 3.17+).
    let inlineValueProvider: AnyCodable?
    /// The server provides inlay hints (LSP 3.17+).
    let inlayHintProvider: AnyCodable?
    /// The server has support for pull-model diagnostics (LSP 3.17+).
    let diagnosticProvider: AnyCodable?
    /// Workspace-specific server capabilities.
    let workspace: AnyCodable?
    /// Experimental server capabilities. Clients must treat this as opaque.
    let experimental: AnyCodable?

    init(
        positionEncoding: PositionEncodingKind? = nil,
        textDocumentSync: AnyCodable? = nil,
        notebookDocumentSync: AnyCodable? = nil,
        completionProvider: AnyCodable? = nil,
        hoverProvider: AnyCodable? = nil,
        signatureHelpProvider: AnyCodable? = nil,
        declarationProvider: AnyCodable? = nil,
        definitionProvider: AnyCodable? = nil,
        typeDefinitionProvider: AnyCodable? = nil,
        implementationProvider: AnyCodable? = nil,
        referencesProvider: AnyCodable? = nil,
        documentHighlightProvider: AnyCodable? = nil,
        documentSymbolProvider: AnyCodable? = nil,
        codeActionProvider: AnyCodable? = nil,
        codeLensProvider: AnyCodable? = nil,
        documentLinkProvider: AnyCodable? = nil,
        colorProvider: AnyCodable? = nil,
        workspaceSymbolProvider: AnyCodable? = nil,
        documentFormattingProvider: AnyCodable? = nil,
        documentRangeFormattingProvider: AnyCodable? = nil,
        documentOnTypeFormattingProvider: AnyCodable? = nil,
        renameProvider: AnyCodable? = nil,
        foldingRangeProvider: AnyCodable? = nil,
        selectionRangeProvider: AnyCodable? = nil,
        executeCommandProvider: AnyCodable? = nil,
        callHierarchyProvider: AnyCodable? = nil,
        linkedEditingRangeProvider: AnyCodable? = nil,
        semanticTokensProvider: AnyCodable? = nil,
        monikerProvider: AnyCodable? = nil,
        typeHierarchyProvider: AnyCodable? = nil,
        inlineValueProvider: AnyCodable? = nil,
        inlayHintProvider: AnyCodable? = nil,
        diagnosticProvider: AnyCodable? = nil,
        workspace: AnyCodable? = nil,
        experimental: AnyCodable? = nil
    ) {
        self.positionEncoding = positionEncoding
        self.textDocumentSync = textDocumentSync
        self.notebookDocumentSync = notebookDocumentSync
        self.completionProvider = completionProvider
        self.hoverProvider = hoverProvider
        self.signatureHelpProvider = signatureHelpProvider
        self.declarationProvider = declarationProvider
        self.definitionProvider = definitionProvider
        self.typeDefinitionProvider = typeDefinitionProvider
        self.implementationProvider = implementationProvider
        self.referencesProvider = referencesProvider
        self.documentHighlightProvider = documentHighlightProvider
        self.documentSymbolProvider = documentSymbolProvider
        self.codeActionProvider = codeActionProvider
        self.codeLensProvider = codeLensProvider
        self.documentLinkProvider = documentLinkProvider
        self.colorProvider = colorProvider
        self.workspaceSymbolProvider = workspaceSymbolProvider
        self.documentFormattingProvider = documentFormattingProvider
        self.documentRangeFormattingProvider = documentRangeFormattingProvider
        self.documentOnTypeFormattingProvider = documentOnTypeFormattingProvider
        self.renameProvider = renameProvider
        self.foldingRangeProvider = foldingRangeProvider
        self.selectionRangeProvider = selectionRangeProvider
        self.executeCommandProvider = executeCommandProvider
        self.callHierarchyProvider = callHierarchyProvider
        self.linkedEditingRangeProvider = linkedEditingRangeProvider
        self.semanticTokensProvider = semanticTokensProvider
        self.monikerProvider = monikerProvider
        self.typeHierarchyProvider = typeHierarchyProvider
        self.inlineValueProvider = inlineValueProvider
        self.inlayHintProvider = inlayHintProvider
        self.diagnosticProvider = diagnosticProvider
        self.workspace = workspace
        self.experimental = experimental
    }
}
