//
//  LSPRange.swift
//  Calyx
//
//  LSP 3.18 Range type. See:
//  https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#range
//
//  Named `LSPRange` rather than `Range` to avoid colliding with Swift's
//  standard library `Range<Bound>`. Do NOT introduce a `typealias Range`
//  shadowing the standard type at module scope.
//

import Foundation

/// A range in a text document expressed as (zero-based) start and end positions.
struct LSPRange: Sendable, Codable, Equatable, Hashable {
    let start: Position
    let end: Position

    init(start: Position, end: Position) {
        self.start = start
        self.end = end
    }
}
