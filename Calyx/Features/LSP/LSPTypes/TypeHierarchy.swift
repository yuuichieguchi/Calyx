//
//  TypeHierarchy.swift
//  Calyx
//
//  LSP 3.18 type-hierarchy request and response types. See:
//  https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocument_prepareTypeHierarchy
//  https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#typeHierarchy_supertypes
//  https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#typeHierarchy_subtypes
//
//  Four related types live here because they form a single closed family
//  and are only ever used together:
//    - TypeHierarchyPrepareParams
//    - TypeHierarchyItem
//    - TypeHierarchySupertypesParams
//    - TypeHierarchySubtypesParams
//
//  `SymbolKind` and `SymbolTag` are reused from `DocumentSymbol.swift`.
//

import Foundation

// MARK: - TypeHierarchyPrepareParams

/// Parameters for the `textDocument/prepareTypeHierarchy` request.
struct TypeHierarchyPrepareParams: Sendable, Codable, Equatable {
    let textDocument: TextDocumentIdentifier
    let position: Position
    let workDoneToken: ProgressToken?

    init(
        textDocument: TextDocumentIdentifier,
        position: Position,
        workDoneToken: ProgressToken? = nil
    ) {
        self.textDocument = textDocument
        self.position = position
        self.workDoneToken = workDoneToken
    }
}

// MARK: - TypeHierarchyItem

/// Represents a programming construct that can participate in a type
/// hierarchy (class, interface, struct, etc.). Returned by
/// `textDocument/prepareTypeHierarchy` and consumed by
/// `typeHierarchy/supertypes` / `typeHierarchy/subtypes`.
struct TypeHierarchyItem: Sendable, Codable, Equatable {
    /// The name of this item.
    let name: String
    /// The kind of this item.
    let kind: SymbolKind
    /// Tags for this item.
    let tags: [SymbolTag]?
    /// More detail for this item, e.g. the signature of a class.
    let detail: String?
    /// The resource identifier of this item.
    let uri: DocumentUri
    /// The range enclosing this symbol not including leading/trailing
    /// whitespace but everything else, e.g. comments and code.
    let range: LSPRange
    /// The range that should be selected and revealed when this symbol is
    /// being picked, e.g. the name of a class. Must be contained by `range`.
    let selectionRange: LSPRange
    /// A data entry field preserved between a type-hierarchy prepare request
    /// and supertypes/subtypes requests.
    let data: AnyCodable?

    init(
        name: String,
        kind: SymbolKind,
        tags: [SymbolTag]? = nil,
        detail: String? = nil,
        uri: DocumentUri,
        range: LSPRange,
        selectionRange: LSPRange,
        data: AnyCodable? = nil
    ) {
        self.name = name
        self.kind = kind
        self.tags = tags
        self.detail = detail
        self.uri = uri
        self.range = range
        self.selectionRange = selectionRange
        self.data = data
    }
}

// MARK: - TypeHierarchySupertypesParams

/// Parameters for the `typeHierarchy/supertypes` request.
struct TypeHierarchySupertypesParams: Sendable, Codable, Equatable {
    let item: TypeHierarchyItem
    let workDoneToken: ProgressToken?
    let partialResultToken: ProgressToken?

    init(
        item: TypeHierarchyItem,
        workDoneToken: ProgressToken? = nil,
        partialResultToken: ProgressToken? = nil
    ) {
        self.item = item
        self.workDoneToken = workDoneToken
        self.partialResultToken = partialResultToken
    }
}

// MARK: - TypeHierarchySubtypesParams

/// Parameters for the `typeHierarchy/subtypes` request.
struct TypeHierarchySubtypesParams: Sendable, Codable, Equatable {
    let item: TypeHierarchyItem
    let workDoneToken: ProgressToken?
    let partialResultToken: ProgressToken?

    init(
        item: TypeHierarchyItem,
        workDoneToken: ProgressToken? = nil,
        partialResultToken: ProgressToken? = nil
    ) {
        self.item = item
        self.workDoneToken = workDoneToken
        self.partialResultToken = partialResultToken
    }
}
