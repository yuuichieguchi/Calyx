//
//  MCPUpstreamClient.swift
//  Calyx
//
//  JSON-RPC client for one upstream MCP server over one
//  `MCPMessageTransport`. The single owner of the handshake and era
//  detection, and the only subscriber of `transport.inbound`.
//
//  Requests:
//    - Ids are integers allocated here. A reply is matched to its request
//      by id; `0` is never allocated but would match like any other id.
//    - Each request other than `tools/call` waits at most `requestTimeout`
//      on the injected clock. `tools/call` has no timer: it ends with the
//      server's reply, cancellation of the awaiting Task, or the loss of
//      the transport. A timeout or cancellation of the awaiting Task calls
//      `transport.cancel(requestID:reason:)` before the result is settled.
//    - Modern-era requests carry the `io.modelcontextprotocol/*` `_meta`
//      keys. Legacy-era requests carry `_meta.progressToken` only, and
//      only when the call has a progress handler.
//
//  Inbound messages are handled one at a time in arrival order:
//    - replies settle their pending request;
//    - `ping` is answered with `{}`; `elicitation/create` is presented
//      and answered; any other server request gets `-32601`;
//    - `notifications/progress`, `notifications/elicitation/complete` and
//      `notifications/subscriptions/acknowledged` are consumed here;
//      every other notification goes to `serverEvents`;
//    - `.error` fails every pending request with `.transport(signal)`;
//    - `.closed` fails every pending and later request with
//      `.transportClosed(reason:)` and is forwarded once on `serverEvents`.
//      When `inbound` finishes without `.closed` (the owner closed the
//      transport), pending and later calls end as `.hostShutdown`.
//

import Foundation

