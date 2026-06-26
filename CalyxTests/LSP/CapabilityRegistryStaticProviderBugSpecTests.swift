//
//  CapabilityRegistryStaticProviderBugSpecTests.swift
//  CalyxTests
//
//  Regression test covering the frozen-list gap in
//  `CapabilityRegistry.staticProvider(_:for:)`. The current implementation
//  is a hardcoded `switch` over ~30 LSP method strings and silently misses
//  a large swathe of the LSP 3.18 surface that the bridge already
//  advertises, including:
//
//    - `textDocument/publishDiagnostics`
//    - `notebookDocument/didOpen` / `didChange` / `didClose`
//    - `workspace/willCreateFiles` / `willRenameFiles` / `willDeleteFiles`
//      / `didCreateFiles` / `didRenameFiles` / `didDeleteFiles`
//    - `textDocument/prepareRename` (under `renameProvider.prepareProvider`)
//    - `callHierarchy/incomingCalls` / `outgoingCalls` (under
//      `callHierarchyProvider`)
//    - `typeHierarchy/supertypes` / `subtypes` (under
//      `typeHierarchyProvider`)
//    - `codeAction/resolve`, `codeLens/resolve`, `completionItem/resolve`,
//      `inlayHint/resolve`, `documentLink/resolve`,
//      `workspaceSymbol/resolve`
//    - `textDocument/colorPresentation`
//
//  Because `staticProvider` falls through to `nil` for these methods,
//  `isCapable(method:)` returns `false` even when the server explicitly
//  advertises the relevant provider in its `ServerCapabilities`. The
//  dispatcher therefore refuses to route methods the server can serve.
//
//  This test MUST FAIL against the current implementation (Red phase).
//  After the fix extends `staticProvider` to cover the LSP 3.18 surface
//  it will pass.
//
//  Spec references:
//    - ServerCapabilities (LSP 3.18):
//      https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#serverCapabilities
//    - RenameOptions.prepareProvider, CompletionOptions.resolveProvider,
//      CodeActionOptions.resolveProvider, CodeLensOptions.resolveProvider,
//      DocumentLinkOptions.resolveProvider,
//      WorkspaceSymbolOptions.resolveProvider,
//      InlayHintOptions.resolveProvider — all live as sub-flags inside the
//      same provider slot.
//

import XCTest
@testable import Calyx

@MainActor
final class CapabilityRegistryStaticProviderBugSpecTests: XCTestCase {

    // MARK: - Helpers

    private func makeRegistry() -> CapabilityRegistry {
        return CapabilityRegistry()
    }

