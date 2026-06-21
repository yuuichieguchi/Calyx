//
//  LSPClient.swift
//  Calyx
//
//  Actor that bridges the byte-level `LSPTransport` to a typed
//  JSON-RPC 2.0 + LSP 3.18 client surface.
//
//  Responsibilities:
//    - Frame outbound JSON-RPC messages with Content-Length headers.
//    - Parse inbound bytes using an incremental Content-Length parser
//      (handles back-to-back and fragmented messages).
//    - Auto-assign integer ids for requests and correlate responses to
//      pending continuations.
//    - Dispatch server-originated notifications/requests to handlers
//      registered by the application layer, replying with -32601
//      MethodNotFound when no handler is registered.
//    - Surface failures via the typed `LSPClientError` enum.
//

import Foundation

/// LSP 3.18 / JSON-RPC 2.0 client over an arbitrary `LSPTransport`.
actor LSPClient {

    // MARK: - State

    private enum State {
        case notStarted
        case started(receiveTask: Task<Void, Never>)
        case closed
    }

    private let transport: any LSPTransport
    private var state: State = .notStarted

    /// Monotonically increasing JSON-RPC request id (client → server).
    private var nextId: Int = 1

    /// Pending requests we have sent and are awaiting a response for.
    private var pending: [Int: CheckedContinuation<AnyCodable?, Error>] = [:]

    /// Application-registered handlers for server-initiated requests.
    private var requestHandlers: [String: @Sendable (AnyCodable?) async throws -> AnyCodable?] = [:]

    /// Application-registered handlers for server-initiated notifications.
    private var notificationHandlers: [String: @Sendable (AnyCodable?) async -> Void] = [:]

    /// Parser scratch buffer.
    private var receiveBuffer = Data()

    // MARK: - Init

    init(transport: any LSPTransport) {
        self.transport = transport
    }

    // MARK: - Lifecycle

    /// Begin consuming bytes from the transport. Must be called exactly
    /// once before the first `sendRequest` / `sendNotification`.
    func start() async throws {
        switch state {
        case .started:
            throw LSPClientError.alreadyStarted
        case .closed:
            throw LSPClientError.transportClosed
        case .notStarted:
            break
        }

        let stream = transport.incoming
        let task = Task { [weak self] in
            for await chunk in stream {
                guard let self else { return }
                await self.ingest(chunk)
            }
            // Stream finished — transport closed or server exited.
            guard let self else { return }
            await self.handleTransportFinished()
        }
        state = .started(receiveTask: task)
    }

    /// Idempotent shutdown. Cancels the receive loop, closes the
    /// transport, and fails any in-flight `sendRequest`.
    func close() async {
        switch state {
        case .closed:
            return
        case .notStarted:
            state = .closed
        case .started(let task):
            task.cancel()
            state = .closed
        }

        await transport.close()
        failAllPending(.transportClosed)
    }

    // MARK: - Client → Server

    /// Send a JSON-RPC request with parameters, awaiting a typed result.
    func sendRequest<Params: Encodable & Sendable, Result: Decodable & Sendable>(
        method: String,
        params: Params,
        resultType: Result.Type
    ) async throws -> Result {
        let raw = try await sendRequestRaw(method: method, params: params)
        return try decodeResult(raw, as: Result.self)
    }

    /// Send a JSON-RPC request without parameters, awaiting a typed result.
    func sendRequest<Result: Decodable & Sendable>(
        method: String,
        resultType: Result.Type
    ) async throws -> Result {
        let raw = try await sendRequestRaw(method: method, params: Optional<AnyCodable>.none)
        return try decodeResult(raw, as: Result.self)
    }

    /// Send a JSON-RPC notification with parameters.
    func sendNotification<Params: Encodable & Sendable>(method: String, params: Params) async throws {
        try ensureStarted()
        let data = try encodeOutbound(id: nil, method: method, params: params)
        try await transport.send(data)
    }

    /// Send a JSON-RPC notification without parameters.
    func sendNotification(method: String) async throws {
        try ensureStarted()
        let data = try encodeOutbound(id: nil, method: method, params: Optional<AnyCodable>.none)
        try await transport.send(data)
    }

    // MARK: - Server → Client Handler Registration

    func setRequestHandler(
        method: String,
        handler: @Sendable @escaping (AnyCodable?) async throws -> AnyCodable?
    ) async {
        requestHandlers[method] = handler
    }

    func setNotificationHandler(
        method: String,
        handler: @Sendable @escaping (AnyCodable?) async -> Void
    ) async {
        notificationHandlers[method] = handler
    }

    // MARK: - Outbound encoding

    private func sendRequestRaw<Params: Encodable & Sendable>(
        method: String,
        params: Params?
    ) async throws -> AnyCodable? {
        try ensureStarted()
        let id = nextId
        nextId += 1
        let data = try encodeOutbound(id: id, method: method, params: params)
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.transport.send(data)
                } catch {
                    await self.failPending(id: id, error: LSPClientError.transportClosed)
                }
            }
        }
    }

    /// Build a `Content-Length`-framed JSON-RPC envelope.
    ///
    /// - `id == nil` produces a notification (no `id` key in the JSON).
    /// - `params == nil` omits the `params` key entirely (LSP servers
    ///   sometimes reject `null` params).
    private func encodeOutbound<Params: Encodable>(
        id: Int?,
        method: String,
        params: Params?
    ) throws -> Data {
        var envelope: [String: AnyCodable] = [
            "jsonrpc": AnyCodable("2.0"),
            "method": AnyCodable(method)
        ]
        if let id {
            envelope["id"] = AnyCodable(id)
        }
        if let params {
            envelope["params"] = AnyCodable.from(params)
        }
        let body = try JSONEncoder().encode(envelope)
        var out = Data("Content-Length: \(body.count)\r\n\r\n".utf8)
        out.append(body)
        return out
    }

    private func decodeResult<Result: Decodable>(_ raw: AnyCodable?, as type: Result.Type) throws -> Result {
        // The result may be `null` (e.g. shutdown) or absent.
        let raw = raw ?? AnyCodable(NSNull())
        do {
            let data = try JSONEncoder().encode(raw)
            return try JSONDecoder().decode(Result.self, from: data)
        } catch {
            throw LSPClientError.responseDecodingFailed(reason: String(describing: error))
        }
    }

    private func ensureStarted() throws {
        switch state {
        case .notStarted:
            throw LSPClientError.notStarted
        case .closed:
            throw LSPClientError.transportClosed
        case .started:
            return
        }
    }

    private func failPending(id: Int, error: Error) {
        if let cont = pending.removeValue(forKey: id) {
            cont.resume(throwing: error)
        }
    }

    private func failAllPending(_ error: LSPClientError) {
        let conts = pending
        pending.removeAll()
        for (_, cont) in conts {
            cont.resume(throwing: error)
        }
    }

    private func handleTransportFinished() {
        // Transport ended. If we are not already closed, transition to
        // closed and fail every in-flight request.
        switch state {
        case .closed:
            return
        case .notStarted, .started:
            state = .closed
            failAllPending(.transportClosed)
        }
    }

    // MARK: - Inbound parsing

    /// Append a chunk to the parser scratch buffer and drain as many
    /// complete LSP-framed messages as possible.
    private func ingest(_ chunk: Data) {
        receiveBuffer.append(chunk)
        drain()
    }

    /// Drain every complete framed message currently in `receiveBuffer`.
    ///
    /// The parser scans for the next `Content-Length:` header start.
    /// Junk bytes ahead of it (e.g. leftovers from a malformed earlier
    /// message) are discarded.
    private func drain() {
        let headerTerminator = Data("\r\n\r\n".utf8)
        let headerMarker = Data("Content-Length:".utf8)

        outer: while !receiveBuffer.isEmpty {
            // 1. Locate the next Content-Length header start.
            guard let markerRange = receiveBuffer.range(of: headerMarker) else {
                // No header at all — wait for more bytes.
                // Optionally bound buffer growth to prevent DoS, but the
                // production language servers never produce arbitrary
                // junk so we keep the implementation minimal.
                return
            }
            // Drop garbage that came before the marker.
            if markerRange.lowerBound > receiveBuffer.startIndex {
                receiveBuffer.removeSubrange(receiveBuffer.startIndex..<markerRange.lowerBound)
            }

            // 2. Locate the header terminator (\r\n\r\n).
            guard let headerEnd = receiveBuffer.range(of: headerTerminator) else {
                // Header still being assembled — wait for more bytes.
                return
            }

            // 3. Parse the header block.
            let headerData = receiveBuffer.subdata(in: receiveBuffer.startIndex..<headerEnd.lowerBound)
            guard let headerString = String(data: headerData, encoding: .utf8) else {
                // Non-UTF8 garbage in headers — drop everything through
                // the terminator and resume scanning.
                receiveBuffer.removeSubrange(receiveBuffer.startIndex..<headerEnd.upperBound)
                continue outer
            }

            var contentLength: Int? = nil
            for line in headerString.split(separator: "\r\n", omittingEmptySubsequences: true) {
                let parts = line.split(separator: ":", maxSplits: 1).map {
                    $0.trimmingCharacters(in: .whitespaces)
                }
                if parts.count == 2, parts[0].lowercased() == "content-length" {
                    contentLength = Int(parts[1])
                }
            }

            guard let length = contentLength, length >= 0 else {
                // Malformed Content-Length. Skip past the header
                // terminator and keep going so subsequent messages still
                // get processed.
                receiveBuffer.removeSubrange(receiveBuffer.startIndex..<headerEnd.upperBound)
                continue outer
            }

            // 4. Wait for the body.
            let bodyStart = headerEnd.upperBound
            let bodyEnd = bodyStart + length
            guard bodyEnd <= receiveBuffer.endIndex else {
                // Body not fully arrived yet.
                return
            }

            let body = receiveBuffer.subdata(in: bodyStart..<bodyEnd)
            // Consume the framed message from the buffer.
            receiveBuffer.removeSubrange(receiveBuffer.startIndex..<bodyEnd)

            // 5. Dispatch.
            dispatch(body: body)
        }
    }

    /// Parse a single JSON body and route it to a pending request, a
    /// notification handler, or a request handler.
    private func dispatch(body: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            // Malformed JSON — log and ignore. We can't usefully respond
            // because we don't know the id.
            return
        }

        let hasMethod = object["method"] is String
        let id = extractInt(object["id"])

        if !hasMethod {
            // Response (must have id).
            guard let id else { return }
            handleResponse(id: id, object: object)
            return
        }

        // method present
        guard let method = object["method"] as? String else { return }
        let params = (object["params"]).flatMap { value -> AnyCodable? in
            if value is NSNull { return nil }
            return AnyCodable(value)
        }

        if let id {
            // Server-initiated request — needs a response.
            handleServerRequest(id: id, method: method, params: params)
        } else {
            // Notification.
            handleNotification(method: method, params: params)
        }
    }

    private func handleResponse(id: Int, object: [String: Any]) {
        guard let cont = pending.removeValue(forKey: id) else {
            // No pending request — silently drop (could log).
            return
        }
        if let errObj = object["error"] as? [String: Any] {
            let code = (errObj["code"] as? Int) ?? 0
            let message = (errObj["message"] as? String) ?? ""
            cont.resume(throwing: LSPClientError.serverError(code: code, message: message))
            return
        }
        let result: AnyCodable?
        if let raw = object["result"] {
            if raw is NSNull {
                result = AnyCodable(NSNull())
            } else {
                result = AnyCodable(raw)
            }
        } else {
            result = nil
        }
        cont.resume(returning: result)
    }

    private func handleNotification(method: String, params: AnyCodable?) {
        guard let handler = notificationHandlers[method] else {
            // No handler — drop silently.
            return
        }
        Task {
            await handler(params)
        }
    }

    private func handleServerRequest(id: Int, method: String, params: AnyCodable?) {
        if let handler = requestHandlers[method] {
            Task { [weak self] in
                do {
                    let result = try await handler(params)
                    await self?.sendServerRequestResult(id: id, result: result)
                } catch {
                    await self?.sendServerRequestError(
                        id: id,
                        code: -32603,
                        message: error.localizedDescription
                    )
                }
            }
        } else {
            Task { [weak self] in
                await self?.sendServerRequestError(
                    id: id,
                    code: -32601,
                    message: "Method not found: \(method)"
                )
            }
        }
    }

    private func sendServerRequestResult(id: Int, result: AnyCodable?) async {
        var envelope: [String: AnyCodable] = [
            "jsonrpc": AnyCodable("2.0"),
            "id": AnyCodable(id)
        ]
        envelope["result"] = result ?? AnyCodable(NSNull())
        await sendEnvelope(envelope)
    }

    private func sendServerRequestError(id: Int, code: Int, message: String) async {
        let errorObject: [String: AnyCodable] = [
            "code": AnyCodable(code),
            "message": AnyCodable(message)
        ]
        let envelope: [String: AnyCodable] = [
            "jsonrpc": AnyCodable("2.0"),
            "id": AnyCodable(id),
            "error": AnyCodable(errorObject)
        ]
        await sendEnvelope(envelope)
    }

    private func sendEnvelope(_ envelope: [String: AnyCodable]) async {
        guard let body = try? JSONEncoder().encode(envelope) else { return }
        var out = Data("Content-Length: \(body.count)\r\n\r\n".utf8)
        out.append(body)
        try? await transport.send(out)
    }

    // MARK: - Utilities

    private func extractInt(_ any: Any?) -> Int? {
        guard let any else { return nil }
        if let i = any as? Int { return i }
        if let n = any as? NSNumber { return n.intValue }
        if let s = any as? String { return Int(s) }
        return nil
    }
}
