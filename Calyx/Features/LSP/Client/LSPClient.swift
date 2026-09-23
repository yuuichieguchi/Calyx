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
//      cap on body size, recovers from a non-numeric Content-Length by
//      discarding just that header, and treats a negative, oversized, or
//      overflowing Content-Length as unrecoverable).
//    - Auto-assign integer ids for requests and correlate responses to
//      pending continuations. String ids round-trip through the
//      `LSPRequestID` enum so servers that echo ids as strings are
//      still matched correctly (with a lenient `string("N")` →
//      `int(N)` fallback at lookup time).
//    - Dispatch server-originated notifications/requests to handlers
//      registered by the application layer through one serial inbound
//      queue, so each message is fully processed before the next one
//      starts and handlers finish in arrival order. Requests reply with
//      -32601 MethodNotFound when no handler is registered, -32602
//      InvalidParams when the handler raises a `DecodingError`, and
//      -32800 RequestCancelled when the server cancels them before
//      their handler runs, or while it runs and it throws. A handler
//      that returns normally despite a cancel has its result sent.
//      Responses to our own requests and the server's `$/cancelRequest`
//      bypass the queue and are handled as soon as they arrive.
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

    /// Methods where the LSP spec permits a client to reply `result: null`
    /// even when no handler is registered. For these, the dispatcher
    /// answers with a successful `null` result instead of
    /// `-32601 MethodNotFound`, so a future-spec or rarely-used
    /// server→client request cannot reproduce the pyright crash by
    /// hitting a missing-handler path. Unknown methods OUTSIDE this set
    /// still get the strict `-32601`.
    ///
    /// Membership rationale (LSP 3.18):
    /// - `workspace/*/refresh`: spec explicitly allows the client to
    ///   acknowledge without taking action.
    /// - `window/workDoneProgress/create`: success means the client
    ///   accepted the token; `null` is the canonical no-op ack.
    /// - `workspace/workspaceFolders`: response is `WorkspaceFolder[] | null`.
    /// - `workspace/configuration`: response is `LSPAny[]` of which `null`
    ///   per item means "no value"; replying top-level `null` is
    ///   commonly tolerated by servers (and is the safest default when
    ///   the client has no configuration to report).
    private static let tolerantUnhandledMethods: Set<String> = [
        "workspace/semanticTokens/refresh",
        "workspace/codeLens/refresh",
        "workspace/inlayHint/refresh",
        "workspace/inlineValue/refresh",
        "workspace/diagnostic/refresh",
        "workspace/foldingRange/refresh",
        "window/workDoneProgress/create",
        "workspace/workspaceFolders",
        "workspace/configuration",
    ]

    /// One unit of server-originated work waiting on the serial inbound
    /// queue. Notification handlers are resolved when the message
    /// arrives (an unregistered notification is dropped without being
    /// queued); request handlers are resolved when the request is
    /// dequeued, so the -32601 reply for an unregistered method is
    /// written in arrival order too.
    private enum InboundWork: Sendable {
        case notification(handler: @Sendable (AnyCodable?) async -> Void, params: AnyCodable?)
        case request(id: LSPRequestID, method: String, params: AnyCodable?)
    }

    /// Producer side of the serial inbound queue. Set in `start()` and
    /// finished (then cleared) on `close()`, transport end, or a fatal
    /// framing error.
    private var inboundContinuation: AsyncStream<InboundWork>.Continuation?

    /// Consumer task that takes one `InboundWork` at a time and awaits
    /// its full processing before taking the next.
    private var inboundTask: Task<Void, Never>?

    /// Ids of server-initiated requests that are on the inbound queue
    /// and have not been dequeued yet. Inserted on enqueue, removed on
    /// dequeue. Lets `$/cancelRequest` tell a queued request apart from
    /// one that was already answered.
    private var queuedServerRequestIDs: Set<LSPRequestID> = []

    /// Ids of queued server-initiated requests the server has cancelled
    /// via `$/cancelRequest`. At dequeue such a request skips its
    /// handler and is answered with -32800 RequestCancelled.
    private var cancelledRequestIDs: Set<LSPRequestID> = []

    /// In-flight handler tasks for server-initiated requests, keyed by
    /// the server's request id. Populated when the inbound consumer
    /// dequeues a request and spawns its handler Task, and cleared when
    /// that Task completes (success or failure). `$/cancelRequest`
    /// looks up this map and cancels the corresponding Task so the
    /// handler can observe `Task.isCancelled` / `CancellationError` and
    /// short-circuit.
    private var inflightServerRequests: [LSPRequestID: Task<Void, Never>] = [:]

    /// Tasks spawned by `onCancel` in `sendRequestRaw` to bounce back
    /// into the actor and emit `$/cancelRequest`. `close()` awaits these
    /// before tearing the transport down so a request cancelled at the
    /// very end of the client's life still gets its `$/cancelRequest`
    /// onto the wire instead of racing the transport's teardown.
    private var pendingCancelTasks: [Task<Void, Never>] = []

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

        installBuiltinNotificationHandlers()

        // Serial inbound queue: one consumer processes server-originated
        // notifications and requests strictly one after another.
        let (inboundStream, inboundContinuation) = AsyncStream.makeStream(of: InboundWork.self)
        self.inboundContinuation = inboundContinuation
        inboundTask = Task { [weak self] in
            for await work in inboundStream {
                guard let self else { return }
                await self.processInbound(work)
            }
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

    /// Install the always-on notification handlers that LSPClient owns
    /// itself (independent of any application-level handler registration).
    ///
    /// These are pinned in code (and exercised in tests) so that a
    /// future refactor of `handleNotification` — for example, adding a
    /// warning for unknown notifications — cannot silently regress them
    /// onto the default-drop path.
    ///
    /// `$/cancelRequest` is not among them: `dispatch` intercepts it
    /// before any handler lookup and calls `handleServerCancelRequest`
    /// directly, so it takes effect even while the inbound queue is
    /// busy with the request it cancels.
    private func installBuiltinNotificationHandlers() {
        // `$/setTrace`: spec defines this as CLIENT→SERVER. Some servers
        // emit it back at the client by mistake; pin a no-op so the
        // contract is explicit and the default-drop path stays
        // unreachable for this method.
        notificationHandlers["$/setTrace"] = { _ in
            // Intentionally empty.
        }

        // `$/logTrace`: spec defines this as SERVER→CLIENT. We do not
        // surface trace data anywhere today, but pinning the empty
        // handler makes the policy testable and prevents a future
        // "warn on unknown notification" change from regressing it.
        notificationHandlers["$/logTrace"] = { _ in
            // Intentionally empty.
        }

        // `telemetry/event`: spec-permitted at any time. Calyx does not
        // forward telemetry anywhere; pin the no-op so the contract is
        // explicit.
        notificationHandlers["telemetry/event"] = { _ in
            // Intentionally empty.
        }
    }

    /// Handle a `$/cancelRequest` notification from the server. Runs
    /// synchronously from `dispatch`, bypassing the inbound queue.
    ///
    /// - If the id matches an in-flight handler Task, that Task is
    ///   cancelled. If the handler still returns normally, its result
    ///   is sent. If it throws, the request is answered with -32800,
    ///   except that a `DecodingError` is answered with -32602.
    /// - If the id belongs to a request still waiting on the inbound
    ///   queue, it is marked cancelled; at dequeue its handler is
    ///   skipped and it is answered with -32800.
    /// - Otherwise the notification is dropped (the response has
    ///   already been sent or the request was never seen).
    ///
    /// `AnyCodable` is opaque-by-design, so the cleanest way to lift
    /// out the structured `id` field is to round-trip through JSON.
    /// The payload is small (a single object with one int/string key)
    /// so the cost is negligible and we avoid coupling LSPClient to
    /// AnyCodable's private storage.
    private func handleServerCancelRequest(params: AnyCodable?) {
        guard let params,
              let data = try? JSONEncoder().encode(params),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawId = dict["id"],
              let id = LSPRequestID(fromAny: rawId) else {
            return
        }
        if let task = inflightServerRequests[id] {
            task.cancel()
        } else if queuedServerRequestIDs.contains(id) {
            cancelledRequestIDs.insert(id)
        }
    }

    /// Stop the serial inbound queue: finish the stream, cancel the
    /// consumer task without awaiting it, and forget every queued or
    /// cancelled request id. Items still buffered in the stream are
    /// dropped by `processInbound` because the client is `.closed` by
    /// the time this runs.
    private func stopInboundQueue() {
        inboundContinuation?.finish()
        inboundContinuation = nil
        inboundTask?.cancel()
        inboundTask = nil
        queuedServerRequestIDs.removeAll()
        cancelledRequestIDs.removeAll()
    }

    /// Cancel every still-running server-initiated request handler so
    /// it observes `Task.isCancelled` and stops touching the transport
    /// on the way out. Handler Tasks do not inherit the consumer task's
    /// cancellation, so they are cancelled explicitly here.
    private func cancelInflightServerRequests() {
        let inflightSnapshot = inflightServerRequests
        inflightServerRequests.removeAll()
        for (_, task) in inflightSnapshot {
            task.cancel()
        }
    }

    /// Idempotent shutdown. Cancels the receive loop, stops the serial
    /// inbound queue (queued server messages are dropped without
    /// running their handlers), cancels running server-initiated
    /// request handlers, closes the transport, and fails any in-flight
    /// `sendRequest`.
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

        stopInboundQueue()
        cancelInflightServerRequests()

        // Drain any `$/cancelRequest` emission tasks spawned by an
        // in-flight `sendRequest`'s `onCancel` before tearing down the
        // transport. Without this `await`, a `sendRequest` whose calling
        // task is cancelled at the same instant `close()` runs would
        // lose the wire-level `$/cancelRequest` because the transport
        // would already be gone by the time `handleCancellation`
        // executes.
        let cancelTasksSnapshot = pendingCancelTasks
        pendingCancelTasks.removeAll()
        for task in cancelTasksSnapshot {
            await task.value
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
            // Bounce back to the actor to do the cleanup work and
            // register the task with `pendingCancelTasks` so `close()`
            // can await its completion before tearing down the
            // transport (otherwise a sendRequest cancelled at the same
            // instant as close() would lose `$/cancelRequest` on the
            // wire).
            let cancelTask = Task { [weak self] in
                _ = await self?.handleCancellation(id: id)
            }
            Task { [weak self] in
                await self?.registerPendingCancelTask(cancelTask)
            }
        }
    }

    /// Add a cancellation-emission task to the pending set. Called from
    /// the `onCancel` continuation so `close()` can `await` it later.
    /// Tasks remove themselves on completion to keep the set bounded.
    private func registerPendingCancelTask(_ task: Task<Void, Never>) {
        pendingCancelTasks.append(task)
        Task { [weak self] in
            await task.value
            await self?.removePendingCancelTask(task)
        }
    }

    private func removePendingCancelTask(_ task: Task<Void, Never>) {
        pendingCancelTasks.removeAll { $0 == task }
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
        // closed, stop the inbound queue, cancel running server request
        // handlers, and fail every in-flight request.
        switch state {
        case .closed:
            return
        case .notStarted, .started:
            state = .closed
            stopInboundQueue()
            cancelInflightServerRequests()
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
    /// A non-numeric Content-Length is recoverable: the header block
    /// itself is structurally complete (its `\r\n\r\n` terminator was
    /// already found), so we discard just that header and let the next
    /// iteration search forward for the next `Content-Length:` marker,
    /// same as junk bytes ahead of a header.
    ///
    /// A negative Content-Length, one larger than `maxContentLength`, or
    /// one causing arithmetic overflow when computing the body end is
    /// treated as a fatal framing failure: every pending request fails
    /// with `.malformedFraming`, the transport is closed, and the loop
    /// exits. These carry a real risk of an attacker- or corruption-
    /// chosen byte count driving unbounded allocation or an indefinite
    /// wait for bytes that will never arrive, so we deliberately do not
    /// attempt resync for them.
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
            guard let length = Int(rawLength) else {
                // The header block is structurally complete (we already
                // found its `\r\n\r\n` terminator) but the declared length
                // is not a number, so we don't know how many bytes this
                // message's body occupies. Unlike a negative or
                // oversized length, a non-numeric value carries no risk
                // of tricking us into allocating or waiting for an
                // attacker-chosen byte count, so it's safe to discard just
                // this header and let the next loop iteration search
                // forward for the next `Content-Length:` marker, treating
                // whatever sits in between as junk — the same recovery
                // already applied to bytes preceding the first marker.
                receiveBuffer.removeSubrange(receiveBuffer.startIndex..<headerEnd.upperBound)
                continue
            }
            guard length >= 0, length <= Self.maxContentLength else {
                await failFatal(
                    reason: "Content-Length \(length) is invalid or exceeds the \(Self.maxContentLength)-byte cap"
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
    /// every in-flight request, stop the inbound queue, cancel running
    /// server request handlers, close the transport, and stop draining.
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
            stopInboundQueue()
            cancelInflightServerRequests()
            await transport.close()
        }
    }

    /// Parse a single JSON body and route it. Responses resolve their
    /// pending request and `$/cancelRequest` is applied immediately;
    /// every other notification and every server-initiated request is
    /// appended to the serial inbound queue.
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
        } else if method == "$/cancelRequest" {
            // Applied at once rather than queued, so it can reach a
            // request that is running or still waiting on the queue.
            handleServerCancelRequest(params: params)
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

    /// Queue a server notification for serial processing. A method with
    /// no registered handler is dropped silently.
    private func handleNotification(method: String, params: AnyCodable?) {
        guard let handler = notificationHandlers[method] else {
            // No handler — drop silently.
            return
        }
        inboundContinuation?.yield(.notification(handler: handler, params: params))
    }

    /// Queue a server-initiated request for serial processing and
    /// record its id as queued so `$/cancelRequest` can reach it before
    /// it is dequeued.
    private func handleServerRequest(id: LSPRequestID, method: String, params: AnyCodable?) {
        guard let inboundContinuation else { return }
        if case .enqueued = inboundContinuation.yield(.request(id: id, method: method, params: params)) {
            queuedServerRequestIDs.insert(id)
        }
    }

    /// Process one item from the serial inbound queue. The consumer
    /// task awaits this call before taking the next item, so handlers
    /// finish in arrival order and responses to server requests are
    /// written in arrival order.
    ///
    /// Items still buffered after the client closes are dropped
    /// without running their handlers.
    private func processInbound(_ work: InboundWork) async {
        if case .closed = state { return }
        if Task.isCancelled { return }

        switch work {
        case .notification(let handler, let params):
            await handler(params)
        case .request(let id, let method, let params):
            await processServerRequest(id: id, method: method, params: params)
        }
    }

    /// Run a dequeued server-initiated request and write its response.
    ///
    /// Between dequeue and registering the handler Task in
    /// `inflightServerRequests` there is no suspension point, so a
    /// `$/cancelRequest` always finds the id in either
    /// `queuedServerRequestIDs` or `inflightServerRequests`.
    private func processServerRequest(id: LSPRequestID, method: String, params: AnyCodable?) async {
        queuedServerRequestIDs.remove(id)
        if cancelledRequestIDs.remove(id) != nil {
            await sendServerRequestCancelled(id: id)
            return
        }

        guard let handler = requestHandlers[method] else {
            await sendServerRequestError(
                id: id,
                code: -32601,
                message: "Method not found: \(method)"
            )
            return
        }

        let task = Task { [weak self] in
            do {
                // A handler that returns normally is answered with its
                // result even if the server cancelled the request while
                // it ran: its work (for example an applied edit) has
                // taken effect, and LSP lets such a request report it.
                let result = try await handler(params)
                await self?.sendServerRequestResult(id: id, result: result)
            } catch {
                // `error.localizedDescription` is often the useless
                // boilerplate `"The operation couldn't be
                // completed. (… error 1.)"`. Use `String(describing:)`
                // instead so JSON-RPC error messages carry the
                // actual underlying cause.
                //
                // `CancellationError` maps to JSON-RPC
                // `-32800 RequestCancelled`. `DecodingError` is the
                // canonical "the caller sent garbage" signal, so it
                // maps to `-32602 InvalidParams` even when the request
                // was cancelled. Any other error thrown by a cancelled
                // handler maps to `-32800`; otherwise it is the generic
                // `-32603 InternalError`.
                if error is CancellationError {
                    await self?.sendServerRequestCancelled(id: id)
                    return
                }
                var code = -32603
                var message = String(describing: error)
                if let decodingError = error as? DecodingError {
                    code = -32602
                    message = String(describing: decodingError)
                } else if Task.isCancelled {
                    await self?.sendServerRequestCancelled(id: id)
                    return
                }
                await self?.sendServerRequestError(
                    id: id,
                    code: code,
                    message: message
                )
            }
        }
        inflightServerRequests[id] = task
        await task.value
        if inflightServerRequests[id] == task {
            inflightServerRequests.removeValue(forKey: id)
        }
    }

    private func sendServerRequestCancelled(id: LSPRequestID) async {
        await sendServerRequestError(
            id: id,
            code: -32800,
            message: "Request cancelled"
        )
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
