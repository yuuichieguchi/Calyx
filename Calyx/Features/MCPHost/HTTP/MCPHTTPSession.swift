//
//  MCPHTTPSession.swift
//  Calyx
//
//  The HTTP primitive under every MCP host HTTP transport and the OAuth
//  flow's own fetches. Applies these rules to every request, whether the
//  body is collected (`send`) or streamed (`stream`):
//    - A 3xx response is an error and its target is never fetched, so an
//      `Authorization` header cannot follow a redirect to another origin.
//    - A response body larger than `maxBodyBytes` is an error, except a
//      2xx `text/event-stream` body read through `stream`. Such a body
//      lives for the whole SSE connection, so it is unbounded as a whole
//      and instead bounded per event by `SSEEventParser`. A collected
//      (`send`) body is always capped.
//    - Plain `http://` is refused unless the host is a loopback address.
//

import Foundation
import os

actor MCPHTTPSession {

    struct Response: Sendable {
        let statusCode: Int
        let headers: [String: String]
        let body: Data
    }

    enum MCPHTTPSessionError: Error, Sendable, Equatable {
        case redirectRefused(status: Int)
        case bodyTooLarge(limit: Int)
        case insecureSchemeRefused(url: URL)
    }

    /// The default cap on a collected (`send`) body and on a streamed body
    /// that is not a 2xx `text/event-stream`. A 2xx `text/event-stream`
    /// body read through `stream` is not capped as a whole; `SSEEventParser`
    /// bounds each of its events by the same number of bytes.
    static let defaultMaxBodyBytes: Int = 64 * 1024 * 1024

    /// Hosts that may be reached over plain `http://`.
    private static let loopbackHosts: Set<String> = ["127.0.0.1", "localhost", "::1"]

    private let urlSession: URLSession
    /// The body cap in bytes; see `defaultMaxBodyBytes` for what it applies to.
    nonisolated let maxBodyBytes: Int

    // MARK: - Init

    /// `urlSession` is used as given; redirect refusal and streaming are
    /// implemented with a per-task delegate, so the session's own
    /// configuration (including `protocolClasses`) applies unchanged.
    init(urlSession: URLSession = .shared, maxBodyBytes: Int = MCPHTTPSession.defaultMaxBodyBytes) {
        self.urlSession = urlSession
        self.maxBodyBytes = maxBodyBytes
    }

    // MARK: - Requests

    /// Sends `request` and collects the whole response body. The body is
    /// capped at `maxBodyBytes` whatever its content type.
    func send(_ request: URLRequest) async throws -> Response {
        let (head, body) = try await stream(request, exemptsEventStreams: false)
        var collected = Data()
        for try await chunk in body {
            collected.append(chunk)
        }
        return Response(statusCode: head.statusCode, headers: head.headers, body: collected)
    }

    /// Sends `request` and returns once the response head arrives. `head.body`
    /// is empty; the body arrives on `body`, one element per chunk received.
    /// `body` is single-consumer. Ending its iteration early cancels the
    /// underlying task. A 2xx `text/event-stream` body is not capped as a
    /// whole; any other body is capped at `maxBodyBytes`.
    func stream(_ request: URLRequest) async throws -> (head: Response, body: AsyncThrowingStream<Data, Error>) {
        try await stream(request, exemptsEventStreams: true)
    }

    // MARK: - Private

    /// `exemptsEventStreams` lifts the body cap for a 2xx
    /// `text/event-stream` response.
    private func stream(
        _ request: URLRequest,
        exemptsEventStreams: Bool
    ) async throws -> (head: Response, body: AsyncThrowingStream<Data, Error>) {
        guard let url = request.url else { throw URLError(.badURL) }
        try Self.requireAllowedScheme(url)

        let (body, bodyContinuation) = AsyncThrowingStream<Data, Error>.makeStream()
        let delegate = MCPHTTPTaskDelegate(
            maxBodyBytes: maxBodyBytes,
            exemptsEventStreams: exemptsEventStreams,
            body: bodyContinuation
        )
        let task = urlSession.dataTask(with: request)
        task.delegate = delegate
        bodyContinuation.onTermination = { _ in task.cancel() }

        let head = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Response, Error>) in
                delegate.awaitHead(continuation)
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
        return (head, body)
    }

    private static func requireAllowedScheme(_ url: URL) throws {
        guard url.scheme?.lowercased() == "http" else { return }
        guard let host = url.host(percentEncoded: false)?.lowercased(), loopbackHosts.contains(host) else {
            throw MCPHTTPSessionError.insecureSchemeRefused(url: url)
        }
    }
}

