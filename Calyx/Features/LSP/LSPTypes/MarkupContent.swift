//
//  MarkupContent.swift
//  Calyx
//
//  LSP 3.18 MarkupKind / MarkupContent / MarkedString. See:
//  https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#markupContent
//

import Foundation

// MARK: - MarkupKind

/// Describes the content type that a client supports in various result
/// literals like `Hover`, `ParameterInfo`, `CompletionItem`.
enum MarkupKind: String, Sendable, Codable, Equatable, Hashable {
    case plaintext
    case markdown

    init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let value = MarkupKind(rawValue: raw) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Unknown MarkupKind raw value: \(raw)"
            ))
        }
        self = value
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(self.rawValue)
    }
}

// MARK: - MarkupContent

/// A `MarkupContent` literal represents a string value which content is
/// interpreted based on its `kind` flag.
struct MarkupContent: Sendable, Codable, Equatable, Hashable {
    let kind: MarkupKind
    let value: String

    init(kind: MarkupKind, value: String) {
        self.kind = kind
        self.value = value
    }
}

// MARK: - MarkedString

/// `MarkedString` is the legacy hover content type. It is either a plain
/// string (interpreted as markdown) or an object `{ language, value }` that
/// is rendered as a fenced code block in the given language.
///
/// Deprecated by the spec in favour of `MarkupContent` but still required
/// for `Hover.contents` decoding from older servers.
enum MarkedString: Sendable, Codable, Equatable, Hashable {
    case string(String)
    case codeBlock(language: String, value: String)

    private enum CodingKeys: String, CodingKey {
        case language
        case value
    }

    init(from decoder: any Decoder) throws {
        // Try the string variant first.
        if let single = try? decoder.singleValueContainer(),
           let s = try? single.decode(String.self) {
            self = .string(s)
            return
        }
        // Otherwise expect `{ language, value }`.
        let keyed = try decoder.container(keyedBy: CodingKeys.self)
        let language = try keyed.decode(String.self, forKey: .language)
        let value = try keyed.decode(String.self, forKey: .value)
        self = .codeBlock(language: language, value: value)
    }

    func encode(to encoder: any Encoder) throws {
        switch self {
        case .string(let s):
            var container = encoder.singleValueContainer()
            try container.encode(s)
        case .codeBlock(let language, let value):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(language, forKey: .language)
            try container.encode(value, forKey: .value)
        }
    }
}
