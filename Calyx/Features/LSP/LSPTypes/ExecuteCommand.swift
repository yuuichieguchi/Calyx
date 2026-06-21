//
//  ExecuteCommand.swift
//  Calyx
//
//  LSP 3.18 ExecuteCommand request parameters. See:
//  https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#workspace_executeCommand
//

import Foundation

/// Parameters of a `workspace/executeCommand` request. The server executes
/// the command in the workspace and may respond with arbitrary JSON.
struct ExecuteCommandParams: Sendable, Codable, Equatable {
    /// The identifier of the actual command handler.
    let command: String
    /// Arguments that the command should be invoked with.
    let arguments: [AnyCodable]?
    /// An optional token that a server can use to report work done progress.
    let workDoneToken: ProgressToken?

    init(
        command: String,
        arguments: [AnyCodable]? = nil,
        workDoneToken: ProgressToken? = nil
    ) {
        self.command = command
        self.arguments = arguments
        self.workDoneToken = workDoneToken
    }
}
