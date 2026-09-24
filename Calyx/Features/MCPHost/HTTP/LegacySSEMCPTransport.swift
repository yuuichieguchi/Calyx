//
//  LegacySSEMCPTransport.swift
//  Calyx
//
//  The 2024-11-05 HTTP+SSE transport. One GET opens a server event
//  stream whose first `endpoint` event names the URL every JSON-RPC
//  message is POSTed to. Replies and server-originated messages arrive
//  as `message` events on that stream.
//
//  Lifecycle:
//    - `openStream()` sends the GET and waits, bounded by
//      `endpointEventTimeout` on the injected clock, for the `endpoint`
//      event. The endpoint must share the scheme, host and port of
//      `sseEndpoint`. Any failure closes the transport and throws. Later
//      calls do nothing.
//    - `close()` stops the GET and finishes `inbound` without `.closed`.
//    - When the GET stream ends or fails without `close()`, `inbound`
//      yields `.closed` and finishes.
//
//  `staticHeaders` and the OAuth hooks apply to the GET and every POST
//  (see `MCPHTTPAuthorizingRequester`).
//

import Foundation

enum LegacySSEError: Error, Equatable {
    case endpointEventTimedOut
    case crossOriginEndpointRefused(URL)
}

/// `openStream()` got a non-2xx response to its GET. `signal` carries the
/// status and, for 401 and 403, the `WWW-Authenticate` value.
struct LegacySSEStreamRefused: Error, Equatable {
    let signal: MCPTransportSignal
}

