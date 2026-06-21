//
//  ProgressToken.swift
//  Calyx
//
//  LSP 3.18 ProgressToken type. See:
//  https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#progress
//

import Foundation

/// A token used to report progress on a long-running operation. Either an
/// integer or a string per spec.
enum ProgressToken: Sendable, Codable, Equatable, Hashable {
    case int(Int)
    case string(String)

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let i = try? container.decode(Int.self) {
            self = .int(i)
            return
        }
        if let s = try? container.decode(String.self) {
            self = .string(s)
            return
        }
        throw DecodingError.dataCorrupted(.init(
            codingPath: decoder.codingPath,
            debugDescription: "ProgressToken must be Int or String."
        ))
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .int(let i):
            try container.encode(i)
        case .string(let s):
            try container.encode(s)
        }
    }
}
