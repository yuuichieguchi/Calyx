//
//  Position.swift
//  Calyx
//
//  LSP 3.18 Position type. See:
//  https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#position
//

import Foundation

/// Position in a text document expressed as zero-based line and character
/// offset. A position is between two characters like an 'insert' cursor in an
/// editor.
struct Position: Sendable, Codable, Equatable, Hashable {
    let line: Int
    let character: Int

    init(line: Int, character: Int) {
        self.line = line
        self.character = character
    }
}
