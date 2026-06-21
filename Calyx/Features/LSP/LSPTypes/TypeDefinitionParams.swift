//
//  TypeDefinitionParams.swift
//  Calyx
//
//  LSP 3.18 TypeDefinitionParams + TypeDefinitionResult. See:
//  https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocument_typeDefinition
//
//  Same wire shape as `DefinitionParams` / `DefinitionResult`, declared as
//  separate types so callers cannot accidentally cross requests.
//

import Foundation

// MARK: - TypeDefinitionParams

/// Parameters for the `textDocument/typeDefinition` request.
struct TypeDefinitionParams: Sendable, Codable, Equatable {
    let textDocument: TextDocumentIdentifier
    let position: Position
    let workDoneToken: ProgressToken?
    let partialResultToken: ProgressToken?

    init(
        textDocument: TextDocumentIdentifier,
        position: Position,
        workDoneToken: ProgressToken? = nil,
        partialResultToken: ProgressToken? = nil
    ) {
        self.textDocument = textDocument
        self.position = position
        self.workDoneToken = workDoneToken
        self.partialResultToken = partialResultToken
    }
}

// MARK: - TypeDefinitionResult

/// Result of a `textDocument/typeDefinition` request (non-null cases).
enum TypeDefinitionResult: Sendable, Codable, Equatable {
    case single(Location)
    case array([Location])
    case linkArray([LocationLink])

    init(from decoder: any Decoder) throws {
        if let links = try? [LocationLink](from: decoder) {
            self = .linkArray(links)
            return
        }
        if let locs = try? [Location](from: decoder) {
            self = .array(locs)
            return
        }
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
