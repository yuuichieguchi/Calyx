//
//  StreamableHTTPMCPTransport.swift
//  Calyx
//
//  MCP Streamable HTTP transport, for both eras:
//
//  Modern (2026-07-28, `protocolVersion.isModern`):
//    - Every message is one POST carrying `MCP-Protocol-Version`,
//      `Mcp-Method`, `Mcp-Name` (for `tools/call`, `resources/read`,
//      `prompts/get`) and one `Mcp-Param-{Name}` per header mirror whose
//      argument is present. Values that are not plain header-safe ASCII
//      use the `=?base64?...?=` sentinel.
//    - `cancel(requestID:reason:)` closes that request's response stream
//      and sends nothing.
//
//  Legacy (2025-11-25 and earlier):
//    - The `Mcp-Session-Id` of the `initialize` response is echoed on
//      every later request, as is `MCP-Protocol-Version`.
//    - A 202 to `notifications/initialized` opens the standalone GET SSE
//      stream (405 means the server offers none). When that stream ends,
//      it is resumed with `Last-Event-ID` after the last `retry:` delay,
//      on the injected clock.
//    - A 404 to a request carrying the session id is session loss: that
//      request fails with `.error`, then `inbound` yields `.closed` and
//      finishes. The transport never re-initializes.
//    - `cancel(requestID:reason:)` POSTs `notifications/cancelled`;
//      `close()` sends a best-effort DELETE.
//
//  The era follows `protocolVersion`, which starts as the init value and
//  is replaced by `setNegotiatedProtocolVersion(_:)`.
//
//  Both eras:
//    - `send` returns once the response head is handled. A 2xx body
//      (JSON or SSE) is read by a per-response task and delivered as
//      `.frame`s in order.
//    - A non-2xx response whose body is a JSON-RPC response with an id is
//      the server's reply to that request and is delivered as `.frame`
//      (for example `-32020` HeaderMismatch). 401, 403 and every other
//      non-2xx response are delivered as `.error` with the status.
//    - `staticHeaders`, `headerProvider`, `on401` and
//      `on403InsufficientScope` apply to every request (see
//      `MCPHTTPAuthorizingRequester`).
//

import Foundation

