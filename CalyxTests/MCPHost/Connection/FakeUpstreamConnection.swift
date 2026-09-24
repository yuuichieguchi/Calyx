//
//  FakeUpstreamConnection.swift
//  CalyxTests
//
//  Scriptable `MCPUpstreamConnecting` test double for later modules
//  (Downstream) that need a connection stand-in without driving a real
//  `MCPUpstreamConnection` through a transport (API contract section
//  14). An actor, so its mutable state is synchronized without
//  `@unchecked Sendable`, per section 14's own correction of the prior
//  contract's lock-free double.
//

import Foundation
@testable import Calyx

actor FakeUpstreamConnection: MCPUpstreamConnecting {

    // MARK: - Scripted state

    private var scriptedState: MCPConnectionState
    private var scriptedTools: [MCPToolDefinition]
    private var scriptedToolCallOutcomes: [MCPUpstreamClient.ToolCallOutcome]
    private var scriptedReadResourceResult: Result<[String: AnyCodable], any Error>
    private var scriptedProgress: [MCPProgressUpdate] = []
    private var scriptedListResources: Result<(items: [[String: AnyCodable]], nextCursor: String?), any Error> = .success(([], nil))
    private var scriptedListResourceTemplates: Result<(items: [[String: AnyCodable]], nextCursor: String?), any Error> = .success(([], nil))
    private var scriptedListPrompts: Result<(items: [[String: AnyCodable]], nextCursor: String?), any Error> = .success(([], nil))

    // MARK: - Recorded calls

    private(set) var callToolInvocations: [(name: String, arguments: [String: AnyCodable], context: MCPToolCallContext)] = []
    private(set) var readResourceURIs: [String] = []
    private(set) var listResourcesCursors: [String?] = []
    private(set) var listResourceTemplatesCursors: [String?] = []
    private(set) var listPromptsCursors: [String?] = []

    // MARK: - Events

    private let eventsContinuation: AsyncStream<MCPServerEvent>.Continuation
    private let eventsStream: AsyncStream<MCPServerEvent>

    // MARK: - Init

    nonisolated let serverID: MCPServerID

    init(
        serverID: MCPServerID,
        initialState: MCPConnectionState = .connecting,
        initialTools: [MCPToolDefinition] = [],
        toolCallOutcomes: [MCPUpstreamClient.ToolCallOutcome] = [],
        readResourceResult: Result<[String: AnyCodable], any Error> = .success([:])
    ) {
        self.serverID = serverID
        self.scriptedState = initialState
        self.scriptedTools = initialTools
        self.scriptedToolCallOutcomes = toolCallOutcomes
        self.scriptedReadResourceResult = readResourceResult
        var capturedContinuation: AsyncStream<MCPServerEvent>.Continuation!
        self.eventsStream = AsyncStream<MCPServerEvent> { continuation in
            capturedContinuation = continuation
        }
        self.eventsContinuation = capturedContinuation
    }

    // MARK: - MCPUpstreamConnecting

    func tools() async -> [MCPToolDefinition] {
        scriptedTools
    }

    func state() async -> MCPConnectionState {
        scriptedState
    }

    var events: AsyncStream<MCPServerEvent> {
        get async { eventsStream }
    }

    func callTool(name: String, arguments: [String: AnyCodable], context: MCPToolCallContext) async -> MCPUpstreamClient.ToolCallOutcome {
        callToolInvocations.append((name, arguments, context))
        if let progress = context.progress {
            let updates = scriptedProgress
            scriptedProgress.removeAll()
            for update in updates {
                await progress(update)
            }
        }
        guard !scriptedToolCallOutcomes.isEmpty else {
            return .protocolError(.transportClosed(reason: "FakeUpstreamConnection has no scripted outcome"))
        }
        return scriptedToolCallOutcomes.removeFirst()
    }

    func readResource(uri: String) async throws -> [String: AnyCodable] {
        readResourceURIs.append(uri)
        switch scriptedReadResourceResult {
        case .success(let value): return value
        case .failure(let error): throw error
        }
    }

    func listResources(cursor: String?) async throws -> (items: [[String: AnyCodable]], nextCursor: String?) {
        listResourcesCursors.append(cursor)
        return try scriptedListResources.get()
    }

    func listResourceTemplates(cursor: String?) async throws -> (items: [[String: AnyCodable]], nextCursor: String?) {
        listResourceTemplatesCursors.append(cursor)
        return try scriptedListResourceTemplates.get()
    }

    func listPrompts(cursor: String?) async throws -> (items: [[String: AnyCodable]], nextCursor: String?) {
        listPromptsCursors.append(cursor)
        return try scriptedListPrompts.get()
    }

    // MARK: - Test API

    /// Overwrite the state reported by the next `state()` call and emit a
    /// matching `.stateChanged` event, mirroring what a real
    /// `MCPUpstreamConnection` transition would do.
    func setState(_ state: MCPConnectionState) {
        scriptedState = state
        eventsContinuation.yield(.stateChanged(state))
    }

    /// Overwrite the tools reported by the next `tools()` call and emit a
    /// `.toolsChanged` event.
    func setTools(_ tools: [MCPToolDefinition]) {
        scriptedTools = tools
        eventsContinuation.yield(.toolsChanged)
    }

    /// Push additional scripted outcomes for subsequent `callTool` calls.
    func enqueueToolCallOutcome(_ outcome: MCPUpstreamClient.ToolCallOutcome) {
        scriptedToolCallOutcomes.append(outcome)
    }

    /// Script progress updates delivered to the next `callTool`'s
    /// `context.progress` handler, in order, before its outcome returns.
    /// Nothing is delivered when the call carries no handler.
    func enqueueProgress(_ update: MCPProgressUpdate) {
        scriptedProgress.append(update)
    }

    /// Script the result of every later `listResources` call.
    func setListResourcesResult(_ result: Result<(items: [[String: AnyCodable]], nextCursor: String?), any Error>) {
        scriptedListResources = result
    }

    /// Script the result of every later `listResourceTemplates` call.
    func setListResourceTemplatesResult(_ result: Result<(items: [[String: AnyCodable]], nextCursor: String?), any Error>) {
        scriptedListResourceTemplates = result
    }

    /// Script the result of every later `listPrompts` call.
    func setListPromptsResult(_ result: Result<(items: [[String: AnyCodable]], nextCursor: String?), any Error>) {
        scriptedListPrompts = result
    }

    func finishEvents() {
        eventsContinuation.finish()
    }
}
