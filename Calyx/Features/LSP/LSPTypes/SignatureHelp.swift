//
//  SignatureHelp.swift
//  Calyx
//
//  LSP 3.18 SignatureHelp request + response types. See:
//  https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocument_signatureHelp
//
//  Eight related types live here because they form a single closed family
//  and are only ever used together:
//    - SignatureHelpParams
//    - SignatureHelpContext
//    - SignatureHelpTriggerKind
//    - SignatureHelp
//    - SignatureInformation
//    - ParameterInformation
//    - ParameterLabel        (union: String | [Int, Int])
//    - StringOrMarkupContent (union: String | MarkupContent)
//

import Foundation

// MARK: - SignatureHelpTriggerKind

/// How a signature help was triggered.
enum SignatureHelpTriggerKind: Int, Sendable, Codable, Equatable, Hashable {
    /// Signature help was invoked manually by the user or by a command.
    case invoked = 1
    /// Signature help was triggered by a trigger character.
    case triggerCharacter = 2
    /// Signature help was triggered by the cursor moving or by document
    /// content changes.
    case contentChange = 3
}

// MARK: - StringOrMarkupContent

/// Documentation may be either a plain string or a `MarkupContent` literal.
enum StringOrMarkupContent: Sendable, Codable, Equatable {
    case string(String)
    case markupContent(MarkupContent)

    init(from decoder: any Decoder) throws {
        // Try the string variant first via a single-value container.
        if let container = try? decoder.singleValueContainer(),
           let s = try? container.decode(String.self) {
            self = .string(s)
            return
        }
        // Otherwise expect a `MarkupContent` object.
        let mc = try MarkupContent(from: decoder)
        self = .markupContent(mc)
    }

    func encode(to encoder: any Encoder) throws {
        switch self {
        case .string(let s):
            var container = encoder.singleValueContainer()
            try container.encode(s)
        case .markupContent(let mc):
            try mc.encode(to: encoder)
        }
    }
}

// MARK: - ParameterLabel

/// A parameter's label inside its containing signature. Either a literal
/// substring of the signature label, or an inclusive `[start, end]`
/// character-offset pair into the signature label.
enum ParameterLabel: Sendable, Codable, Equatable {
    case string(String)
    case range(start: Int, end: Int)

    init(from decoder: any Decoder) throws {
        // Try the string variant first.
        if let container = try? decoder.singleValueContainer(),
           let s = try? container.decode(String.self) {
            self = .string(s)
            return
        }
        // Otherwise expect a 2-element [Int, Int] array.
        var unkeyed = try decoder.unkeyedContainer()
        let start = try unkeyed.decode(Int.self)
        let end = try unkeyed.decode(Int.self)
        self = .range(start: start, end: end)
    }

    func encode(to encoder: any Encoder) throws {
        switch self {
        case .string(let s):
            var container = encoder.singleValueContainer()
            try container.encode(s)
        case .range(let start, let end):
            var unkeyed = encoder.unkeyedContainer()
            try unkeyed.encode(start)
            try unkeyed.encode(end)
        }
    }
}

// MARK: - ParameterInformation

/// Represents a parameter of a callable signature.
struct ParameterInformation: Sendable, Codable, Equatable {
    /// The label of this parameter. May be a literal substring or an
    /// inclusive `[start, end]` offset pair into the signature's label.
    let label: ParameterLabel
    /// Optional human-readable documentation.
    let documentation: StringOrMarkupContent?

    init(label: ParameterLabel, documentation: StringOrMarkupContent? = nil) {
        self.label = label
        self.documentation = documentation
    }
}

// MARK: - SignatureInformation

/// Represents the signature of something callable.
struct SignatureInformation: Sendable, Codable, Equatable {
    /// The label of this signature.
    let label: String
    /// Optional human-readable documentation.
    let documentation: StringOrMarkupContent?
    /// The parameters of this signature.
    let parameters: [ParameterInformation]?
    /// The index of the active parameter. If provided, overrides
    /// `SignatureHelp.activeParameter`.
    let activeParameter: Int?

    init(
        label: String,
        documentation: StringOrMarkupContent? = nil,
        parameters: [ParameterInformation]? = nil,
        activeParameter: Int? = nil
    ) {
        self.label = label
        self.documentation = documentation
        self.parameters = parameters
        self.activeParameter = activeParameter
    }
}

// MARK: - SignatureHelp

/// The result of a `textDocument/signatureHelp` request.
struct SignatureHelp: Sendable, Codable, Equatable {
    /// One or more signatures.
    let signatures: [SignatureInformation]
    /// The active signature.
    let activeSignature: Int?
    /// The active parameter of the active signature.
    let activeParameter: Int?

    init(
        signatures: [SignatureInformation],
        activeSignature: Int? = nil,
        activeParameter: Int? = nil
    ) {
        self.signatures = signatures
        self.activeSignature = activeSignature
        self.activeParameter = activeParameter
    }
}

// MARK: - SignatureHelpContext

/// Additional information about the context in which a signature help
/// request was triggered.
struct SignatureHelpContext: Sendable, Codable, Equatable {
    /// Action that caused signature help to be triggered.
    let triggerKind: SignatureHelpTriggerKind
    /// Character that caused signature help to be triggered. Only present
    /// for `triggerKind == .triggerCharacter`.
    let triggerCharacter: String?
    /// `true` if signature help was already showing when it was re-triggered.
    let isRetrigger: Bool
    /// The currently active `SignatureHelp`. Carried across re-triggers so
    /// the server can update the active signature/parameter without losing
    /// state.
    let activeSignatureHelp: SignatureHelp?

    init(
        triggerKind: SignatureHelpTriggerKind,
        triggerCharacter: String? = nil,
        isRetrigger: Bool,
        activeSignatureHelp: SignatureHelp? = nil
    ) {
        self.triggerKind = triggerKind
        self.triggerCharacter = triggerCharacter
        self.isRetrigger = isRetrigger
        self.activeSignatureHelp = activeSignatureHelp
    }
}

// MARK: - SignatureHelpParams

/// Parameters for the `textDocument/signatureHelp` request.
struct SignatureHelpParams: Sendable, Codable, Equatable {
    let textDocument: TextDocumentIdentifier
    let position: Position
    /// Additional context. Only present when the client supports it.
    let context: SignatureHelpContext?
    let workDoneToken: ProgressToken?

    init(
        textDocument: TextDocumentIdentifier,
        position: Position,
        context: SignatureHelpContext? = nil,
        workDoneToken: ProgressToken? = nil
    ) {
        self.textDocument = textDocument
        self.position = position
        self.context = context
        self.workDoneToken = workDoneToken
    }
}