actor StreamableHTTPMCPTransport: MCPMessageTransport {

    /// `notifications/cancelled` as sent by `cancel(requestID:reason:)`.
    private struct CancelledNotification: Encodable {
        let jsonrpc = "2.0"
        let method = "notifications/cancelled"
        let params: MCPCancelledNotificationParams
    }

    /// A task reading one 2xx response body.
    private struct ResponseReader {
        let requestID: JSONRPCId?
        let task: Task<Void, Never>
    }

    private static let sentinelPrefix = "=?base64?"
    private static let sentinelSuffix = "?="
    /// Methods whose target name is mirrored into `Mcp-Name`, and the
    /// `params` key it is read from.
    private static let nameSourceKeys: [String: String] = [
        "tools/call": "name",
        "prompts/get": "name",
        "resources/read": "uri",
    ]

    private let endpoint: URL
    private var protocolVersion: MCPProtocolVersion
    private let requester: MCPHTTPAuthorizingRequester
    private let clock: any MCPClock

    /// Set by `close()`. Loss of the transport is reported as `.closed`
    /// only while this is false.
    private var isCloseRequested = false
    /// Set by `close()` or by session loss. `send` throws once set.
    private var isClosed = false
    /// Legacy only: the `Mcp-Session-Id` assigned by the `initialize` response.
    private var sessionID: String?
    private var responseReaders: [UUID: ResponseReader] = [:]
    /// Legacy only: the task running the standalone GET stream.
    private var eventStreamTask: Task<Void, Never>?
    /// Legacy only: the last event ID and `retry:` delay of the standalone
    /// GET stream, kept across reconnections.
    private var eventStreamLastEventID: String?
    private var eventStreamRetryMs: Int?

    nonisolated let inbound: AsyncStream<MCPInbound>
    private let continuation: AsyncStream<MCPInbound>.Continuation

    // MARK: - Init

    init(
        endpoint: URL,
        session: MCPHTTPSession,
        protocolVersion: MCPProtocolVersion,
        staticHeaders: [String: String] = [:],
        headerProvider: (@Sendable () async throws -> String)? = nil,
        on401: (@Sendable () async throws -> Void)? = nil,
        on403InsufficientScope: (@Sendable (String?) async throws -> Void)? = nil,
        clock: any MCPClock = SystemMCPClock()
    ) {
        self.endpoint = endpoint
        self.protocolVersion = protocolVersion
        self.requester = MCPHTTPAuthorizingRequester(
            session: session,
            staticHeaders: staticHeaders,
            headerProvider: headerProvider,
            on401: on401,
            on403InsufficientScope: on403InsufficientScope
        )
        self.clock = clock
        let (stream, continuation) = AsyncStream<MCPInbound>.makeStream()
        self.inbound = stream
        self.continuation = continuation
    }

    // MARK: - MCPMessageTransport

    /// POSTs one JSON-RPC message. Throws when `data` is not JSON-RPC, when
    /// the request cannot be made, or when `headerProvider` throws.
    func send(_ data: Data, kind: MCPOutboundKind) async throws {
        guard !isClosed else { throw MCPTransportError.closed }
        let message = try JSONRPCMessage.parse(data)
        let headers = messageHeaders(for: message, kind: kind)
        let endpoint = self.endpoint
        let exchange = try await requester.perform { authorization in
            Self.makeRequest(url: endpoint, method: "POST", headers: headers, authorization: authorization, body: data)
        }
        guard !isClosed else {
            MCPHTTPAuthorizingRequester.discard(exchange.body)
            throw MCPTransportError.closed
        }

        let status = exchange.head.statusCode
        guard (200..<300).contains(status) else {
            try await handleFailure(exchange, method: Self.method(of: message), carriedSession: headers["Mcp-Session-Id"] != nil)
            return
        }

        if !protocolVersion.isModern, case .request(_, "initialize", _) = message {
            sessionID = exchange.head.headerValue("Mcp-Session-Id")
        }
        startReading(exchange, requestID: Self.requestID(of: message))
        if !protocolVersion.isModern, case .notification("notifications/initialized", _) = message {
            openEventStream()
        }
    }

    /// Modern: cancels the task reading the request's response, which
    /// closes its stream. Legacy: POSTs `notifications/cancelled`; a
    /// failure to encode or send it, and its response, are dropped, since
    /// an `.error` here would read as a failure of every request in flight.
    func cancel(requestID: JSONRPCId, reason: String?) async {
        guard !isClosed else { return }
        guard !protocolVersion.isModern else {
            for (readerID, reader) in responseReaders where reader.requestID == requestID {
                reader.task.cancel()
                responseReaders[readerID] = nil
            }
            return
        }
        let notification = CancelledNotification(
            params: MCPCancelledNotificationParams(requestId: requestID, reason: reason)
        )
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .withoutEscapingSlashes
            let payload = try encoder.encode(notification)
            let message = try JSONRPCMessage.parse(payload)
            let headers = messageHeaders(for: message, kind: .notification)
            let endpoint = self.endpoint
            let exchange = try await requester.perform { authorization in
                Self.makeRequest(url: endpoint, method: "POST", headers: headers, authorization: authorization, body: payload)
            }
            MCPHTTPAuthorizingRequester.discard(exchange.body)
        } catch {
            return
        }
    }

    /// Finishes `inbound` directly and stops every response and event
    /// stream. Legacy: then sends DELETE with the session id; the result
    /// is ignored because the session is abandoned either way. Idempotent.
    func close() async {
        guard !isCloseRequested else { return }
        isCloseRequested = true
        isClosed = true
        continuation.finish()
        stopReading()

        guard !protocolVersion.isModern, let sessionID else { return }
        let endpoint = self.endpoint
        let headers = [
            "MCP-Protocol-Version": protocolVersion.rawValue,
            "Mcp-Session-Id": sessionID,
        ]
        do {
            let authorization = try await requester.authorization()
            let request = Self.makeRequest(url: endpoint, method: "DELETE", headers: headers, authorization: authorization, body: nil)
            _ = try await requester.session.send(requester.addingStaticHeaders(to: request))
        } catch {
            return
        }
    }

    /// Replaces the version that selects the era and the
    /// `MCP-Protocol-Version` value of every later request.
    func setNegotiatedProtocolVersion(_ version: MCPProtocolVersion) async {
        protocolVersion = version
    }

    // MARK: - Headers

    private func messageHeaders(for message: JSONRPCMessage, kind: MCPOutboundKind) -> [String: String] {
        var headers = [
            "Content-Type": "application/json",
            "Accept": "application/json, text/event-stream",
        ]
        guard protocolVersion.isModern else {
            if case .request(_, "initialize", _) = message {
                return headers
            }
            headers["MCP-Protocol-Version"] = protocolVersion.rawValue
            if let sessionID {
                headers["Mcp-Session-Id"] = sessionID
            }
            return headers
        }

        headers["MCP-Protocol-Version"] = protocolVersion.rawValue
        let params: [String: AnyCodable]?
        switch message {
        case .request(_, let method, let messageParams), .notification(let method, let messageParams):
            headers["Mcp-Method"] = method
            params = messageParams
            if let key = Self.nameSourceKeys[method], let name = messageParams?[key]?.stringValue {
                headers["Mcp-Name"] = Self.headerSafeValue(name)
            }
        case .response, .batch:
            params = nil
        }
        if case .request(let mirrors) = kind {
            for mirror in mirrors {
                guard let value = Self.mirroredValue(at: mirror.propertyPath, in: params?["arguments"]) else { continue }
                headers["Mcp-Param-\(mirror.headerName)"] = Self.headerSafeValue(value)
            }
        }
        return headers
    }

    /// The string form of the argument at `path`, or nil when no value is
    /// present there. Only strings, integers and booleans can be mirrored.
    private static func mirroredValue(at path: [String], in arguments: AnyCodable?) -> String? {
        var current = arguments
        for key in path {
            current = current?.objectValue?[key]
        }
        guard let value = current else { return nil }
        if let string = value.stringValue { return string }
        if let integer = value.intValue { return String(integer) }
        if let boolean = value.boolValue { return boolean ? "true" : "false" }
        return nil
    }

    /// `value` as is when it is header-safe ASCII (0x20-0x7E or tab, no
    /// leading or trailing whitespace, not itself sentinel-shaped);
    /// otherwise the Base64 sentinel form of its UTF-8 bytes.
    private static func headerSafeValue(_ value: String) -> String {
        let isVisibleASCII = value.unicodeScalars.allSatisfy { scalar in
            (0x20...0x7E).contains(scalar.value) || scalar.value == 0x09
        }
        let whitespace: Set<Character> = [" ", "\t"]
        let hasEdgeWhitespace = value.first.map(whitespace.contains) == true || value.last.map(whitespace.contains) == true
        let looksEncoded = value.hasPrefix(sentinelPrefix) && value.hasSuffix(sentinelSuffix)
        if isVisibleASCII && !hasEdgeWhitespace && !looksEncoded {
            return value
        }
        return sentinelPrefix + Data(value.utf8).base64EncodedString() + sentinelSuffix
    }

    private static func makeRequest(
        url: URL,
        method: String,
        headers: [String: String],
        authorization: String?,
        body: Data?
    ) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        if let authorization {
            request.setValue(authorization, forHTTPHeaderField: "Authorization")
        }
        request.httpBody = body
        return request
    }

    private static func method(of message: JSONRPCMessage) -> String? {
        switch message {
        case .request(_, let method, _), .notification(let method, _):
            return method
        case .response, .batch:
            return nil
        }
    }

    private static func requestID(of message: JSONRPCMessage) -> JSONRPCId? {
        guard case .request(let id, _, _) = message else { return nil }
        return id
    }

    // MARK: - Responses

    /// Delivers a non-2xx response to a POST.
    private func handleFailure(_ exchange: MCPHTTPAuthorizingRequester.Exchange, method: String?, carriedSession: Bool) async throws {
        let status = exchange.head.statusCode
        if !protocolVersion.isModern, carriedSession, status == 404 {
            MCPHTTPAuthorizingRequester.discard(exchange.body)
            loseSession()
            return
        }
        if status == 401 || status == 403 {
            MCPHTTPAuthorizingRequester.discard(exchange.body)
            continuation.yield(.error(MCPTransportSignal(
                httpStatus: status,
                message: Self.failureMessage(method: method, status: status),
                wwwAuthenticate: exchange.head.headerValue("WWW-Authenticate")
            )))
            return
        }
        var body = Data()
        for try await chunk in exchange.body {
            body.append(chunk)
        }
        guard !isClosed else { return }
        if Self.isReplyWithID(body) {
            continuation.yield(.frame(body))
            return
        }
        continuation.yield(.error(MCPTransportSignal(
            httpStatus: status,
            message: Self.failureMessage(method: method, status: status)
        )))
    }

    /// True when `body` is a JSON-RPC response carrying a request id. Any
    /// other body, including one that is not JSON-RPC, is not a reply.
    private static func isReplyWithID(_ body: Data) -> Bool {
        let message: JSONRPCMessage
        do {
            message = try JSONRPCMessage.parse(body)
        } catch {
            return false
        }
        guard case .response(.some, _, _) = message else { return false }
        return true
    }

    private static func failureMessage(method: String?, status: Int) -> String {
        "\(method ?? "message") failed with HTTP \(status)"
    }

    /// Starts the task that reads a 2xx response body. An SSE body yields
    /// one `.frame` per non-empty `message` event; any other body yields
    /// one `.frame` when it is not empty.
    private func startReading(_ exchange: MCPHTTPAuthorizingRequester.Exchange, requestID: JSONRPCId?) {
        let readerID = UUID()
        let isEventStream = exchange.head.isEventStream
        let body = exchange.body
        let task = Task { [weak self] in
            do {
                if isEventStream {
                    var parser = SSEEventParser()
                    for try await chunk in body {
                        guard let self else { return }
                        await self.deliver(parser.feed(chunk))
                    }
                } else {
                    var collected = Data()
                    for try await chunk in body {
                        collected.append(chunk)
                    }
                    if !Task.isCancelled, !collected.isEmpty {
                        await self?.deliver(frame: collected)
                    }
                }
                await self?.readerFinished(readerID, error: nil)
            } catch {
                await self?.readerFinished(readerID, error: error)
            }
        }
        responseReaders[readerID] = ResponseReader(requestID: requestID, task: task)
    }

    private func deliver(_ events: [SSEEvent]) {
        guard !isClosed else { return }
        for event in events {
            guard let frame = Self.frame(of: event) else { continue }
            continuation.yield(.frame(frame))
        }
    }

    private func deliver(frame: Data) {
        guard !isClosed else { return }
        continuation.yield(.frame(frame))
    }

    /// A reader ended. A failure other than cancellation is reported as
    /// `.error`, since the reply it carried is lost.
    private func readerFinished(_ readerID: UUID, error: (any Error)?) {
        responseReaders[readerID] = nil
        guard let error, !isClosed, !Self.isCancellation(error) else { return }
        continuation.yield(.error(MCPTransportSignal(httpStatus: nil, message: "response stream failed: \(error)")))
    }

    private static func frame(of event: SSEEvent) -> Data? {
        guard event.event == nil || event.event == "message", let data = event.data, !data.isEmpty else { return nil }
        return Data(data.utf8)
    }

    private static func isCancellation(_ error: any Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        return false
    }

    private func stopReading() {
        for reader in responseReaders.values {
            reader.task.cancel()
        }
        responseReaders.removeAll()
        eventStreamTask?.cancel()
        eventStreamTask = nil
    }

    /// Session loss: fails the request with `.error(404)`, then reports the
    /// transport as lost.
    private func loseSession() {
        guard !isClosed else { return }
        isClosed = true
        continuation.yield(.error(MCPTransportSignal(httpStatus: 404, message: "session not found")))
        continuation.yield(.closed(reason: "session not found", exit: nil, stderrTail: nil))
        continuation.finish()
        stopReading()
    }

    // MARK: - Standalone Event Stream (Legacy)

    private func openEventStream() {
        guard eventStreamTask == nil, !isClosed else { return }
        eventStreamTask = Task { [weak self] in
            await self?.runEventStream()
        }
    }

    /// Runs the standalone GET stream until it cannot be resumed. A stream
    /// that ends is resumed after the last `retry:` delay; without one it
    /// is not resumed. A failure to open the stream is reported as `.error`,
    /// except 405 (no stream offered) and 404 (session loss).
    private func runEventStream() async {
        while !Task.isCancelled, !isClosed {
            var headers = ["Accept": "text/event-stream", "MCP-Protocol-Version": protocolVersion.rawValue]
            if let sessionID { headers["Mcp-Session-Id"] = sessionID }
            if let eventStreamLastEventID { headers["Last-Event-ID"] = eventStreamLastEventID }
            let endpoint = self.endpoint
            let requestHeaders = headers

            let exchange: MCPHTTPAuthorizingRequester.Exchange
            do {
                exchange = try await requester.perform { authorization in
                    Self.makeRequest(url: endpoint, method: "GET", headers: requestHeaders, authorization: authorization, body: nil)
                }
            } catch {
                reportEventStreamFailure(error)
                return
            }
            guard !Task.isCancelled, !isClosed else {
                MCPHTTPAuthorizingRequester.discard(exchange.body)
                return
            }

            let status = exchange.head.statusCode
            guard (200..<300).contains(status) else {
                MCPHTTPAuthorizingRequester.discard(exchange.body)
                if status == 405 { return }
                if status == 404, sessionID != nil {
                    loseSession()
                    return
                }
                continuation.yield(.error(MCPTransportSignal(
                    httpStatus: status,
                    message: Self.failureMessage(method: "GET event stream", status: status),
                    wwwAuthenticate: status == 401 || status == 403 ? exchange.head.headerValue("WWW-Authenticate") : nil
                )))
                return
            }

            var parser = SSEEventParser()
            var streamError: (any Error)?
            do {
                for try await chunk in exchange.body {
                    receiveEventStream(parser.feed(chunk))
                }
            } catch {
                streamError = error
            }
            guard !Task.isCancelled, !isClosed else { return }
            guard let retryMs = eventStreamRetryMs else {
                if let streamError { reportEventStreamFailure(streamError) }
                return
            }
            await clock.sleep(for: TimeInterval(retryMs) / 1000.0)
        }
    }

    private func receiveEventStream(_ events: [SSEEvent]) {
        guard !isClosed else { return }
        for event in events {
            if let id = event.id { eventStreamLastEventID = id }
            if let retryMs = event.retryMs { eventStreamRetryMs = retryMs }
            guard let frame = Self.frame(of: event) else { continue }
            continuation.yield(.frame(frame))
        }
    }

    private func reportEventStreamFailure(_ error: any Error) {
        guard !isClosed, !Self.isCancellation(error) else { return }
        continuation.yield(.error(MCPTransportSignal(httpStatus: nil, message: "GET event stream failed: \(error)")))
    }
}

