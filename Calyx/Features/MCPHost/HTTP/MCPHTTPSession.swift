//
//  MCPHTTPSession.swift
//  Calyx
//
//  The HTTP primitive under every MCP host HTTP transport and the OAuth
//  flow's own fetches. Applies three rules to every request, whether the
//  body is collected (`send`) or streamed (`stream`):
//    - A 3xx response is an error and its target is never fetched, so an
//      `Authorization` header cannot follow a redirect to another origin.
//    - A response body larger than `maxBodyBytes` is an error.
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

    static let defaultMaxBodyBytes: Int = 64 * 1024 * 1024

    /// Hosts that may be reached over plain `http://`.
    private static let loopbackHosts: Set<String> = ["127.0.0.1", "localhost", "::1"]

    private let urlSession: URLSession
    private let maxBodyBytes: Int

    // MARK: - Init

    /// `urlSession` is used as given; redirect refusal and streaming are
    /// implemented with a per-task delegate, so the session's own
    /// configuration (including `protocolClasses`) applies unchanged.
    init(urlSession: URLSession = .shared, maxBodyBytes: Int = MCPHTTPSession.defaultMaxBodyBytes) {
        self.urlSession = urlSession
        self.maxBodyBytes = maxBodyBytes
    }

    // MARK: - Requests

    /// Sends `request` and collects the whole response body.
    func send(_ request: URLRequest) async throws -> Response {
        let (head, body) = try await stream(request)
        var collected = Data()
        for try await chunk in body {
            collected.append(chunk)
        }
        return Response(statusCode: head.statusCode, headers: head.headers, body: collected)
    }

    /// Sends `request` and returns once the response head arrives. `head.body`
    /// is empty; the body arrives on `body`, one element per chunk received.
    /// `body` is single-consumer. Ending its iteration early cancels the
    /// underlying task.
    func stream(_ request: URLRequest) async throws -> (head: Response, body: AsyncThrowingStream<Data, Error>) {
        guard let url = request.url else { throw URLError(.badURL) }
        try Self.requireAllowedScheme(url)

        let (body, bodyContinuation) = AsyncThrowingStream<Data, Error>.makeStream()
        let delegate = MCPHTTPTaskDelegate(maxBodyBytes: maxBodyBytes, body: bodyContinuation)
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

    // MARK: - Private

    private static func requireAllowedScheme(_ url: URL) throws {
        guard url.scheme?.lowercased() == "http" else { return }
        guard let host = url.host(percentEncoded: false)?.lowercased(), loopbackHosts.contains(host) else {
            throw MCPHTTPSessionError.insecureSchemeRefused(url: url)
        }
    }
}

/// Per-task delegate for one `MCPHTTPSession.stream(_:)` call. Resumes the
/// head continuation exactly once and forwards body chunks to the body
/// continuation, enforcing the size cap across chunks.
private final class MCPHTTPTaskDelegate: NSObject, URLSessionDataDelegate, Sendable {

    private struct State: Sendable {
        var head: CheckedContinuation<MCPHTTPSession.Response, Error>?
        var receivedBytes = 0
    }

    private let maxBodyBytes: Int
    private let body: AsyncThrowingStream<Data, Error>.Continuation
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(maxBodyBytes: Int, body: AsyncThrowingStream<Data, Error>.Continuation) {
        self.maxBodyBytes = maxBodyBytes
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
        takeHead()?.resume(returning: MCPHTTPSession.Response(statusCode: http.statusCode, headers: headers, body: Data()))
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let limit = maxBodyBytes
        let withinLimit = state.withLock { state in
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
