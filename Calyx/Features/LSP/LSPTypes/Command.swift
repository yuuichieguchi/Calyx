//
//  Command.swift
//  Calyx
//
//  LSP 3.18 Command type. See:
//  https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#command
//

import Foundation

// MARK: - Command

/// LSP 3.18 `Command`. Represents a reference to a command. Provides a `title`
/// the UI uses to label the command, and a `command` identifier the server
/// uses to dispatch execution. `arguments` is runtime-typed JSON forwarded
/// verbatim by the server back through `workspace/executeCommand`.
struct Command: Sendable, Codable, Equatable, Hashable {
    /// Title of the command, like `save`.
    let title: String
    /// The identifier of the actual command handler.
    let command: String
    /// Arguments that the command handler should be invoked with.
    let arguments: [AnyCodable]?

    init(
        title: String,
        command: String,
        arguments: [AnyCodable]? = nil
    ) {
        self.title = title
        self.command = command
        self.arguments = arguments
    }
}

// MARK: - Hashable for AnyCodable-bearing types
//
// `Command` carries an `[AnyCodable]?` payload. `AnyCodable` only conforms
// to `Equatable`, not `Hashable`. We give `Command` a custom `Hashable`
// that hashes the structural fields and ignores the freeform `arguments`.
// This is acceptable because Hashable only requires
// `a == b ⇒ hash(a) == hash(b)`: when two `Command` values are `==`, their
// non-arguments fields are equal, and we hash exactly those. Mirrors the
// pattern used by `Diagnostic`.

extension Command {
    func hash(into hasher: inout Hasher) {
        hasher.combine(title)
        hasher.combine(command)
        // `arguments` deliberately omitted — AnyCodable is not Hashable.
    }
}