// MARK: - Authorization

/// Sends HTTP requests with the configured headers and the OAuth hooks of
/// an HTTP transport:
///   - `staticHeaders` are set on every request, except a field the
///     transport sets itself (protocol headers, and `Authorization` when
///     `headerProvider` supplies one).
///   - `headerProvider` supplies the token for `Authorization: Bearer <token>`
///     on every request; nil means the server takes no authorization.
///   - A 401 calls `on401` once, then resends once with a fresh header.
///   - A 403 whose first Bearer challenge has `error="insufficient_scope"`
///     calls `on403InsufficientScope` once with the challenge's scope,
///     then resends once.
/// When a hook is nil or throws, the 401 or 403 response is returned as
/// the result, so the transport reports it as `.error` with the status.
struct MCPHTTPAuthorizingRequester: Sendable {

    typealias Exchange = (head: MCPHTTPSession.Response, body: AsyncThrowingStream<Data, Error>)

    let session: MCPHTTPSession
    let staticHeaders: [String: String]
    let headerProvider: (@Sendable () async throws -> String)?
    let on401: (@Sendable () async throws -> Void)?
    let on403InsufficientScope: (@Sendable (String?) async throws -> Void)?

    /// The `Authorization` header value, or nil without a `headerProvider`.
    func authorization() async throws -> String? {
        guard let headerProvider else { return nil }
        return "Bearer \(try await headerProvider())"
    }

