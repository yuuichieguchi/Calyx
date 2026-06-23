//
//  DocumentChange.swift
//  Calyx
//
//  LSP 3.18 DocumentChange union. See:
//  https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#workspaceEdit
//
//  In the spec the `documentChanges` array of a `WorkspaceEdit` is the union
//      (TextDocumentEdit | CreateFile | RenameFile | DeleteFile)[]
//  discriminated by the `kind` key:
//      "create" → CreateFile
//      "rename" → RenameFile
//      "delete" → DeleteFile
//      (absent) → TextDocumentEdit
//  We peek `kind` during decoding to dispatch to the right concrete type.
//

import Foundation

/// One element of `WorkspaceEdit.documentChanges`.
enum DocumentChange: Sendable, Codable, Equatable, Hashable {
    case textDocumentEdit(TextDocumentEdit)
    case create(CreateFile)
    case rename(RenameFile)
    case delete(DeleteFile)

    private enum DiscriminatorKey: String, CodingKey {
        case kind
    }

    init(from decoder: any Decoder) throws {
        let probe = try decoder.container(keyedBy: DiscriminatorKey.self)
        let kind = try probe.decodeIfPresent(String.self, forKey: .kind)
        switch kind {
        case "create":
            self = .create(try CreateFile(from: decoder))
        case "rename":
            self = .rename(try RenameFile(from: decoder))
        case "delete":
            self = .delete(try DeleteFile(from: decoder))
        case nil:
            self = .textDocumentEdit(try TextDocumentEdit(from: decoder))
        case .some(let unknown):
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: probe,
                debugDescription: "Unknown DocumentChange kind '\(unknown)'."
            )
        }
    }

    func encode(to encoder: any Encoder) throws {
        switch self {
        case .textDocumentEdit(let edit):
            try edit.encode(to: encoder)
        case .create(let op):
            try op.encode(to: encoder)
        case .rename(let op):
            try op.encode(to: encoder)
        case .delete(let op):
            try op.encode(to: encoder)
        }
    }
}
