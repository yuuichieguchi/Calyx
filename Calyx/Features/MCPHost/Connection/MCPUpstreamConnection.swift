//
//  MCPUpstreamConnection.swift
//  Calyx
//
//  Supervises one upstream MCP server: creates the transport and the
//  `MCPUpstreamClient` above it, runs the handshake, caches the tool
//  list, restarts after an unsolicited transport loss, and tracks the
//  `MCPConnectionState` of the server.
//
//  One supervised run (a Task owned by the actor) goes through:
//    - `transportFactory(.standard)`, a new client, and `negotiate`. When
//      `negotiate` throws `.legacySSERequired`, the transport is closed and
//      the handshake is repeated on `transportFactory(.legacySSE)` with
//      `.initializeFirst`.
//    - `tools/list`, following `nextCursor` until it is absent (an empty
//      string is a cursor), then on the modern era `subscriptions/listen`
//      with `toolsListChanged`, waiting for its acknowledgement.
//    - `.ready`, then `client.serverEvents` until the stream ends.
//      `notifications/tools/list_changed` fetches the tool list again.
//      `.closed` is a crash: the client has already failed every call in
//      flight with `.transportClosed` (calls are never retried), the run
//      enters `.restarting` and sleeps 1, 2, 4, ... seconds (capped) on the
//      injected clock before connecting again. The crash that reaches
//      `maxCrashesBeforeFailed` enters `.failed` instead.
//
//  `stop()`, `disable()` and an HTTP 401 cancel the run and close the
//  transport. A closed transport ends `serverEvents` without `.closed`,
//  so these are never observed as crashes. A cancelled run leaves every
//  piece of actor state to whoever cancelled it.
//

import Foundation

/// Which transport `transportFactory` builds.
enum MCPTransportVariant: Sendable, Equatable {
    /// The configured transport (stdio or Streamable HTTP).
    case standard
    /// Legacy HTTP+SSE, after `negotiate` threw `.legacySSERequired` or
    /// when the configuration asks for it.
    case legacySSE
}

