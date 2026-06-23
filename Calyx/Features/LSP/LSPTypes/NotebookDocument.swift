//
//  NotebookDocument.swift
//  Calyx
//
//  LSP 3.18 notebook-document synchronisation types. See:
//  https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#notebookDocument
//
//  Covers the structural payloads used by the three notebook-document
//  notifications shipped through `MCPLSPBridge`:
//
//      notebookDocument/didOpen    -> DidOpenNotebookDocumentParams
//      notebookDocument/didChange  -> DidChangeNotebookDocumentParams
//      notebookDocument/didClose   -> DidCloseNotebookDocumentParams
//
//  Optional fields use Swift `Optional` so the synthesized `Codable`
//  conformance encodes via `encodeIfPresent` — i.e. `nil` values drop out
//  of the encoded JSON entirely, preserving the spec's wire shape on a
//  decode-then-encode round-trip.
//

import Foundation

// MARK: - NotebookDocumentIdentifier
//
// Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#notebookDocumentIdentifier

/// A literal identifier (URI only) for a notebook document. Used by the
/// `notebookDocument/didClose` notification.
struct NotebookDocumentIdentifier: Sendable, Codable, Equatable {
    let uri: URI
}

// MARK: - VersionedNotebookDocumentIdentifier
//
// Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#versionedNotebookDocumentIdentifier

/// A versioned identifier for a notebook document. Used by the
/// `notebookDocument/didChange` notification so the server can detect
/// out-of-order updates against the same notebook URI.
struct VersionedNotebookDocumentIdentifier: Sendable, Codable, Equatable {
    let version: Int
    let uri: URI
}

// MARK: - ExecutionSummary
//
// Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#executionSummary

/// Per-cell execution metadata. `success` is optional — it is only
/// meaningful once the cell has been executed.
struct ExecutionSummary: Sendable, Codable, Equatable {
    let executionOrder: Int
    let success: Bool?
}

// MARK: - NotebookCellKind
//
// Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#notebookCellKind

/// Notebook-cell kind enum. Encoded as an integer on the wire to match
/// the LSP specification (`1` = markup, `2` = code).
enum NotebookCellKind: Int, Sendable, Codable, Equatable {
    case markup = 1
    case code = 2
}

// MARK: - NotebookCell
//
// Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#notebookCell

/// A single cell inside a `NotebookDocument`. `metadata` and
/// `executionSummary` are optional and must drop out of the encoded
/// payload when absent.
struct NotebookCell: Sendable, Codable, Equatable {
    let kind: NotebookCellKind
    let document: URI
    let metadata: AnyCodable?
    let executionSummary: ExecutionSummary?
}

// MARK: - NotebookDocument
//
// Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#notebookDocument

/// A notebook document being synchronised with the language server. The
/// `cells` list mirrors the order surfaced to the user. `metadata` is
/// optional and is dropped on encode when nil.
struct NotebookDocument: Sendable, Codable, Equatable {
    let uri: URI
    let notebookType: String
    let version: Int
    let metadata: AnyCodable?
    let cells: [NotebookCell]
}

// MARK: - DidOpenNotebookDocumentParams
//
// Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#notebookDocument_didOpen

/// Payload of the `notebookDocument/didOpen` notification. Carries the
/// full notebook plus a separate `TextDocumentItem` for each cell that
/// hosts code (so the standard text-document plumbing can address cells
/// uniformly).
struct DidOpenNotebookDocumentParams: Sendable, Codable, Equatable {
    let notebookDocument: NotebookDocument
    let cellTextDocuments: [TextDocumentItem]
}

// MARK: - NotebookCellArrayChange
//
// Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#notebookCellArrayChange

/// A splice into the `cells` array of a notebook. `cells` is optional —
/// a pure-delete change omits it.
struct NotebookCellArrayChange: Sendable, Codable, Equatable {
    let start: Int
    let deleteCount: Int
    let cells: [NotebookCell]?
}

// MARK: - NotebookDocumentChangeEventCellsStructure
//
// Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#notebookDocumentChangeEvent

/// Structural changes to the cell list (insertions / deletions). The
/// `didOpen` / `didClose` lists carry the matching text-document
/// open/close events for any cells whose text-document identity changed.
struct NotebookDocumentChangeEventCellsStructure: Sendable, Codable, Equatable {
    let array: NotebookCellArrayChange
    let didOpen: [TextDocumentItem]?
    let didClose: [TextDocumentIdentifier]?
}

// MARK: - NotebookDocumentChangeEventCellsTextContent

/// A text-content change inside one cell's `TextDocumentItem`. Reuses
/// the standard `TextDocumentContentChangeEvent` so cell-content edits
/// follow the same wire shape as `textDocument/didChange` edits.
struct NotebookDocumentChangeEventCellsTextContent: Sendable, Codable, Equatable {
    let document: VersionedTextDocumentIdentifier
    let changes: [TextDocumentContentChangeEvent]
}

// MARK: - NotebookDocumentChangeEventCells

/// The three independent cell-level change arms (structure / metadata /
/// text-content). All three are optional so a change event can describe
/// just one slice at a time.
struct NotebookDocumentChangeEventCells: Sendable, Codable, Equatable {
    let structure: NotebookDocumentChangeEventCellsStructure?
    let data: [NotebookCell]?
    let textContent: [NotebookDocumentChangeEventCellsTextContent]?
}

// MARK: - NotebookDocumentChangeEvent

/// One notebook-level change. Either notebook-wide `metadata` or
/// per-cell `cells` changes (or both). Both fields are optional and drop
/// out of the encoded payload when nil.
struct NotebookDocumentChangeEvent: Sendable, Codable, Equatable {
    let metadata: AnyCodable?
    let cells: NotebookDocumentChangeEventCells?
}

// MARK: - DidChangeNotebookDocumentParams
//
// Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#notebookDocument_didChange

/// Payload of the `notebookDocument/didChange` notification.
struct DidChangeNotebookDocumentParams: Sendable, Codable, Equatable {
    let notebookDocument: VersionedNotebookDocumentIdentifier
    let change: NotebookDocumentChangeEvent
}

// MARK: - DidCloseNotebookDocumentParams
//
// Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#notebookDocument_didClose

/// Payload of the `notebookDocument/didClose` notification. Carries the
/// matching `TextDocumentIdentifier` for every cell so the server can
/// clean up the per-cell text-document state.
struct DidCloseNotebookDocumentParams: Sendable, Codable, Equatable {
    let notebookDocument: NotebookDocumentIdentifier
    let cellTextDocuments: [TextDocumentIdentifier]
}
