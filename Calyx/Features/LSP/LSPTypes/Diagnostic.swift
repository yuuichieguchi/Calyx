//
//  Diagnostic.swift
//  Calyx
//
//  LSP 3.18 Diagnostic + supporting types. See:
//  https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#diagnostic
//  https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#diagnosticSeverity
//  https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#diagnosticTag
//  https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#diagnosticRelatedInformation
//  https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#codeDescription
//

import Foundation

// MARK: - DiagnosticSeverity

/// The severity of a diagnostic. The spec defines values 1..4; unknown
/// values must fail to decode rather than silently degrade.
enum DiagnosticSeverity: Int, Sendable, Codable, Equatable, Hashable {
    case error = 1
    case warning = 2
    case information = 3
    case hint = 4

    init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(Int.self)
        guard let value = DiagnosticSeverity(rawValue: raw) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Unknown DiagnosticSeverity raw value: \(raw)"
            ))
        }
        self = value
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(self.rawValue)
    }
}

// MARK: - DiagnosticTag

/// Diagnostic tags allow the client to render diagnostics differently
/// (e.g. faded out for unused code, struck-through for deprecated APIs).
enum DiagnosticTag: Int, Sendable, Codable, Equatable, Hashable {
    case unnecessary = 1
    case deprecated = 2

    init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(Int.self)
        guard let value = DiagnosticTag(rawValue: raw) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Unknown DiagnosticTag raw value: \(raw)"
            ))
        }
        self = value
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(self.rawValue)
    }
}

// MARK: - DiagnosticRelatedInformation

/// Represents a related message and source code location for a diagnostic.
struct DiagnosticRelatedInformation: Sendable, Codable, Equatable, Hashable {
    let location: Location
    let message: String

    init(location: Location, message: String) {
        self.location = location
        self.message = message
    }
}

// MARK: - CodeDescription

/// Structure to capture a description for an error code.
struct CodeDescription: Sendable, Codable, Equatable, Hashable {
    /// An URI to open with more information about the diagnostic error.
    let href: URI

    init(href: URI) {
        self.href = href
    }
}

// MARK: - DiagnosticCode

/// LSP allows `Diagnostic.code` to be either an `Int` or a `String`.
enum DiagnosticCode: Sendable, Codable, Equatable, Hashable {
    case int(Int)
    case string(String)

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        // Try Int first; if that fails fall back to String. Order matters:
        // a numeric JSON value would also be decodable as a String via
        // permissive coercion in some flows, but JSONDecoder enforces type
        // here so Int-then-String is safe.
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
            debugDescription: "DiagnosticCode must be Int or String."
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

// MARK: - Diagnostic

/// Represents a diagnostic, such as a compiler error or warning. Diagnostic
/// objects are only valid in the scope of a resource.
struct Diagnostic: Sendable, Codable, Equatable, Hashable {
    /// The range at which the message applies.
    let range: LSPRange
    /// The diagnostic's severity. If omitted the client should interpret
    /// the severity using its own policy.
    let severity: DiagnosticSeverity?
    /// The diagnostic's code, which might appear in the user interface.
    let code: DiagnosticCode?
    /// Additional metadata about the code.
    let codeDescription: CodeDescription?
    /// A human-readable string describing the source of this diagnostic,
    /// e.g. `"swiftc"` or `"clippy"`.
    let source: String?
    /// The diagnostic's message.
    let message: String
    /// Additional metadata about the diagnostic.
    let tags: [DiagnosticTag]?
    /// An array of related diagnostic information, e.g. when symbol
    /// definitions are referenced in a diagnostic message.
    let relatedInformation: [DiagnosticRelatedInformation]?
    /// A data entry field preserved between a `textDocument/publishDiagnostics`
    /// notification and `textDocument/codeAction` request.
    let data: AnyCodable?

    init(
        range: LSPRange,
        severity: DiagnosticSeverity? = nil,
        code: DiagnosticCode? = nil,
        codeDescription: CodeDescription? = nil,
        source: String? = nil,
        message: String,
        tags: [DiagnosticTag]? = nil,
        relatedInformation: [DiagnosticRelatedInformation]? = nil,
        data: AnyCodable? = nil
    ) {
        self.range = range
        self.severity = severity
        self.code = code
        self.codeDescription = codeDescription
        self.source = source
        self.message = message
        self.tags = tags
        self.relatedInformation = relatedInformation
        self.data = data
    }
}

// MARK: - Hashable for AnyCodable-bearing types
//
// `Diagnostic` carries an `AnyCodable?` payload. `AnyCodable` only conforms
// to `Equatable`, not `Hashable`. We give `Diagnostic` a custom `Hashable`
// that hashes the structural fields and ignores the freeform `data`. This
// is acceptable because Hashable only requires `a == b ⇒ hash(a) == hash(b)`:
// when two `Diagnostic` values are `==`, their non-data fields are equal,
// and we hash exactly those.

extension Diagnostic {
    func hash(into hasher: inout Hasher) {
        hasher.combine(range)
        hasher.combine(severity)
        hasher.combine(code)
        hasher.combine(codeDescription)
        hasher.combine(source)
        hasher.combine(message)
        hasher.combine(tags)
        hasher.combine(relatedInformation)
        // `data` deliberately omitted — AnyCodable is not Hashable.
    }
}
