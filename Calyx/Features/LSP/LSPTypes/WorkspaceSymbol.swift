//
//  WorkspaceSymbol.swift
//  Calyx
//
//  LSP 3.18 `workspace/symbol` request and response types. See:
//  https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#workspace_symbol
//
//  Four related types live here because they form a single closed family
//  and are only ever used together:
//    - WorkspaceSymbolParams
//    - WorkspaceSymbol
//    - WorkspaceSymbolLocation (union: Location | { uri })
//    - WorkspaceSymbolResult   (union: WorkspaceSymbol[] | SymbolInformation[])
//
//  `SymbolKind` and `SymbolTag` are reused from `DocumentSymbol.swift`.
//

import Foundation

// MARK: - WorkspaceSymbolParams

/// Parameters for the `workspace/symbol` request.
struct WorkspaceSymbolParams: Sendable, Codable, Equatable {
    /// A non-empty query string filtering symbols across the project. Empty
    /// `query` is allowed and conventionally returns "all" symbols (server
    /// dependent).
    let query: String
    let workDoneToken: ProgressToken?
    let partialResultToken: ProgressToken?

    init(
        query: String,
        workDoneToken: ProgressToken? = nil,
        partialResultToken: ProgressToken? = nil
    ) {
        self.query = query
        self.workDoneToken = workDoneToken
        self.partialResultToken = partialResultToken
    }
}

// MARK: - WorkspaceSymbolLocation
//
// `WorkspaceSymbol.location` is a union of either a full `Location`
// (`{uri, range}`) or a partial `{uri}` only — the latter lets servers defer
// computing ranges until `workspaceSymbol/resolve`. Disambiguation is by the
// presence of the `range` key.

/// The `location` field of a `WorkspaceSymbol`. Either a full `Location` or
/// just a `{ uri }` placeholder to be filled in by `workspaceSymbol/resolve`.
enum WorkspaceSymbolLocation: Sendable, Codable, Equatable {
    case full(Location)
    case uriOnly(uri: DocumentUri)

    private enum CodingKeys: String, CodingKey {
        case uri
        case range
    }

    init(from decoder: any Decoder) throws {
        let keyed = try decoder.container(keyedBy: CodingKeys.self)
        if keyed.contains(.range) {
            let loc = try Location(from: decoder)
            self = .full(loc)
            return
        }
        let uri = try keyed.decode(DocumentUri.self, forKey: .uri)
        self = .uriOnly(uri: uri)
    }

    func encode(to encoder: any Encoder) throws {
        switch self {
        case .full(let loc):
            try loc.encode(to: encoder)
        case .uriOnly(let uri):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(uri, forKey: .uri)
        }
    }
}

// MARK: - WorkspaceSymbol

/// A symbol representing a workspace-wide entity. Compared to
/// `SymbolInformation` this allows the `location` to be lazy and adds an
/// opaque `data` field for use with `workspaceSymbol/resolve`.
struct WorkspaceSymbol: Sendable, Codable, Equatable {
    /// The name of this symbol.
    let name: String
    /// The kind of this symbol.
    let kind: SymbolKind
    /// Tags for this symbol.
    let tags: [SymbolTag]?
    /// The name of the symbol containing this symbol.
    let containerName: String?
    /// The location of this symbol. Either a full `Location` or just a
    /// `{ uri }` placeholder.
    let location: WorkspaceSymbolLocation
    /// A data entry field passed through unchanged from the server to the
    /// client and back, useful for `workspaceSymbol/resolve`.
    let data: AnyCodable?

    init(
        name: String,
        kind: SymbolKind,
        tags: [SymbolTag]? = nil,
        containerName: String? = nil,
        location: WorkspaceSymbolLocation,
        data: AnyCodable? = nil
    ) {
        self.name = name
        self.kind = kind
        self.tags = tags
        self.containerName = containerName
        self.location = location
        self.data = data
    }
}

// MARK: - WorkspaceSymbolResult
//
// `workspace/symbol` returns
//     `WorkspaceSymbol[] | SymbolInformation[] | null`.
// The `null` case is modelled by `Optional<WorkspaceSymbolResult>` at the
// call site; this enum captures the two non-null shapes.
//
// The two shapes are wire-compatible when the location is a full
// `{uri, range}` Location (both can decode such an entry). We try
// `WorkspaceSymbol[]` first because it is the modern preferred form and
// because it is the only one that accepts the lazy `{uri}` location shape.
// Fall back to `SymbolInformation[]` only if the modern decode fails.

/// Result of `workspace/symbol` (non-null cases).
enum WorkspaceSymbolResult: Sendable, Codable, Equatable {
    case workspaceSymbols([WorkspaceSymbol])
    case symbolInformations([SymbolInformation])

    init(from decoder: any Decoder) throws {
        if let arr = try? [WorkspaceSymbol](from: decoder) {
            self = .workspaceSymbols(arr)
            return
        }
        let arr = try [SymbolInformation](from: decoder)
        self = .symbolInformations(arr)
    }

    func encode(to encoder: any Encoder) throws {
        switch self {
        case .workspaceSymbols(let arr):
            try arr.encode(to: encoder)
        case .symbolInformations(let arr):
            try arr.encode(to: encoder)
        }
    }
}
