//
//  Location.swift
//  Calyx
//
//  LSP 3.18 Location type. See:
//  https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#location
//

import Foundation

/// Represents a location inside a resource, such as a line inside a text file.
struct Location: Sendable, Codable, Equatable, Hashable {
    let uri: DocumentUri
    let range: LSPRange

    init(uri: DocumentUri, range: LSPRange) {
        self.uri = uri
        self.range = range
    }
}