actor MCPUpstreamClient {

    struct Configuration: Sendable {
        let clientInfo: MCPImplementation
        let requestTimeout: TimeInterval
        let serverDisplayName: String
        /// Resends allowed per `tools/call` in answer to `input_required`.
        let maxMRTRRounds: Int
    }

    enum ToolCallOutcome: Sendable {
        case result(MCPCallToolResult)
        case protocolError(MCPClientProtocolError)
        case cancelled(reason: MCPCancellationReason)
    }

    /// The `notifications` param of `subscriptions/listen`. Each type is
    /// opt-in: the server does not send a type that is not requested.
    struct MCPSubscriptionFilter: Sendable, Equatable {
        var toolsListChanged: Bool = true
        var resourcesListChanged: Bool = false
        var promptsListChanged: Bool = false
        var resourceSubscriptions: [String] = []
    }

    // MARK: - Private Types

    /// How one request ended.
    private enum Reply: Sendable {
        case result(AnyCodable)
        case error(JSONRPCError)
        case transportError(MCPTransportSignal)
        case timeout
        case cancelled
        case transportLost(reason: String)
        case transportShutDown
        /// The request could not be encoded; nothing was sent.
        case encodingFailed(String)
    }

    private struct PendingRequest {
        /// `subscriptions/listen`: settled by the acknowledged notification.
        /// A success reply only ends the stream and is not an acknowledgement.
        let awaitsAcknowledgement: Bool
        /// A reply that arrived before the waiter attached.
        var reply: Reply?
        var waiter: CheckedContinuation<Reply, Never>?
    }

    private enum Termination {
        /// The transport yielded `.closed`.
        case lost(reason: String)
        /// `inbound` finished without `.closed`.
        case shutDown

        var reply: Reply {
            switch self {
            case .lost(let reason): .transportLost(reason: reason)
            case .shutDown: .transportShutDown
            }
        }
    }

    /// A decoded `elicitation/create` request.
    private struct ElicitationPrompt {
        let request: MCPElicitationRequest
        /// The 2025-11-25 URL-mode id matched by `notifications/elicitation/complete`.
        let elicitationId: String?

        var isForm: Bool {
            if case .form = request.mode { return true }
            return false
        }
    }

    private enum HandshakeProbe {
        case negotiated(MCPNegotiatedEra)
        /// nil when the reply was a result that did not decode as expected.
        case failed(MCPClientProtocolError?)

        var failure: MCPClientProtocolError? {
            if case .failed(let error) = self { return error }
            return nil
        }
    }

    private struct ToolsPage: Decodable {
        let tools: [[String: AnyCodable]]
        let nextCursor: String?
    }

    private struct ResourcesPage: Decodable {
        let resources: [[String: AnyCodable]]
        let nextCursor: String?
    }

    private struct ResourceTemplatesPage: Decodable {
        let resourceTemplates: [[String: AnyCodable]]
        let nextCursor: String?
    }

    private struct PromptsPage: Decodable {
        let prompts: [[String: AnyCodable]]
        let nextCursor: String?
    }

    // MARK: - State

    nonisolated let serverEvents: AsyncStream<MCPClientServerEvent>
    private let serverEventsContinuation: AsyncStream<MCPClientServerEvent>.Continuation

    private let transport: any MCPMessageTransport
    private let configuration: Configuration
    private let elicitationPresenter: any MCPElicitationPresenting
    private let clock: any MCPClock

    private var era: MCPProtocolEra?
    private var termination: Termination?
    private var nextRequestID = 1
    private var nextProgressToken = 1
    private var pending: [Int: PendingRequest] = [:]
    private var progressSinks: [Int: AsyncStream<MCPProgressUpdate>.Continuation] = [:]
    /// URL-mode `elicitationId` to the presentation it belongs to. An entry
    /// is removed when its completion notification arrives, or when the
    /// user does not accept.
    private var urlElicitations: [String: MCPElicitationID] = [:]

    // MARK: - Init

    init(
        transport: any MCPMessageTransport,
        configuration: Configuration,
        elicitationPresenter: any MCPElicitationPresenting,
        clock: any MCPClock = SystemMCPClock()
    ) {
        self.transport = transport
        self.configuration = configuration
        self.elicitationPresenter = elicitationPresenter
        self.clock = clock
        let (stream, continuation) = AsyncStream<MCPClientServerEvent>.makeStream()
        self.serverEvents = stream
        self.serverEventsContinuation = continuation

        // The loop holds the client weakly so dropping the client stops it.
        let inbound = transport.inbound
        Task { [weak self] in
            for await element in inbound {
                guard let self else { return }
                await self.receive(element)
            }
            await self?.inboundFinished()
        }
    }

    // MARK: - Handshake

    /// Detects the era and completes its handshake.
    ///
    /// A non-nil `knownEra` is tried first; if it fails, `order` runs as
    /// usual, without resending a probe identical to the one that failed.
    /// `.initializeFirst` sends `initialize`, then `server/discover` on any
    /// failure. `.discoverFirst` sends `server/discover`, then `initialize`
    /// when discover failed with HTTP 400/404/405 or a JSON-RPC error;
    /// `initialize` failing with HTTP 400/404/405 as well throws
    /// `.legacySSERequired`. HTTP 401 at any step throws
    /// `.authorizationRequired` without sending anything further.
    /// A legacy result is followed by `notifications/initialized`.
    ///
    /// Before each probe the transport is given the version that probe
    /// speaks (the requested legacy version before `initialize`,
    /// 2026-07-28 before `server/discover`), and once the era is decided,
    /// the negotiated version, before `notifications/initialized`.
    func negotiate(order: MCPHandshakeOrder, knownEra: MCPProtocolEra?) async throws -> MCPNegotiatedEra {
        var initializeProbes: [MCPProtocolVersion: HandshakeProbe] = [:]
        var discoverProbe: HandshakeProbe?

        switch knownEra {
        case .legacy(let version):
            let probe = try await probeInitialize(version: version)
            if case .negotiated(let negotiated) = probe { return try await complete(negotiated) }
            initializeProbes[version] = probe
        case .modern:
            let probe = try await probeDiscover()
            if case .negotiated(let negotiated) = probe { return try await complete(negotiated) }
            discoverProbe = probe
        case nil:
            break
        }

        let initializeVersion = MCPClientPayload.latestLegacyVersion
        switch order {
        case .initializeFirst:
            let initialize: HandshakeProbe
            if let tried = initializeProbes[initializeVersion] {
                initialize = tried
            } else {
                initialize = try await probeInitialize(version: initializeVersion)
            }
            if case .negotiated(let negotiated) = initialize { return try await complete(negotiated) }

            let discover: HandshakeProbe
            if let tried = discoverProbe {
                discover = tried
            } else {
                discover = try await probeDiscover()
            }
            if case .negotiated(let negotiated) = discover { return try await complete(negotiated) }
            throw MCPNegotiationError.handshakeFailed(initialize: initialize.failure, discover: discover.failure)

        case .discoverFirst:
            let discover: HandshakeProbe
            if let tried = discoverProbe {
                discover = tried
            } else {
                discover = try await probeDiscover()
            }
            if case .negotiated(let negotiated) = discover { return try await complete(negotiated) }
            guard Self.discoverFailureFallsBackToInitialize(discover.failure) else {
                throw MCPNegotiationError.handshakeFailed(initialize: nil, discover: discover.failure)
            }

            let initialize: HandshakeProbe
            if let tried = initializeProbes[initializeVersion] {
                initialize = tried
            } else {
                initialize = try await probeInitialize(version: initializeVersion)
            }
            if case .negotiated(let negotiated) = initialize { return try await complete(negotiated) }
            if case .transport(let signal)? = initialize.failure, Self.isNonModernHTTPStatus(signal.httpStatus) {
                throw MCPNegotiationError.legacySSERequired
            }
            throw MCPNegotiationError.handshakeFailed(initialize: initialize.failure, discover: discover.failure)
        }
    }

    // MARK: - Requests

    /// Calls a tool, answering `input_required` rounds (MRTR) until the
    /// server returns a final result.
    func callTool(
        name: String,
        arguments: [String: AnyCodable],
        context: MCPToolCallContext
    ) async -> ToolCallOutcome {
        guard let progress = context.progress else {
            return await runToolCall(name: name, arguments: arguments, context: context, progressToken: nil)
        }

        let token = nextProgressToken
        nextProgressToken += 1
        let (updates, sink) = AsyncStream<MCPProgressUpdate>.makeStream()
        progressSinks[token] = sink

        // Updates are delivered in order by one child task, so a slow
        // handler never stalls the inbound loop. The group returns only
        // after every update received during the call has been delivered.
        return await withTaskGroup(of: Void.self, returning: ToolCallOutcome.self) { group in
            group.addTask {
                for await update in updates {
                    await progress(update)
                }
            }
            let outcome = await runToolCall(name: name, arguments: arguments, context: context, progressToken: token)
            progressSinks[token] = nil
            sink.finish()
            return outcome
        }
    }

    /// `resources/read`. Returns the result object as received.
    func readResource(uri: String) async throws -> [String: AnyCodable] {
        var params = requestMeta(includeRoots: false, progressToken: nil)
        params["uri"] = AnyCodable(uri)
        let result = try Self.requireResult(await request(method: "resources/read", params: params))
        return try MCPClientPayload.decode([String: AnyCodable].self, from: result)
    }

    /// One page of `tools/list`. The caller follows `nextCursor`.
    func listTools(cursor: String?) async throws -> (tools: [MCPToolDefinition], nextCursor: String?) {
        var params = requestMeta(includeRoots: false, progressToken: nil)
        if let cursor {
            params["cursor"] = AnyCodable(cursor)
        }
        let result = try Self.requireResult(await request(method: "tools/list", params: params))
        let page = try MCPClientPayload.decode(ToolsPage.self, from: result)
        return (try page.tools.map(MCPToolDefinition.init(raw:)), page.nextCursor)
    }

    /// One page of `resources/list`, items as received. The caller follows
    /// `nextCursor`.
    func listResources(cursor: String?) async throws -> (items: [[String: AnyCodable]], nextCursor: String?) {
        let result = try await listPage(method: "resources/list", cursor: cursor)
        let page = try MCPClientPayload.decode(ResourcesPage.self, from: result)
        return (page.resources, page.nextCursor)
    }

    /// One page of `resources/templates/list`, items as received.
    func listResourceTemplates(cursor: String?) async throws -> (items: [[String: AnyCodable]], nextCursor: String?) {
        let result = try await listPage(method: "resources/templates/list", cursor: cursor)
        let page = try MCPClientPayload.decode(ResourceTemplatesPage.self, from: result)
        return (page.resourceTemplates, page.nextCursor)
    }

    /// One page of `prompts/list`, items as received.
    func listPrompts(cursor: String?) async throws -> (items: [[String: AnyCodable]], nextCursor: String?) {
        let result = try await listPage(method: "prompts/list", cursor: cursor)
        let page = try MCPClientPayload.decode(PromptsPage.self, from: result)
        return (page.prompts, page.nextCursor)
    }

    /// The result of one paginated list request, with `cursor` when non-nil.
    private func listPage(method: String, cursor: String?) async throws -> AnyCodable {
        var params = requestMeta(includeRoots: false, progressToken: nil)
        if let cursor {
            params["cursor"] = AnyCodable(cursor)
        }
        return try Self.requireResult(await request(method: method, params: params))
    }

    /// Opens a `subscriptions/listen` stream and returns once the server
    /// sends `notifications/subscriptions/acknowledged` for it. The wait
    /// for the acknowledgement is bounded by `requestTimeout`.
    func subscribeToSubscriptions(filter: MCPSubscriptionFilter) async throws {
        var params = requestMeta(includeRoots: false, progressToken: nil)
        params["notifications"] = AnyCodable([
            "toolsListChanged": AnyCodable(filter.toolsListChanged),
            "resourcesListChanged": AnyCodable(filter.resourcesListChanged),
            "promptsListChanged": AnyCodable(filter.promptsListChanged),
            "resourceSubscriptions": AnyCodable(filter.resourceSubscriptions.map { AnyCodable($0) }),
        ])
        _ = try Self.requireResult(
            await request(method: "subscriptions/listen", params: params, awaitsAcknowledgement: true)
        )
    }

    // MARK: - Handshake Steps

    private func probeInitialize(version: MCPProtocolVersion) async throws -> HandshakeProbe {
        await transport.setNegotiatedProtocolVersion(version)
        let params = MCPClientPayload.initializeParams(version: version, clientInfo: configuration.clientInfo)
        let reply = await request(method: "initialize", params: params)
        switch reply {
        case .result(let value):
            let result: MCPInitializeResult
            do {
                result = try MCPClientPayload.decode(MCPInitializeResult.self, from: value)
            } catch {
                return .failed(nil)
            }
            guard let negotiated = MCPProtocolVersion(rawValue: result.protocolVersion), !negotiated.isModern else {
                return .failed(nil)
            }
            return .negotiated(.legacy(version: negotiated, result: result))
        case .error(let error):
            if let supported = Self.modernSupportedVersions(in: error) {
                return .negotiated(.modern(
                    result: MCPClientPayload.discoverResultFromUnsupportedVersionError(supportedVersions: supported)
                ))
            }
            return .failed(.serverError(error))
        default:
            return .failed(try Self.handshakeFailure(reply))
        }
    }

    private func probeDiscover() async throws -> HandshakeProbe {
        await transport.setNegotiatedProtocolVersion(.v2026_07_28)
        let params: [String: AnyCodable] = [
            "_meta": AnyCodable(MCPClientPayload.modernMeta(
                clientInfo: configuration.clientInfo,
                includeRoots: false,
                progressToken: nil
            )),
        ]
        let reply = await request(method: "server/discover", params: params)
        switch reply {
        case .result(let value):
            do {
                return .negotiated(.modern(result: try MCPClientPayload.decode(MCPDiscoverResult.self, from: value)))
            } catch {
                return .failed(nil)
            }
        case .error(let error):
            return .failed(.serverError(error))
        default:
            return .failed(try Self.handshakeFailure(reply))
        }
    }

    /// Records the era, gives the transport the negotiated version and, for
    /// a legacy result, sends `notifications/initialized`.
    private func complete(_ negotiated: MCPNegotiatedEra) async throws -> MCPNegotiatedEra {
        switch negotiated {
        case .legacy(let version, _):
            era = .legacy(version)
            await transport.setNegotiatedProtocolVersion(version)
            let notification = try JSONRPCMessage.notification(method: "notifications/initialized", params: nil).serialize()
            try await transport.send(notification, kind: .notification)
        case .modern:
            era = .modern
            await transport.setNegotiatedProtocolVersion(.v2026_07_28)
        }
        return negotiated
    }

    /// Maps a handshake reply that is neither a result nor a JSON-RPC error.
    /// Throws for the outcomes that end the handshake without fallback.
    private static func handshakeFailure(_ reply: Reply) throws -> MCPClientProtocolError {
        switch reply {
        case .transportError(let signal):
            if signal.httpStatus == 401 {
                throw MCPNegotiationError.authorizationRequired(signal)
            }
            return .transport(signal)
        case .timeout:
            return .timeout
        case .transportLost(let reason):
            return .transportClosed(reason: reason)
        case .encodingFailed(let description):
            return .encodingFailed(description)
        case .cancelled, .transportShutDown:
            throw CancellationError()
        case .result, .error:
            preconditionFailure("results and JSON-RPC errors are handled by the probe")
        }
    }

    /// The versions in a `-32022` error's `data.supported`, when they
    /// include 2026-07-28.
    private static func modernSupportedVersions(in error: JSONRPCError) -> [String]? {
        guard error.code == -32022,
              let supported = error.data?["supported"]?.arrayValue?.compactMap(\.stringValue),
              supported.contains(MCPProtocolVersion.v2026_07_28.rawValue) else {
            return nil
        }
        return supported
    }

    private static func discoverFailureFallsBackToInitialize(_ failure: MCPClientProtocolError?) -> Bool {
        switch failure {
        case .serverError?:
            return true
        case .transport(let signal)?:
            return isNonModernHTTPStatus(signal.httpStatus)
        default:
            return false
        }
    }

    /// HTTP statuses a server without the probed endpoint answers with.
    private static func isNonModernHTTPStatus(_ status: Int?) -> Bool {
        guard let status else { return false }
        return [400, 404, 405].contains(status)
    }

    // MARK: - Tool Call

    private func runToolCall(
        name: String,
        arguments: [String: AnyCodable],
        context: MCPToolCallContext,
        progressToken: Int?
    ) async -> ToolCallOutcome {
        var retryParams: [String: AnyCodable] = [:]
        var rounds = 0

        while true {
            var params = requestMeta(includeRoots: context.cwd != nil, progressToken: progressToken)
            params["name"] = AnyCodable(name)
            params["arguments"] = AnyCodable(arguments)
            params.merge(retryParams) { _, retry in retry }

            let reply = await request(
                method: "tools/call",
                params: params,
                kind: .request(headerMirrors: context.headerMirrors),
                deadline: .none
            )
            guard case .result(let value) = reply else {
                return Self.toolCallOutcome(forFailure: reply)
            }
            guard let object = value.objectValue else {
                return .protocolError(.malformedReply("tools/call result is not an object"))
            }
            guard object["resultType"]?.stringValue == "input_required" else {
                return .result(MCPCallToolResult(raw: object))
            }
            guard rounds < configuration.maxMRTRRounds else {
                return .protocolError(.mrtrRoundLimitExceeded)
            }

            let inputRequired: MCPInputRequiredResult
            do {
                inputRequired = try MCPClientPayload.decode(MCPInputRequiredResult.self, from: value)
            } catch {
                return .protocolError(.malformedReply("tools/call input_required result is malformed: \(error)"))
            }
            let inputRequests = (inputRequired.inputRequests ?? [:]).sorted { $0.key < $1.key }
            if inputRequests.contains(where: { $0.value.method == "sampling/createMessage" }) {
                return .result(MCPCallToolResult(raw: MCPClientPayload.samplingUnsupportedResult))
            }

            var inputResponses: [String: AnyCodable] = [:]
            for (key, inputRequest) in inputRequests {
                switch inputRequest.method {
                case "elicitation/create":
                    guard let prompt = elicitationPrompt(from: inputRequest.params, surfaceID: context.surfaceID) else {
                        return .protocolError(.malformedReply(
                            "input request \(key) has invalid elicitation/create params"
                        ))
                    }
                    let response = await present(prompt)
                    inputResponses[key] = MCPClientPayload.elicitResult(response, isForm: prompt.isForm)
                case "roots/list":
                    // Without a cwd there is no root to report; the entry is
                    // left unanswered.
                    if let cwd = context.cwd {
                        inputResponses[key] = MCPClientPayload.listRootsResult(cwd: cwd)
                    }
                default:
                    return .protocolError(.malformedReply(
                        "input request \(key) uses unsupported method \(inputRequest.method)"
                    ))
                }
            }

            rounds += 1
            retryParams = ["inputResponses": AnyCodable(inputResponses)]
            if let requestState = inputRequired.requestState {
                retryParams["requestState"] = AnyCodable(requestState)
            }
        }
    }

    private static func toolCallOutcome(forFailure reply: Reply) -> ToolCallOutcome {
        switch reply {
        case .error(let error):
            return .protocolError(.serverError(error))
        case .transportError(let signal):
            return .protocolError(.transport(signal))
        case .timeout:
            return .protocolError(.timeout)
        case .transportLost(let reason):
            return .protocolError(.transportClosed(reason: reason))
        case .cancelled:
            return .cancelled(reason: .agentCancelled)
        case .transportShutDown:
            return .cancelled(reason: .hostShutdown)
        case .encodingFailed(let description):
            return .protocolError(.encodingFailed(description))
        case .result:
            preconditionFailure("a result is not a failure")
        }
    }

    /// The value of a successful reply, or the failure as an error.
    private static func requireResult(_ reply: Reply) throws -> AnyCodable {
        switch reply {
        case .result(let value):
            return value
        case .error(let error):
            throw MCPClientProtocolError.serverError(error)
        case .transportError(let signal):
            throw MCPClientProtocolError.transport(signal)
        case .timeout:
            throw MCPClientProtocolError.timeout
        case .transportLost(let reason):
            throw MCPClientProtocolError.transportClosed(reason: reason)
        case .encodingFailed(let description):
            throw MCPClientProtocolError.encodingFailed(description)
        case .cancelled, .transportShutDown:
            throw CancellationError()
        }
    }

    /// `params` for a request in the current era: the modern `_meta`, or a
    /// legacy `_meta` holding only `progressToken`, or nothing.
    private func requestMeta(includeRoots: Bool, progressToken: Int?) -> [String: AnyCodable] {
        switch era {
        case .modern:
            return ["_meta": AnyCodable(MCPClientPayload.modernMeta(
                clientInfo: configuration.clientInfo,
                includeRoots: includeRoots,
                progressToken: progressToken
            ))]
        case .legacy, nil:
            guard let progressToken else { return [:] }
            return ["_meta": AnyCodable(["progressToken": AnyCodable(progressToken)])]
        }
    }

    // MARK: - Request Lifecycle

    /// Whether a request waits for its reply against `requestTimeout`.
    private enum Deadline {
        case requestTimeout
        case none
    }

    /// Sends one request and waits for how it ends.
    private func request(
        method: String,
        params: [String: AnyCodable],
        kind: MCPOutboundKind = .request(headerMirrors: []),
        awaitsAcknowledgement: Bool = false,
        deadline: Deadline = .requestTimeout
    ) async -> Reply {
        if let termination { return termination.reply }
        // Nothing has been sent yet, so there is nothing to cancel.
        if Task.isCancelled { return .cancelled }

        let id = nextRequestID
        nextRequestID += 1
        let payload: Data
        do {
            payload = try JSONRPCMessage.request(id: .int(id), method: method, params: params).serialize()
        } catch {
            return .encodingFailed("\(method) request could not be encoded: \(error)")
        }

        // Registered before sending: the reply can arrive while `send` is
        // suspended.
        pending[id] = PendingRequest(awaitsAcknowledgement: awaitsAcknowledgement)
        do {
            try await transport.send(payload, kind: kind)
        } catch {
            pending[id] = nil
            if let termination { return termination.reply }
            if let transportError = error as? MCPTransportError, transportError == .closed {
                return .transportLost(reason: "transport closed")
            }
            return .transportError(MCPTransportSignal(httpStatus: nil, message: "\(method) send failed: \(error)"))
        }

        let reply = await awaitReply(id: id, deadline: deadline)
        switch reply {
        case .timeout:
            await transport.cancel(requestID: .int(id), reason: "request timed out")
        case .cancelled:
            await transport.cancel(requestID: .int(id), reason: "request cancelled")
        default:
            break
        }
        return reply
    }

    /// Races the reply against cancellation of the calling Task and, for
    /// `.requestTimeout`, against `requestTimeout`. The timer is cancelled
    /// and awaited before returning, so no timer outlives its request.
    private func awaitReply(id: Int, deadline: Deadline) async -> Reply {
        let clock = self.clock
        let timeout = configuration.requestTimeout
        return await withTaskGroup(of: Void.self, returning: Reply.self) { group in
            if case .requestTimeout = deadline {
                group.addTask {
                    await clock.sleep(for: timeout)
                    guard !Task.isCancelled else { return }
                    await self.settle(id: id, with: .timeout)
                }
            }
            let reply = await withTaskCancellationHandler {
                await waitForReply(id: id)
            } onCancel: {
                Task { await self.settle(id: id, with: .cancelled) }
            }
            group.cancelAll()
            return reply
        }
    }

    private func waitForReply(id: Int) async -> Reply {
        guard let entry = pending[id] else {
            preconditionFailure("request \(id) is awaited only once, after registration")
        }
        if let reply = entry.reply {
            pending[id] = nil
            return reply
        }
        return await withCheckedContinuation { continuation in
            pending[id]?.waiter = continuation
        }
    }

    /// Settles a pending request. The first outcome wins; later ones are
    /// ignored.
    private func settle(id: Int, with reply: Reply) {
        guard var entry = pending[id], entry.reply == nil else { return }
        if let waiter = entry.waiter {
            pending[id] = nil
            waiter.resume(returning: reply)
        } else {
            entry.reply = reply
            pending[id] = entry
        }
    }

    private func settleAll(with reply: Reply) {
        for id in pending.keys {
            settle(id: id, with: reply)
        }
    }

    // MARK: - Inbound

    private func receive(_ element: MCPInbound) async {
        switch element {
        case .frame(let data):
            let message: JSONRPCMessage
            do {
                message = try JSONRPCMessage.parse(data)
            } catch {
                // A frame that is not JSON-RPC cannot be matched to a
                // request or answered; a request it belonged to ends by
                // its timeout, or a `tools/call` by cancellation or the
                // loss of the transport.
                return
            }
            await dispatch(message)
        case .error(let signal):
            // The signal carries no request id, so it fails every
            // request in flight.
            settleAll(with: .transportError(signal))
        case .closed(let reason, let exit, let stderrTail):
            guard termination == nil else { return }
            termination = .lost(reason: reason)
            settleAll(with: .transportLost(reason: reason))
            serverEventsContinuation.yield(.closed(reason: reason, exit: exit, stderrTail: stderrTail))
            serverEventsContinuation.finish()
        }
    }

    private func inboundFinished() {
        if termination == nil {
            termination = .shutDown
            settleAll(with: .transportShutDown)
        }
        serverEventsContinuation.finish()
    }

    private func dispatch(_ message: JSONRPCMessage) async {
        switch message {
        case .response(let id, let result, let error):
            handleResponse(id: id, result: result, error: error)
        case .request(let id, let method, let params):
            await handleServerRequest(id: id, method: method, params: params)
        case .notification(let method, let params):
            await handleNotification(method: method, params: params)
        case .batch(let messages):
            for message in messages {
                await dispatch(message)
            }
        }
    }

    private func handleResponse(id: JSONRPCId?, result: AnyCodable?, error: JSONRPCError?) {
        // Only integer ids are allocated; any other id belongs to no request.
        guard case .int(let requestID)? = id, let entry = pending[requestID] else { return }
        if let error {
            settle(id: requestID, with: .error(error))
            return
        }
        guard !entry.awaitsAcknowledgement else { return }
        settle(id: requestID, with: .result(result ?? .null))
    }

    private func handleServerRequest(id: JSONRPCId, method: String, params: [String: AnyCodable]?) async {
        switch method {
        case "ping":
            await sendReply(to: id, result: AnyCodable([String: AnyCodable]()))
        case "elicitation/create":
            guard let prompt = elicitationPrompt(from: params.map { AnyCodable($0) }, surfaceID: nil) else {
                await sendReply(to: id, error: JSONRPCError(code: -32602, message: "Invalid params", data: nil))
                return
            }
            // Presented off the inbound loop so replies and notifications
            // keep flowing while the user decides.
            Task {
                let response = await present(prompt)
                await sendReply(to: id, result: MCPClientPayload.elicitResult(response, isForm: prompt.isForm))
            }
        default:
            await sendReply(to: id, error: JSONRPCError(code: -32601, message: "Method not found", data: nil))
        }
    }

    private func handleNotification(method: String, params: [String: AnyCodable]?) async {
        switch method {
        case "notifications/progress":
            deliverProgress(params)
        case "notifications/elicitation/complete":
            await completeURLElicitation(params)
        case "notifications/subscriptions/acknowledged":
            acknowledgeSubscription(params)
        default:
            serverEventsContinuation.yield(.notification(method: method, params: params))
        }
    }

    private func deliverProgress(_ params: [String: AnyCodable]?) {
        guard let params else { return }
        let progress: MCPProgressNotificationParams
        do {
            progress = try MCPClientPayload.decode(MCPProgressNotificationParams.self, from: AnyCodable(params))
        } catch {
            // Without a valid token and value there is no call to route to.
            return
        }
        guard case .int(let token) = progress.progressToken, let sink = progressSinks[token] else { return }
        sink.yield(MCPProgressUpdate(progress: progress.progress, total: progress.total, message: progress.message))
    }

    private func acknowledgeSubscription(_ params: [String: AnyCodable]?) {
        guard let subscriptionID = params?["_meta"]?["io.modelcontextprotocol/subscriptionId"]?.intValue,
              pending[subscriptionID]?.awaitsAcknowledgement == true else {
            return
        }
        settle(id: subscriptionID, with: .result(params?["notifications"] ?? .null))
    }

    private func completeURLElicitation(_ params: [String: AnyCodable]?) async {
        guard let elicitationId = params?["elicitationId"]?.stringValue,
              let presentationID = urlElicitations.removeValue(forKey: elicitationId) else {
            return
        }
        await elicitationPresenter.dismiss(presentationID)
    }

    // MARK: - Elicitation

    /// Decodes `elicitation/create` params. nil when they are not a valid
    /// form or URL request.
    private func elicitationPrompt(from params: AnyCodable?, surfaceID: UUID?) -> ElicitationPrompt? {
        guard let params else { return nil }
        let decoded: MCPElicitRequestParams
        do {
            decoded = try MCPClientPayload.decode(MCPElicitRequestParams.self, from: params)
        } catch {
            return nil
        }
        let mode: MCPElicitationRequest.Mode
        switch decoded.mode {
        case nil, "form":
            mode = .form(message: decoded.message, requestedSchema: decoded.requestedSchema)
        case "url":
            guard let url = decoded.url else { return nil }
            mode = .url(message: decoded.message, url: url)
        default:
            return nil
        }
        let request = MCPElicitationRequest(
            id: MCPElicitationID(),
            serverContext: MCPElicitationRequest.ServerContext(displayName: configuration.serverDisplayName),
            surfaceID: surfaceID,
            mode: mode
        )
        let isURL: Bool
        if case .url = mode { isURL = true } else { isURL = false }
        return ElicitationPrompt(request: request, elicitationId: isURL ? decoded.elicitationId : nil)
    }

    /// Presents one elicitation. A URL-mode `elicitationId` is registered
    /// before presenting, since its completion notification can arrive
    /// while `present` is still running, and dropped unless the user
    /// accepted.
    private func present(_ prompt: ElicitationPrompt) async -> MCPElicitationResponse {
        if let elicitationId = prompt.elicitationId {
            urlElicitations[elicitationId] = prompt.request.id
        }
        let response = await elicitationPresenter.present(prompt.request)
        guard let elicitationId = prompt.elicitationId else { return response }
        if case .accept = response { return response }
        if urlElicitations[elicitationId] == prompt.request.id {
            urlElicitations[elicitationId] = nil
        }
        return response
    }

    // MARK: - Replies

    private func sendReply(to id: JSONRPCId, result: AnyCodable) async {
        let payload: Data
        do {
            payload = try JSONRPCMessage.response(id: id, result: result, error: nil).serialize()
        } catch {
            await sendReply(to: id, error: JSONRPCError(
                code: -32603,
                message: "reply could not be encoded: \(error)",
                data: nil
            ))
            return
        }
        await sendReplyPayload(payload)
    }

    private func sendReply(to id: JSONRPCId, error: JSONRPCError) async {
        let payload: Data
        do {
            payload = try JSONRPCMessage.response(id: id, result: nil, error: error).serialize()
        } catch {
            // An id, an Int code and a String message always encode.
            preconditionFailure("error reply failed to encode: \(error)")
        }
        await sendReplyPayload(payload)
    }

    /// A reply that cannot be sent is dropped: the only failure is a
    /// closed transport, which is reported through `.closed`.
    private func sendReplyPayload(_ payload: Data) async {
        do {
            try await transport.send(payload, kind: .response)
        } catch {
            return
        }
    }
}
