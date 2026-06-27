//
//  DefinitionResult.swift
//  Calyx
//
//  LSP 3.18 DefinitionResult. See:
//  https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocument_definition
//
//  Result of `textDocument/definition` is:
//      Location | Location[] | LocationLink[] | null
//
//  The `null` case is handled at the JSON-RPC envelope layer (Optional<DefinitionResult>).
//  This enum models the non-null cases:
//      .single(Location), .array([Location]), .linkArray([LocationLink]).
//
//  Disambiguation:
//    - JSON array of objects with `targetUri` key -> .linkArray
//    - JSON array of objects with `uri` key      -> .array
//    - JSON single object with `uri` key         -> .single
//

import Foundation

/// Result of a `textDocument/definition` request (non-null cases).
enum DefinitionResult: Sendable, Codable, Equatable {
    case single(Location)
    case array([Location])
    case linkArray([LocationLink])

    init(from decoder: any Decoder) throws {
        // Try LocationLink[] first: required `targetUri` is disjoint from
        // Location.uri so a Location[] payload will fail to decode here.
        // BUT: an empty JSON array `[]` decodes successfully as BOTH
        // `[LocationLink]` and `[Location]`. Prefer the simpler `.array([])`
        // variant in that case so consumers can treat "no result" uniformly
        // without having to special-case both empty-array enum cases.
        if let links = try? [LocationLink](from: decoder) {
            if links.isEmpty {
                self = .array([])
            } else {
                self = .linkArray(links)
            }
            return
        }
        // Then a plain Location[].
        if let locs = try? [Location](from: decoder) {
            self = .array(locs)
            return
        }
        // Finally a single Location object.
        let loc = try Location(from: decoder)
        self = .single(loc)
    }

    func encode(to encoder: any Encoder) throws {
        switch self {
        case .single(let loc):
            try loc.encode(to: encoder)
        case .array(let arr):
            try arr.encode(to: encoder)
        case .linkArray(let arr):
            try arr.encode(to: encoder)
        }
    }
}
