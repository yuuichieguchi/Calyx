//
//  Formatting.swift
//  Calyx
//
//  LSP 3.18 formatting parameter types. See:
//  https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocument_formatting
//  https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocument_rangeFormatting
//  https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocument_onTypeFormatting
//  https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#formattingOptions
//

import Foundation

// MARK: - FormattingOptions

/// Value-object describing what options formatting should use.
struct FormattingOptions: Sendable, Codable, Equatable {
    /// Size of a tab in spaces.
    let tabSize: Int
    /// Prefer spaces over tabs.
    let insertSpaces: Bool
    /// Trim trailing whitespace on a line.
    let trimTrailingWhitespace: Bool?
    /// Insert a newline character at the end of the file if one does not
    /// exist.
    let insertFinalNewline: Bool?
    /// Trim all newlines after the final newline at the end of the file.
    let trimFinalNewlines: Bool?

    init(
        tabSize: Int,
        insertSpaces: Bool,
        trimTrailingWhitespace: Bool? = nil,
        insertFinalNewline: Bool? = nil,
        trimFinalNewlines: Bool? = nil
    ) {
        self.tabSize = tabSize
        self.insertSpaces = insertSpaces
        self.trimTrailingWhitespace = trimTrailingWhitespace
        self.insertFinalNewline = insertFinalNewline
        self.trimFinalNewlines = trimFinalNewlines
    }
}

// MARK: - DocumentFormattingParams

/// Parameters for the `textDocument/formatting` request.
struct DocumentFormattingParams: Sendable, Codable, Equatable {
    let textDocument: TextDocumentIdentifier
    let options: FormattingOptions
    let workDoneToken: ProgressToken?

    init(
        textDocument: TextDocumentIdentifier,
        options: FormattingOptions,
        workDoneToken: ProgressToken? = nil
    ) {
        self.textDocument = textDocument
        self.options = options
        self.workDoneToken = workDoneToken
    }
}

// MARK: - DocumentRangeFormattingParams

/// Parameters for the `textDocument/rangeFormatting` request.
struct DocumentRangeFormattingParams: Sendable, Codable, Equatable {
    let textDocument: TextDocumentIdentifier
    let range: LSPRange
    let options: FormattingOptions
    let workDoneToken: ProgressToken?

    init(
        textDocument: TextDocumentIdentifier,
        range: LSPRange,
        options: FormattingOptions,
        workDoneToken: ProgressToken? = nil
    ) {
        self.textDocument = textDocument
        self.range = range
        self.options = options
        self.workDoneToken = workDoneToken
    }
}

// MARK: - DocumentOnTypeFormattingParams

/// Parameters for the `textDocument/onTypeFormatting` request.
struct DocumentOnTypeFormattingParams: Sendable, Codable, Equatable {
    let textDocument: TextDocumentIdentifier
    let position: Position
    /// The character that has been typed that triggered the formatting on-type
    /// request. NOTE: this is not necessarily the last character in the
    /// document after the inserted text.
    let ch: String
    let options: FormattingOptions

    init(
        textDocument: TextDocumentIdentifier,
        position: Position,
        ch: String,
        options: FormattingOptions
    ) {
        self.textDocument = textDocument
        self.position = position
        self.ch = ch
        self.options = options
    }
}