    /// `request` with every static header whose field it does not set.
    /// Field names are compared case-insensitively.
    func addingStaticHeaders(to request: URLRequest) -> URLRequest {
        var request = request
        for (name, value) in staticHeaders where request.value(forHTTPHeaderField: name) == nil {
            request.setValue(value, forHTTPHeaderField: name)
        }
        return request
    }

    func perform(_ makeRequest: @Sendable (_ authorization: String?) -> URLRequest) async throws -> Exchange {
        var hasCalledOn401 = false
        var hasCalledOn403 = false
        while true {
            let exchange = try await session.stream(addingStaticHeaders(to: makeRequest(try await authorization())))
            switch exchange.head.statusCode {
            case 401:
                guard !hasCalledOn401, let on401 else { return exchange }
                hasCalledOn401 = true
                do {
                    try await on401()
                } catch {
                    return exchange
                }
            case 403:
                guard !hasCalledOn403, let on403InsufficientScope,
                      let challenge = MCPHTTPBearerChallenge.parse(exchange.head.headerValue("WWW-Authenticate") ?? "").first,
                      challenge.error == "insufficient_scope" else {
                    return exchange
                }
                hasCalledOn403 = true
                do {
                    try await on403InsufficientScope(challenge.scope)
                } catch {
                    return exchange
                }
            default:
                return exchange
            }
            Self.discard(exchange.body)
        }
    }

    /// Stops a response body that will not be read, cancelling its task.
    static func discard(_ body: AsyncThrowingStream<Data, Error>) {
        let reader = Task {
            for try await _ in body {}
        }
        reader.cancel()
    }
}

extension MCPHTTPSession.Response {

    /// The value of the header `name`, matched case-insensitively.
    func headerValue(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    var isEventStream: Bool {
        headerValue("Content-Type")?.lowercased().hasPrefix("text/event-stream") == true
    }
}