actor LegacySSEMCPTransport: MCPMessageTransport {

    static let endpointEventTimeout: TimeInterval = 10

    /// `notifications/cancelled` as sent by `cancel(requestID:reason:)`.
    private struct CancelledNotification: Encodable {
        let jsonrpc = "2.0"
        let method = "notifications/cancelled"
        let params: MCPCancelledNotificationParams
    }

    private let sseEndpoint: URL
    private let requester: MCPHTTPAuthorizingRequester
    private let clock: any MCPClock

    private var hasStartedOpening = false
    /// Set by `close()`.
    private var isCloseRequested = false
    /// Set by `close()`, by a failed `openStream()`, or by loss of the GET
    /// stream. `send` throws once set.
    private var isClosed = false
    /// The URL from the `endpoint` event. Nil until `openStream()` succeeds.
    private var postEndpoint: URL?
    /// The suspended `openStream()` while it waits for the `endpoint` event.
    private var endpointWaiter: CheckedContinuation<URL, Error>?
    private var streamTask: Task<Void, Never>?

    nonisolated let inbound: AsyncStream<MCPInbound>
    private let continuation: AsyncStream<MCPInbound>.Continuation

    // MARK: - Init

    init(
        sseEndpoint: URL,
        session: MCPHTTPSession,
        staticHeaders: [String: String] = [:],
        headerProvider: (@Sendable () async throws -> String)? = nil,
        on401: (@Sendable () async throws -> Void)? = nil,
        on403InsufficientScope: (@Sendable (String?) async throws -> Void)? = nil,
        clock: any MCPClock = SystemMCPClock()
    ) {
        self.sseEndpoint = sseEndpoint
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

    // MARK: - Opening

    /// Opens the GET stream and returns once a same-origin `endpoint` event
    /// has arrived. Throws `LegacySSEError`, `LegacySSEStreamRefused`, the
    /// request's own error, or `MCPTransportError.closed` when the stream
    /// ends first or the transport is closed. A call after the first does
    /// nothing.
    func openStream() async throws {
        guard !isClosed else { throw MCPTransportError.closed }
        guard !hasStartedOpening else { return }
        hasStartedOpening = true

        let clock = self.clock
        let timeout = Task { [weak self] in
            await clock.sleep(for: Self.endpointEventTimeout)
            guard !Task.isCancelled else { return }
            await self?.failOpening(LegacySSEError.endpointEventTimedOut)
        }
        defer { timeout.cancel() }

        _ = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                endpointWaiter = continuation
                streamTask = Task { [weak self] in
                    await self?.runStream()
                }
            }
        } onCancel: {
            Task { await self.failOpening(CancellationError()) }
        }
    }

    // MARK: - MCPMessageTransport

    /// POSTs one JSON-RPC message to the discovered endpoint. The reply
    /// arrives on the GET stream. A non-2xx response is delivered as
    /// `.error` with the status.
    func send(_ data: Data, kind: MCPOutboundKind) async throws {
        guard !isClosed, let postEndpoint else { throw MCPTransportError.closed }
        let exchange = try await requester.perform { authorization in
            Self.makePOST(url: postEndpoint, authorization: authorization, body: data)
        }
        MCPHTTPAuthorizingRequester.discard(exchange.body)
        guard !isClosed else { throw MCPTransportError.closed }

        let status = exchange.head.statusCode
        guard (200..<300).contains(status) else {
            continuation.yield(.error(MCPTransportSignal(
                httpStatus: status,
                message: "POST to the message endpoint failed with HTTP \(status)",
                wwwAuthenticate: status == 401 || status == 403 ? exchange.head.headerValue("WWW-Authenticate") : nil
            )))
            return
        }
    }

    /// POSTs `notifications/cancelled`. A failure to encode or send it, and
    /// its response, are dropped, since an `.error` here would read as a
    /// failure of every request in flight.
    func cancel(requestID: JSONRPCId, reason: String?) async {
        guard !isClosed, let postEndpoint else { return }
        let notification = CancelledNotification(
            params: MCPCancelledNotificationParams(requestId: requestID, reason: reason)
        )
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .withoutEscapingSlashes
            let payload = try encoder.encode(notification)
            let exchange = try await requester.perform { authorization in
                Self.makePOST(url: postEndpoint, authorization: authorization, body: payload)
            }
            MCPHTTPAuthorizingRequester.discard(exchange.body)
        } catch {
            return
        }
    }

    /// Finishes `inbound` directly and stops the GET stream. Idempotent.
    func close() async {
        guard !isCloseRequested else { return }
        isCloseRequested = true
        tearDown()
        if let waiter = endpointWaiter {
            endpointWaiter = nil
            waiter.resume(throwing: MCPTransportError.closed)
        }
    }

    // MARK: - Event Stream

    private func runStream() async {
        let sseEndpoint = self.sseEndpoint
        let exchange: MCPHTTPAuthorizingRequester.Exchange
        do {
            exchange = try await requester.perform { authorization in
                var request = URLRequest(url: sseEndpoint)
                request.httpMethod = "GET"
                request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                if let authorization {
                    request.setValue(authorization, forHTTPHeaderField: "Authorization")
                }
                return request
            }
        } catch {
            failOpening(error)
            return
        }

        let status = exchange.head.statusCode
        guard (200..<300).contains(status) else {
            MCPHTTPAuthorizingRequester.discard(exchange.body)
            failOpening(LegacySSEStreamRefused(signal: MCPTransportSignal(
                httpStatus: status,
                message: "GET event stream failed with HTTP \(status)",
                wwwAuthenticate: status == 401 || status == 403 ? exchange.head.headerValue("WWW-Authenticate") : nil
            )))
            return
        }
        guard !isClosed else {
            MCPHTTPAuthorizingRequester.discard(exchange.body)
            return
        }

        var parser = SSEEventParser()
        var streamError: (any Error)?
        do {
            for try await chunk in exchange.body {
                receive(parser.feed(chunk))
            }
        } catch {
            streamError = error
        }
        streamEnded(error: streamError)
    }

    private func receive(_ events: [SSEEvent]) {
        for event in events {
            guard !isClosed else { return }
            switch event.event {
            case "endpoint":
                receiveEndpoint(event.data)
            case nil, "message":
                guard let data = event.data, !data.isEmpty else { continue }
                continuation.yield(.frame(Data(data.utf8)))
            default:
                continue
            }
        }
    }

    /// Resolves the endpoint against `sseEndpoint` and resumes
    /// `openStream()`. An `endpoint` event after the first is ignored.
    private func receiveEndpoint(_ data: String?) {
        guard endpointWaiter != nil else { return }
        guard let data, let url = URL(string: data, relativeTo: sseEndpoint)?.absoluteURL else {
            failOpening(URLError(.badURL))
            return
        }
        guard Self.isSameOrigin(url, sseEndpoint) else {
            failOpening(LegacySSEError.crossOriginEndpointRefused(url))
            return
        }
        postEndpoint = url
        let waiter = endpointWaiter
        endpointWaiter = nil
        waiter?.resume(returning: url)
    }

    /// The GET stream ended. Before the endpoint event this fails
    /// `openStream()`; afterwards, unless the transport was closed, it is
    /// reported as `.closed`.
    private func streamEnded(error: (any Error)?) {
        if endpointWaiter != nil {
            failOpening(error ?? MCPTransportError.closed)
            return
        }
        guard !isClosed else { return }
        let reason = error.map { "event stream failed: \($0)" } ?? "event stream ended"
        isClosed = true
        continuation.yield(.closed(reason: reason, exit: nil, stderrTail: nil))
        continuation.finish()
    }

    /// Fails a pending `openStream()` with `error` and closes the transport.
    /// Does nothing once `openStream()` has returned.
    private func failOpening(_ error: any Error) {
        guard let waiter = endpointWaiter else { return }
        endpointWaiter = nil
        tearDown()
        waiter.resume(throwing: error)
    }

    private func tearDown() {
        isClosed = true
        continuation.finish()
        streamTask?.cancel()
        streamTask = nil
    }

    // MARK: - Helpers

    private static func makePOST(url: URL, authorization: String?, body: Data) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let authorization {
            request.setValue(authorization, forHTTPHeaderField: "Authorization")
        }
        request.httpBody = body
        return request
    }

    /// Same scheme, host and port, with an absent port read as the
    /// scheme's default.
    private static func isSameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.scheme?.lowercased() == rhs.scheme?.lowercased()
            && lhs.host(percentEncoded: false)?.lowercased() == rhs.host(percentEncoded: false)?.lowercased()
            && effectivePort(of: lhs) == effectivePort(of: rhs)
    }

    private static func effectivePort(of url: URL) -> Int? {
        if let port = url.port { return port }
        switch url.scheme?.lowercased() {
        case "https": return 443
        case "http": return 80
        default: return nil
        }
    }
}
