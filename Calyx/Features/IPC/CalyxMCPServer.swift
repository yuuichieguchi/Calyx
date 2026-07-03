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

    // MARK: - Agent Monitor

    /// Registry that `/agent-event` writes into. Defaults to the shared
    /// singleton; tests inject an isolated instance so assertions don't
    /// leak state across cases.
    var agentRegistry: AgentRegistry = .shared

    /// Directory `agent-endpoint.json` is written to (by `finishStart`)
    /// and removed from (by `stop()`). Defaults to
    /// `AgentEndpointFile.defaultDirectory`
    /// (`~/Library/Application Support/Calyx`); tests inject a per-test
    /// temp directory so `start()`/`stop()` never touch the real file.
    var agentEndpointDirectory: String = AgentEndpointFile.defaultDirectory

    /// The slow-loris deadline `handleConnection` bounds *receiving* a
    /// complete request to (not request processing — see
    /// `handleConnection`'s doc comment). 10s in production;
    /// test-overridable so tests can exercise both "receiving itself is
    /// slow, hits the deadline" and "receiving is fast, `route(request:)`
    /// alone taking a long time must not hit it" without either waiting
    /// a full 10s or shrinking the production default.
    var connectionReceiveDeadline: Duration = .seconds(10)

    /// Test-only artificial delay injected at the top of
    /// `route(request:)`, used to simulate a slow `tools/call` (e.g. a
    /// long-running `lsp_*` tool, which can legitimately run for up to
    /// an hour — see `LSPTimeouts`) without depending on a real slow
    /// language server. `nil` (no delay) in production and by default
    /// in every test that doesn't explicitly set it.
    var _testRouteDelay: Duration?

    /// Test-only counter of how many times `sendHTTPResponse` was
    /// *entered* for any connection on this server instance —
    /// incremented unconditionally, before its `accumulator.didRespond`
    /// guard. Confirmed empirically (Round 5 final review) to reach `2`
    /// for a single connection in the exact scenario the deadline
    /// double-send bug describes — the guard makes the second entry a
    /// harmless no-op, but does not prevent the entry itself, so this
    /// counter alone is *not* the correctness signal a test should
    /// assert `== 1` against. See `_testSendHTTPResponseSentCount` for
    /// that, and `sendHTTPResponse`'s doc comment for why a wire-level
    /// "did the client see two responses" check can't reliably
    /// distinguish the fixed and unfixed behavior either (the
    /// connection may already be torn down by the time a stale second
    /// entry happens, silently dropping its `connection.send(...)`
    /// bytes before they ever reach a test's socket).
    private(set) var _testSendHTTPResponseAttemptCount = 0

    /// Test-only counter of how many times `sendHTTPResponse` actually
    /// proceeded past its `accumulator.didRespond` guard to call
    /// `connection.send(...)` — i.e. the count that must stay at `1` per
    /// connection for the Round 5 final review's Critical fix to hold.
    /// See `_testSendHTTPResponseAttemptCount` for the (deliberately
    /// unguarded) entry counter this complements.
    private(set) var _testSendHTTPResponseSentCount = 0

    /// Routes an `HTTPRequest` by path. `POST /mcp` dispatches to the
    /// existing `handleJSONRPC`; `POST /agent-event` dispatches to
    /// `handleAgentEvent`. Everything else is 404. Extracted from
    /// `handleConnection` so tests can drive routing directly without a
    /// real `NWConnection`.
    func route(request: HTTPRequest) async -> HTTPResponse {
        if let delay = _testRouteDelay {
            try? await Task.sleep(for: delay)
        }
        switch (request.method, request.path) {
        case ("POST", "/mcp"):
            return await routeMCP(request: request)
        case ("POST", "/agent-event"):
            return await routeAgentEvent(request: request)
        default:
            return HTTPParser.response(statusCode: 404, body: nil)
        }
    }

    private func routeMCP(request: HTTPRequest) async -> HTTPResponse {
        let authToken = bearerToken(from: request.headers)
        guard let body = request.body else {
            return HTTPParser.response(statusCode: 400, body: nil)
        }
        // A missing, empty, or non-UUID value means "no surface binding
        // for this connection" here — unlike `/agent-event`'s required
        // header below, `/mcp` predates `X-Calyx-Surface-ID`, and every
        // existing MCP client that doesn't send it (or an older Claude
        // Code build whose `${VAR:-default}` expansion isn't supported,
        // leaving the literal placeholder string in place) must keep
        // working exactly as before — so `nil` here is not a request
        // error, just "not bound".
        let surfaceID = parseSurfaceID(from: request.headers)
        let (statusCode, responseBody) = await handleJSONRPC(data: body, authToken: authToken, surfaceID: surfaceID)
        return HTTPParser.response(statusCode: statusCode, body: responseBody)
    }

    /// Trims whitespace from `X-Calyx-Surface-ID` and parses it as a
    /// `UUID`, returning `nil` for a missing, empty, or non-UUID value.
    /// Shared (Round 4 review) by both `/mcp` (`routeMCP`) and
    /// `/agent-event` (`routeAgentEvent`) so the same header — sent by an
    /// actual Claude Code MCP client on one route and by
    /// `calyx-agent-hook`'s own hook POST on the other — is parsed
    /// identically on both: e.g. a value padded with incidental
    /// whitespace parses the same way regardless of which route received
    /// it, rather than one route trimming and the other not. What differs
    /// per route is only what a `nil` result *means*: `routeMCP` treats it
    /// as "no binding for this connection" (see its own comment),
    /// `routeAgentEvent` treats it as a 400 request error (the header is
    /// required there).
    ///
    /// The `trimmingCharacters` call below is defensive duplication:
    /// `HTTPParser` already trims every header value while parsing the
    /// raw request, so in practice `headers` never contains untrimmed
    /// whitespace by the time it reaches here. Kept anyway as a
    /// self-contained guarantee against a future `HTTPParser` change (or
    /// a header dictionary built directly in a test) that stops trimming.
    private func parseSurfaceID(from headers: [String: String]) -> UUID? {
        guard let trimmed = header(named: "X-Calyx-Surface-ID", in: headers)?
            .trimmingCharacters(in: .whitespaces), !trimmed.isEmpty else {
            return nil
        }
        return UUID(uuidString: trimmed)
    }

    private func routeAgentEvent(request: HTTPRequest) async -> HTTPResponse {
        guard let authToken = bearerToken(from: request.headers), authToken == token else {
            return HTTPParser.response(statusCode: 401, body: nil)
        }

        guard let surfaceID = parseSurfaceID(from: request.headers) else {
            return HTTPParser.response(statusCode: 400, body: nil)
        }

        guard let body = request.body, let event = AgentEvent.decode(from: body) else {
            return HTTPParser.response(statusCode: 400, body: nil)
        }

        // Trim whitespace and fall back to claude-code when the header is
        // absent OR present-but-blank (e.g. a proxy/plugin bug that sends
        // `X-Calyx-Agent-Kind: ` with no value), rather than letting an
        // empty-string kind reach the registry and the sidebar.
        let kind: String
        if let trimmed = header(named: "X-Calyx-Agent-Kind", in: request.headers)?
            .trimmingCharacters(in: .whitespaces), !trimmed.isEmpty {
            kind = trimmed
        } else {
            kind = AgentEntry.claudeCodeKind
        }
        agentRegistry.handleHookEvent(event, surfaceID: surfaceID, kind: kind)
        return HTTPParser.response(statusCode: 204, body: nil)
    }

    /// Case-insensitive `Authorization: Bearer <token>` extraction, shared
    /// by both `/mcp` and `/agent-event`. Built on `header(named:in:)` so
    /// the case-insensitive lookup itself exists in exactly one place.
    private func bearerToken(from headers: [String: String]) -> String? {
        guard let value = header(named: "Authorization", in: headers), value.hasPrefix("Bearer ") else {
            return nil
        }
        return String(value.dropFirst(7))
    }

    /// Case-insensitive header lookup by name.
    private func header(named name: String, in headers: [String: String]) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
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
        // If a port in that window is free we bind it and publish the port
        // the listener actually resolved to (see `bindListener(onPort:)`) —
        // which matches the requested port for the common non-zero case,
        // preserving the "well-known port" UX, but can differ when
        // `preferredPort` is `0` and the kernel silently assigns an
        // ephemeral slot instead of literally binding port `0` (see
        // `bindKernelAssignedListener`'s doc comment for why that can
        // happen even on this, the canonical-scan, path).
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
            guard let (nl, resolvedPort) = bindListener(onPort: tryPort) else {
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
            if resolvedPort != tryPort {
                NSLog("[CalyxMCPServer] canonical scan requested port \(tryPort) but the listener resolved to \(resolvedPort); recording the resolved port")
            }
            finishStart(listener: nl, boundPort: resolvedPort, priorTeardown: priorTeardown)
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
    /// started listener together with the port it actually resolved to
    /// once ready, or `nil` if the bind fails (e.g. EADDRINUSE), does not
    /// become ready within 1s, or reaches `.ready` without a resolvable
    /// non-zero port.
    ///
    /// The resolved port is read back from `nl.port?.rawValue` rather than
    /// trusted to equal `tryPort` because `requiredLocalEndpoint` with a
    /// literal port of `0` is not rejected by Network framework on every
    /// host (Round 5 / task #47 — see `bindKernelAssignedListener`'s doc
    /// comment): on hosts where it isn't rejected, this very function can
    /// reach `.ready` with the kernel having silently picked an ephemeral
    /// port for `tryPort == 0`, and the only way to learn which port that
    /// is is to ask the listener itself. A `nil`/`0` readback here is
    /// treated as a bind failure (cancel + `nil`) so a caller can never
    /// record port `0` as if it were a successful bind.
    ///
    /// Note: the listener's queue is intentionally a dedicated background
    /// queue rather than `.main`. `start()` runs on the main thread and
    /// must block-wait on the state semaphore; running the listener
    /// callbacks on `.main` would deadlock. Once the listener is ready
    /// we reassign `newConnectionHandler` so connections route back into
    /// `@MainActor` via `Task { @MainActor in ... }`.
    private func bindListener(onPort tryPort: Int) -> (NWListener, Int)? {
        let params = NWParameters.tcp
        let nwPort = NWEndpoint.Port(integerLiteral: UInt16(tryPort))
        params.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: .ipv4(.loopback),
            port: nwPort
        )
        guard let nl = try? NWListener(using: params) else { return nil }
        guard let ready = startListenerAndWaitForReady(nl) else { return nil }
        guard let resolvedPort = ready.port?.rawValue, resolvedPort != 0 else {
            ready.cancel()
            return nil
        }
        return (ready, Int(resolvedPort))
    }

    /// Fallback bind path used when the canonical scan (Phase 1 in
    /// `start()`) exhausts `preferredPort..<preferredPort+10` without
    /// finding a free port. Asks the kernel for a free ephemeral loopback
    /// port via a throwaway BSD socket, then binds an `NWListener` to
    /// that resolved port with `requiredLocalEndpoint`. Returns the
    /// started listener and the port the kernel actually picked, or
    /// `nil` if every attempt fails.
    ///
    /// Implementation note: this path resolves a concrete port via a BSD
    /// socket before ever touching `NWListener`, rather than binding
    /// `requiredLocalEndpoint` with a literal port of `0` directly, on
    /// the assumption that Network framework rejects a literal-`0`
    /// `requiredLocalEndpoint` at `start()` time
    /// (`nw_path_create_evaluator_for_listener failed`). Round 5 (task
    /// #47) established that this rejection is environment-dependent,
    /// not universal: on hosts where it does *not* reject the bind, a
    /// literal-`0` `requiredLocalEndpoint` reaches `.ready` directly,
    /// with the kernel silently choosing the ephemeral port during
    /// Phase 1's canonical scan itself (`bindListener(onPort:)`) —
    /// which is exactly why `bindListener(onPort:)` reads back
    /// `nl.port?.rawValue` after `.ready` instead of trusting the
    /// requested port. This fallback remains in place for hosts where
    /// the literal-`0` bind genuinely is rejected and the canonical
    /// scan's `tryPort == 0` iteration fails outright.
    ///
    /// `internal` (not `private`) so `CalyxMCPServerTests` can exercise
    /// it directly via `@testable import` without needing to exhaust
    /// the whole canonical scan range first just to reach this path.
    func bindKernelAssignedListener() -> (NWListener, Int)? {
        // Strategy: use the BSD socket API to ask the kernel for a free
        // ephemeral port on 127.0.0.1, then probe that exact port via
        // `requiredLocalEndpoint` with the resolved port number — see
        // this function's doc comment for why a literal port `0` isn't
        // handed to `NWListener` directly. The BSD socket is closed
        // before NWListener binds; the race window is sub-millisecond
        // and the test exercises a host where the pre-bound ports are
        // deliberately outside this range.
        //
        // Try up to a handful of kernel-assigned ports — if one happens
        // to lose the close→bind race we ask the kernel for another.
        for attempt in 0..<5 {
            guard let probedPort = askKernelForFreeLoopbackPort() else {
                NSLog("[CalyxMCPServer] BSD fallback attempt \(attempt): kernel did not return a port")
                continue
            }

            let params = NWParameters.tcp
            let nwPort = NWEndpoint.Port(integerLiteral: UInt16(probedPort))
            params.requiredLocalEndpoint = NWEndpoint.hostPort(
                host: .ipv4(.loopback),
                port: nwPort
            )
            guard let nl = try? NWListener(using: params) else { continue }
            guard let ready = startListenerAndWaitForReady(nl) else { continue }

            // Symmetric with `bindListener(onPort:)`: read the port the
            // listener itself actually resolved to, rather than
            // trusting `probedPort` (the pre-bind BSD-socket probe) to
            // still be accurate. No observed real-world divergence
            // between the two today — the BSD socket is closed before
            // `NWListener` binds, and the race window between them is
            // sub-millisecond — but nothing structurally guarantees
            // they can never differ, and recording an unverified
            // pre-bind guess here would silently reopen the exact class
            // of bug `bindListener(onPort:)` was fixed to close (Round
            // 5 / task #47): a caller trusting a port number the
            // listener never confirmed it actually bound.
            guard let boundPort = ready.port?.rawValue, boundPort != 0 else {
                ready.cancel()
                continue
            }
            if Int(boundPort) != probedPort {
                NSLog("[CalyxMCPServer] BSD fallback probed port \(probedPort) but the listener resolved to \(boundPort); recording the resolved port")
            }
            return (ready, Int(boundPort))
        }
        return nil
    }

    /// Ask the kernel for a free ephemeral port on `127.0.0.1` by
    /// binding a throwaway BSD socket to `127.0.0.1:0`, reading the
    /// assigned port via `getsockname`, then closing the socket. The
    /// returned port is the kernel's choice from the ephemeral range —
    /// use it as the desired port for an `NWListener` bind.
    ///
    /// `internal` (not `private`) so `CalyxMCPServerTests` can call this
    /// directly via `@testable import` instead of maintaining its own
    /// duplicate copy of the same BSD-socket probe.
    func askKernelForFreeLoopbackPort() -> Int? {
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
    ///
    /// Writes `agent-endpoint.json` (port/token for the calyx-agent-hook
    /// script) on a best-effort basis: a write failure only degrades the
    /// Agents sidebar (hook events from panes have nowhere to POST to)
    /// and must not take down the whole IPC server, whose MCP tools have
    /// nothing to do with this file.
    private func finishStart(
        listener nl: NWListener,
        boundPort: Int,
        priorTeardown: Task<Void, Never>?
    ) {
        do {
            try AgentEndpointFile.write(port: boundPort, token: token, directory: agentEndpointDirectory)
        } catch {
            NSLog("[CalyxMCPServer] failed to write agent-endpoint.json: \(error)")
        }

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
        // AgentStatusView observes AgentRegistry (not this @MainActor,
        // non-@Observable class) directly, so it needs this signal to
        // redraw out of the "disabled" placeholder.
        agentRegistry.markServerStarted()
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
        AgentEndpointFile.remove(directory: agentEndpointDirectory)
        // Clears every Agents sidebar row and flips AgentStatusView back
        // to its "disabled" placeholder — without this, disabling IPC
        // (or a start()-triggered restart) leaves stale rows on screen
        // for panes the registry will never hear from again.
        agentRegistry.reset()
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

    /// Reference-typed accumulation state for one connection's
    /// `receiveUntilComplete` read loop, held for the lifetime of a
    /// single `handleConnection` call. A plain `Data` value threaded
    /// through the recursive `receive` calls as a parameter would force
    /// a full copy of the bytes already accumulated on every chunk —
    /// the recursive function's own parameter keeps the previous `Data`
    /// alive as a second reference for the duration of each call, so
    /// appending into a shadowed copy can never reuse its storage in
    /// place (copy-on-write only elides the copy when there is exactly
    /// one live reference). Holding the bytes in a single mutable `var`
    /// on a class instead means every chunk's `append` mutates the one
    /// and only reference in place, making accumulation amortized
    /// O(total bytes) rather than O(total bytes²) for a request that
    /// arrives in many small chunks.
    ///
    /// `requiredTotal`, once known (i.e. once `HTTPParser.completeness(of:)`
    /// has found the header terminator), is cached here too, so a large
    /// body doesn't pay for re-finding that terminator via a fresh
    /// `Data.range(of:)` scan on every single chunk — once cached,
    /// `receiveUntilComplete` compares `data.count` against it directly
    /// instead of calling back into `HTTPParser.completeness(of:)`.
    ///
    /// `@MainActor`-isolated like the rest of this class (and therefore
    /// implicitly `Sendable`, safe to capture across the `NWConnection`
    /// completion-handler boundary) — every read and mutation happens
    /// from within the `Task { @MainActor in ... }` hop `receiveUntilComplete`
    /// already performs for every other reason.
    ///
    /// `didRespond` is this same isolation's other job: the single
    /// source of truth `sendHTTPResponse` checks-and-sets to guarantee
    /// at most one HTTP response ever goes out on the connection this
    /// accumulator belongs to — see `sendHTTPResponse`'s doc comment
    /// for the double-send this closes off (the receive-deadline `Task`
    /// and `receiveUntilComplete`'s own terminal branches can otherwise
    /// both end up calling it for the same connection).
    @MainActor
    private final class ReceiveAccumulator {
        var data = Data()
        var requiredTotal: Int?
        var didRespond = false
    }

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: .main)

        // Constructed before `deadlineTask` (and captured by both it
        // and `receiveUntilComplete` below) specifically so the two independent
        // paths that can send a response for this connection share one
        // `didRespond` flag — see `sendHTTPResponse`'s doc comment.
        let accumulator = ReceiveAccumulator()

        // Slow-loris guard, bounded to *receiving* a complete request
        // only: a peer that opens the connection and never sends one
        // (or trickles it in a byte at a time) would otherwise pin
        // `receiveUntilComplete`'s accumulation loop below open
        // indefinitely — that loop has no per-call timeout of its own.
        // `receiveUntilComplete` cancels this Task the moment
        // accumulation reaches a terminal outcome (complete, too-large,
        // or peer-closed/error) — *before* handing off to
        // `finishRequest`/`route(request:)` — so this deadline never
        // covers request *processing* time. It deliberately must not:
        // some `lsp_*` tool calls legitimately run for up to an hour
        // (see `LSPTimeouts`), and a deadline spanning processing would
        // cut those off with a spurious 408. `!Task.isCancelled` below
        // is a cheap early-exit optimization, not the correctness
        // guarantee against a double send — that's `sendHTTPResponse`'s
        // `accumulator.didRespond` check.
        let deadline = connectionReceiveDeadline
        let deadlineTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: deadline)
            guard let self, !Task.isCancelled else { return }
            self.sendHTTPResponse(connection: connection, httpResponse: HTTPParser.response(statusCode: 408, body: nil), accumulator: accumulator)
        }

        receiveUntilComplete(connection: connection, accumulator: accumulator, deadlineTask: deadlineTask)
    }

    /// Recursively accumulates `NWConnection.receive` chunks into
    /// `accumulator.data` until a complete HTTP request — or a
    /// definitive terminal condition (buffer too large, peer closed, or
    /// a receive error) — is reached, then hands off to `finishRequest`.
    ///
    /// Re-issuing `receive` here (rather than parsing whatever a single
    /// call returned, as the previous implementation did) matters
    /// because `minimumIncompleteLength: 1` only guarantees *at least
    /// one* byte per callback: a request whose header block and
    /// `Content-Length`-declared body arrive as separate TCP segments
    /// (more likely under load — see `CalyxMCPServerTests`'s
    /// `test_realHTTPRequest_headersAndBodySplitAcrossTCPSegments_stillParsesCompleteRequest`)
    /// used to reach `HTTPParser.parse` with the body segment still
    /// missing. `HTTPParser.parse` doesn't treat that as an error
    /// either — with no body bytes yet present it silently returns
    /// `HTTPRequest.body == nil` rather than raising an
    /// `HTTPParseError` — so `routeMCP`'s `guard let body else { 400 }`
    /// fired on a request that was actually well-formed, just not
    /// fully arrived yet.
    ///
    /// `HTTPParser.completeness(of:)` only ever inspects `accumulator.data`
    /// for completeness (and only until `accumulator.requiredTotal` is
    /// known — see `ReceiveAccumulator`'s doc comment); `HTTPParser.parse`
    /// itself is still invoked exactly once, in `finishRequest`, on a
    /// buffer this function has already established is complete (or
    /// terminal) — `HTTPParser`'s existing contract of "given a
    /// complete buffer, parse it" is unchanged.
    private func receiveUntilComplete(
        connection: NWConnection,
        accumulator: ReceiveAccumulator,
        deadlineTask: Task<Void, Never>
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: HTTPParser.maxHeaderSize + HTTPParser.maxBodySize) { [weak self] data, _, isComplete, error in
            Task { @MainActor [weak self] in
                guard let self else {
                    connection.cancel()
                    return
                }

                if let data {
                    accumulator.data.append(data)
                }

                let state: HTTPParser.Completeness
                if let requiredTotal = accumulator.requiredTotal {
                    // The header terminator (and, if present, a valid
                    // Content-Length) were already resolved on an
                    // earlier chunk — skip `HTTPParser.completeness(of:)`'s
                    // header-terminator search entirely and just compare
                    // against the byte count it already computed then.
                    state = accumulator.data.count >= requiredTotal ? .complete : .incomplete
                } else {
                    let (resolvedState, resolvedTotal) = HTTPParser.completeness(of: accumulator.data)
                    accumulator.requiredTotal = resolvedTotal
                    state = resolvedState
                }

                switch state {
                case .incomplete:
                    if isComplete || error != nil {
                        // The peer closed (or the read errored) before
                        // a complete request arrived — OR (see
                        // `sendHTTPResponse`'s doc comment) this is a
                        // *stale* `receive()` call that only completed
                        // because the receive-deadline `Task` already
                        // sent a 408 and cancelled the connection out
                        // from under it. Either way, hand whatever
                        // bytes we do have to the same parse-and-respond
                        // path a complete request goes through —
                        // `sendHTTPResponse`'s `accumulator.didRespond`
                        // guard is what actually decides whether this
                        // particular call gets to respond.
                        deadlineTask.cancel()
                        await self.finishRequest(connection: connection, buffer: accumulator.data, accumulator: accumulator)
                        return
                    }
                    self.receiveUntilComplete(connection: connection, accumulator: accumulator, deadlineTask: deadlineTask)
                case .complete:
                    deadlineTask.cancel()
                    await self.finishRequest(connection: connection, buffer: accumulator.data, accumulator: accumulator)
                case .tooLarge:
                    deadlineTask.cancel()
                    self.sendHTTPResponse(connection: connection, httpResponse: HTTPParser.response(statusCode: 413, body: nil), accumulator: accumulator)
                }
            }
        }
    }

    /// Parses a buffer already established as complete (or terminal) by
    /// `receiveUntilComplete` and dispatches it through `route(request:)`
    /// — the same parse-error-to-status-code mapping the pre-buffering
    /// implementation always used. Called only after `receiveUntilComplete`
    /// has already cancelled the receive-phase deadline, so however long
    /// `route(request:)` takes is never bounded by it.
    ///
    /// Can be entered more than once for the same `accumulator` (see
    /// `sendHTTPResponse`'s doc comment for how) — every exit path here
    /// routes through `sendHTTPResponse`, which is what actually
    /// guarantees only the first call gets to respond.
    private func finishRequest(connection: NWConnection, buffer: Data, accumulator: ReceiveAccumulator) async {
        do {
            let httpRequest = try HTTPParser.parse(buffer)
            let httpResponse = await self.route(request: httpRequest)
            self.sendHTTPResponse(connection: connection, httpResponse: httpResponse, accumulator: accumulator)
        } catch let error as HTTPParseError {
            let statusCode: Int
            switch error {
            case .headerTooLarge, .bodyTooLarge: statusCode = 413
            case .invalidContentLength, .malformedRequest: statusCode = 400
            case .timeout: statusCode = 408
            }
            self.sendHTTPResponse(connection: connection, httpResponse: HTTPParser.response(statusCode: statusCode, body: nil), accumulator: accumulator)
        } catch {
            self.sendHTTPResponse(connection: connection, httpResponse: HTTPParser.response(statusCode: 500, body: nil), accumulator: accumulator)
        }
    }

    /// Sends `httpResponse` and cancels the connection once it's fully
    /// written — but only the *first* time this is called for a given
    /// `accumulator` (i.e. for a given connection). `accumulator.didRespond`
    /// is the single source of truth "has a response already gone out
    /// on this connection", checked and set atomically here (no `await`
    /// between the check and the set, and this whole class is
    /// `@MainActor`-isolated, so there is no interleaving window for a
    /// second caller to slip in between them).
    ///
    /// This guard exists because the receive-deadline `Task` (started
    /// in `handleConnection`) and `receiveUntilComplete`'s own terminal
    /// branches can otherwise both end up calling this for the same
    /// connection: when the deadline actually elapses (the slow-loris
    /// case it exists to handle), its 408 send's own
    /// `connection.cancel()` completes whatever `receive()` call was
    /// still outstanding at that moment. That completion re-enters
    /// `receiveUntilComplete`'s `isComplete || error != nil` branch —
    /// indistinguishable there from a genuine peer close — which would,
    /// without this guard, call `finishRequest` and send a second,
    /// spurious response on a connection already cancelled by the
    /// first. `deadlineTask.cancel()` at each of `receiveUntilComplete`'s
    /// terminal branches narrows the same race in the other direction
    /// but — being only a cooperative-cancellation flag — cannot fully
    /// close it either: this `didRespond` check is the actual
    /// correctness guarantee in both directions.
    private func sendHTTPResponse(connection: NWConnection, httpResponse: HTTPResponse, accumulator: ReceiveAccumulator) {
        _testSendHTTPResponseAttemptCount += 1
        guard !accumulator.didRespond else { return }
        accumulator.didRespond = true
        _testSendHTTPResponseSentCount += 1
        let data = httpResponse.serialize()
        connection.send(content: data, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    // MARK: - JSON-RPC Handler

    /// Process a single JSON-RPC request.
    /// Returns an HTTP-like status code and optional response body.
    ///
    /// - Parameter surfaceID: The pane's `X-Calyx-Surface-ID` header, when
    ///   present and valid on the underlying HTTP request (Round 4),
    ///   parsed by `routeMCP`'s `parseSurfaceID(from:)`. When non-`nil`,
    ///   the `initialize` case reports (and, if needed, (re)binds) that
    ///   surface's one true peer identity (Round 6 review — see that call
    ///   site's own comment), and `tools/call`'s `register_peer`
    ///   unconditionally binds it to whatever peer it resolves to — both
    ///   via `agentRegistry.bindSurface` — so a pane's row gets its unread
    ///   badge lit even if it never calls a calyx-ipc tool itself (the
    ///   pre-Round-4 hook-derived binding in `AgentRegistry.handleHookEvent`
    ///   still runs independently, as a fallback that needs no
    ///   `X-Calyx-Surface-ID` header at all).
    func handleJSONRPC(data: Data, authToken: String?, surfaceID: UUID? = nil) async -> (statusCode: Int, body: Data?) {

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
            // Round 6: auto-register a peer ONLY for a surface-bound
            // connection (one carrying `X-Calyx-Surface-ID`). A
            // surfaceless connection (e.g. an external MCP client like
            // OpenCode) has no surface for a peer to ever be bound to —
            // auto-registering one for it on every `initialize` just
            // leaves an orphaned, unaddressable identity behind on every
            // reconnect, with no way to rename it back onto whatever
            // identity the client eventually self-registers via
            // `register_peer`. Such a client keeps the pre-Round-6
            // "self-register immediately" instructions (see
            // `MCPRouter.instructions`) as its only path to a peer_id —
            // that's the intended, unchanged contract for it, not a gap.
            //
            // Round 6 review: a surface-bound connection instead resolves
            // to the surface's ONE peer identity, not a fresh one every
            // time:
            // - Bound to a peer that's still alive in `IPCStore`: report
            //   that SAME peer_id, and do nothing else. This is what a
            //   pane reconnecting mid-session (e.g. after a Claude Code
            //   MCP client restart, or the deliberate re-init following
            //   `/clear`) hits on every subsequent `initialize` — the
            //   pane's identity and inbox carry over, by design (Calyx's
            //   peer identity is pane-centric, not process-centric).
            //   Skipping `registerPeer` here is what makes
            //   `buildInitializeResponse`'s "already registered as X, and
            //   register_peer returns the SAME X" promise actually hold
            //   after a reconnect — minting a second peer here would
            //   report a fresh X that `register_peer` could then never
            //   reproduce.
            // - Not bound, or bound to a peer that's since been
            //   TTL-purged: register a fresh peer and (re)bind
            //   unconditionally — the same self-heal `register_peer`
            //   itself falls back to below when its own bound peer has
            //   died (see `handleRegisterPeer`).
            var peerID: UUID?
            if let surfaceID {
                if let boundPeerID = agentRegistry.boundPeerID(for: surfaceID),
                   let alivePeer = await store.peerStatus(id: boundPeerID) {
                    peerID = alivePeer.id
                } else {
                    let clientName = extractClientName(from: request.params) ?? "claude-code"
                    let peer = await store.registerPeer(name: clientName, role: "claude-code")
                    peerID = peer.id
                    agentRegistry.bindSurface(surfaceID, toPeer: peer.id)
                }
            }
            let resp = MCPRouter.buildInitializeResponse(id: requestId, peerID: peerID)
            return (200, encode(resp))

        case "tools/list":
            let resp = MCPRouter.buildToolsListResponse(id: requestId)
            return (200, encode(resp))

        case "notifications/initialized":
            return (204, nil)

        case "tools/call":
            return await handleToolCall(id: requestId, params: request.params, surfaceID: surfaceID)

        default:
            let resp = MCPRouter.buildErrorResponse(id: requestId, code: -32601, message: "Method not found")
            return (200, encode(resp))
        }
    }

    // MARK: - Tool Call Dispatch

    private func handleToolCall(
        id: JSONRPCId,
        params: [String: AnyCodable]?,
        surfaceID: UUID?
    ) async -> (statusCode: Int, body: Data?) {

        guard let params else {
            return toolError(id: id, text: "Missing params")
        }

        guard let toolName = extractString(params, "name") else {
            return toolError(id: id, text: "Missing tool name")
        }

        let response = await dispatchToolCall(id: id, toolName: toolName, params: params, surfaceID: surfaceID)

        // Refresh every bound peer's unread badge once, at the end of
        // every calyx-ipc messaging tools/call request, rather than each
        // individual IPC tool handler syncing only the peer(s) it
        // directly touched — see `syncBoundPeerInboxCounts`'s doc
        // comment.
        await syncBoundPeerInboxCounts(toolName: toolName)

        return response
    }

    /// The calyx-ipc tools whose effects can change a bound peer's unread
    /// count (directly, by delivering/receiving a message, or indirectly,
    /// by being the kind of call after which a stale count is worth
    /// refreshing). `syncBoundPeerInboxCounts` only runs for these —
    /// see its own doc comment for why.
    private static let inboxSyncToolNames: Set<String> = [
        "register_peer", "list_peers", "send_message", "broadcast",
        "receive_messages", "get_peer_status"
    ]

    private func dispatchToolCall(
        id: JSONRPCId,
        toolName: String,
        params: [String: AnyCodable],
        surfaceID: UUID?
    ) async -> (statusCode: Int, body: Data?) {
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
            return await handleRegisterPeer(id: id, arguments: arguments, surfaceID: surfaceID)

        case "list_peers":
            return await handleListPeers(id: id)

        case "send_message":
            return await handleSendMessage(id: id, arguments: arguments)

        case "broadcast":
            return await handleBroadcast(id: id, arguments: arguments)

        case "receive_messages":
            return await handleReceiveMessages(id: id, arguments: arguments)

        case "get_peer_status":
            return await handleGetPeerStatus(id: id, arguments: arguments)

        default:
            return toolError(id: id, text: "Unknown tool: \(toolName)")
        }
    }

    /// Refreshes every currently peer-bound surface's unread-message
    /// badge in one batch: `IPCStore.inboxCounts(for:)` +
    /// `AgentRegistry.syncInboxCounts`. Replaces three separate
    /// per-recipient `inboxCount` round trips that used to live in
    /// `handleSendMessage` / `handleReceiveMessages` (one each) and
    /// `handleBroadcast` (one *per recipient* — K actor round trips for a
    /// K-recipient broadcast) with exactly one batched query.
    ///
    /// Gated by two checks, in cost order: `toolName` must be one of
    /// `inboxSyncToolNames` (a plain `Set` lookup, no actor hop), and only
    /// then is `agentRegistry.boundPeerIDs` consulted for an early-out
    /// when nothing is bound. The `toolName` gate matters because
    /// `tools/call` also carries high-frequency, unrelated traffic (e.g.
    /// `lsp_*`) that would otherwise pay for an `IPCStore` actor round
    /// trip on every single call for no reason — badges only ever change
    /// as a side effect of one of the messaging tools below.
    ///
    /// One consequence: a peer's inbox can also shrink from an entry
    /// aging out under `IPCStore`'s TTL purge, which happens on its own
    /// schedule, not in response to any particular tool call. That drift
    /// isn't synced immediately — it's picked up the next time any
    /// messaging tool below runs and this function's batch query re-reads
    /// the current counts, which every real client does routinely (e.g.
    /// polling via `receive_messages`). There is no dedicated eager sync
    /// for a TTL purge in isolation.
    private func syncBoundPeerInboxCounts(toolName: String) async {
        guard Self.inboxSyncToolNames.contains(toolName) else { return }
        let peerIDs = agentRegistry.boundPeerIDs
        guard !peerIDs.isEmpty else { return }
        let counts = await store.inboxCounts(for: peerIDs)
        agentRegistry.syncInboxCounts(counts)
    }

    // MARK: - Tool Handlers

    /// Round 6: enforces "1 surface = 1 peer identity". Before this fix,
    /// `register_peer` always minted a brand-new peer, while `initialize`
    /// already auto-registers one for every surface-bound connection and
    /// (contradictorily) the old instructions told clients to call
    /// `register_peer` immediately after connecting anyway. A pane that
    /// followed that instruction ended up with two disconnected
    /// identities — the auto-registered one other peers actually message,
    /// and an orphaned second one nobody addresses. Fix: a surface-bound
    /// call whose already-bound peer is still alive in `IPCStore` gets
    /// that peer RENAMED in place (same `peer_id` returned, binding
    /// untouched) instead of a second identity being created. A stale
    /// binding (peer TTL-purged) or a surfaceless caller (no binding to
    /// rename onto) both fall through to the original
    /// register-and-(re)bind behavior.
    ///
    /// Known accepted gap: a nested `claude` subprocess launched from
    /// within an already-bound pane (inheriting the same
    /// `CALYX_SURFACE_ID` env var) resolves to the SAME bound surface, so
    /// its own `register_peer` call renames — and lastSeen-extends — the
    /// parent pane's peer rather than getting an identity of its own.
    /// This is a consequence of surface identity being inherited by
    /// subprocess env vars, not something this fix introduces or closes.
    private func handleRegisterPeer(
        id: JSONRPCId,
        arguments: [String: Any]?,
        surfaceID: UUID?
    ) async -> (statusCode: Int, body: Data?) {
        // `nil` (as opposed to `""`) is passed through to `updatePeer` for
        // an omitted, empty, or whitespace-only argument, so the rename
        // path below preserves the peer's existing name/role instead of
        // blanking it out when a caller only supplies one of the two
        // (e.g. a bare "give me a descriptive name" call that doesn't
        // repeat the role `initialize` already set) — or supplies
        // whitespace where a value was expected. Trimming before the
        // emptiness check mirrors the header-parsing convention used
        // elsewhere in this file (`parseSurfaceID`, the `X-Calyx-Agent-Kind`
        // handling in `routeAgentEvent`).
        let nameArg = (arguments?["name"] as? String)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .flatMap { $0.isEmpty ? nil : $0 }
        let roleArg = (arguments?["role"] as? String)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .flatMap { $0.isEmpty ? nil : $0 }

        if let surfaceID, let boundPeerID = agentRegistry.boundPeerID(for: surfaceID),
           let renamed = await store.updatePeer(id: boundPeerID, name: nameArg, role: roleArg) {
            return toolSuccess(id: id, text: registerPeerResultJSON(peerID: renamed.id))
        }

        // A brand-new registration has no existing name/role to preserve,
        // so an omitted/empty argument here becomes "" exactly as before
        // Round 6.
        let peer = await store.registerPeer(name: nameArg ?? "", role: roleArg ?? "")
        // Bind the connection's own surface (Round 4) to the freshly
        // created peer — covers explicit re-registration (e.g. after
        // `/clear`, or self-healing a stale binding above) the same way
        // `initialize`'s auto-registration does in `handleJSONRPC`, not
        // just the hook-derived binding path.
        if let surfaceID {
            agentRegistry.bindSurface(surfaceID, toPeer: peer.id)
        }
        return toolSuccess(id: id, text: registerPeerResultJSON(peerID: peer.id))
    }

    /// The `register_peer` tool result body shared by both the rename and
    /// fresh-registration paths in `handleRegisterPeer` above.
    private func registerPeerResultJSON(peerID: UUID) -> String {
        "{\"peerId\":\"\(peerID.uuidString)\"}"
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
            // The recipient's unread badge (if a pane has learned a
            // binding to this peer — see AgentEvent.ipcSelfPeerID) is
            // refreshed once, after this handler returns, by
            // `handleToolCall`'s `syncBoundPeerInboxCounts` — not here.
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
            // Every recipient's unread badge is refreshed once, after
            // this handler returns, by `handleToolCall`'s
            // `syncBoundPeerInboxCounts` — not with a per-recipient
            // `inboxCount` round trip here.
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
        // This peer's unread badge is refreshed once, after this handler
        // returns, by `handleToolCall`'s `syncBoundPeerInboxCounts` — it
        // will read 0 for `peerUUID` immediately, since `receiveMessages`
        // just deleted every one of these messages from the inbox
        // (delete-on-read).
        let messageDicts: [[String: Any]] = messages.map { messageToDict($0) }
        let result: [String: Any] = ["messages": messageDicts]
        guard let jsonData = try? JSONSerialization.data(withJSONObject: result),
              let json = String(data: jsonData, encoding: .utf8) else {
            // Serialization failed AFTER receiveMessages already deleted
            // these messages from the store — without requeuing them
            // here, they'd be lost outright rather than merely returned
            // as an error the caller can retry. Put them back at the
            // front of the inbox so the next receive_messages call gets
            // another chance to return (and serialize) them.
            await store.requeue(messages, for: peerUUID)
            return toolError(id: id, text: "Failed to serialize messages")
        }
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
