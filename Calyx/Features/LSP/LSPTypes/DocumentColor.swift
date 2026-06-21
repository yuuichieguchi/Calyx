//
//  DocumentColor.swift
//  Calyx
//
//  LSP 3.18 textDocument/documentColor and textDocument/colorPresentation
//  parameter & response types. See:
//  https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocument_documentColor
//  https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocument_colorPresentation
//  https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#color
//  https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#colorInformation
//  https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#colorPresentation
//

import Foundation

// MARK: - DocumentColorParams

/// Parameters for the `textDocument/documentColor` request.
struct DocumentColorParams: Sendable, Codable, Equatable {
    let textDocument: TextDocumentIdentifier
    let workDoneToken: ProgressToken?
    let partialResultToken: ProgressToken?

    init(
        textDocument: TextDocumentIdentifier,
        workDoneToken: ProgressToken? = nil,
        partialResultToken: ProgressToken? = nil
    ) {
        self.textDocument = textDocument
        self.workDoneToken = workDoneToken
        self.partialResultToken = partialResultToken
    }
}

// MARK: - LSPColor
//
// The spec names this type `Color`. Renamed to `LSPColor` here so it does
// not collide with `SwiftUI.Color` once SwiftUI is imported anywhere in the
// app target.

/// Represents a color in RGBA space. Components are in the closed range `[0, 1]`.
struct LSPColor: Sendable, Codable, Equatable, Hashable {
    /// The red component of this color in the range `[0, 1]`.
    let red: Double
    /// The green component of this color in the range `[0, 1]`.
    let green: Double
    /// The blue component of this color in the range `[0, 1]`.
    let blue: Double
    /// The alpha component of this color in the range `[0, 1]`.
    let alpha: Double

    init(red: Double, green: Double, blue: Double, alpha: Double) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }
}

// MARK: - ColorInformation

/// Represents a color range in a document, returned by
/// `textDocument/documentColor`.
struct ColorInformation: Sendable, Codable, Equatable, Hashable {
    /// The range in the document where this color appears.
    let range: LSPRange
    /// The actual color value for this color range.
    let color: LSPColor

    init(range: LSPRange, color: LSPColor) {
        self.range = range
        self.color = color
    }
}

// MARK: - ColorPresentationParams

/// Parameters for the `textDocument/colorPresentation` request.
struct ColorPresentationParams: Sendable, Codable, Equatable {
    let textDocument: TextDocumentIdentifier
    /// The color information to request presentations for.
    let color: LSPColor
    /// The range where the color would be inserted. Serves as a context.
    let range: LSPRange
    let workDoneToken: ProgressToken?
    let partialResultToken: ProgressToken?

    init(
        textDocument: TextDocumentIdentifier,
        color: LSPColor,
        range: LSPRange,
        workDoneToken: ProgressToken? = nil,
        partialResultToken: ProgressToken? = nil
    ) {
        self.textDocument = textDocument
        self.color = color
        self.range = range
        self.workDoneToken = workDoneToken
        self.partialResultToken = partialResultToken
    }
}

// MARK: - ColorPresentation

/// A textual presentation of a color, returned by
/// `textDocument/colorPresentation`.
struct ColorPresentation: Sendable, Codable, Equatable, Hashable {
    /// The label of this color presentation. Used to fill in the
    /// `textDocument` upon selection if no `textEdit` is provided.
    let label: String
    /// An edit which is applied to the document when selecting this
    /// presentation for the color. When `nil`, the editor uses `label`.
    let textEdit: TextEdit?
    /// Additional edits to apply alongside `textEdit`. Must not overlap with
    /// `textEdit` nor with each other.
    let additionalTextEdits: [TextEdit]?

    init(
        label: String,
        textEdit: TextEdit? = nil,
        additionalTextEdits: [TextEdit]? = nil
    ) {
        self.label = label
        self.textEdit = textEdit
        self.additionalTextEdits = additionalTextEdits
    }
}
