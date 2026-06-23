//
//  Moniker.swift
//  Calyx
//
//  LSP 3.18 textDocument/moniker request and response types. See:
//  https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocument_moniker
//  https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#uniquenessLevel
//  https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#monikerKind
//  https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#moniker
//
//  Four related types live here because they form a single closed family
//  and are only ever used together:
//    - MonikerParams
//    - UniquenessLevel
//    - MonikerKind
//    - Moniker
//

import Foundation

// MARK: - MonikerParams

/// Parameters for the `textDocument/moniker` request.
struct MonikerParams: Sendable, Codable, Equatable {
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

// MARK: - UniquenessLevel

/// Moniker uniqueness level to define scope of the moniker.
enum UniquenessLevel: String, Sendable, Codable, Equatable, Hashable {
    /// The moniker is only unique inside a document.
    case document
    /// The moniker is unique inside a project for which a dump got created.
    case project
    /// The moniker is unique inside the group to which a project belongs.
    case group
    /// The moniker is unique inside the moniker scheme.
    case scheme
    /// The moniker is globally unique.
    case global
}

// MARK: - MonikerKind

/// The moniker kind.
///
/// Swift reserved-word `import` is escaped with backticks at source level but
/// the raw value remains the plain string `"import"`, so JSON round-tripping
/// produces the spec-defined literals.
enum MonikerKind: String, Sendable, Codable, Equatable, Hashable {
    /// The moniker represent a symbol that is imported into a project.
    case `import`
    /// The moniker represents a symbol that is exported from a project.
    case export
    /// The moniker represents a symbol that is local to a project (e.g. a
    /// local variable of a function, a class not visible outside the project, ...).
    case local
}

// MARK: - Moniker

/// Moniker definition to match LSIF 0.5 moniker definition.
struct Moniker: Sendable, Codable, Equatable {
    /// The scheme of the moniker. For example tsc or .Net.
    let scheme: String
    /// The identifier of the moniker. The value is opaque in LSIF however
    /// schema owners are allowed to define the structure if they want.
    let identifier: String
    /// The scope in which the moniker is unique.
    let unique: UniquenessLevel
    /// The moniker kind if known.
    let kind: MonikerKind?

    init(
        scheme: String,
        identifier: String,
        unique: UniquenessLevel,
        kind: MonikerKind? = nil
    ) {
        self.scheme = scheme
        self.identifier = identifier
        self.unique = unique
        self.kind = kind
    }
}
