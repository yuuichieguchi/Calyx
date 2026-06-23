//
//  DocumentSymbol.swift
//  Calyx
//
//  LSP 3.18 `textDocument/documentSymbol` request and response types. See:
//  https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocument_documentSymbol
//
//  Six related types live here because they form a single closed family
//  and are only ever used together:
//    - DocumentSymbolParams
//    - SymbolKind / SymbolTag
//    - DocumentSymbol  (hierarchical, recursive)
//    - SymbolInformation (legacy flat, deprecated since 3.17)
//    - DocumentSymbolResult (union: DocumentSymbol[] | SymbolInformation[])
//

import Foundation

// MARK: - SymbolKind

/// A symbol kind, used by both `DocumentSymbol` and `SymbolInformation`.
enum SymbolKind: Int, Sendable, Codable, Equatable, Hashable {
    case file = 1
    case module = 2
    case namespace = 3
    case package = 4
    case `class` = 5
    case method = 6
    case property = 7
    case field = 8
    case constructor = 9
    case `enum` = 10
    case interface = 11
    case function = 12
    case variable = 13
    case constant = 14
    case string = 15
    case number = 16
    case boolean = 17
    case array = 18
    case object = 19
    case key = 20
    case null = 21
    case enumMember = 22
    case `struct` = 23
    case event = 24
    case `operator` = 25
    case typeParameter = 26
}

// MARK: - SymbolTag

/// Symbol tags are extra annotations that tweak the rendering of a symbol.
enum SymbolTag: Int, Sendable, Codable, Equatable, Hashable {
    /// Render a symbol as obsolete, usually using a strike-out style.
    case deprecated = 1
}

// MARK: - DocumentSymbol

/// Represents programming constructs like variables, classes, interfaces,
/// etc. that appear in a document. Hierarchical: contains a `children`
/// array so consumers can build a tree.
struct DocumentSymbol: Sendable, Codable, Equatable {
    /// The name of this symbol.
    let name: String
    /// More detail for this symbol (e.g. the signature of a function).
    let detail: String?
    /// The kind of this symbol.
    let kind: SymbolKind
    /// Tags for this symbol.
    let tags: [SymbolTag]?
    /// Indicates if this symbol is deprecated. Use `tags` instead in 3.16+.
    let deprecated: Bool?
    /// The range enclosing this symbol not including leading/trailing
    /// whitespace but everything else, e.g. comments and code.
    let range: LSPRange
    /// The range that should be selected and revealed when this symbol is
    /// being picked, e.g. the name of a function. Must be contained by `range`.
    let selectionRange: LSPRange
    /// Children of this symbol, e.g. properties of a class.
    let children: [DocumentSymbol]?

    init(
        name: String,
        detail: String? = nil,
        kind: SymbolKind,
        tags: [SymbolTag]? = nil,
        deprecated: Bool? = nil,
        range: LSPRange,
        selectionRange: LSPRange,
        children: [DocumentSymbol]? = nil
    ) {
        self.name = name
        self.detail = detail
        self.kind = kind
        self.tags = tags
        self.deprecated = deprecated
        self.range = range
        self.selectionRange = selectionRange
        self.children = children
    }
}

// MARK: - SymbolInformation

/// Represents information about programming constructs like variables,
/// classes, interfaces, etc. Flat (no children). Deprecated since LSP 3.17
/// in favour of `DocumentSymbol` and `WorkspaceSymbol`, but still emitted by
/// some servers.
struct SymbolInformation: Sendable, Codable, Equatable {
    /// The name of this symbol.
    let name: String
    /// The kind of this symbol.
    let kind: SymbolKind
    /// Tags for this symbol.
    let tags: [SymbolTag]?
    /// Indicates if this symbol is deprecated. Use `tags` instead in 3.16+.
    let deprecated: Bool?
    /// The location of this symbol. The range used is the same as the range
    /// returned by `DocumentSymbol.range` (i.e. the full enclosing range).
    let location: Location
    /// The name of the symbol containing this symbol, e.g. the class
    /// containing a method.
    let containerName: String?

    init(
        name: String,
        kind: SymbolKind,
        tags: [SymbolTag]? = nil,
        deprecated: Bool? = nil,
        location: Location,
        containerName: String? = nil
    ) {
        self.name = name
        self.kind = kind
        self.tags = tags
        self.deprecated = deprecated
        self.location = location
        self.containerName = containerName
    }
}

// MARK: - DocumentSymbolParams

/// Parameters for the `textDocument/documentSymbol` request.
struct DocumentSymbolParams: Sendable, Codable, Equatable {
    let textDocument: TextDocumentIdentifier
    let workDoneToken: ProgressToken?
    let partialResultToken: ProgressToken?

    init(
        textDocument: TextDocumentIdentifier,
        workDoneToken: ProgressToken? = nil,
        partialResultToken: ProgressToken? = nil
    ) {
        self.textDocument = textDocument
        self.workDoneToken = workDoneToken
        self.partialResultToken = partialResultToken
    }
}

// MARK: - DocumentSymbolResult
//
// `textDocument/documentSymbol` returns
//     `DocumentSymbol[] | SymbolInformation[] | null`.
// The `null` case is modelled by `Optional<DocumentSymbolResult>` at the call
// site; this enum captures the two non-null shapes.
//
// Discrimination rule: `DocumentSymbol` has a required `selectionRange`,
// `SymbolInformation` has a required `location` and no `selectionRange`.
// Pragmatically we try the hierarchical form first; the flat form fails
// because it lacks `selectionRange`.

/// Result of `textDocument/documentSymbol` (non-null cases).
enum DocumentSymbolResult: Sendable, Codable, Equatable {
    case hierarchical([DocumentSymbol])
    case flat([SymbolInformation])

    init(from decoder: any Decoder) throws {
        if let arr = try? [DocumentSymbol](from: decoder) {
            self = .hierarchical(arr)
            return
        }
        let arr = try [SymbolInformation](from: decoder)
        self = .flat(arr)
    }

    func encode(to encoder: any Encoder) throws {
        switch self {
        case .hierarchical(let arr):
            try arr.encode(to: encoder)
        case .flat(let arr):
            try arr.encode(to: encoder)
        }
    }
}
