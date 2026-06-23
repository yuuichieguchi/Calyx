//
//  Rename.swift
//  Calyx
//
//  LSP 3.18 textDocument/rename + textDocument/prepareRename parameter and
//  response types. See:
//  https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocument_rename
//  https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocument_prepareRename
//  https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#prepareRenameResult
//

import Foundation

// MARK: - RenameParams

/// Parameters for the `textDocument/rename` request.
struct RenameParams: Sendable, Codable, Equatable {
    let textDocument: TextDocumentIdentifier
    let position: Position
    /// The new name of the symbol. If the given name is not valid the
    /// request must return a `ResponseError` with an appropriate message.
    let newName: String
    let workDoneToken: ProgressToken?

    init(
        textDocument: TextDocumentIdentifier,
        position: Position,
        newName: String,
        workDoneToken: ProgressToken? = nil
    ) {
        self.textDocument = textDocument
        self.position = position
        self.newName = newName
        self.workDoneToken = workDoneToken
    }
}

// MARK: - PrepareRenameParams

/// Parameters for the `textDocument/prepareRename` request.
struct PrepareRenameParams: Sendable, Codable, Equatable {
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

// MARK: - PrepareRenameResult (union: Range | { range, placeholder } | { defaultBehavior })
//
// The result of `textDocument/prepareRename` is one of:
//   - a bare `Range` (no placeholder text supplied)
//   - `{ range: Range, placeholder: string }` (suggested initial text)
//   - `{ defaultBehavior: bool }` (delegate to the client's default behavior)
//
// Discriminator: `placeholder` key → placeholder variant; `defaultBehavior`
// key → defaultBehavior variant; otherwise decode as `LSPRange` (the bare
// Range form has `start`/`end` keys at the top level).

enum PrepareRenameResult: Sendable, Codable, Equatable {
    case range(LSPRange)
    case placeholder(range: LSPRange, placeholder: String)
    case defaultBehavior(Bool)

    private enum CodingKeys: String, CodingKey {
        case range
        case placeholder
        case defaultBehavior
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.placeholder) {
            let range = try container.decode(LSPRange.self, forKey: .range)
            let placeholder = try container.decode(String.self, forKey: .placeholder)
            self = .placeholder(range: range, placeholder: placeholder)
        } else if container.contains(.defaultBehavior) {
            let value = try container.decode(Bool.self, forKey: .defaultBehavior)
            self = .defaultBehavior(value)
        } else {
            // Bare `Range`: { "start": ..., "end": ... } — decode the entire
            // top-level object as an LSPRange.
            self = .range(try LSPRange(from: decoder))
        }
    }

    func encode(to encoder: any Encoder) throws {
        switch self {
        case .range(let r):
            try r.encode(to: encoder)
        case .placeholder(let r, let p):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(r, forKey: .range)
            try container.encode(p, forKey: .placeholder)
        case .defaultBehavior(let b):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(b, forKey: .defaultBehavior)
        }
    }
}
