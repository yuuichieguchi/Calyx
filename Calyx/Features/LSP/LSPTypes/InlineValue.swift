//
//  InlineValue.swift
//  Calyx
//
//  LSP 3.18 textDocument/inlineValue parameter & response types. See:
//  https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocument_inlineValue
//  https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#inlineValueContext
//  https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#inlineValueText
//  https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#inlineValueVariableLookup
//  https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#inlineValueEvaluatableExpression
//

import Foundation

// MARK: - InlineValueContext

/// Context information for inline values requests.
struct InlineValueContext: Sendable, Codable, Equatable, Hashable {
    /// The stack frame (as a DAP frame id) where the execution has stopped.
    let frameId: Int
    /// The document range where execution has stopped. Typically the end
    /// position of the range denotes the line where the inline values are
    /// shown.
    let stoppedLocation: LSPRange

    init(frameId: Int, stoppedLocation: LSPRange) {
        self.frameId = frameId
        self.stoppedLocation = stoppedLocation
    }
}

// MARK: - InlineValueParams

/// Parameters for the `textDocument/inlineValue` request.
struct InlineValueParams: Sendable, Codable, Equatable {
    let textDocument: TextDocumentIdentifier
    /// The document range for which inline values should be computed.
    let range: LSPRange
    /// Additional information about the context in which inline values were
    /// requested.
    let context: InlineValueContext
    let workDoneToken: ProgressToken?

    init(
        textDocument: TextDocumentIdentifier,
        range: LSPRange,
        context: InlineValueContext,
        workDoneToken: ProgressToken? = nil
    ) {
        self.textDocument = textDocument
        self.range = range
        self.context = context
        self.workDoneToken = workDoneToken
    }
}

// MARK: - InlineValueText

/// Provide inline value as text.
struct InlineValueText: Sendable, Codable, Equatable, Hashable {
    /// The document range for which the inline value applies.
    let range: LSPRange
    /// The text of the inline value.
    let text: String

    init(range: LSPRange, text: String) {
        self.range = range
        self.text = text
    }
}

// MARK: - InlineValueVariableLookup

/// Provide inline value through a variable lookup.
struct InlineValueVariableLookup: Sendable, Codable, Equatable, Hashable {
    /// The document range for which the inline value applies. The range is
    /// used to extract the variable name from the underlying document.
    let range: LSPRange
    /// If specified the name of the variable to look up.
    let variableName: String?
    /// How to perform the lookup.
    let caseSensitiveLookup: Bool

    init(range: LSPRange, variableName: String? = nil, caseSensitiveLookup: Bool) {
        self.range = range
        self.variableName = variableName
        self.caseSensitiveLookup = caseSensitiveLookup
    }
}

// MARK: - InlineValueEvaluatableExpression

/// Provide an inline value through an expression evaluation.
struct InlineValueEvaluatableExpression: Sendable, Codable, Equatable, Hashable {
    /// The document range for which the inline value applies. The range is
    /// used to extract the evaluatable expression from the underlying
    /// document.
    let range: LSPRange
    /// If specified the expression overrides the extracted expression.
    let expression: String?

    init(range: LSPRange, expression: String? = nil) {
        self.range = range
        self.expression = expression
    }
}

// MARK: - InlineValue
//
// Union: `InlineValueText | InlineValueVariableLookup | InlineValueEvaluatableExpression`.
//
// Spec discriminator (by key presence):
//   - `text` key present                 -> InlineValueText
//   - `caseSensitiveLookup` key present  -> InlineValueVariableLookup
//   - otherwise                          -> InlineValueEvaluatableExpression
//     (i.e. an `expression` field, or just `range`).

/// Inline value information that can be shown by the editor while debugging.
enum InlineValue: Sendable, Codable, Equatable {
    case text(InlineValueText)
    case variableLookup(InlineValueVariableLookup)
    case evaluatableExpression(InlineValueEvaluatableExpression)

    private enum DiscriminatorKey: String, CodingKey {
        case text
        case caseSensitiveLookup
    }

    init(from decoder: any Decoder) throws {
        let keyed = try decoder.container(keyedBy: DiscriminatorKey.self)
        if keyed.contains(.text) {
            self = .text(try InlineValueText(from: decoder))
        } else if keyed.contains(.caseSensitiveLookup) {
            self = .variableLookup(try InlineValueVariableLookup(from: decoder))
        } else {
            self = .evaluatableExpression(try InlineValueEvaluatableExpression(from: decoder))
        }
    }

    func encode(to encoder: any Encoder) throws {
        switch self {
        case .text(let t):
            try t.encode(to: encoder)
        case .variableLookup(let v):
            try v.encode(to: encoder)
        case .evaluatableExpression(let e):
            try e.encode(to: encoder)
        }
    }
}
