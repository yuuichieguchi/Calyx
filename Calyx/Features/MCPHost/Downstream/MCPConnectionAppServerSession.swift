//
//  MCPConnectionAppServerSession.swift
//  Calyx
//
//  `MCPAppServerSession` over one upstream connection, handed to the view
//  host with each rendered invocation.
//

import Foundation

enum MCPAppServerSessionError: Error, Equatable {
    /// The upstream call did not return a result.
    case callFailed(String)
}

struct MCPConnectionAppServerSession: MCPAppServerSession {
    private let connection: any MCPUpstreamConnecting
    let serverDisplayName: String

    init(connection: any MCPUpstreamConnecting, serverDisplayName: String) {
        self.connection = connection
        self.serverDisplayName = serverDisplayName
    }

    var serverID: MCPServerID { connection.serverID }

    func callTool(name: String, arguments: [String: AnyCodable]) async throws -> MCPCallToolResult {
        switch await connection.callTool(name: name, arguments: arguments, context: .none) {
        case .result(let result):
            return result
        case .cancelled:
            throw CancellationError()
        case .protocolError(let error):
            throw MCPAppServerSessionError.callFailed(String(describing: error))
        }
    }

    func readResource(uri: String) async throws -> [String: AnyCodable] {
        try await connection.readResource(uri: uri)
    }

    func listTools() async -> [MCPToolDefinition] {
        await connection.tools().filter { $0.visibility.contains(.app) }
    }

    func listResources(cursor: String?) async throws -> (items: [[String: AnyCodable]], nextCursor: String?) {
        try await connection.listResources(cursor: cursor)
    }

    func listResourceTemplates(cursor: String?) async throws -> (items: [[String: AnyCodable]], nextCursor: String?) {
        try await connection.listResourceTemplates(cursor: cursor)
    }

    func listPrompts(cursor: String?) async throws -> (items: [[String: AnyCodable]], nextCursor: String?) {
        try await connection.listPrompts(cursor: cursor)
    }

    func events() -> AsyncStream<MCPServerEvent> {
        let connection = self.connection
        return AsyncStream { continuation in
            let task = Task {
                for await event in await connection.events {
                    continuation.yield(event)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
