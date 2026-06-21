//
//  StdioBackedLSPSessionFactory.swift
//  Calyx
//
//  Production-side `LSPSessionFactory` that wires `LSPClient` onto a
//  real `StdioLSPTransport`, so each session spawns the language server
//  as a child process and communicates over stdio. Tests inject an
//  `InMemoryLSPTransport`-backed factory instead.
//

import Foundation

/// `LSPSessionFactory` whose `makeClient(...)` returns an `LSPClient`
/// connected to `StdioLSPTransport`. Stateless and Sendable.
struct StdioBackedLSPSessionFactory: LSPSessionFactory {

    init() {}

    func makeClient(
        executable: String,
        arguments: [String],
        environment: [String: String]?,
        workingDirectory: URL?
    ) async throws -> LSPClient {
        let transport = StdioLSPTransport(
            executable: executable,
            arguments: arguments,
            environment: environment,
            workingDirectory: workingDirectory
        )
        return LSPClient(transport: transport)
    }
}
