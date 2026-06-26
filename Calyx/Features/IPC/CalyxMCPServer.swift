//
//  CalyxMCPServer.swift
//  Calyx
//
//  MCP server: accepts JSON-RPC over TCP, authenticates via bearer token,
//  routes to MCPRouter / IPCStore for IPC tool calls.
//

import Foundation
import Network

@MainActor
final class CalyxMCPServer {

    static let shared = CalyxMCPServer()

    // MARK: - Public State

    private(set) var isRunning: Bool = false
    private(set) var port: Int = 0
    private(set) var token: String = ""
    let store = IPCStore()
    private(set) var appPeerID: UUID?
    private var peerRegistrationTask: Task<Void, Never>?

    /// Bridge that exposes LSP requests as MCP tools. `nil` until
    /// `startLSP()` (or `_testInjectLSPBridge(_:)`) wires one in.
    private(set) var lspBridge: MCPLSPBridge?

    /// Count of teardown Tasks that are currently in flight — i.e.,
    /// scheduled by `stop()` but not yet returned. Race-safety tests
    /// observe this to confirm that the new LSP startup scheduled by
    /// `start()` has fully waited for the prior bridge teardown before
    /// running its body. Without that chain, the previous (cancelled
    /// but still-executing) `lspStartTask` could race the new one to
    /// install bridges into `self.lspBridge`, with the loser leaking
    /// a fully-built `LSPService` plus its child language-server
    /// processes.
    private(set) var inflightTeardownCount: Int = 0

    /// Snapshot of `inflightTeardownCount` recorded at the moment
    /// `startLSP()` last began executing its body. Lifecycle race
    /// tests assert this is `0` after a `start()` → `start()` toggle to
    /// confirm the new LSP startup chained behind — and waited for —
    /// the prior teardown. Defaults to `-1` so a test can distinguish
    /// "startLSP() has never been entered" from "entered with no
    /// teardown in flight". Internal access so XCTest with
    /// `@testable import` can read it.
    private(set) var inflightTeardownCountAtLastStartLSPEntry: Int = -1

    // MARK: - Private

    private var listener: NWListener?
    /// Background task running `startLSP()`. Retained so `stop()` can
    /// cancel it (and await its completion) before tearing down the
    /// resulting `lspBridge`. Without this, a `start()` → `stop()` pair
    /// fired before `startLSP()` finishes would leak the freshly-built
    /// `LSPService` plus its child language-server processes and
    /// `FSEvents` watches.
    private var lspStartTask: Task<Void, Never>?

    private static let iso8601: ISO8601DateFormatter = {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fmt
    }()

    // MARK: - Init

    init() {}

    /// For testing only — sets the token without starting the listener.
    func _testSetToken(_ token: String) {
        self.token = token
    }

    // MARK: - LSP Bridge Lifecycle

    /// Spin up the LSP tool bridge with the production stdio transport and
    /// system command runner. Idempotent — re-entry replaces the existing
    /// bridge with a fresh one.
    func startLSP() async {
        // Test-observable probe: race-safety tests use this to confirm
        // that the new LSP startup did not begin its body until the
        // prior teardown drained. With the chain fix in `start()` this
        // is `0`; without it, this can be non-zero because the new
        // `lspStartTask` ran on `@MainActor` while the prior teardown
        // Task was still in flight (suspended in `shutdownAll`).
        self.inflightTeardownCountAtLastStartLSPEntry = self.inflightTeardownCount

        // Defensive teardown of any prior bridge so re-entry replaces it
        // cleanly. In the normal `start()` -> `stop()` -> `start()` flow
        // `stop()` already nils `lspBridge`, but tests that drive
        // `startLSP()` directly (or `_testInjectLSPBridge` followed by a
        // real `startLSP()`) can land here with a stale bridge still
        // attached.
        if let priorBridge = lspBridge {
            self.lspBridge = nil
            await priorBridge.service.shutdownAll()
        }

        let registry = LSPServerRegistry.builtIn()
        let runner = SystemCommandRunner()
        let installer = LSPInstaller(registry: registry, runner: runner)
        let factory = StdioBackedLSPSessionFactory()
        // Production wiring uses the FSEvents-backed event source so
        // on-disk edits outside Calyx's own writers feed back into LSP
        // synchronisation notifications.
        let fileSyncManager = FileSyncManager()
        // Default persistence store under
        // `~/Library/Application Support/Calyx/lsp/sessions.json`. Snapshots
        // are written on every `didOpen` / `didClose` and removed on
        // `shutdown()`, so a subsequent launch can replay the open-file
        // set via `LSPService.availableSnapshots()`.
        let persistence = LSPSessionPersistence()
        // Single `DiagnosticsStore` shared between `LSPService` (which
        // hands it to every freshly built `LSPSession` so server
        // `textDocument/publishDiagnostics` notifications are ingested)
        // and `MCPLSPBridge` (which reads from the same store when
        // serving the `lsp_diagnostics_diff` tool). Without the shared
        // reference the store the bridge reads from would never be
        // populated and the diff would always come back empty.
        let diagnosticsStore = DiagnosticsStore()
        let service = LSPService(
            registry: registry,
            installer: installer,
            sessionFactory: factory,
            config: LSPServiceConfig(),
            fileSyncManager: fileSyncManager,
            persistence: persistence,
            diagnosticsStore: diagnosticsStore
        )
        let resolver = WorkspaceResolver(registry: registry)
        self.lspBridge = MCPLSPBridge(
            service: service,
            workspaceResolver: resolver,
            installer: installer,
            diagnosticsStore: diagnosticsStore
        )
    }