extension MCPHTTPSession.Response {

    /// The value of the header `name`, matched case-insensitively.
    func headerValue(_ name: String) -> String? {
        Self.headerValue(name, in: headers)
    }

    var isEventStream: Bool {
        Self.isEventStream(headers: headers)
    }

    /// The value of the header `name` in `headers`, matched case-insensitively.
    static func headerValue(_ name: String, in headers: [String: String]) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    /// True when `headers` has a `Content-Type` of `text/event-stream`,
    /// with any parameters and in any case.
    static func isEventStream(headers: [String: String]) -> Bool {
        headerValue("Content-Type", in: headers)?.lowercased().hasPrefix("text/event-stream") == true
    }
}

/// Per-task delegate for one `MCPHTTPSession` request. Resumes the head
/// continuation exactly once and forwards body chunks to the body
/// continuation, enforcing the size cap across chunks unless the response
/// is an exempt event stream.
private final class MCPHTTPTaskDelegate: NSObject, URLSessionDataDelegate, Sendable {

    private struct State: Sendable {
        var head: CheckedContinuation<MCPHTTPSession.Response, Error>?
        var receivedBytes = 0
        /// Set when the response is a 2xx `text/event-stream` and
        /// `exemptsEventStreams` is true; its body is then not capped.
        var isExemptFromCap = false
    }

    private let maxBodyBytes: Int
    private let exemptsEventStreams: Bool
    private let body: AsyncThrowingStream<Data, Error>.Continuation
    private let state = OSAllocatedUnfairLock(initialState: State())

    /// `exemptsEventStreams` lifts the body cap for a 2xx
    /// `text/event-stream` response.
    init(maxBodyBytes: Int, exemptsEventStreams: Bool, body: AsyncThrowingStream<Data, Error>.Continuation) {
        self.maxBodyBytes = maxBodyBytes
        self.exemptsEventStreams = exemptsEventStreams
        self.body = body
    }

    /// Registers the head continuation. Called before the task is resumed,
    /// so no delegate callback can precede it.
    func awaitHead(_ continuation: CheckedContinuation<MCPHTTPSession.Response, Error>) {
        state.withLock { $0.head = continuation }
    }

    private func takeHead() -> CheckedContinuation<MCPHTTPSession.Response, Error>? {
        state.withLock { state in
            defer { state.head = nil }
            return state.head
        }
    }

    // MARK: - URLSessionTaskDelegate

    /// Refuses every redirect. The 3xx response is then delivered as the
    /// final response and rejected in `didReceive response`.
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if let error {
            takeHead()?.resume(throwing: error)
            body.finish(throwing: error)
        } else {
            takeHead()?.resume(throwing: URLError(.badServerResponse))
            body.finish()
        }
    }

    // MARK: - URLSessionDataDelegate

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            takeHead()?.resume(throwing: URLError(.badServerResponse))
            completionHandler(.cancel)
            return
        }
        if (300..<400).contains(http.statusCode) {
            takeHead()?.resume(throwing: MCPHTTPSession.MCPHTTPSessionError.redirectRefused(status: http.statusCode))
            completionHandler(.cancel)
            return
        }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            guard let name = key as? String, let text = value as? String else { continue }
            headers[name] = text
        }
        if exemptsEventStreams,
           (200..<300).contains(http.statusCode),
           MCPHTTPSession.Response.isEventStream(headers: headers) {
            state.withLock { $0.isExemptFromCap = true }
        }
        takeHead()?.resume(returning: MCPHTTPSession.Response(statusCode: http.statusCode, headers: headers, body: Data()))
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let limit = maxBodyBytes
        let withinLimit = state.withLock { state in
            if state.isExemptFromCap { return true }
            state.receivedBytes += data.count
            return state.receivedBytes <= limit
        }
        guard withinLimit else {
            body.finish(throwing: MCPHTTPSession.MCPHTTPSessionError.bodyTooLarge(limit: limit))
            dataTask.cancel()
            return
        }
        body.yield(data)
    }
}
