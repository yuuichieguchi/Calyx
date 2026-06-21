//
//  CallHierarchy.swift
//  Calyx
//
//  LSP 3.18 call-hierarchy request and response types. See:
//  https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocument_prepareCallHierarchy
//  https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#callHierarchy_incomingCalls
//  https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#callHierarchy_outgoingCalls
//
//  Six related types live here because they form a single closed family
//  and are only ever used together:
//    - CallHierarchyPrepareParams
//    - CallHierarchyItem
//    - CallHierarchyIncomingCallsParams / CallHierarchyIncomingCall
//    - CallHierarchyOutgoingCallsParams / CallHierarchyOutgoingCall
//
//  `SymbolKind` and `SymbolTag` are reused from `DocumentSymbol.swift`.
//

import Foundation

// MARK: - CallHierarchyPrepareParams

/// Parameters for the `textDocument/prepareCallHierarchy` request.
struct CallHierarchyPrepareParams: Sendable, Codable, Equatable {
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

// MARK: - CallHierarchyItem

/// Represents a programming construct that can participate in a call
/// hierarchy (function, method, constructor, etc.). Returned by
/// `textDocument/prepareCallHierarchy` and consumed by
/// `callHierarchy/incomingCalls` / `callHierarchy/outgoingCalls`.
struct CallHierarchyItem: Sendable, Codable, Equatable {
    /// The name of this item.
    let name: String
    /// The kind of this item.
    let kind: SymbolKind
    /// Tags for this item.
    let tags: [SymbolTag]?
    /// More detail for this item, e.g. the signature of a function.
    let detail: String?
    /// The resource identifier of this item.
    let uri: DocumentUri
    /// The range enclosing this symbol not including leading/trailing
    /// whitespace but everything else, e.g. comments and code.
    let range: LSPRange
    /// The range that should be selected and revealed when this symbol is
    /// being picked, e.g. the name of a function. Must be contained by `range`.
    let selectionRange: LSPRange
    /// A data entry field preserved between a call-hierarchy prepare request
    /// and incoming/outgoing calls requests.
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

// MARK: - CallHierarchyIncomingCallsParams

/// Parameters for the `callHierarchy/incomingCalls` request.
struct CallHierarchyIncomingCallsParams: Sendable, Codable, Equatable {
    let item: CallHierarchyItem
    let workDoneToken: ProgressToken?
    let partialResultToken: ProgressToken?

    init(
        item: CallHierarchyItem,
        workDoneToken: ProgressToken? = nil,
        partialResultToken: ProgressToken? = nil
    ) {
        self.item = item
        self.workDoneToken = workDoneToken
        self.partialResultToken = partialResultToken
    }
}

// MARK: - CallHierarchyIncomingCall

/// Represents an incoming call, e.g. a caller of a method or constructor.
struct CallHierarchyIncomingCall: Sendable, Codable, Equatable {
    /// The item that makes the call.
    let from: CallHierarchyItem
    /// The ranges at which the calls appear. Relative to the caller, denoted
    /// by `from`.
    let fromRanges: [LSPRange]

    init(from: CallHierarchyItem, fromRanges: [LSPRange]) {
        self.from = from
        self.fromRanges = fromRanges
    }
}

// MARK: - CallHierarchyOutgoingCallsParams

/// Parameters for the `callHierarchy/outgoingCalls` request.
struct CallHierarchyOutgoingCallsParams: Sendable, Codable, Equatable {
    let item: CallHierarchyItem
    let workDoneToken: ProgressToken?
    let partialResultToken: ProgressToken?

    init(
        item: CallHierarchyItem,
        workDoneToken: ProgressToken? = nil,
        partialResultToken: ProgressToken? = nil
    ) {
        self.item = item
        self.workDoneToken = workDoneToken
        self.partialResultToken = partialResultToken
    }
}

// MARK: - CallHierarchyOutgoingCall

/// Represents an outgoing call, e.g. calls to methods or constructors made
/// from the item whose `outgoingCalls` were requested.
struct CallHierarchyOutgoingCall: Sendable, Codable, Equatable {
    /// The item that is called.
    let to: CallHierarchyItem
    /// The ranges at which this item is called. Relative to the caller (the
    /// item passed in the request), NOT to `to`.
    let fromRanges: [LSPRange]

    init(to: CallHierarchyItem, fromRanges: [LSPRange]) {
        self.to = to
        self.fromRanges = fromRanges
    }
}
