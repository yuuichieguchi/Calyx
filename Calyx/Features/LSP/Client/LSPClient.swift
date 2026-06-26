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
//      (handles back-to-back and fragmented messages, enforces a 64 MiB
//      cap on body size, and treats any malformed Content-Length as
//      unrecoverable).
//    - Auto-assign integer ids for requests and correlate responses to
//      pending continuations. String ids round-trip through the
//      `LSPRequestID` enum so servers that echo ids as strings are
//      still matched correctly (with a lenient `string("N")` →
//      `int(N)` fallback at lookup time).
//    - Dispatch server-originated notifications/requests to handlers
//      registered by the application layer, replying with -32601
//      MethodNotFound when no handler is registered and -32602
//      InvalidParams when the handler raises a `DecodingError`.
//    - Honor cooperative task cancellation: on cancel, the in-flight
//      `sendRequest` resumes with `CancellationError` and a
//      `$/cancelRequest` notification is sent to the server.
//    - Enforce a wall-clock request timeout (default 120 s) that fails
//      the continuation with `LSPClientError.timeout` and notifies the
//      server via `$/cancelRequest`.
//    - Surface failures via the typed `LSPClientError` enum.
//

import Foundation

// MARK: - LSPRequestID

/// JSON-RPC request id. The wire format permits either an integer or a
/// string and many servers echo the id back exactly as they received
/// it, so the dispatch table must key on both shapes.
///
/// Outbound id allocation in `LSPClient` continues to use sequential
/// integers; the enum exists so the receive loop can carry a string id
/// straight back through to the request handler for server-initiated
/// requests, and so a string id sent by a misbehaving server (e.g. a
/// response with `"id": "1"` to our `"id": 1` request) still finds its
/// pending continuation via the lenient lookup in `handleResponse`.
enum LSPRequestID: Sendable, Hashable {
    case int(Int)
    case string(String)

    /// Decode an id from a value extracted via `JSONSerialization`.
    ///
    /// JSON ints arrive as `NSNumber`; JSON strings arrive as `String`
    /// (bridged from `NSString`). Booleans are NSNumber too and would
    /// otherwise satisfy `as? Int` — `CFGetTypeID(n) == CFBooleanGetTypeID()`
    /// is checked explicitly so a misbehaving server that sends a
    /// boolean as an id is not silently coerced to `.int(0)` / `.int(1)`.
    init?(fromAny anyValue: Any) {
        if let n = anyValue as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                return nil
            }
            self = .int(n.intValue)
            return
        }
        if let i = anyValue as? Int {
            self = .int(i)
            return
        }
        if let s = anyValue as? String {
            self = .string(s)
            return
        }
        return nil
    }

    /// JSON-RPC encoding for the id. Used when writing responses to
    /// server-initiated requests and the `$/cancelRequest` payload.
    var jsonValue: AnyCodable {
        switch self {
        case .int(let i):
            return AnyCodable(i)
        case .string(let s):
            return AnyCodable(s)
        }
    }
}

// MARK: - LSPClient