    /// For testing only — inject a pre-built `MCPLSPBridge` (typically
    /// wired against a fake `LSPSessionFactory`) so tool dispatch can be
    /// exercised without spawning a real language server.
    func _testInjectLSPBridge(_ bridge: MCPLSPBridge) {
        self.lspBridge = bridge
    }

    /// For testing only — install an arbitrary `Task` reference into the
    /// `lspStartTask` slot so tests can simulate the `start()` → `stop()`
    /// → `start()` race the teardown identity check guards against without
    /// having to bind a real `NWListener` port.
    func _testInjectLSPStartTask(_ task: Task<Void, Never>?) {
        self.lspStartTask = task
    }

    /// For testing only — read the current `lspStartTask` reference so
    /// race-safety tests can `await` its `.value` and observe the new
    /// startup body completing. Returns `nil` between `stop()` (which
    /// clears the slot synchronously) and the next `start()` /
    /// `_testInjectLSPStartTask` call.
    func _testCurrentLSPStartTask() -> Task<Void, Never>? {
        self.lspStartTask
    }

    // MARK: - Lifecycle

    func start(token: String, preferredPort: Int = 41830) throws {
        // Capture the teardown Task scheduled by the prior `stop()` so
        // the new LSP startup can wait for it before installing a fresh
        // bridge. Without this chain the new `lspStartTask` and the
        // prior teardown would both be live on `@MainActor`: the prior
        // teardown's `await pendingStartup?.value` and
        // `await preStartupBridge.shutdownAll()` are suspension points,
        // during which `@MainActor` happily schedules the freshly
        // enqueued `lspStartTask` body. The two `lspStartTask`s end up
        // racing to install bridges into `self.lspBridge`, and the
        // loser leaks a fully-built `LSPService` plus its child
        // language-server processes and `FSEvents` watches.
        //
        // `stop()` synchronously clears `isRunning` / `listener` /
        // `lspBridge` / `lspStartTask` and returns the teardown Task
        // that completes the async portion. Chaining the new
        // `lspStartTask` body off `await priorTeardown.value` makes the
        // ordering explicit: the new `startLSP()` body runs only after
        // the prior teardown has finished its `shutdownAll` and
        // identity check.
        let priorTeardown: Task<Void, Never>? = isRunning ? stop() : nil

        self.token = token

        var lastError: Error?

        // Phase 1: canonical linear scan over `preferredPort..<preferredPort+10`.
        // If a port in that window is free we bind it and publish that exact
        // port — preserves the "well-known port" UX for the common case.
        //
        // `NWListener(using:)` does NOT actually validate the bind — it only
        // checks parameter shape. The kernel-level bind happens later during
        // `start(queue:)` and bind failures (e.g. EADDRINUSE) surface via
        // `stateUpdateHandler` as `.failed`. So we must wait for the listener
        // to reach `.ready` (or `.failed`) before declaring the slot taken.
        // Without this, the loop "succeeds" on the very first port even when
        // the kernel will subsequently refuse the bind, and the listener
        // never accepts connections.
        for portOffset in 0..<10 {
            let tryPort = preferredPort + portOffset
            guard let nl = bindListener(onPort: tryPort) else {
                lastError = NSError(
                    domain: "CalyxMCPServer",
                    code: 3,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Failed to bind to 127.0.0.1:\(tryPort)",
                    ]
                )
                continue
            }
            finishStart(listener: nl, boundPort: tryPort, priorTeardown: priorTeardown)
            return
        }

        // Phase 2: kernel-assigned ephemeral port fallback. The canonical
        // scan exhausted; on a busy host we must not hard-fail. Bind with
        // `NWEndpoint.Port(integerLiteral: 0)` so the kernel picks an
        // ephemeral slot, then read whichever port it actually returned
        // back out of the listener so `self.port` (and downstream the
        // URL published by `ClaudeConfigManager.enableIPC`) stays
        // consistent with the bind.
        if let (nl, resolvedPort) = bindKernelAssignedListener() {
            finishStart(listener: nl, boundPort: resolvedPort, priorTeardown: priorTeardown)
            return
        }

