//
//  FakeMCPAppServerSession.swift
//  CalyxTests
//
//  Test double for MCPAppServerSession (Host §9, assigned in contract v2
//  §14). readResource/callTool responses are injected by the test via
//  Result values set before the call; call counts let a test observe a
//  reload actually re-issuing resources/read.
//

import Foundation
@testable import Calyx

final class FakeMCPAppServerSession: MCPAppServerSession, @unchecked Sendable {
    let serverID: MCPServerID
    let serverDisplayName: String

    private let lock = NSLock()
    private var _readResourceResult: Result<[String: AnyCodable], Error>
    private var _callToolResult: Result<MCPCallToolResult, Error>
    private var _readResourceCallCount = 0
    private var _callToolCallCount = 0
    private var _listResourcesResult: Result<(items: [[String: AnyCodable]], nextCursor: String?), Error> = .success(([], nil))

    init(
        serverID: MCPServerID = MCPServerID(rawValue: UUID()),
        serverDisplayName: String = "Weather",
        readResourceResult: Result<[String: AnyCodable], Error> = .success([:]),
        callToolResult: Result<MCPCallToolResult, Error> = .success(MCPCallToolResult(raw: [:]))
    ) {
        self.serverID = serverID
        self.serverDisplayName = serverDisplayName
        self._readResourceResult = readResourceResult
        self._callToolResult = callToolResult
    }

    var readResourceResult: Result<[String: AnyCodable], Error> {
        get { lock.lock(); defer { lock.unlock() }; return _readResourceResult }
        set { lock.lock(); defer { lock.unlock() }; _readResourceResult = newValue }
    }
    var callToolResult: Result<MCPCallToolResult, Error> {
        get { lock.lock(); defer { lock.unlock() }; return _callToolResult }
        set { lock.lock(); defer { lock.unlock() }; _callToolResult = newValue }
    }
    var listResourcesResult: Result<(items: [[String: AnyCodable]], nextCursor: String?), Error> {
        get { lock.lock(); defer { lock.unlock() }; return _listResourcesResult }
        set { lock.lock(); defer { lock.unlock() }; _listResourcesResult = newValue }
    }
    var readResourceCallCount: Int {
        lock.lock(); defer { lock.unlock() }; return _readResourceCallCount
    }
    var callToolCallCount: Int {
        lock.lock(); defer { lock.unlock() }; return _callToolCallCount
    }

    func callTool(name: String, arguments: [String: AnyCodable]) async throws -> MCPCallToolResult {
        let result = lock.withLock { () -> Result<MCPCallToolResult, Error> in
            _callToolCallCount += 1
            return _callToolResult
        }
        return try result.get()
    }

    func readResource(uri: String) async throws -> [String: AnyCodable] {
        let result = lock.withLock { () -> Result<[String: AnyCodable], Error> in
            _readResourceCallCount += 1
            return _readResourceResult
        }
        return try result.get()
    }

    func listTools() async -> [MCPToolDefinition] { [] }
    func listResources(cursor: String?) async throws -> (items: [[String: AnyCodable]], nextCursor: String?) {
        try lock.withLock { _listResourcesResult }.get()
    }
    func listResourceTemplates(cursor: String?) async throws -> (items: [[String: AnyCodable]], nextCursor: String?) { ([], nil) }
    func listPrompts(cursor: String?) async throws -> (items: [[String: AnyCodable]], nextCursor: String?) { ([], nil) }
    func events() -> AsyncStream<MCPServerEvent> { AsyncStream { _ in } }
}

struct FakeSessionError: Error, Equatable {
    let message: String
}