/// LSP 3.18 / JSON-RPC 2.0 client over an arbitrary `LSPTransport`.
actor LSPClient {

    // MARK: - State

    private enum State {
        case notStarted
        case started(receiveTask: Task<Void, Never>)
        case closed
    }

    /// Reference-typed dispatch slot held in `pending`. The slot stores
    /// either the continuation we will resume when the response
    /// arrives, or — if the response (or cancellation / timeout) raced
    /// ahead of the continuation registration — the result that should
    /// be delivered as soon as the continuation is attached.
    private final class PendingEntry: @unchecked Sendable {
        var continuation: CheckedContinuation<AnyCodable?, Error>?
        var earlyResult: Result<AnyCodable?, Error>?
    }

    /// Largest Content-Length we will accept on inbound frames.
    /// Anything larger is treated as a malformed framing event: every
    /// pending request fails with `.malformedFraming`, the transport
    /// is closed, and the receive loop exits. 64 MiB sits well above
    /// the largest realistic LSP payload (semantic tokens on a huge
    /// file) and well below the point where a single allocation would
    /// threaten the process.
    private static let maxContentLength = 64 * 1024 * 1024

    private let transport: any LSPTransport
    private let requestTimeoutSeconds: TimeInterval
    private let initializeTimeoutSeconds: TimeInterval
    private var state: State = .notStarted

    /// Monotonically increasing JSON-RPC request id (client → server).
    private var nextId: Int = 1

    /// Pending requests we have sent and are awaiting a response for.
    private var pending: [LSPRequestID: PendingEntry] = [:]

    /// Application-registered handlers for server-initiated requests.
    private var requestHandlers: [String: @Sendable (AnyCodable?) async throws -> AnyCodable?] = [:]

    /// Application-registered handlers for server-initiated notifications.
    private var notificationHandlers: [String: @Sendable (AnyCodable?) async -> Void] = [:]

    /// Parser scratch buffer.
    private var receiveBuffer = Data()

    // MARK: - Init

    /// - Parameter requestTimeoutSeconds: wall-clock budget for every
    ///   `sendRequest` except the LSP `initialize` handshake. After
    ///   this elapses the continuation fails with
    ///   `LSPClientError.timeout` and `$/cancelRequest` is sent to the
    ///   server. Default is 120 s, which comfortably accommodates
    ///   steady-state requests on language servers like `rust-analyzer`
    ///   and `sourcekit-lsp` without leaking forever on a stuck server.
    /// - Parameter initializeTimeoutSeconds: wall-clock budget for the
    ///   `initialize` request specifically. Real-world language servers
    ///   (`rust-analyzer`, `jdtls`) routinely take 3-10 minutes for
    ///   first-time workspace indexing, exceeding the steady-state
    ///   `requestTimeoutSeconds` cap. Default is 600 s (10 minutes).
    init(
        transport: any LSPTransport,
        requestTimeoutSeconds: TimeInterval = 120,
        initializeTimeoutSeconds: TimeInterval = 600
    ) {
        self.transport = transport
        self.requestTimeoutSeconds = requestTimeoutSeconds
        self.initializeTimeoutSeconds = initializeTimeoutSeconds
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
    ///
    /// Drops every registered request/notification handler before
    /// returning. The handlers installed by `LSPSession` capture the
    /// session strongly (so the underlying receive task stays alive for
    /// the lifetime of the server-initiated traffic stream); clearing
    /// the handler dictionaries on close breaks that retain cycle so
    /// `LSPSession ↔ LSPClient ↔ handler closure ↔ LSPSession` can
    /// deinit once the application releases its references.
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
        // Break the retain cycle with `LSPSession`: the seven handlers
        // installed during the initialize handshake capture the session
        // strongly, which would otherwise keep the session, this client,
        // and the closure dictionary alive forever once the application
        // drops its top-level reference.
        requestHandlers.removeAll()
        notificationHandlers.removeAll()
    }

    // MARK: - Internal accessors (for tests / diagnostics)

    /// Number of in-flight `sendRequest` continuations awaiting a
    /// response. Exposed for test assertions and diagnostic harnesses.
    var pendingCount: Int {
        pending.count
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

    /// Core dispatch for client → server requests.
    ///
    /// Ordering invariants:
    ///   1. The pending slot is registered BEFORE we touch the
    ///      transport so the receive loop can resolve the continuation
    ///      as soon as the response arrives (even if the response
    ///      races ahead of the calling task's resumption after `send`).
    ///   2. `transport.send(data)` is awaited in this actor's calling
    ///      task — NOT in a spawned `Task` — so the encode-then-send
    ///      sequence stays serialized with respect to other in-flight
    ///      requests on the same actor. If `send` itself fails we undo
    ///      the registration and re-throw `.transportClosed`.
    ///   3. The continuation is then awaited inside
    ///      `withTaskCancellationHandler` and raced against a
    ///      wall-clock timeout (`requestTimeoutSeconds`). On cancel we
    ///      send `$/cancelRequest`; on timeout we do the same.
    private func sendRequestRaw<Params: Encodable & Sendable>(
        method: String,
        params: Params?
    ) async throws -> AnyCodable? {
        try ensureStarted()
        let rawId = nextId
        nextId += 1
        let id: LSPRequestID = .int(rawId)
        let data = try encodeOutbound(id: id, method: method, params: params)

        // 1. Register the dispatch slot.
        let entry = PendingEntry()
        pending[id] = entry

        // 2. Send synchronously within the actor. If the transport
        // rejects the bytes, unwind the registration and re-throw.
        do {
            try await transport.send(data)
        } catch {
            pending.removeValue(forKey: id)
            throw LSPClientError.transportClosed
        }

        // 3. Race the continuation against the wall-clock timeout while
        // honoring cooperative task cancellation. The LSP `initialize`
        // handshake gets a separate, larger budget because first-time
        // workspace indexing in real-world language servers
        // (`rust-analyzer`, `jdtls`) can run for several minutes; all
        // other methods stay on the steady-state `requestTimeoutSeconds`.
        let timeout = (method == "initialize") ? initializeTimeoutSeconds : requestTimeoutSeconds
        return try await withTaskCancellationHandler {
            try await raceResponseAgainstTimeout(
                id: id,
                entry: entry,
                timeoutSeconds: timeout
            )
        } onCancel: { [weak self] in
            // `onCancel` runs synchronously in the cancelling context.
            // Bounce back to the actor to do the cleanup work.
            Task { [weak self] in
                await self?.handleCancellation(id: id)
            }
        }
    }

    private func raceResponseAgainstTimeout(
        id: LSPRequestID,
        entry: PendingEntry,
        timeoutSeconds: TimeInterval
    ) async throws -> AnyCodable? {
        try await withThrowingTaskGroup(of: AnyCodable?.self) { group in
            // Producer A: suspend on the dispatch slot until the
            // receive loop resolves it (or `failAllPending` does on
            // close).
            group.addTask { [weak self] in
                guard let self else {
                    throw LSPClientError.transportClosed
                }
                return try await self.suspendOnEntry(id: id, entry: entry)
            }

            // Producer B: wall-clock timeout.
            group.addTask {
                let nanos = max(0, UInt64(timeoutSeconds * 1_000_000_000))
                try await Task.sleep(nanoseconds: nanos)
                throw LSPClientError.timeout
            }

            defer { group.cancelAll() }

            do {
                let first = try await group.next()
                return first ?? nil
            } catch {
                // If the timeout fired first, the response continuation
                // is still suspended on `entry`; resolve it explicitly
                // (otherwise the child task would leak) and tell the
                // server to stop working on the request.
                if let lsp = error as? LSPClientError, lsp == .timeout {
                    await handleTimeout(id: id)
                }
                throw error
            }
        }
    }

    /// Suspend on the dispatch slot. Runs in actor context (called from
    /// `sendRequestRaw`'s task-group child), so the synchronous body
    /// of `withCheckedThrowingContinuation` can touch `pending` and
    /// `entry` directly.
    private func suspendOnEntry(
        id: LSPRequestID,
        entry: PendingEntry
    ) async throws -> AnyCodable? {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<AnyCodable?, Error>) in
            if let early = entry.earlyResult {
                // The response (or cancel / timeout) raced ahead of
                // us. Deliver immediately. `pending[id]` may already
                // be gone — that's fine.
                pending.removeValue(forKey: id)
                switch early {
                case .success(let value):
                    continuation.resume(returning: value)
                case .failure(let err):
                    continuation.resume(throwing: err)
                }
            } else {
                entry.continuation = continuation
            }
        }
    }

    /// Cleanup path when the calling task of `sendRequest` is
    /// cancelled. Removes the dispatch slot, resumes the continuation
    /// with `CancellationError()`, and sends a `$/cancelRequest`
    /// notification so the server can abort its work.
    private func handleCancellation(id: LSPRequestID) async {
        guard let entry = pending.removeValue(forKey: id) else {
            // Already resolved (response arrived first, or close()
            // cleaned up). Nothing to do — no `$/cancelRequest` sent
            // because the server is no longer working on it.
            return
        }
        if let cont = entry.continuation {
            entry.continuation = nil
            cont.resume(throwing: CancellationError())
        } else {
            entry.earlyResult = .failure(CancellationError())
        }
        await sendCancelRequest(id: id)
    }

    /// Cleanup path when the wall-clock timeout fires before the
    /// server responds. Symmetric to `handleCancellation` but resumes
    /// with `LSPClientError.timeout`.
    private func handleTimeout(id: LSPRequestID) async {
        guard let entry = pending.removeValue(forKey: id) else {
            return
        }
        if let cont = entry.continuation {
            entry.continuation = nil
            cont.resume(throwing: LSPClientError.timeout)
        } else {
            entry.earlyResult = .failure(LSPClientError.timeout)
        }
        await sendCancelRequest(id: id)
    }

    private func sendCancelRequest(id: LSPRequestID) async {
        let params: [String: AnyCodable] = ["id": id.jsonValue]
        let envelope: [String: AnyCodable] = [
            "jsonrpc": AnyCodable("2.0"),
            "method": AnyCodable("$/cancelRequest"),
            "params": AnyCodable(params),
        ]
        await sendEnvelope(envelope)
    }

    /// Build a `Content-Length`-framed JSON-RPC envelope.
    ///
    /// - `id == nil` produces a notification (no `id` key in the JSON).
    /// - `params == nil` omits the `params` key entirely (LSP servers
    ///   sometimes reject `null` params).
    private func encodeOutbound<Params: Encodable>(
        id: LSPRequestID?,
        method: String,
        params: Params?
    ) throws -> Data {
        var envelope: [String: AnyCodable] = [
            "jsonrpc": AnyCodable("2.0"),
            "method": AnyCodable(method),
        ]
        if let id {
            envelope["id"] = id.jsonValue
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

    private func failAllPending(_ error: LSPClientError) {
        // Iterate a snapshot so `pending` mutations in the middle of
        // resume callbacks (none in our current code, but cheap to be
        // safe) cannot trip mutation-during-iteration. Each entry's
        // continuation is consumed exactly once.
        let snapshot = pending
        pending.removeAll()
        for (_, entry) in snapshot {
            if let cont = entry.continuation {
                entry.continuation = nil
                cont.resume(throwing: error)
            } else {
                entry.earlyResult = .failure(error)
            }
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
    private func ingest(_ chunk: Data) async {
        receiveBuffer.append(chunk)
        await drain()
    }

    /// Drain every complete framed message currently in `receiveBuffer`.
    ///
    /// The parser scans for the next `Content-Length:` header start.
    /// Junk bytes ahead of it (e.g. leftovers from a malformed earlier
    /// message) are discarded.
    ///
    /// Any invalid Content-Length (non-integer, negative, larger than
    /// `maxContentLength`, or causing arithmetic overflow when
    /// computing the body end) is treated as a fatal framing failure:
    /// every pending request fails with `.malformedFraming`, the
    /// transport is closed, and the loop exits. We deliberately do not
    /// attempt resync — once framing is broken there is no safe way to
    /// find the next message boundary.
    private func drain() async {
        let headerTerminator = Data("\r\n\r\n".utf8)
        let headerMarker = Data("Content-Length:".utf8)

        while !receiveBuffer.isEmpty {
            // 1. Locate the next Content-Length header start.
            guard let markerRange = receiveBuffer.range(of: headerMarker) else {
                // No header at all — wait for more bytes.
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
                await failFatal(reason: "header block is not valid UTF-8")
                return
            }

            var contentLengthRaw: String? = nil
            for line in headerString.split(separator: "\r\n", omittingEmptySubsequences: true) {
                let parts = line.split(separator: ":", maxSplits: 1).map {
                    $0.trimmingCharacters(in: .whitespaces)
                }
                if parts.count == 2, parts[0].lowercased() == "content-length" {
                    contentLengthRaw = parts[1]
                }
            }

            guard let rawLength = contentLengthRaw else {
                await failFatal(reason: "Content-Length header missing")
                return
            }
            guard let length = Int(rawLength),
                  length >= 0,
                  length <= Self.maxContentLength else {
                await failFatal(
                    reason: "Content-Length \(rawLength) is invalid or exceeds the \(Self.maxContentLength)-byte cap"
                )
                return
            }

            // 4. Wait for the body, guarding against arithmetic overflow.
            let bodyStart = headerEnd.upperBound
            let (bodyEnd, overflowed) = bodyStart.addingReportingOverflow(length)
            if overflowed {
                await failFatal(reason: "Content-Length \(length) overflows the buffer offset")
                return
            }
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

    /// Fatal framing failure: surface `.malformedFraming(reason:)` to
    /// every in-flight request, close the transport, and stop draining.
    /// The receive loop's outer `for await` will then terminate when
    /// `transport.close()` finishes the incoming stream.
    private func failFatal(reason: String) async {
        failAllPending(.malformedFraming(reason: reason))
        receiveBuffer.removeAll()
        switch state {
        case .closed:
            break
        case .notStarted, .started:
            state = .closed
            await transport.close()
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
        let reqId: LSPRequestID? = (object["id"]).flatMap { LSPRequestID(fromAny: $0) }

        if !hasMethod {
            // Response (must have id).
            guard let reqId else { return }
            handleResponse(id: reqId, object: object)
            return
        }

        // method present
        guard let method = object["method"] as? String else { return }
        let params = (object["params"]).flatMap { value -> AnyCodable? in
            if value is NSNull { return nil }
            return AnyCodable(value)
        }

        if let reqId {
            // Server-initiated request — needs a response.
            handleServerRequest(id: reqId, method: method, params: params)
        } else {
            // Notification.
            handleNotification(method: method, params: params)
        }
    }

    private func handleResponse(id: LSPRequestID, object: [String: Any]) {
        // Direct lookup first, then a lenient fallback for servers
        // that echo our integer id back as a string (e.g.
        // `"id": "1"` in response to our `"id": 1` request). The
        // lookup is symmetric in both directions so a future change
        // to outbound string ids would also keep working.
        var entry = pending.removeValue(forKey: id)
        if entry == nil {
            switch id {
            case .string(let s):
                if let i = Int(s) {
                    entry = pending.removeValue(forKey: .int(i))
                }
            case .int(let i):
                entry = pending.removeValue(forKey: .string(String(i)))
            }
        }

        guard let entry else {
            // No pending request — silently drop (could log).
            return
        }

        // Resolve the entry: prefer error, then result, then surface a
        // protocol violation when both fields are missing.
        let outcome: Result<AnyCodable?, Error>
        if let errObj = object["error"] as? [String: Any] {
            let code = (errObj["code"] as? Int) ?? 0
            let message = (errObj["message"] as? String) ?? ""
            outcome = .failure(LSPClientError.serverError(code: code, message: message))
        } else if object.keys.contains("result") {
            // The key is present (possibly with a JSON `null` value
            // that arrives as `NSNull`). Anything else flows through
            // `AnyCodable`'s untyped initializer.
            let raw = object["result"] ?? NSNull()
            let result: AnyCodable
            if raw is NSNull {
                result = AnyCodable(NSNull())
            } else {
                result = AnyCodable(raw)
            }
            outcome = .success(result)
        } else {
            outcome = .failure(LSPClientError.malformedFraming(
                reason: "response missing both result and error"
            ))
        }

        if let cont = entry.continuation {
            entry.continuation = nil
            switch outcome {
            case .success(let value): cont.resume(returning: value)
            case .failure(let err): cont.resume(throwing: err)
            }
        } else {
            // Continuation not yet attached (rare race: response
            // arrived between `transport.send(data)` completing and
            // `withCheckedThrowingContinuation` registering). Stash
            // for pickup by `suspendOnEntry`.
            entry.earlyResult = outcome
        }
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

    private func handleServerRequest(id: LSPRequestID, method: String, params: AnyCodable?) {
        if let handler = requestHandlers[method] {
            Task { [weak self] in
                do {
                    let result = try await handler(params)
                    await self?.sendServerRequestResult(id: id, result: result)
                } catch {
                    // `error.localizedDescription` is often the useless
                    // boilerplate `"The operation couldn't be
                    // completed. (… error 1.)"`. Use `String(describing:)`
                    // instead so JSON-RPC error messages carry the
                    // actual underlying cause.
                    //
                    // `DecodingError` is the canonical "the caller sent
                    // garbage" signal — surface it as JSON-RPC
                    // `-32602 InvalidParams` rather than the generic
                    // `-32603 InternalError`.
                    var code = -32603
                    var message = String(describing: error)
                    if let decodingError = error as? DecodingError {
                        code = -32602
                        message = String(describing: decodingError)
                    }
                    await self?.sendServerRequestError(
                        id: id,
                        code: code,
                        message: message
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

    private func sendServerRequestResult(id: LSPRequestID, result: AnyCodable?) async {
        var envelope: [String: AnyCodable] = [
            "jsonrpc": AnyCodable("2.0"),
            "id": id.jsonValue,
        ]
        envelope["result"] = result ?? AnyCodable(NSNull())
        await sendEnvelope(envelope)
    }

    private func sendServerRequestError(id: LSPRequestID, code: Int, message: String) async {
        let errorObject: [String: AnyCodable] = [
            "code": AnyCodable(code),
            "message": AnyCodable(message),
        ]
        let envelope: [String: AnyCodable] = [
            "jsonrpc": AnyCodable("2.0"),
            "id": id.jsonValue,
            "error": AnyCodable(errorObject),
        ]
        await sendEnvelope(envelope)
    }

    private func sendEnvelope(_ envelope: [String: AnyCodable]) async {
        guard let body = try? JSONEncoder().encode(envelope) else { return }
        var out = Data("Content-Length: \(body.count)\r\n\r\n".utf8)
        out.append(body)
        try? await transport.send(out)
    }
}