        throw lastError ?? NSError(
            domain: "CalyxMCPServer",
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "Failed to bind to any port in range \(preferredPort)-\(preferredPort + 9) and kernel-assigned fallback also failed",
            ]
        )
    }

    /// Attempt to bind an `NWListener` on `127.0.0.1:<port>`. Returns the
    /// started listener once it reaches `.ready`, or `nil` if the bind
    /// fails (e.g. EADDRINUSE) or does not become ready within 1s.
    ///
    /// Note: the listener's queue is intentionally a dedicated background
    /// queue rather than `.main`. `start()` runs on the main thread and
    /// must block-wait on the state semaphore; running the listener
    /// callbacks on `.main` would deadlock. Once the listener is ready
    /// we reassign `newConnectionHandler` so connections route back into
    /// `@MainActor` via `Task { @MainActor in ... }`.
    private func bindListener(onPort tryPort: Int) -> NWListener? {
        let params = NWParameters.tcp
        let nwPort = NWEndpoint.Port(integerLiteral: UInt16(tryPort))
        params.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: .ipv4(.loopback),
            port: nwPort
        )
        guard let nl = try? NWListener(using: params) else { return nil }
        return startListenerAndWaitForReady(nl)
    }

    /// Bind an `NWListener` with `NWEndpoint.Port(integerLiteral: 0)`
    /// (the kernel-assigned ephemeral slot fallback). Returns the
    /// started listener and the port the kernel actually picked, or
    /// `nil` if the bind fails.
    ///
    /// Implementation note: for the ephemeral case we use the
    /// `NWListener(using:on:)` constructor with `.any` (i.e. port 0)
    /// rather than `requiredLocalEndpoint`. Network framework rejects
    /// `requiredLocalEndpoint` with `host: .ipv4(.loopback), port: 0`
    /// at `start()` time with `nw_path_create_evaluator_for_listener
    /// failed`, but the `on:` form correctly asks the kernel to pick
    /// a free port. Loopback-only binding is then ensured by
    /// `params.requiredInterfaceType = .loopback` (the test harness
    /// connects to `127.0.0.1:<port>` from the same process so this
    /// is consistent with the canonical-scan path's `.ipv4(.loopback)`
    /// bind).
    private func bindKernelAssignedListener() -> (NWListener, Int)? {
        // Network framework rejects `requiredLocalEndpoint` with port 0
        // (returns EINVAL during `nw_path_create_evaluator_for_listener`).
        // Strategy: use the BSD socket API to ask the kernel for a free
        // ephemeral port on 127.0.0.1, then probe that exact port via
        // `requiredLocalEndpoint` with the resolved port number. The
        // BSD socket is closed before NWListener binds; the race window
        // is sub-millisecond and the test exercises a host where the
        // pre-bound ports are deliberately outside this range.
        //
        // Try up to a handful of kernel-assigned ports — if one happens
        // to lose the close→bind race we ask the kernel for another.
        for attempt in 0..<5 {
            guard let resolvedPort = askKernelForFreeLoopbackPort() else {
                NSLog("[CalyxMCPServer] BSD fallback attempt \(attempt): kernel did not return a port")
                continue
            }

            let params = NWParameters.tcp
            let nwPort = NWEndpoint.Port(integerLiteral: UInt16(resolvedPort))
            params.requiredLocalEndpoint = NWEndpoint.hostPort(
                host: .ipv4(.loopback),
                port: nwPort
            )
            guard let nl = try? NWListener(using: params) else { continue }
            if let ready = startListenerAndWaitForReady(nl) {
                return (ready, resolvedPort)
            }
        }
        return nil
    }

    /// Ask the kernel for a free ephemeral port on `127.0.0.1` by
    /// binding a throwaway BSD socket to `127.0.0.1:0`, reading the
    /// assigned port via `getsockname`, then closing the socket. The
    /// returned port is the kernel's choice from the ephemeral range —
    /// use it as the desired port for an `NWListener` bind.
    private func askKernelForFreeLoopbackPort() -> Int? {
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = UInt32(0x7F000001).bigEndian  // 127.0.0.1
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)

        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        let bindResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                Darwin.bind(fd, saPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { return nil }

        var boundAddr = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &boundAddr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                getsockname(fd, saPtr, &len)
            }
        }
        guard nameResult == 0 else { return nil }
        let resolvedPort = Int(UInt16(bigEndian: boundAddr.sin_port))
        return resolvedPort != 0 ? resolvedPort : nil
    }

    /// Shared helper: start `nl` on a dedicated background queue and
    /// block until it reaches `.ready` (success) or `.failed` /
    /// `.cancelled` / timeout (failure). Returns the listener on
    /// success, `nil` on failure.
    private func startListenerAndWaitForReady(_ nl: NWListener) -> NWListener? {
        // Reference-typed box so the `stateUpdateHandler` closure
        // (running on the listener queue) and the main-thread reader
        // after `sema.wait` share a single storage cell without
        // triggering Swift 6's "concurrently-executing var capture"
        // diagnostic. The semaphore signal/wait provides the
        // happens-before edge that makes the unsynchronised
        // assignment safe.
        final class OutcomeBox: @unchecked Sendable {
            var didSucceed: Bool = false
        }
        let box = OutcomeBox()
        let sema = DispatchSemaphore(value: 0)
        let listenerQueue = DispatchQueue(
            label: "CalyxMCPServer.listenerProbe"
        )
        nl.stateUpdateHandler = { state in
            switch state {
            case .ready:
                box.didSucceed = true
                sema.signal()
            case .failed(let err):
                NSLog("[CalyxMCPServer] probe listener failed: \(err)")
                box.didSucceed = false
                sema.signal()
            case .cancelled:
                box.didSucceed = false
                sema.signal()
            default:
                break
            }
        }
        // NWListener fails its `start()` with EINVAL when no
        // `newConnectionHandler` is set before `start()` is invoked.
        // Install a no-op placeholder here purely to satisfy the
        // start-time invariant; `finishStart` reassigns the real
        // production handler after the probe completes successfully.
        // Without this placeholder every bind in the canonical
        // 41830-41839 scan fails with `POSIXErrorCode(rawValue: 22)`
        // and `start()` ends up in the kernel-assigned fallback path
        // unconditionally — which used to throw outright before the
        // fallback existed, breaking previously-passing tests.
        nl.newConnectionHandler = { connection in
            connection.cancel()
        }
        nl.start(queue: listenerQueue)

        // 1s is generous: a successful loopback bind reaches `.ready` in
        // sub-millisecond on a healthy host; bind failures are reported
        // essentially synchronously from the kernel. We cap so a wedged
        // listener never blocks `start()` indefinitely.
        let result = sema.wait(timeout: .now() + 1.0)
        if result == .timedOut || !box.didSucceed {
            nl.cancel()
            return nil
        }
        return nl
    }

    /// Common tail of every successful bind path. Installs the
    /// production `newConnectionHandler`, records bookkeeping state
    /// (`port` / `isRunning` / peer registration / LSP startup), and
    /// chains the new LSP startup off the prior teardown.
    ///
    /// The listener arrives here already started (on its probe queue)
    /// and in `.ready` state, so we only need to replace the
    /// `stateUpdateHandler` / `newConnectionHandler` with the
    /// production wiring.
    private func finishStart(
        listener nl: NWListener,
        boundPort: Int,
        priorTeardown: Task<Void, Never>?
    ) {
        // Drop the probe handler — from here on we don't need to
        // observe further state transitions.
        nl.stateUpdateHandler = nil
        nl.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                self?.handleConnection(connection)
            }
        }

        self.listener = nl
        self.port = boundPort
        self.isRunning = true
        self.peerRegistrationTask = Task {
            let peer = await self.store.registerPeer(name: "calyx-app", role: "review-ui")
            self.appPeerID = peer.id
        }
        // Retain the LSP startup task so `stop()` can cancel + await
        // it before tearing down the resulting bridge. The body
        // first awaits the prior teardown (if any) so the new
        // `startLSP()` install never races a previous bridge
        // shutdown — see the comment above the `priorTeardown`
        // capture for the leak this guards against.
        self.lspStartTask = Task { @MainActor in
            if let priorTeardown {
                await priorTeardown.value
            }
            if Task.isCancelled { return }
            await self.startLSP()
        }
    }

    @discardableResult
    func stop() -> Task<Void, Never> {
        listener?.cancel()
        listener = nil
        isRunning = false
        appPeerID = nil
        peerRegistrationTask?.cancel()
        peerRegistrationTask = nil
        port = 0
        Task { await store.cleanup() }

        // LSP bridge teardown. `stop()` is synchronous to match the
        // existing call sites (`CalyxWindowController.disableIPC`,
        // `start()`'s reset-on-toggle path) so we schedule the actual
        // service shutdown on a fire-and-forget Task. The listener is
        // already cancelled at this point so no new requests can land in
        // the meantime; what matters is that the in-flight `startLSP()`
        // — if any — gets cancelled and awaited before we ask its
        // bridge to release every child LSP process and `FSEvents`
        // watch.
        //
        // The teardown Task is returned to the caller so a follow-up
        // `start()` can chain its new `lspStartTask` body off
        // `await teardown.value` — closing the race where the new
        // startup body would otherwise run on `@MainActor` while this
        // teardown was still suspended in `shutdownAll`, allowing both
        // `lspStartTask`s to race to install bridges. `stopAndWait()`
        // also uses the return value to drain teardown synchronously
        // from async contexts.
        //
        // Race-safety: callers polling `lspBridge` right after `stop()`
        // observe a cleared state, and a follow-up `start(B)` landing
        // before the teardown Task wakes must NOT have its
        // freshly-installed bridge clobbered. We achieve both by:
        //
        //   1. Snapshotting `pendingStartup` + `preStartupBridge` and
        //      synchronously clearing `lspStartTask` / `lspBridge`.
        //   2. Inside the Task: cancel + await the snapshotted startup
        //      so any in-flight `startLSP()` finishes before we touch
        //      its bridge, then unconditionally shut down
        //      `preStartupBridge` (it belonged to us).
        //   3. Identity-checking `self.lspStartTask` as the gate: if it
        //      is still `nil`, no follow-up `start()` has landed and any
        //      bridge that surfaced in `self.lspBridge` between the sync
        //      clear and now is also ours (a late `startLSP()` racing
        //      past the clear). If it is non-`nil`, a follow-up
        //      `start(B)` has taken over and the bridge in
        //      `self.lspBridge` belongs to that new startup — we leave
        //      it untouched. The previous identity-agnostic re-read
        //      would tear down `start(B)`'s bridge, leaving the server
        //      in a state where `isRunning == true` yet every `lsp_*`
        //      tool returned "LSP bridge is not started".
        let pendingStartup = lspStartTask
        let preStartupBridge = lspBridge
        self.lspStartTask = nil
        self.lspBridge = nil
        self.inflightTeardownCount += 1
        let teardown = Task { @MainActor in
            defer { self.inflightTeardownCount -= 1 }

            pendingStartup?.cancel()
            _ = await pendingStartup?.value

            // Shut down the bridge that this `stop()` owns. Always
            // safe — `preStartupBridge` was the live bridge at the
            // moment of the sync clear, and no later code path
            // reinstates it.
            await preStartupBridge?.service.shutdownAll()

            // Identity gate. A non-nil `lspStartTask` means a
            // follow-up `start(B)` already took over since our sync
            // clear; the bridge currently in `self.lspBridge` (if
            // any) belongs to that new startup and must be left
            // alone.
            guard self.lspStartTask == nil else {
                return
            }

            // No follow-up start landed. If a late `startLSP()`
            // installed a bridge after our sync clear, it is ours to
            // tear down. The `!==` guard short-circuits when
            // `self.lspBridge` somehow points back at the same
            // instance as `preStartupBridge` (already shut down
            // above).
            let postStartupBridge = self.lspBridge
            if postStartupBridge !== preStartupBridge,
               let bridge = postStartupBridge {
                self.lspBridge = nil
                await bridge.service.shutdownAll()
            }
        }
        return teardown
    }

    /// Async variant of `stop()` that awaits the teardown Task to
    /// completion before returning. Use this from async contexts — most
    /// importantly any caller racing a follow-up `start()` — where the
    /// new code path must not run until the prior bridge teardown has
    /// fully drained.
    func stopAndWait() async {
        let teardown = stop()
        await teardown.value
    }

    /// Ensures the app peer is registered before proceeding.
    /// Call this before accessing `appPeerID` from async contexts.
    func ensureAppPeerRegistered() async {
        await peerRegistrationTask?.value
    }

    // MARK: - Connection Handling

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: .main)
        connection.receive(minimumIncompleteLength: 1, maximumLength: HTTPParser.maxHeaderSize + HTTPParser.maxBodySize) { [weak self] data, _, _, error in
            Task { @MainActor [weak self] in
                guard let self, let data else {
                    connection.cancel()
                    return
                }

                do {
                    let httpRequest = try HTTPParser.parse(data)

                    // Only accept POST /mcp
                    guard httpRequest.method == "POST", httpRequest.path == "/mcp" else {
                        self.sendHTTPResponse(connection: connection, httpResponse: HTTPParser.response(statusCode: 404, body: nil))
                        return
                    }

                    // Extract bearer token from Authorization header (case-insensitive)
                    let authToken: String? = {
                        for (key, value) in httpRequest.headers {
                            if key.lowercased() == "authorization", value.hasPrefix("Bearer ") {
                                return String(value.dropFirst(7))
                            }
                        }
                        return nil
                    }()

                    guard let body = httpRequest.body else {
                        self.sendHTTPResponse(connection: connection, httpResponse: HTTPParser.response(statusCode: 400, body: nil))
                        return
                    }

                    let (statusCode, responseBody) = await self.handleJSONRPC(data: body, authToken: authToken)
                    let httpResponse = HTTPParser.response(statusCode: statusCode, body: responseBody)
                    self.sendHTTPResponse(connection: connection, httpResponse: httpResponse)
                } catch let error as HTTPParseError {
                    let statusCode: Int
                    switch error {
                    case .headerTooLarge, .bodyTooLarge: statusCode = 413
                    case .invalidContentLength, .malformedRequest: statusCode = 400
                    case .timeout: statusCode = 408
                    }
                    self.sendHTTPResponse(connection: connection, httpResponse: HTTPParser.response(statusCode: statusCode, body: nil))
                } catch {
                    self.sendHTTPResponse(connection: connection, httpResponse: HTTPParser.response(statusCode: 500, body: nil))
                }
            }
        }
    }

    private func sendHTTPResponse(connection: NWConnection, httpResponse: HTTPResponse) {
        let data = httpResponse.serialize()
        connection.send(content: data, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    // MARK: - JSON-RPC Handler

    /// Process a single JSON-RPC request.
    /// Returns an HTTP-like status code and optional response body.
    func handleJSONRPC(data: Data, authToken: String?) async -> (statusCode: Int, body: Data?) {

        // 1. Authentication
        guard let authToken, authToken == token else {
            return unauthorizedResponse()
        }

        // 2. Parse JSON
        let request: JSONRPCRequest
        do {
            request = try JSONDecoder().decode(JSONRPCRequest.self, from: data)
        } catch {
            let resp = MCPRouter.buildErrorResponse(id: nil, code: -32700, message: "Parse error")
            return (200, encode(resp))
        }

        // 3. Notifications (no id) → 204
        guard let requestId = request.id else {
            return (204, nil)
        }

        // 4. Route by method
        switch request.method {
        case "initialize":
            // Auto-register the connecting client as a peer
            let clientName = extractClientName(from: request.params) ?? "claude-code"
            let peer = await store.registerPeer(name: clientName, role: "claude-code")
            let resp = MCPRouter.buildInitializeResponse(id: requestId, peerID: peer.id)
            return (200, encode(resp))

        case "tools/list":
            let resp = MCPRouter.buildToolsListResponse(id: requestId)
            return (200, encode(resp))

        case "notifications/initialized":
            return (204, nil)

        case "tools/call":
            return await handleToolCall(id: requestId, params: request.params)

        default:
            let resp = MCPRouter.buildErrorResponse(id: requestId, code: -32601, message: "Method not found")
            return (200, encode(resp))
        }
    }

    // MARK: - Tool Call Dispatch

    private func handleToolCall(
        id: JSONRPCId,
        params: [String: AnyCodable]?
    ) async -> (statusCode: Int, body: Data?) {

        guard let params else {
            return toolError(id: id, text: "Missing params")
        }

        guard let toolName = extractString(params, "name") else {
            return toolError(id: id, text: "Missing tool name")
        }

        // LSP route — `lsp_*` tools are dispatched through `MCPLSPBridge`.
        if MCPRouter.isLSPTool(name: toolName) {
            return await handleLSPToolCall(
                id: id,
                toolName: toolName,
                params: params
            )
        }

        let arguments = extractDict(params, "arguments")

        switch toolName {
        case "register_peer":
            return await handleRegisterPeer(id: id, arguments: arguments)

        case "list_peers":
            return await handleListPeers(id: id)

        case "send_message":
            return await handleSendMessage(id: id, arguments: arguments)

        case "broadcast":
            return await handleBroadcast(id: id, arguments: arguments)

        case "receive_messages":
            return await handleReceiveMessages(id: id, arguments: arguments)

        case "ack_messages":
            return await handleAckMessages(id: id, arguments: arguments)

        case "get_peer_status":
            return await handleGetPeerStatus(id: id, arguments: arguments)

        default:
            return toolError(id: id, text: "Unknown tool: \(toolName)")
        }
    }

    // MARK: - Tool Handlers

    private func handleRegisterPeer(
        id: JSONRPCId,
        arguments: [String: Any]?
    ) async -> (statusCode: Int, body: Data?) {
        let name = (arguments?["name"] as? String) ?? ""
        let role = (arguments?["role"] as? String) ?? ""
        let peer = await store.registerPeer(name: name, role: role)
        let json = "{\"peerId\":\"\(peer.id.uuidString)\"}"
        return toolSuccess(id: id, text: json)
    }

    private func handleListPeers(
        id: JSONRPCId
    ) async -> (statusCode: Int, body: Data?) {
        let peers = await store.listPeers()
        let peerDicts: [[String: Any]] = peers.map { peerToDict($0) }
        let result: [String: Any] = ["peers": peerDicts]
        guard let jsonData = try? JSONSerialization.data(withJSONObject: result),
              let json = String(data: jsonData, encoding: .utf8) else {
            return toolError(id: id, text: "Failed to serialize peers")
        }
        return toolSuccess(id: id, text: json)
    }

    private func handleSendMessage(
        id: JSONRPCId,
        arguments: [String: Any]?
    ) async -> (statusCode: Int, body: Data?) {
        guard let fromStr = arguments?["from"] as? String,
              let toStr = arguments?["to"] as? String,
              let content = arguments?["content"] as? String,
              let fromUUID = UUID(uuidString: fromStr),
              let toUUID = UUID(uuidString: toStr) else {
            return toolError(id: id, text: "Missing or invalid from/to/content")
        }

        do {
            let message = try await store.sendMessage(from: fromUUID, to: toUUID, content: content)
            let json = "{\"messageId\":\"\(message.id.uuidString)\"}"
            return toolSuccess(id: id, text: json)
        } catch let error as IPCError {
            return toolError(id: id, text: error.errorDescription ?? error.localizedDescription)
        } catch {
            return toolError(id: id, text: error.localizedDescription)
        }
    }

    private func handleBroadcast(
        id: JSONRPCId,
        arguments: [String: Any]?
    ) async -> (statusCode: Int, body: Data?) {
        guard let fromStr = arguments?["from"] as? String,
              let content = arguments?["content"] as? String,
              let fromUUID = UUID(uuidString: fromStr) else {
            return toolError(id: id, text: "Missing or invalid from/content")
        }

        do {
            let messages = try await store.broadcast(from: fromUUID, content: content)
            let json = "{\"messageCount\":\(messages.count)}"
            return toolSuccess(id: id, text: json)
        } catch let error as IPCError {
            return toolError(id: id, text: error.errorDescription ?? error.localizedDescription)
        } catch {
            return toolError(id: id, text: error.localizedDescription)
        }
    }

    private func handleReceiveMessages(
        id: JSONRPCId,
        arguments: [String: Any]?
    ) async -> (statusCode: Int, body: Data?) {
        guard let peerStr = arguments?["peer_id"] as? String,
              let peerUUID = UUID(uuidString: peerStr) else {
            return toolError(id: id, text: "Missing or invalid peer_id")
        }

        let messages = await store.receiveMessages(for: peerUUID)
        let messageDicts: [[String: Any]] = messages.map { messageToDict($0) }
        let result: [String: Any] = ["messages": messageDicts]
        guard let jsonData = try? JSONSerialization.data(withJSONObject: result),
              let json = String(data: jsonData, encoding: .utf8) else {
            return toolError(id: id, text: "Failed to serialize messages")
        }
        return toolSuccess(id: id, text: json)
    }

    private func handleAckMessages(
        id: JSONRPCId,
        arguments: [String: Any]?
    ) async -> (statusCode: Int, body: Data?) {
        guard let peerStr = arguments?["peer_id"] as? String,
              let peerUUID = UUID(uuidString: peerStr),
              let messageIdStrings = arguments?["message_ids"] as? [String] else {
            return toolError(id: id, text: "Missing or invalid peer_id/message_ids")
        }

        let messageUUIDs = messageIdStrings.compactMap { UUID(uuidString: $0) }
        await store.ackMessages(ids: messageUUIDs, for: peerUUID)
        let json = "{\"acknowledged\":\(messageUUIDs.count)}"
        return toolSuccess(id: id, text: json)
    }

    private func handleGetPeerStatus(
        id: JSONRPCId,
        arguments: [String: Any]?
    ) async -> (statusCode: Int, body: Data?) {
        guard let peerStr = arguments?["peer_id"] as? String,
              let peerUUID = UUID(uuidString: peerStr) else {
            return toolError(id: id, text: "Missing or invalid peer_id")
        }

        guard let peer = await store.peerStatus(id: peerUUID) else {
            return toolError(id: id, text: "Peer not found")
        }

        let dict = peerToDict(peer)
        guard let jsonData = try? JSONSerialization.data(withJSONObject: dict),
              let json = String(data: jsonData, encoding: .utf8) else {
            return toolError(id: id, text: "Failed to serialize peer")
        }
        return toolSuccess(id: id, text: json)
    }

    // MARK: - LSP Tool Dispatch

    /// Route an `lsp_*` tool call to the configured `MCPLSPBridge`.
    /// Returns a structured error when the bridge has not been started,
    /// the tool name is unknown, or an argument fails validation. The
    /// bridge itself catches LSP server errors and shapes them into the
    /// returned `MCPContent.text`, so this method only has to translate
    /// bridge-side validation failures into MCP error envelopes.
    private func handleLSPToolCall(
        id: JSONRPCId,
        toolName: String,
        params: [String: AnyCodable]
    ) async -> (statusCode: Int, body: Data?) {
        guard let bridge = lspBridge else {
            return toolError(
                id: id,
                text: "LSP bridge is not started. Call startLSP() first."
            )
        }

        let arguments = extractAnyCodableDict(params, "arguments") ?? [:]

        do {
            let content = try await bridge.handleToolCall(
                name: toolName,
                arguments: arguments
            )
            let resp = MCPRouter.buildToolCallResponse(
                id: id,
                content: [content],
                isError: false
            )
            return (200, encode(resp))
        } catch let error as MCPLSPBridgeError {
            let text: String
            switch error {
            case .unknownTool(let name):
                text = "Unknown LSP tool: \(name)"
            case .missingArgument(let key):
                text = "Missing argument: \(key)"
            case .invalidArgument(let name, let reason):
                text = "Invalid argument \(name): \(reason)"
            }
            return toolError(id: id, text: text)
        } catch {
            return toolError(
                id: id,
                text: "LSP tool error: \(error.localizedDescription)"
            )
        }
    }

    // MARK: - Response Helpers

    private func unauthorizedResponse() -> (statusCode: Int, body: Data?) {
        let dict: [String: Any] = ["error": "Unauthorized"]
        let data = try? JSONSerialization.data(withJSONObject: dict)
        return (401, data)
    }

    private func toolSuccess(id: JSONRPCId, text: String) -> (statusCode: Int, body: Data?) {
        let content = [MCPContent(type: "text", text: text)]
        let resp = MCPRouter.buildToolCallResponse(id: id, content: content, isError: false)
        return (200, encode(resp))
    }

    private func toolError(id: JSONRPCId, text: String) -> (statusCode: Int, body: Data?) {
        let content = [MCPContent(type: "text", text: text)]
        let resp = MCPRouter.buildToolCallResponse(id: id, content: content, isError: true)
        return (200, encode(resp))
    }

    private func encode(_ response: JSONRPCResponse) -> Data? {
        try? JSONEncoder().encode(response)
    }

    // MARK: - Serialization Helpers

    private func peerToDict(_ peer: Peer) -> [String: Any] {
        [
            "id": peer.id.uuidString,
            "name": peer.name,
            "role": peer.role,
            "lastSeen": Self.iso8601.string(from: peer.lastSeen),
            "registeredAt": Self.iso8601.string(from: peer.registeredAt),
        ]
    }

    private func messageToDict(_ message: Message) -> [String: Any] {
        [
            "id": message.id.uuidString,
            "from": message.from.uuidString,
            "to": message.to.uuidString,
            "content": message.content,
            "timestamp": Self.iso8601.string(from: message.timestamp),
        ]
    }

    // MARK: - AnyCodable Extraction Helpers

    /// Extract a string value from an AnyCodable dictionary.
    private func extractString(_ dict: [String: AnyCodable], _ key: String) -> String? {
        guard let value = dict[key] else { return nil }
        // Encode the AnyCodable to JSON, then decode as a plain string
        guard let data = try? JSONEncoder().encode(value),
              let str = try? JSONDecoder().decode(String.self, from: data) else {
            return nil
        }
        return str
    }

    /// Extract a [String: Any] dictionary from an AnyCodable value at the given key.
    private func extractDict(_ dict: [String: AnyCodable], _ key: String) -> [String: Any]? {
        guard let value = dict[key] else { return nil }
        guard let data = try? JSONEncoder().encode(value),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return obj
    }

    /// Extract a `[String: AnyCodable]` map from an `AnyCodable` value at
    /// the given key. Used to forward `tools/call.arguments` to the LSP
    /// bridge, which is keyed on `AnyCodable`.
    private func extractAnyCodableDict(
        _ dict: [String: AnyCodable],
        _ key: String
    ) -> [String: AnyCodable]? {
        guard let value = dict[key] else { return nil }
        guard let data = try? JSONEncoder().encode(value),
              let decoded = try? JSONDecoder().decode(
                [String: AnyCodable].self,
                from: data
              )
        else { return nil }
        return decoded
    }

    /// Extract the client name from an initialize request's clientInfo.
    private func extractClientName(from params: [String: AnyCodable]?) -> String? {
        guard let params,
              let clientInfoDict = extractDict(params, "clientInfo"),
              let name = clientInfoDict["name"] as? String else {
            return nil
        }
        return name
    }
}
