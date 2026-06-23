//
//  DocumentUri.swift
//  Calyx
//
//  LSP 3.18 DocumentUri type. See:
//  https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#uri
//

import Foundation

/// A tagging type for a document URI. In LSP this is always a string carrying
/// an RFC 3986 URI. We model it as a `String` typealias rather than a wrapper
/// struct so that callers can pass string literals directly and so JSON
/// encoding/decoding is identical to `String`.
typealias DocumentUri = String

/// Alias for `DocumentUri`. LSP 3.17+ introduced `URI` as a separate (but
/// currently identical) alias to mark URIs that are not necessarily document
/// references (e.g. workspace folder URIs).
typealias URI = String