    /// A `ServerCapabilities` value that explicitly advertises every
    /// provider slot relevant to the missing-method list. The provider
    /// values are either `true` (boolean form) or a small options
    /// dictionary that carries a sub-resolver flag (`prepareProvider`,
    /// `resolveProvider`) so the same slot can answer both the parent
    /// method and the resolve-variant method.
    private func fullyAdvertisedCapabilities() -> ServerCapabilities {
        // Argument order MUST match the ServerCapabilities init signature
        // (Swift enforces external-argument order on positional+keyword
        // init calls). Layout in the source: notebookDocumentSync,
        // completionProvider, ..., codeActionProvider, codeLensProvider,
        // documentLinkProvider, colorProvider, workspaceSymbolProvider,
        // ..., renameProvider, ..., callHierarchyProvider, ...,
        // typeHierarchyProvider, ..., inlayHintProvider,
        // diagnosticProvider, workspace, experimental.
        return ServerCapabilities(
            // Notebook docs: a notebookDocumentSync value of any shape
            // means the server accepts notebook document lifecycle
            // notifications.
            notebookDocumentSync: AnyCodable(["notebookSelector": [["notebook": "*"]]]),
            // Completion + resolve.
            completionProvider: AnyCodable(["resolveProvider": true]),
            // Code action + resolve.
            codeActionProvider: AnyCodable(["resolveProvider": true]),
            // Code lens + resolve.
            codeLensProvider: AnyCodable(["resolveProvider": true]),
            // Document link + resolve.
            documentLinkProvider: AnyCodable(["resolveProvider": true]),
            // Color provider also serves textDocument/colorPresentation
            // (LSP spec keeps both under the same slot).
            colorProvider: AnyCodable(true),
            // Workspace symbol + resolve.
            workspaceSymbolProvider: AnyCodable(["resolveProvider": true]),
            // Rename + prepareRename.
            renameProvider: AnyCodable(["prepareProvider": true]),
            // Call hierarchy: prepare + incomingCalls + outgoingCalls all
            // sit under callHierarchyProvider.
            callHierarchyProvider: AnyCodable(true),
            // Type hierarchy: prepare + supertypes + subtypes all sit
            // under typeHierarchyProvider.
            typeHierarchyProvider: AnyCodable(true),
            // Inlay hint + resolve.
            inlayHintProvider: AnyCodable(["resolveProvider": true]),
            // Pull-model diagnostics. publishDiagnostics is push-model and
            // the LSP spec does not put it under a provider slot, but the
            // bridge treats diagnosticProvider as the capability gate for
            // both directions.
            diagnosticProvider: AnyCodable([
                "interFileDependencies": false,
                "workspaceDiagnostics": false
            ]),
            // workspace.fileOperations carries the will*/did* file
            // notification gates. The exact key shape is opaque to the
            // registry; advertising a non-empty `workspace` object is
            // enough for the bridge to treat file-operation methods as
            // capable.
            workspace: AnyCodable([
                "fileOperations": [
                    "willCreate": ["filters": []],
                    "willRename": ["filters": []],
                    "willDelete": ["filters": []],
                    "didCreate": ["filters": []],
                    "didRename": ["filters": []],
                    "didDelete": ["filters": []]
                ]
            ])
        )
    }

    // ====================================================================
    // MARK: - LSP 3.18 surface coverage
    // ====================================================================

    /// Every method listed in the bug spec must be reported as capable
    /// when the corresponding provider slot is advertised. The current
    /// frozen-list `switch` in `staticProvider(_:for:)` returns `nil` for
    /// every one of these, so `isCapable(method:)` falls through to the
    /// dynamic-registration check and (since nothing is dynamically
    /// registered) returns `false`. That mismatch is the bug.
    func test_staticProvider_coversLSP3_18_surface() async {
        let registry = makeRegistry()
        await registry.setStaticCapabilities(fullyAdvertisedCapabilities())

        let methodsExpectedCapable: [String] = [
            // Push-model diagnostics — server side notification.
            "textDocument/publishDiagnostics",

            // Notebook document lifecycle.
            "notebookDocument/didOpen",
            "notebookDocument/didChange",
            "notebookDocument/didClose",

            // Workspace file-operation will-/did- notifications.
            "workspace/willCreateFiles",
            "workspace/willRenameFiles",
            "workspace/willDeleteFiles",
            "workspace/didCreateFiles",
            "workspace/didRenameFiles",
            "workspace/didDeleteFiles",

            // Prepare-rename lives under renameProvider.prepareProvider.
            "textDocument/prepareRename",

            // Call hierarchy follow-up methods sit under
            // callHierarchyProvider, not under their own slots.
            "callHierarchy/incomingCalls",
            "callHierarchy/outgoingCalls",

            // Type hierarchy follow-up methods sit under
            // typeHierarchyProvider.
            "typeHierarchy/supertypes",
            "typeHierarchy/subtypes",

            // Resolve-variant methods sit under the parent provider slot
            // via the `resolveProvider` sub-flag.
            "codeAction/resolve",
            "codeLens/resolve",
            "completionItem/resolve",
            "inlayHint/resolve",
            "documentLink/resolve",
            "workspaceSymbol/resolve",

            // Color presentation shares the colorProvider slot with
            // textDocument/documentColor.
            "textDocument/colorPresentation"
        ]

        for method in methodsExpectedCapable {
            let capable = await registry.isCapable(method: method)
            XCTAssertTrue(
                capable,
                "staticProvider must map '\(method)' to its ServerCapabilities slot; current frozen-list switch returns nil for this method, causing isCapable to return false despite the server advertising the relevant provider"
            )
        }
    }
}
