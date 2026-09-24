//
//  LoopbackRedirectListener.swift
//  Calyx
//
//  Receives the OAuth authorization response on a loopback HTTP listener
//  (RFC 8252 section 7.3). One shot: the first request on the exact path
//  ends the wait, a request on any other path is answered with 404 and
//  ignored. The listener has no timer; it ends on a callback,
//  `cancel(reason:)`, or app exit, and releases its port when it ends.
//

import Foundation
import Network
import os

struct MCPOAuthCallback: Sendable, Equatable {
    let code: String
    let state: String
    let iss: String?
}

enum MCPOAuthRedirectListenerError: Error, Sendable, Equatable {
    case stateMismatch
    case portBusy(Int)
    /// Thrown by `waitForCallback()` after `cancel(reason:)`.
    case cancelled(reason: String)
    /// The redirect carried `error` instead of `code` (RFC 6749 section 4.1.2.1).
    case authorizationServerError(error: String, description: String?)
}

actor LoopbackRedirectListener {

    /// Largest request head read from a connection before it is dropped.
    private static let maxRequestHeadBytes = 16 * 1024
    private static let logLabel = "LoopbackRedirectListener"

    private let config: MCPOAuthRedirectConfig
    private let expectedState: String
    private let path: String
    private let connectionQueue = DispatchQueue(label: "LoopbackRedirectListener.connections")

    private var listener: NWListener?
    /// Set once, by the first callback on `path` or by `cancel(reason:)`.
    private var outcome: Result<MCPOAuthCallback, MCPOAuthRedirectListenerError>?
    private var waiters: [CheckedContinuation<MCPOAuthCallback, any Error>] = []

    init(config: MCPOAuthRedirectConfig, expectedState: String, path: String = "/callback") {
        self.config = config
        self.expectedState = expectedState
        self.path = path
    }

    // MARK: - Lifecycle

    /// Binds `127.0.0.1` on the configured port. A busy fixed port throws
    /// `.portBusy(41890)` immediately. The returned host is the one the
    /// redirect URI names: `127.0.0.1` or `localhost`.
    func start() async throws -> (port: Int, host: String) {
        let bound: (NWListener, Int)?
        let requestedPort: Int
        switch config.port {
        case .calyxFixed:
            requestedPort = MCPOAuthRedirectConfig.calyxFixedPort
            bound = await LoopbackListenerBinder.bindListener(onPort: requestedPort, logLabel: Self.logLabel)
        case .random:
            requestedPort = 0
            bound = await LoopbackListenerBinder.bindKernelAssignedListener(logLabel: Self.logLabel)
        }
        guard let (boundListener, port) = bound else {
            throw MCPOAuthRedirectListenerError.portBusy(requestedPort)
        }
        if case .failure(let error) = outcome {
            await Self.shutDown(boundListener)
            throw error
        }

        let queue = connectionQueue
        boundListener.newConnectionHandler = { [weak self] connection in
            guard let self else {
                connection.cancel()
                return
            }
            Task { await Self.serve(connection, queue: queue, listener: self) }
        }
        listener = boundListener

        switch config.host {
        case .loopback:
            return (port, "127.0.0.1")
        case .localhost:
            return (port, "localhost")
        }
    }

    /// Suspends until the callback arrives or `cancel(reason:)` is called.
    /// A callback whose `state` differs throws `.stateMismatch`; an error
    /// redirect throws `.authorizationServerError`.
    func waitForCallback() async throws -> MCPOAuthCallback {
        if let outcome {
            return try outcome.get()
        }
        return try await withCheckedThrowingContinuation { continuation in
            waiters.append(continuation)
        }
    }

    /// Ends a pending wait with `.cancelled(reason:)` and releases the port
    /// before returning. After a callback has arrived it only releases the port.
    func cancel(reason: String) async {
        await finish(.failure(.cancelled(reason: reason)))
    }

    // MARK: - Private

    private enum Reply {
        case completed
        case denied
        case rejected
        case notFound
        case incomplete

        var statusLine: String {
            switch self {
            case .completed, .denied: "HTTP/1.1 200 OK"
            case .rejected, .incomplete: "HTTP/1.1 400 Bad Request"
            case .notFound: "HTTP/1.1 404 Not Found"
            }
        }

        var message: String {
            switch self {
            case .completed: "Sign-in complete. You can close this tab and return to Calyx."
            case .denied: "Sign-in was not completed. You can close this tab and return to Calyx."
            case .rejected: "Sign-in failed: this response does not belong to the sign-in Calyx started."
            case .notFound: "Not found."
            case .incomplete: "The response has neither a code nor an error."
            }
        }
    }

    /// Records the first outcome, resumes every waiter with it, and
    /// releases the port. Later outcomes only release the port.
    private func finish(_ result: Result<MCPOAuthCallback, MCPOAuthRedirectListenerError>) async {
        if outcome == nil {
            outcome = result
            let pending = waiters
            waiters = []
            for waiter in pending {
                waiter.resume(with: result.mapError { $0 as any Error })
            }
        }
        if let current = listener {
            listener = nil
            await Self.shutDown(current)
        }
    }

    /// Decides the reply to one request target and records the outcome
    /// when the target is the callback.
    private func handle(target: String) async -> Reply {
        guard outcome == nil else { return .notFound }
        // application/x-www-form-urlencoded: "+" is a space.
        guard var components = URLComponents(string: target) else { return .notFound }
        guard components.percentEncodedPath == path else { return .notFound }
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%20")
        let items = components.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value
        }
        guard let state = value("state"), state == expectedState else {
            await finish(.failure(.stateMismatch))
            return .rejected
        }
        guard let code = value("code") else {
            // RFC 6749 section 4.1.2.1 error response.
            guard let error = value("error") else {
                return .incomplete
            }
            await finish(.failure(.authorizationServerError(error: error, description: value("error_description"))))
            return .denied
        }
        await finish(.success(MCPOAuthCallback(code: code, state: state, iss: value("iss"))))
        return .completed
    }

    /// Reads one request head from `connection`, answers it, and closes it.
    private static func serve(_ connection: NWConnection, queue: DispatchQueue, listener: LoopbackRedirectListener) async {
        connection.start(queue: queue)
        guard let requestLine = await readRequestLine(connection) else {
            connection.cancel()
            return
        }
        let parts = requestLine.split(separator: " ")
        let reply: Reply
        if parts.count == 3, parts[0] == "GET" {
            reply = await listener.handle(target: String(parts[1]))
        } else {
            reply = .notFound
        }
        send(reply, on: connection)
    }

    /// The request line of the request head, or nil when the connection
    /// closes, fails, or exceeds `maxRequestHeadBytes` before the head ends.
    private static func readRequestLine(_ connection: NWConnection) async -> String? {
        var buffer = Data()
        let terminator = Data("\r\n\r\n".utf8)
        while buffer.count <= maxRequestHeadBytes {
            let chunk: Data? = await withCheckedContinuation { continuation in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, error in
                    if error == nil, let data, !data.isEmpty {
                        continuation.resume(returning: data)
                    } else {
                        continuation.resume(returning: nil)
                    }
                }
            }
            guard let chunk else { return nil }
            buffer.append(chunk)
            if let end = buffer.range(of: terminator) {
                let head = String(decoding: buffer[buffer.startIndex..<end.lowerBound], as: UTF8.self)
                return head.components(separatedBy: "\r\n").first
            }
        }
        return nil
    }

    private static func send(_ reply: Reply, on connection: NWConnection) {
        let body = Data("<!doctype html><html><head><meta charset=\"utf-8\"><title>Calyx</title></head><body><p>\(reply.message)</p></body></html>".utf8)
        let head = [
            reply.statusLine,
            "Content-Type: text/html; charset=utf-8",
            "Content-Length: \(body.count)",
            "Cache-Control: no-store",
            "Connection: close",
            "",
            "",
        ].joined(separator: "\r\n")
        connection.send(content: Data(head.utf8) + body, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    /// Cancels `listener` and returns once it reports `.cancelled` (or
    /// `.failed`), so the port is free when this returns.
    private static func shutDown(_ listener: NWListener) async {
        let resumed = OSAllocatedUnfairLock(initialState: false)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            listener.stateUpdateHandler = { state in
                switch state {
                case .cancelled, .failed:
                    let isFirst = resumed.withLock { alreadyResumed in
                        defer { alreadyResumed = true }
                        return !alreadyResumed
                    }
                    if isFirst { continuation.resume() }
                default:
                    break
                }
            }
            listener.cancel()
        }
    }
}