actor MCPUpstreamConnection: MCPUpstreamConnecting {

    struct Configuration: Sendable {
        let client: MCPUpstreamClient.Configuration
        /// The crash count at which automatic restarts stop.
        let maxCrashesBeforeFailed: Int
        /// The largest restart delay.
        let backoffCapSeconds: TimeInterval
    }

    // MARK: - Private Types

    /// A transport and the client that owns its inbound stream.
    private struct Session {
        let transport: any MCPMessageTransport
        let client: MCPUpstreamClient
    }

    /// An unsolicited transport loss reported on `serverEvents`.
    private struct TransportLoss {
        let reason: String
        let stderrTail: String?
    }

    /// `HeaderMismatch`: the request headers do not match the tool's
    /// current `x-mcp-header` declarations.
    private static let headerMismatchCode = -32020

    // MARK: - State

    nonisolated let serverID: MCPServerID

    private let transportFactory: @Sendable (MCPTransportVariant) async throws -> any MCPMessageTransport
    private let handshakeOrder: MCPHandshakeOrder
    private let knownEra: MCPProtocolEra?
    private let configuration: Configuration
    private let clock: any MCPClock
    private let elicitationPresenter: any MCPElicitationPresenting

    private let eventsStream: AsyncStream<MCPServerEvent>
    private let eventsContinuation: AsyncStream<MCPServerEvent>.Continuation

    /// `.disabled` until `start()`.
    private var currentState: MCPConnectionState = .disabled
    /// The tool list from the most recent successful `tools/list`.
    private var cachedTools: [MCPToolDefinition] = []
    private var session: Session?
    private var runTask: Task<Void, Never>?
    /// Crashes since the last `start()`, `enable()`, `retryFromFailed()`
    /// or successful `endAuthorization`. Reaching `.ready` does not reset it.
    private var crashCount = 0

    // MARK: - Init

    init(
        serverID: MCPServerID,
        transportFactory: @escaping @Sendable (MCPTransportVariant) async throws -> any MCPMessageTransport,
        handshakeOrder: MCPHandshakeOrder,
        knownEra: MCPProtocolEra?,
        configuration: Configuration,
        clock: any MCPClock = SystemMCPClock(),
        elicitationPresenter: any MCPElicitationPresenting
    ) {
        self.serverID = serverID
        self.transportFactory = transportFactory
        self.handshakeOrder = handshakeOrder
        self.knownEra = knownEra
        self.configuration = configuration
        self.clock = clock
        self.elicitationPresenter = elicitationPresenter
        let (stream, continuation) = AsyncStream<MCPServerEvent>.makeStream()
        self.eventsStream = stream
        self.eventsContinuation = continuation
    }

    deinit {
        runTask?.cancel()
        eventsContinuation.finish()
    }

    // MARK: - Lifecycle

    /// Starts connecting from `.disabled`. Returns once `.connecting` is
    /// entered; the handshake continues in the background.
    func start() async {
        guard case .disabled = currentState else { return }
        launch()
    }

    /// Closes the transport, enters `.disabled` and finishes `events`.
    func stop() async {
        await shutDown()
        eventsContinuation.finish()
    }

    /// From `.failed`, connects again.
    func retryFromFailed() async {
        guard case .failed = currentState else { return }
        launch()
    }

    /// From any state, closes the transport and enters `.disabled`.
    func disable() async {
        await shutDown()
    }

    /// From `.disabled`, connects as `start()` does.
    func enable() async {
        guard case .disabled = currentState else { return }
        launch()
    }

    /// From `.needsAuthorization`, enters `.authorizing`.
    func beginAuthorization() async {
        guard case .needsAuthorization = currentState else { return }
        transition(to: .authorizing)
    }

    /// From `.authorizing`, connects again on a new transport when
    /// `succeeded`, or returns to `.needsAuthorization`.
    func endAuthorization(succeeded: Bool) async {
        guard case .authorizing = currentState else { return }
        if succeeded {
            launch()
        } else {
            transition(to: .needsAuthorization)
        }
    }

    // MARK: - MCPUpstreamConnecting

    func tools() async -> [MCPToolDefinition] {
        cachedTools
    }

    func state() async -> MCPConnectionState {
        currentState
    }

    var events: AsyncStream<MCPServerEvent> {
        eventsStream
    }

    /// Calls a tool on the ready server with the cached definition's
    /// `headerMirrors`. A `-32020` reply fetches the tool list again and
    /// retries once with the refreshed `headerMirrors`; the retry's outcome
    /// is returned as is. An HTTP 401 enters `.needsAuthorization`.
    func callTool(
        name: String,
        arguments: [String: AnyCodable],
        context: MCPToolCallContext
    ) async -> MCPUpstreamClient.ToolCallOutcome {
        guard case .ready = currentState, let session else {
            return .protocolError(.transportClosed(reason: "server is not ready"))
        }
        var callContext = context
        callContext.headerMirrors = Self.headerMirrors(forTool: name, in: cachedTools)
        let outcome = await session.client.callTool(name: name, arguments: arguments, context: callContext)

        guard case .protocolError(.serverError(let error)) = outcome, error.code == Self.headerMismatchCode else {
            await requireAuthorizationIfUnauthorized(outcome, session: session)
            return outcome
        }

        let refreshed: [MCPToolDefinition]
        do {
            refreshed = try await refreshTools(session)
        } catch {
            let failure = Self.toolCallOutcome(forRefreshFailure: error)
            await requireAuthorizationIfUnauthorized(failure, session: session)
            return failure
        }
        callContext.headerMirrors = Self.headerMirrors(forTool: name, in: refreshed)
        let retried = await session.client.callTool(name: name, arguments: arguments, context: callContext)
        await requireAuthorizationIfUnauthorized(retried, session: session)
        return retried
    }

    /// `resources/read` on the ready server. An HTTP 401 enters
    /// `.needsAuthorization` and is rethrown.
    func readResource(uri: String) async throws -> [String: AnyCodable] {
        try await onReadySession { client in
            try await client.readResource(uri: uri)
        }
    }

    /// One page of `resources/list` on the ready server, as
    /// `readResource` handles failures.
    func listResources(cursor: String?) async throws -> (items: [[String: AnyCodable]], nextCursor: String?) {
        try await onReadySession { client in
            try await client.listResources(cursor: cursor)
        }
    }

    /// One page of `resources/templates/list` on the ready server.
    func listResourceTemplates(cursor: String?) async throws -> (items: [[String: AnyCodable]], nextCursor: String?) {
        try await onReadySession { client in
            try await client.listResourceTemplates(cursor: cursor)
        }
    }

    /// One page of `prompts/list` on the ready server.
    func listPrompts(cursor: String?) async throws -> (items: [[String: AnyCodable]], nextCursor: String?) {
        try await onReadySession { client in
            try await client.listPrompts(cursor: cursor)
        }
    }

    /// Runs one request on the ready session's client. Throws
    /// `.transportClosed` when not ready. An HTTP 401 enters
    /// `.needsAuthorization` and is rethrown.
    private func onReadySession<T: Sendable>(
        _ perform: @Sendable (MCPUpstreamClient) async throws -> T
    ) async throws -> T {
        guard case .ready = currentState, let session else {
            throw MCPClientProtocolError.transportClosed(reason: "server is not ready")
        }
        do {
            return try await perform(session.client)
        } catch {
            if Self.isUnauthorized(error) {
                await requireAuthorization(session: session)
            }
            throw error
        }
    }

    // MARK: - Supervision

    /// Enters `.connecting` and starts a new supervised run.
    private func launch() {
        crashCount = 0
        transition(to: .connecting)
        runTask = Task { await self.run() }
    }

    /// Cancels the run, closes the transport and enters `.disabled`.
    private func shutDown() async {
        runTask?.cancel()
        runTask = nil
        let ending = session
        session = nil
        transition(to: .disabled)
        await ending?.transport.close()
    }

    private func run() async {
        while true {
            guard let session = await connect() else { return }
            guard let loss = await serve(session) else { return }

            await end(session)
            guard !Task.isCancelled else { return }
            crashCount += 1
            if crashCount >= configuration.maxCrashesBeforeFailed {
                transition(to: .failed(MCPConnectionFailure(reason: loss.reason, stderrTail: loss.stderrTail)))
                return
            }
            let delay = min(configuration.backoffCapSeconds, pow(2, Double(crashCount - 1)))
            transition(to: .restarting(attempt: crashCount, after: delay))
            await clock.sleep(for: delay)
            guard !Task.isCancelled else { return }
            transition(to: .connecting)
        }
    }

    /// Runs one connection attempt from `.connecting`. Returns the session
    /// once `.ready` is entered; nil when the attempt ended in another state
    /// or the run was cancelled.
    private func connect() async -> Session? {
        do {
            let (session, negotiated) = try await negotiateSession()
            let tools = try await fetchTools(session.client)
            if case .modern = negotiated {
                try await session.client.subscribeToSubscriptions(
                    filter: MCPUpstreamClient.MCPSubscriptionFilter(toolsListChanged: true)
                )
            }
            guard !Task.isCancelled else { return nil }
            cachedTools = tools
            transition(to: .ready(serverInfo(for: negotiated), toolCount: tools.count))
            return session
        } catch {
            guard !Task.isCancelled else { return nil }
            if let session = self.session {
                await end(session)
                guard !Task.isCancelled else { return nil }
            }
            if Self.isUnauthorized(error) {
                transition(to: .needsAuthorization)
            } else {
                transition(to: .failed(MCPConnectionFailure(reason: String(describing: error), stderrTail: nil)))
            }
            return nil
        }
    }

    /// Opens a session and negotiates on it, switching to the legacy
    /// HTTP+SSE transport when the server requires it.
    private func negotiateSession() async throws -> (Session, MCPNegotiatedEra) {
        let standard = try await openSession(.standard)
        do {
            return (standard, try await standard.client.negotiate(order: handshakeOrder, knownEra: knownEra))
        } catch MCPNegotiationError.legacySSERequired {
            await end(standard)
            guard !Task.isCancelled else { throw CancellationError() }
            let legacySSE = try await openSession(.legacySSE)
            return (legacySSE, try await legacySSE.client.negotiate(order: .initializeFirst, knownEra: nil))
        }
    }

    /// Builds a transport and its client and makes them the current session.
    private func openSession(_ variant: MCPTransportVariant) async throws -> Session {
        let transport = try await transportFactory(variant)
        guard !Task.isCancelled else {
            await transport.close()
            throw CancellationError()
        }
        let client = MCPUpstreamClient(
            transport: transport,
            configuration: configuration.client,
            elicitationPresenter: elicitationPresenter,
            clock: clock
        )
        let opened = Session(transport: transport, client: client)
        session = opened
        return opened
    }

    /// Consumes `serverEvents` while ready. Returns the loss when the
    /// transport was lost without `close()`; nil when the stream ended
    /// otherwise or the run was cancelled.
    private func serve(_ session: Session) async -> TransportLoss? {
        for await event in session.client.serverEvents {
            switch event {
            case .notification(let method, _):
                guard method == "notifications/tools/list_changed" else { continue }
                do {
                    _ = try await refreshTools(session)
                } catch {
                    // No caller awaits this refresh. HTTP 401 changes the
                    // state; any other failure keeps the previous tool list.
                    if Self.isUnauthorized(error) {
                        await requireAuthorization(session: session)
                        return nil
                    }
                }
            case .closed(let reason, _, let stderrTail):
                guard !Task.isCancelled else { return nil }
                return TransportLoss(
                    reason: reason,
                    stderrTail: stderrTail.map { String(decoding: $0, as: UTF8.self) }
                )
            }
        }
        return nil
    }

    /// Closes `ended`, and forgets it when it is still the current session.
    private func end(_ ended: Session) async {
        if session?.client === ended.client {
            session = nil
        }
        await ended.transport.close()
    }

    /// Enters `.needsAuthorization` when `session` is still current:
    /// cancels the run and closes the transport.
    private func requireAuthorization(session ending: Session) async {
        guard session?.client === ending.client else { return }
        runTask?.cancel()
        runTask = nil
        session = nil
        transition(to: .needsAuthorization)
        await ending.transport.close()
    }

    private func requireAuthorizationIfUnauthorized(
        _ outcome: MCPUpstreamClient.ToolCallOutcome,
        session: Session
    ) async {
        guard case .protocolError(.transport(let signal)) = outcome, signal.httpStatus == 401 else { return }
        await requireAuthorization(session: session)
    }

    // MARK: - Tools

    /// Every page of `tools/list`. An empty-string `nextCursor` is followed.
    private func fetchTools(_ client: MCPUpstreamClient) async throws -> [MCPToolDefinition] {
        var tools: [MCPToolDefinition] = []
        var cursor: String?
        repeat {
            let page = try await client.listTools(cursor: cursor)
            tools.append(contentsOf: page.tools)
            cursor = page.nextCursor
        } while cursor != nil
        return tools
    }

    /// Fetches the tool list again. When `session` is still current, the
    /// cache and the ready state's tool count are replaced and
    /// `.toolsChanged` is emitted.
    private func refreshTools(_ session: Session) async throws -> [MCPToolDefinition] {
        let tools = try await fetchTools(session.client)
        guard self.session?.client === session.client, case .ready(let info, _) = currentState else {
            return tools
        }
        cachedTools = tools
        transition(to: .ready(info, toolCount: tools.count))
        eventsContinuation.yield(.toolsChanged)
        return tools
    }

    /// A tool absent from `tools` declares no `x-mcp-header` properties.
    private static func headerMirrors(forTool name: String, in tools: [MCPToolDefinition]) -> [MCPHTTPHeaderMirror] {
        tools.first { $0.name == name }?.headerMirrors ?? []
    }

    // MARK: - State

    private func transition(to newState: MCPConnectionState) {
        guard newState != currentState else { return }
        currentState = newState
        eventsContinuation.yield(.stateChanged(newState))
    }

    private func serverInfo(for negotiated: MCPNegotiatedEra) -> MCPServerInfo {
        switch negotiated {
        case .legacy(let version, let result):
            return MCPServerInfo(negotiatedEra: version, serverInfo: result.serverInfo, instructions: result.instructions)
        case .modern(let result):
            return MCPServerInfo(
                negotiatedEra: .v2026_07_28,
                serverInfo: result.serverInfo,
                instructions: result.instructions
            )
        }
    }

    // MARK: - Errors

    /// HTTP 401 from the handshake or from a request.
    private static func isUnauthorized(_ error: any Error) -> Bool {
        if let negotiationError = error as? MCPNegotiationError,
           case .authorizationRequired = negotiationError {
            return true
        }
        if let protocolError = error as? MCPClientProtocolError,
           case .transport(let signal) = protocolError {
            return signal.httpStatus == 401
        }
        return false
    }

    /// The outcome of a `-32020` call whose tool list refresh failed.
    private static func toolCallOutcome(forRefreshFailure error: any Error) -> MCPUpstreamClient.ToolCallOutcome {
        if let protocolError = error as? MCPClientProtocolError {
            return .protocolError(protocolError)
        }
        if error is CancellationError {
            // The client reports both a cancelled Task and a transport
            // closed by its owner as `CancellationError`.
            return .cancelled(reason: Task.isCancelled ? .agentCancelled : .hostShutdown)
        }
        return .protocolError(.malformedReply("tools/list reply is malformed: \(error)"))
    }
}
