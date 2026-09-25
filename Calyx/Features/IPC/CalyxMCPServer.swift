//
//  CalyxMCPServer.swift
//  Calyx
//
//  MCP server: accepts JSON-RPC over TCP, authenticates via bearer token,
//  routes to MCPRouter / IPCStore for IPC tool calls.
//

import Foundation
import Network
import Synchronization

@MainActor
final class CalyxMCPServer {

    static let shared = CalyxMCPServer(agentEndpointDirectory: AgentEndpointFile.defaultDirectory)

    // MARK: - Public State

    private(set) var isRunning: Bool = false
    private(set) var port: Int = 0
    private(set) var token: String = "" {
        didSet { sessionBearerToken.value = token }
    }
    /// `token`, readable off the main actor. The `/calyx-mcp` router keys
    /// its session ids with it; `start` sets `token` before it binds the
    /// listener, so the first request the listener accepts already sees
    /// the token it was authenticated with.
    let sessionBearerToken = MCPSessionBearerToken()
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

    /// The `/approval-request` route's path, shared by `route(request:)`'s
    /// own switch case and `dispatchRoute`'s guard so the one path string
    /// that gates the connection-drop watch exists in exactly one place.
    private static let approvalRequestPath = "/approval-request"

    /// Shared request-body size cap (bytes), checked BEFORE decode, by
    /// both `routeCommandEvent` and `routeApprovalRequest` -- one 256 KiB
    /// ceiling for every event-ingestion route on this server, rather
    /// than two independently-maintained copies of the same literal.
    private static let maxEventBodyBytes = 262_144

    // MARK: - Init

    init(agentEndpointDirectory: String) {
        self.agentEndpointDirectory = agentEndpointDirectory
    }

    /// For testing only — sets the token without starting the listener.
    func _testSetToken(_ token: String) {
        self.token = token
    }

    // MARK: - Agent Monitor

    /// Registry that `/agent-event` writes into. Defaults to the shared
    /// singleton; tests inject an isolated instance so assertions don't
    /// leak state across cases.
    var agentRegistry: AgentRegistry = .shared

    /// Store that `/command-event` ingests into. Defaults to the shared
    /// singleton; tests inject an isolated instance so assertions don't
    /// leak state across cases -- same rationale as `agentRegistry`.
    var commandLogStore: CommandLogStore = .shared

    /// Lazily constructed, cached `MCPCommandLogBridge` that `terminal_*`
    /// calls dispatch through. `lazy` so it's only built on first actual
    /// `terminal_*` dispatch (not at `CalyxMCPServer` init), by which
    /// point any test that overrides `commandLogStore`/`sessionSurfaceMap`
    /// has already done so; built exactly once and reused afterward
    /// (never recreated per call).
    private lazy var lazyCommandLogBridge = MCPCommandLogBridge(
        store: commandLogStore, sessionSurfaceMap: sessionSurfaceMap
    )

    /// Resolves a calyx-session ID to the surface UUID currently
    /// attached to it, for `/mcp` and `/agent-event` requests whose
    /// `X-Calyx-Surface-ID` header carries a session ID rather than a
    /// raw surface UUID (persistent-session panes, see
    /// `AgentHookScript`'s `CALYX_SESSION_ID` precedence). Defaults to
    /// the shared singleton; tests inject an isolated instance.
    /// Consulted by `resolveSurfaceID(from:)` as the fallback once
    /// `parseSurfaceID` fails to parse the header as a raw UUID.
    var sessionSurfaceMap: SessionSurfaceMap = .shared

    /// The live-app view `pane_list`/`pane_split`/`tab_create` (and the
    /// gated tools) dispatch through. Defaults to the real
    /// `LiveCockpitAppAccess`; tests inject a fake so assertions don't
    /// need a live `AppDelegate`/window, same rationale as
    /// `agentRegistry`/`commandLogStore`/`sessionSurfaceMap`.
    var cockpitAccess: CockpitAppAccessing = LiveCockpitAppAccess()

    /// The approval inbox the gated Cockpit tools (pane_run/
    /// pane_send_keys/palette_execute) submit into when
    /// `ApprovalPolicy.requiresApproval()`, via `lazyCockpitBridge`'s own
    /// `gate(toolName:targetSurfaceID:payload:)`. Defaults to the shared
    /// singleton; tests inject an isolated instance, same rationale as
    /// `agentRegistry`/`commandLogStore`/`sessionSurfaceMap`/
    /// `cockpitAccess`. This is a security-critical seam: `stop()`
    /// synchronously drains every pending request via `expireAll()` (see
    /// that method), so a stopped server never strands an MCP caller
    /// waiting on a decision nobody can make anymore.
    var approvalInbox: ApprovalInboxStore = .shared

    /// Session-scoped "Always Allow" memory `routeApprovalRequest`
    /// consults (after the global-auto-approve short-circuit, before
    /// submitting to `approvalInbox`): a pane- or cross-scoped hit
    /// short-circuits to 200 with an allow body, same as global
    /// auto-approve, without ever reaching the inbox. Defaults to the
    /// shared singleton; tests inject an isolated instance, same
    /// rationale as `approvalInbox` above. `stop()` clears it via
    /// `clearAll()`, mirroring that method's own `approvalInbox.expireAll()`.
    var agentHookApprovalMemory: AgentHookApprovalMemory = .shared

    /// Whether a resolved surface UUID corresponds to a still-live pane
    /// anywhere in the app -- consulted by `routeApprovalRequest`
    /// immediately before it would otherwise submit to `approvalInbox`
    /// (R4): a stale/forged/torn-down surface short-circuits to 200 with
    /// an EMPTY body, submitting nothing and posting no notification,
    /// rather than queuing a request whose banner no window could ever
    /// show (see `ApprovalBannerModel.isVisible` -- nothing owns a
    /// surface that doesn't exist) while the hook script long-polls for
    /// a decision nobody can ever make. Defaults to
    /// `LiveCockpitAppAccess.paneExists(_:)` -- the same canonical
    /// "does this surface exist" check `MCPCockpitBridge`'s `pane_run`/
    /// `pane_send_keys` already gate on before ever bothering a human
    /// (see `CockpitAppAccessing`'s own doc comment for why `paneExists`,
    /// not a second, separately-maintained membership check, is the one
    /// source of truth for pane identity). Test-overridable, same
    /// rationale as `approvalInbox`/`agentHookApprovalMemory` above.
    var approvalSurfaceExists: (UUID) -> Bool = { LiveCockpitAppAccess().paneExists($0) }

    /// The timeout `POST /approval-request`'s long-poll (`routeApprovalRequest`)
    /// gives `approvalInbox.awaitDecision` before resolving `.expired`.
    /// Defaults to `ApprovalHookTiming.serverTimeoutMs` (see that enum's
    /// header comment for the full nesting rationale against the hook
    /// script's own curl timeout and the CLI's hook-entry timeout);
    /// test-overridable so tests can drive the timeout path in well
    /// under a second rather than actually waiting out the real
    /// production value, same rationale as `MCPCockpitBridge`'s own
    /// `approvalTimeoutMs`.
    var approvalRequestTimeoutMs: Int = ApprovalHookTiming.serverTimeoutMs

    // MARK: - /calyx-mcp

    /// The router `/calyx-mcp` dispatches to. Every `/calyx-mcp` request
    /// is answered 503 while it is nil.
    private var calyxMCPRouter: MCPCalyxMCPRouter?

    /// Consulted by `/calyx-mcp`'s herdr-first pane resolution. Defaults
    /// to the shared singleton; tests inject an isolated instance, same
    /// rationale as `agentRegistry`/`sessionSurfaceMap`.
    var herdrPaneRegistry: HerdrPaneRegistry = .shared

    /// What `app_context` reads. Nil until a view host is attached, in
    /// which case no pane has a live view.
    var calyxMCPModelContextProvider: (any MCPAppModelContextProviding)?

    /// The herdr socket a pane is looked up under when its
    /// `X-Calyx-Herdr-Socket-Path` is empty (`HERDR_SOCKET_PATH` unset):
    /// herdr's default session socket. Test-overridable.
    var herdrDefaultSocketPath: () -> String? = { HerdrConfigPaths.defaultRootDirectory + "/herdr.sock" }

    /// Installs the router `/calyx-mcp` dispatches to; nil makes every
    /// `/calyx-mcp` request 503 again.
    func setCalyxMCPRouter(_ router: MCPCalyxMCPRouter?) {
        calyxMCPRouter = router
    }

    /// Lazily constructed, cached `MCPCockpitBridge` that Cockpit tool
    /// calls dispatch through -- same `lazy` caveat as
    /// `lazyCommandLogBridge`: only built on first actual Cockpit-tool
    /// dispatch, by which point any test that overrides
    /// `cockpitAccess`/`sessionSurfaceMap`/`approvalInbox`/
    /// `agentRegistry`/`commandLogStore` has already done so.
    private lazy var lazyCockpitBridge = MCPCockpitBridge(
        access: cockpitAccess, sessionSurfaceMap: sessionSurfaceMap,
        approvals: approvalInbox, agentRegistry: agentRegistry, commandLogStore: commandLogStore
    )

    /// Records an agent hook event's self-reported session ID into the
    /// calyx-session daemon's per-session meta map, so a later
    /// reattach can offer to resume the same CLI conversation. Defaults
    /// to a bridge over the shared singletons; tests inject their own
    /// instance the same way as `agentRegistry`/`sessionSurfaceMap`.
    var agentSessionMetaBridge = AgentSessionMetaBridge()

    /// Directory `agent-endpoint.json` is written to (by `finishStart`)
    /// and removed from (by `stop()`). Required at construction, not
    /// defaulted: a caller that forgets to wire this fails to build
    /// rather than silently pointing at
    /// `AgentEndpointFile.defaultDirectory`
    /// (`~/Library/Application Support/Calyx`): only
    /// `CalyxMCPServer.shared` passes that value; every test passes a
    /// per-test temp directory so `start()`/`stop()` never touch the
    /// real file.
    let agentEndpointDirectory: String

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
    /// guard. Confirmed empirically to reach `2`
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
    /// connection.
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
        case ("POST", "/command-event"):
            return await routeCommandEvent(request: request)
        case ("POST", Self.approvalRequestPath):
            return await routeApprovalRequest(request: request)
        case ("POST", HTTPParser.calyxMCPPath):
            return await routeCalyxMCP(request: request)
        case ("GET", HTTPParser.calyxMCPPath):
            return await Self.collect(await routeCalyxMCPStream(request: request))
        case ("DELETE", HTTPParser.calyxMCPPath):
            return await routeCalyxMCPDelete(request: request)
        default:
            return HTTPParser.response(statusCode: 404, body: nil)
        }
    }

    private func routeMCP(request: HTTPRequest) async -> HTTPResponse {
        let authToken = bearerToken(from: request.headers)
        guard let body = request.body else {
            return HTTPParser.response(statusCode: 400, body: nil)
        }
        // A missing, empty, or unresolvable value means "no surface
        // binding for this connection" here — unlike `/agent-event`'s
        // required header below, `/mcp` predates `X-Calyx-Surface-ID`,
        // and every existing MCP client that doesn't send it (or an
        // older Claude Code build whose `${VAR:-default}` expansion
        // isn't supported, leaving the literal placeholder string in
        // place) must keep working exactly as before — so `nil` here is
        // not a request error, just "not bound". `resolveSurfaceID`
        // also resolves a calyx-session ID via `sessionSurfaceMap` (the
        // same two-stage fallback `/agent-event` uses) so an MCP client
        // running inside a persistent-session pane keeps its surface
        // binding across a reconnect too.
        let surfaceID = resolveSurfaceID(from: request.headers)
        let kind = explicitAgentKind(from: request.headers)
        let (statusCode, responseBody) = await handleJSONRPC(
            data: body,
            authToken: authToken,
            surfaceID: surfaceID,
            agentKind: kind
        )
        return HTTPParser.response(statusCode: statusCode, body: responseBody)
    }

    /// Trims whitespace from `X-Calyx-Surface-ID` and parses it as a
    /// `UUID`, returning `nil` for a missing, empty, or non-UUID value.
    /// Shared by both `/mcp` (`routeMCP`) and
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

    /// Resolves the request's Calyx pane identity, shared by both
    /// `/mcp` (`routeMCP`) and `/agent-event` (`routeAgentEvent`): first
    /// a stable `X-Calyx-Session-ID` looked up in `sessionSurfaceMap`, then
    /// the legacy overloaded `X-Calyx-Surface-ID` contract: raw surface UUID
    /// first, calyx-session ID fallback. Separate headers let clients whose
    /// config interpolation has no fallback syntax send both environment
    /// variables; an absent or unresolved session header simply falls through
    /// to the ordinary surface header. A persistent-session pane's hook still
    /// sends its stable calyx-session ID in `X-Calyx-Surface-ID` (see
    /// `AgentHookScript.scriptBody`'s
    /// `${CALYX_SESSION_ID:-$CALYX_SURFACE_ID}` fallback), so that older
    /// path remains supported. `nil` if neither header resolves; what a
    /// `nil` result *means* still differs per route (see each route's
    /// own comment).
    private func resolveSurfaceID(from headers: [String: String]) -> UUID? {
        if let sessionID = header(named: "X-Calyx-Session-ID", in: headers)?
            .trimmingCharacters(in: .whitespaces),
           !sessionID.isEmpty,
           let surfaceID = sessionSurfaceMap.surfaceID(for: sessionID) {
            return surfaceID
        }
        if let surfaceID = parseSurfaceID(from: headers) {
            return surfaceID
        }
        guard let raw = header(named: "X-Calyx-Surface-ID", in: headers)?
            .trimmingCharacters(in: .whitespaces), !raw.isEmpty else {
            return nil
        }
        return sessionSurfaceMap.surfaceID(for: raw)
    }

    /// Resolves `X-Calyx-Agent-Kind`, trimming whitespace and falling
    /// back to `AgentEntry.claudeCodeKind` when the header is absent OR
    /// present-but-blank (e.g. a proxy/plugin bug that sends
    /// `X-Calyx-Agent-Kind: ` with no value), rather than letting an
    /// empty-string kind reach the registry, the sidebar, or the
    /// approval inbox. Shared by `routeAgentEvent` and
    /// `routeApprovalRequest` so the same header is resolved identically
    /// on both routes.
    private func agentKind(from headers: [String: String]) -> String {
        explicitAgentKind(from: headers) ?? AgentEntry.claudeCodeKind
    }

    /// Returns an explicitly supplied, non-empty agent kind. Unlike
    /// `agentKind(from:)`, this deliberately has no Claude Code default:
    /// `/mcp` is also used by generic clients, and a surface header alone
    /// must not manufacture an Agents row for one of them.
    private func explicitAgentKind(from headers: [String: String]) -> String? {
        guard let trimmed = header(named: "X-Calyx-Agent-Kind", in: headers)?
            .trimmingCharacters(in: .whitespaces), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    /// Deliberately has no route-level body-size cap of its own, unlike
    /// `routeCommandEvent` and `routeApprovalRequest`. `calyx-agent-hook`
    /// forwards a hook's stdin verbatim, and a `PreToolUse`/`PostToolUse`
    /// event legitimately embeds a whole file's contents in `tool_input`/
    /// `tool_response`, so this route cannot be bounded more tightly than
    /// the transport without silently discarding real hook traffic (a
    /// `Read`/`Write` of a file anywhere from a few hundred KiB up to the
    /// transport's own ceiling). The other two routes cap tighter than
    /// the transport on purpose, because their payloads are bounded and
    /// structured. `HTTPParser.parse`'s own `maxBodySize` gate (1 MiB)
    /// already bounds every route ahead of any handler running, so a
    /// second cap here would either discard legitimate events (set below
    /// 1 MiB) or never trigger (set at or above it) -- there is no useful
    /// value to pick.
    private func routeAgentEvent(request: HTTPRequest) async -> HTTPResponse {
        guard let authToken = bearerToken(from: request.headers), authToken == token else {
            return HTTPParser.response(statusCode: 401, body: nil)
        }

        guard let surfaceID = resolveSurfaceID(from: request.headers) else {
            return HTTPParser.response(statusCode: 400, body: nil)
        }

        guard let body = request.body else {
            return HTTPParser.response(statusCode: 400, body: nil)
        }

        guard let event = AgentEvent.decode(from: body) else {
            return HTTPParser.response(statusCode: 400, body: nil)
        }

        let kind = agentKind(from: request.headers)
        agentRegistry.handleHookEvent(event, surfaceID: surfaceID, kind: kind)
        // Record the agent's self-reported session ID (when
        // present) into the calyx-session daemon's per-session meta so
        // a later reattach can offer to resume this conversation. A
        // no-op inside the bridge itself when `surfaceID` has no
        // tracked calyx-session (an ordinary, non-persistent pane). A
        // subagent event's sessionID must never reach this: recording a
        // child's session ID would make a later reattach offer to resume
        // the CHILD's transcript instead of the parent's.
        if !event.isSubagentEvent, let agentSessionID = event.sessionID {
            await agentSessionMetaBridge.recordAgentSession(
                surfaceID: surfaceID, agentKind: kind, agentSessionID: agentSessionID
            )
        }
        return HTTPParser.response(statusCode: 204, body: nil)
    }

    /// Ingests a shell integration's command-lifecycle event
    /// (`CommandEvent`) into `commandLogStore`. Contract:
    /// bearer token check (401) -> body present and <= maxEventBodyBytes
    /// bytes, cap checked BEFORE decode (400 missing / 413 oversized) ->
    /// `CommandEvent.decode(from:)` (400 on nil) -> `X-Calyx-Surface-ID`
    /// header: missing/empty is a malformed-client 400, but a
    /// present-and-non-empty header that `resolveSurfaceID(from:)` still
    /// can't resolve (an unknown calyx-session ID -- a detached
    /// persistent session that keeps emitting after its pane closed,
    /// normal steady-state) is a silent 204 drop, NOT a 400 -> resolved,
    /// `agentRegistry.recordCalyxShellIntegrationReported(surfaceID:phase:)`
    /// runs unconditionally, for BOTH a `.start` and an `.end` event and
    /// regardless of whether `commandLogStore.ingest(event, surfaceID:)`
    /// below accepts or rejects it: a rejected duplicate still proves
    /// Calyx's own integration is live in this pane. Recording on
    /// `.start` too, not just `.end`, matters because ghostty's own OSC
    /// 133 D can otherwise arrive first for the same command -- see
    /// `AgentRegistry.calyxShellIntegrationReportedSurfaces`'s own doc
    /// comment for the full race and its rationale. `event.phase`
    /// (`CommandEvent.Phase`) is converted to the resolver's own
    /// `CalyxShellReportPhase` at this boundary -- only a `.commandEnd`
    /// report answers an outstanding ghostty deferral
    /// (`AgentStateResolver.resolveCalyxShellIntegrationReported`); a
    /// `.commandStart` report only proves the integration is live, which
    /// is exactly what the unconditional recording above is for. Then
    /// `commandLogStore.ingest(event, surfaceID:)` runs. A `phase: end`
    /// event `ingest` actually accepted (its own return value -- NOT a
    /// duplicate/late end `CommandLogStore` silently drops, see that
    /// method's doc comment) additionally calls
    /// `agentRegistry.handlePaneCommandFinished(surfaceID:exitCode:suspended:)`
    /// (settling the surface's Agents row -- see that method's doc
    /// comment for why `phase: end` is trustworthy evidence of that, and
    /// why a stop-signal `exitCode` is excluded). Only when THAT call
    /// reports an actual settle does this also expire the surface's
    /// pending approvals (`approvalInbox.expireForSurface`): a suspend,
    /// an already-settled row, or an end this store rejected must not
    /// cancel an approval request the still-alive agent is waiting on ->
    /// 204 either way. Unlike `routeAgentEvent`, ingestion is NOT gated
    /// on `CommandTrackingSettings.trackingEnabled` -- the endpoint stays
    /// live regardless; the shell-integration env injection is the only
    /// gate on whether events ever arrive here at all.
    private func routeCommandEvent(request: HTTPRequest) async -> HTTPResponse {
        guard let authToken = bearerToken(from: request.headers), authToken == token else {
            return HTTPParser.response(statusCode: 401, body: nil)
        }

        guard let body = request.body else {
            return HTTPParser.response(statusCode: 400, body: nil)
        }
        guard body.count <= Self.maxEventBodyBytes else {
            return HTTPParser.response(statusCode: 413, body: nil)
        }

        guard let event = CommandEvent.decode(from: body) else {
            return HTTPParser.response(statusCode: 400, body: nil)
        }

        guard let rawSurfaceIDHeader = header(named: "X-Calyx-Surface-ID", in: request.headers)?
            .trimmingCharacters(in: .whitespaces), !rawSurfaceIDHeader.isEmpty else {
            return HTTPParser.response(statusCode: 400, body: nil)
        }

        guard let surfaceID = resolveSurfaceID(from: request.headers) else {
            // A present, non-empty header that still doesn't resolve (an
            // unregistered calyx-session ID) is normal steady-state for a
            // detached persistent session, not a client error.
            return HTTPParser.response(statusCode: 204, body: nil)
        }

        // Recorded for both phases, and regardless of `ingest`'s
        // acceptance below -- see `routeCommandEvent`'s own doc comment
        // and `AgentRegistry.calyxShellIntegrationReportedSurfaces`'s for
        // why a `.start` recording, not just `.end`, is needed to win a
        // same-command race against ghostty's own OSC 133 D.
        let shellReportPhase: CalyxShellReportPhase = event.phase == .end ? .commandEnd : .commandStart
        agentRegistry.recordCalyxShellIntegrationReported(surfaceID: surfaceID, phase: shellReportPhase)

        let accepted = commandLogStore.ingest(event, surfaceID: surfaceID)
        if event.phase == .end, accepted,
           agentRegistry.handlePaneCommandFinished(
               surfaceID: surfaceID, exitCode: event.exitCode, suspended: event.suspended
           ) {
            approvalInbox.expireForSurface(surfaceID)
        }
        return HTTPParser.response(statusCode: 204, body: nil)
    }

    /// Handles `POST /approval-request`, the long-poll endpoint the
    /// `calyx-approval-hook` script blocks on from a CLI agent's
    /// PermissionRequest hook while a human decides whether to allow its
    /// next tool call. Contract, in order: bearer auth (401) -> body
    /// present (400) -> body.count <= maxEventBodyBytes, checked BEFORE
    /// decode (413, mirrors `routeCommandEvent`) -> `X-Calyx-Agent-Kind`
    /// read (no failure path, so reading it before decode does not
    /// reorder anything below) -> `AgentHookToolCall.decode(from:kind:)`
    /// (400) -> `resolveSurfaceID` (400) -> an unrecognized
    /// `X-Calyx-Agent-Kind` (anything other than
    /// claude-code/codex/grok/pi)
    /// short-circuits to 200 with an EMPTY body, never submitting
    /// anything -> a hook event name that isn't the one this kind's gate
    /// fires under (`ApprovalHookEvent.isApprovalGate(_:kind:)` -- so
    /// anything else, including a missing key, or `"PreToolUse"`
    /// specifically) short-circuits the same inert way. NOT harmless during the
    /// migration window it exists for: a CLI session already running
    /// before an app update re-migrates `settings.json`/`config.toml`
    /// (see `AgentHooksCoordinator.resyncInstalled()`, run from
    /// `AppDelegate.applicationDidFinishLaunching`) keeps the hook
    /// snapshot it loaded at its own startup, so it keeps POSTing here
    /// with `hook_event_name: "PreToolUse"` from the OLD synchronous
    /// approval entry for as long as it stays alive. Before this
    /// migration that same POST reached the auto-approve /
    /// Always-Allow-memory / inbox-submission branches below;
    /// short-circuiting it here instead means that, until such a
    /// session restarts, no Calyx banner shows for its tool calls, and
    /// any confirmation cockpit auto-approve or a remembered
    /// Always-Allow used to suppress silently now surfaces instead as
    /// that CLI's own local prompt, with no reason shown. Answering in
    /// the OLD `PreToolUse` shape here to close that gap is not an
    /// option: `PreToolUse` fires for every tool call regardless of
    /// whether the CLI itself would ever show a confirmation for it, so
    /// a real decision on this path would resurrect, for old sessions
    /// only, exactly the over-prompting this migration to
    /// `PermissionRequest` exists to remove for everyone (see
    /// `ClaudeHooksConfigManager.installHooks`'s own doc comment).
    /// Staying inert is the smaller, temporary cost, and resolves
    /// itself the moment the session restarts and reloads its migrated
    /// config -> a grok payload whose `permissionMode` is anything but
    /// `bypassPermissions` (`ApprovalHookEvent.gateIsSoleAuthority`)
    /// short-circuits the same inert way, because Grok's own permission
    /// pipeline still runs behind this gate in every other mode: a
    /// banner here would duplicate the prompt Grok is about to show in
    /// its own pane, and an allow here would not answer that prompt
    /// -> `CockpitSettings.agentHookApprovalEnabled` being off does the
    /// same -> for a non-question-tool call (`!call.isQuestionTool`):
    /// global auto-approve (`!ApprovalPolicy.requiresApproval()`)
    /// short-circuits to 200 with an ALLOW body, also without ever
    /// submitting -> an `agentHookApprovalMemory.isAutoAllowed` (pane
    /// scope) hit short-circuits the same way, also without submitting.
    /// Neither of those two short-circuits ever applies to a
    /// claude-code `AskUserQuestion` call (`call.isQuestionTool`) --
    /// gated on the TOOL, not on whether `tool_input.questions` happened
    /// to decode: a question must always reach a human, even one whose
    /// malformed shape falls back to the generic `.agentHook` banner
    /// below, so both are skipped for it. -> an
    /// `approvalSurfaceExists` miss (a stale/forged/torn-down surface)
    /// short-circuits the same inert way
    /// as the unrecognized-kind case above, also without submitting ->
    /// otherwise submits an `ApprovalRequest`, sourced `.agentQuestion`
    /// for a claude-code `AskUserQuestion` call (`call.question != nil`)
    /// or `.agentHook` otherwise, posts one user notification (its `body`
    /// run through `SecretRedactor.redact` first -- see that call site's
    /// own comment for why only the notification, never the banner, is
    /// redacted; a question's notification title is "... asks a
    /// question" and its body is the first question's own text), and
    /// long-polls `approvalInbox.awaitDecisionHonoringCancellation`. The
    /// resolved `ApprovalDecision` already carries its own `DenyReason`/
    /// `InterruptReason` (the model/view picked it when the human
    /// decided) -- `AgentHookPermissionResponse.body(kind:decision:)`
    /// alone maps that reason to the message/reason text a given `kind`'s
    /// hook actually reads; this route never passes a message string of
    /// its own.
    ///
    /// Three invariants a future change here must preserve:
    ///
    /// (a) THE RESPONSE BODY IS THE HOOK'S STDOUT, BYTE FOR BYTE --
    ///     Claude Code / Codex parse it directly as their own
    ///     PermissionRequest hook JSON contract, Grok as its own flat
    ///     PreToolUse decision, and pi's extension reads that same flat
    ///     decision from the response body of this very request (see
    ///     `AgentHookPermissionResponse`'s header comment). Nothing here
    ///     may wrap, prepend, or otherwise reshape it.
    ///
    /// (b) Fail-safe mapping: every path that resolves without a genuine
    ///     human decision (timed-out long-poll, `server.stop()`'s drain,
    ///     or this call's own Task being cancelled mid-poll) maps to
    ///     `.expired`, which `AgentHookPermissionResponse` renders as an
    ///     EMPTY body for both claude-code and codex -- neither CLI has
    ///     an "ask" analog under PermissionRequest, so absent output
    ///     lets that CLI's own confirmation prompt take over -- and as an
    ///     explicit deny for grok and pi: a grok request reaches this
    ///     point only under `bypassPermissions`, the one mode where
    ///     nothing behind this gate would ask anyone before running the
    ///     call, and pi has no prompt of its own in any mode, so silence
    ///     for either would let the call run unreviewed. NEVER
    ///     "allow". `awaitDecisionHonoringCancellation` is what re-maps an
    ///     `.allowed` decision that raced a concurrent cancellation of
    ///     this call's own Task to `.expired` -- see that method's own
    ///     doc comment on `ApprovalInboxStore` (the same re-check
    ///     `MCPCockpitBridge.gate` also goes through, centralized there
    ///     rather than duplicated in both places).
    ///
    /// (c) A hook killed client-side (curl's own `-m` deadline, the CLI's
    ///     hook-entry timeout, or the whole hook process being killed
    ///     outright, e.g. by SIGKILL) drops this connection out from
    ///     under the still-suspended long-poll. `dispatchRoute`'s sentinel
    ///     receive (scoped to this endpoint only -- see that method's own
    ///     doc comment for the real detection mechanism, and why a
    ///     `stateUpdateHandler`-based approach does NOT work here) is what
    ///     notices the drop and cancels the `Task` running this call,
    ///     which propagates into `approvalInbox.awaitDecision`'s
    ///     cancellation handler and expires the pending request through
    ///     the same mechanism as a timeout, clearing its banner. A
    ///     decision that still resolves `.allowed` for such an
    ///     already-abandoned call is harmless: no hook process is left to
    ///     read this response, and nothing executes server-side as a
    ///     result of it -- execution happens inside the CLI agent's own
    ///     process, driven entirely by whatever it read from its own
    ///     hook's stdout.
    private func routeApprovalRequest(request: HTTPRequest) async -> HTTPResponse {
        guard let authToken = bearerToken(from: request.headers), authToken == token else {
            return HTTPParser.response(statusCode: 401, body: nil)
        }

        guard let body = request.body else {
            return HTTPParser.response(statusCode: 400, body: nil)
        }
        guard body.count <= Self.maxEventBodyBytes else {
            return HTTPParser.response(statusCode: 413, body: nil)
        }

        // Read before decode: `agentKind(from:)` has no failure path, so
        // reading it here first does not change this method's response
        // ordering for any existing guard below.
        let kind = agentKind(from: request.headers)
        guard let call = AgentHookToolCall.decode(from: body, kind: kind) else {
            return HTTPParser.response(statusCode: 400, body: nil)
        }

        guard let surfaceID = resolveSurfaceID(from: request.headers) else {
            return HTTPParser.response(statusCode: 400, body: nil)
        }

        guard kind == AgentEntry.claudeCodeKind || kind == AgentEntry.codexKind
            || kind == AgentEntry.grokKind || kind == AgentEntry.piKind else {
            // An agent CLI Calyx doesn't have a hook-response contract
            // for at all (see `AgentHookPermissionResponse`'s own
            // fail-safe contract) -- never submit to the inbox for one.
            return HTTPParser.response(statusCode: 200, body: nil)
        }

        guard ApprovalHookEvent.isApprovalGate(call.hookEventName, kind: kind) else {
            // A stale PreToolUse-fired POST (a not-yet-migrated install,
            // see this method's own doc comment) or any other/missing
            // hook event name -- inert, same as the unrecognized-kind
            // guard above, never submitted to the inbox.
            return HTTPParser.response(statusCode: 200, body: nil)
        }

        guard ApprovalHookEvent.gateIsSoleAuthority(kind: kind, permissionMode: call.permissionMode) else {
            // A Grok session outside bypassPermissions: Grok's own
            // permission pipeline, its in-pane prompt included, still
            // runs after this gate, and a decision here could not grant
            // anything anyway (see `gateIsSoleAuthority`). Answering
            // with no decision at all leaves that pipeline deciding
            // exactly as it would without Calyx, rather than asking the
            // same human the same question in two places.
            return HTTPParser.response(statusCode: 200, body: nil)
        }

        guard CockpitSettings.agentHookApprovalEnabled else {
            return HTTPParser.response(statusCode: 200, body: nil)
        }

        // An AskUserQuestion call must always ask a human: neither global
        // auto-approve nor pane-scoped Always-Allow memory may ever
        // short-circuit a question the way they do a plain tool call --
        // a "yes always allow this tool" memory says nothing about which
        // OPTION a human would have picked. Gated on `call.isQuestionTool`,
        // not `call.question == nil`: a malformed `tool_input.questions`
        // (decoded to `nil` by `decodeQuestions`) still reaches the
        // generic `.agentHook` banner below, but must still never be
        // auto-allowed just because decoding failed to produce option
        // buttons to answer with -- the hold window expiring with no
        // decision made (`.expired`, no body -- see
        // `AgentHookPermissionResponse`'s own fail-safe contract) is one
        // path that hands an AskUserQuestion call to Claude Code's own
        // in-pane prompt; the panel's own × dismiss action
        // (`ApprovalDecision.dismissed`, also no body for claude-code) is
        // another.
        if !call.isQuestionTool {
            guard ApprovalPolicy.requiresApproval() else {
                return HTTPParser.response(
                    statusCode: 200, body: AgentHookPermissionResponse.body(kind: kind, decision: .allowed)
                )
            }

            if agentHookApprovalMemory.isAutoAllowed(surfaceID: surfaceID, kind: kind, toolName: call.toolName) {
                return HTTPParser.response(
                    statusCode: 200, body: AgentHookPermissionResponse.body(kind: kind, decision: .allowed)
                )
            }
        }

        // R4: a valid-FORMAT surface UUID no live surface registry
        // actually knows about (pane already closed, or a stale/forged
        // header) -- inert pass-through, same as the unrecognized-kind
        // guard above, rather than queuing a request whose banner no
        // window could ever show.
        guard approvalSurfaceExists(surfaceID) else {
            return HTTPParser.response(statusCode: 200, body: nil)
        }

        let requestID = UUID()
        let source: ApprovalRequest.Source
        let notificationTitle: String
        let notificationBody: String
        if let question = call.question {
            source = .agentQuestion(kind: kind, prompt: question)
            notificationTitle = "\(AgentEntry.displayName(forKind: kind)) asks a question"
            notificationBody = SecretRedactor.redact(question.questions[0].text)
        } else {
            let offers = AgentHookOffers(
                permissionUpdates: call.permissionOffers,
                cliOwnsPersistence: !call.permissionOffers.isEmpty
            )
            source = .agentHook(toolName: call.toolName, kind: kind, summary: call.summary, offers: offers)
            notificationTitle = "\(AgentEntry.displayName(forKind: kind)) wants to run \(call.toolName)"
            notificationBody = SecretRedactor.redact("\(call.toolName): \(call.summary)")
        }
        approvalInbox.submit(ApprovalRequest(
            id: requestID,
            source: source,
            targetSurfaceID: surfaceID,
            payload: call.payload,
            createdAt: Date()
        ))
        // R3 fix-pin: the notification body is redacted through
        // SecretRedactor -- the same redaction CommandLogStore already
        // runs text through before persistence (see that type's own
        // header comment) -- because a notification can leak into places
        // (Notification Center history, a screen someone else can see)
        // the human never explicitly chose to expose a raw secret to.
        // The BANNER, in contrast, deliberately keeps `call.summary`/the
        // question text verbatim (via `ApprovalRequest.displayPayload` --
        // `.agentHook`'s own `summary`, `.agentQuestion`'s own question
        // texts) -- the human approving this exact tool call must see
        // exactly what they're being asked to approve, unredacted;
        // `ControlCharacterDisplay` there guards a different concern
        // (terminal-control-character spoofing), not secret leakage.
        // NotificationSanitizer still runs inside sendNotification itself
        // -- no need to sanitize title/body for that separate concern
        // here.
        NotificationManager.shared.sendNotification(
            title: notificationTitle, body: notificationBody, tabID: surfaceID
        )

        let decision = await approvalInbox.awaitDecisionHonoringCancellation(id: requestID, timeoutMs: approvalRequestTimeoutMs)
        return HTTPParser.response(
            statusCode: 200,
            body: AgentHookPermissionResponse.body(kind: kind, decision: decision)
        )
    }

    // MARK: - /calyx-mcp routes

    /// Like `route(request:)`, but a `/calyx-mcp` POST or GET may answer
    /// with a stream. The stream finishes once `lifetime` (the caller's
    /// handle on the connection) completes; a stream that finishes, or is
    /// no longer consumed, cancels whatever it was producing.
    func routeStreaming(request: HTTPRequest, lifetime: Task<Void, Never>) async -> RoutedResponse {
        let routed: RoutedResponse
        switch (request.method, request.path) {
        case ("POST", HTTPParser.calyxMCPPath):
            routed = await routeCalyxMCPPost(request: request)
        case ("GET", HTTPParser.calyxMCPPath):
            routed = await routeCalyxMCPStream(request: request)
        default:
            return .buffered(await route(request: request))
        }
        guard case .stream(let head, let body) = routed else { return routed }
        return .stream(head: head, body: Self.bounded(body, by: lifetime))
    }

    private func routeCalyxMCP(request: HTTPRequest) async -> HTTPResponse {
        await Self.collect(await routeCalyxMCPPost(request: request))
    }

    private func routeCalyxMCPPost(request: HTTPRequest) async -> RoutedResponse {
        if let rejection = calyxMCPRejection(for: request) {
            return .buffered(rejection)
        }
        guard let router = calyxMCPRouter else {
            return .buffered(HTTPParser.response(statusCode: 503, body: nil))
        }
        return await router.routeCalyxMCP(
            request: request,
            paneContext: calyxMCPPaneContext(from: request.headers),
            modelContextProvider: calyxMCPModelContextProvider
        )
    }

    private func routeCalyxMCPStream(request: HTTPRequest) async -> RoutedResponse {
        if let rejection = calyxMCPRejection(for: request) {
            return .buffered(rejection)
        }
        guard let router = calyxMCPRouter else {
            return .buffered(HTTPParser.response(statusCode: 503, body: nil))
        }
        return await router.routeCalyxMCPStream(request: request)
    }

    private func routeCalyxMCPDelete(request: HTTPRequest) async -> HTTPResponse {
        if let rejection = calyxMCPRejection(for: request) {
            return rejection
        }
        guard let router = calyxMCPRouter else {
            return HTTPParser.response(statusCode: 503, body: nil)
        }
        return await router.routeCalyxMCPDelete(request: request)
    }

    /// The checks every `/calyx-mcp` request passes before its router: a
    /// present `Origin` must be loopback (403), then the bearer token (401).
    /// A request without `Origin` is not rejected for it.
    private func calyxMCPRejection(for request: HTTPRequest) -> HTTPResponse? {
        if let origin = header(named: "Origin", in: request.headers), !Self.isLoopbackOrigin(origin) {
            return HTTPParser.response(statusCode: 403, body: nil)
        }
        guard let authToken = bearerToken(from: request.headers), authToken == token else {
            return HTTPParser.response(statusCode: 401, body: nil)
        }
        return nil
    }

    private static func isLoopbackOrigin(_ origin: String) -> Bool {
        guard let host = URLComponents(string: origin)?.host?.lowercased() else { return false }
        return host == "127.0.0.1" || host == "localhost" || host == "::1" || host == "[::1]"
    }

    /// Pane resolution for `/calyx-mcp`: a non-empty
    /// `X-Calyx-Herdr-Pane-ID` is final, resolved or not; otherwise the
    /// session and surface headers resolve exactly as for `/mcp`
    /// (`resolveSurfaceID`). An empty or whitespace-only herdr pane id is
    /// the unset-variable expansion outside herdr and counts as absent.
    private func calyxMCPPaneContext(from headers: [String: String]) -> MCPPaneResolutionContext {
        if let ref = resolveHerdrPaneRef(from: headers) {
            return MCPPaneResolutionContext(
                surfaceID: herdrPaneRegistry.surfaceID(forPaneID: ref.paneID, socketPath: ref.socketPath),
                clientName: nil,
                herdrPaneRef: ref
            )
        }
        if herdrPaneID(from: headers) != nil {
            // A herdr pane with no socket to look it up under.
            return MCPPaneResolutionContext(surfaceID: nil, clientName: nil, herdrPaneRef: nil)
        }
        return MCPPaneResolutionContext(surfaceID: resolveSurfaceID(from: headers), clientName: nil, herdrPaneRef: nil)
    }

    /// The herdr pane the request names. The socket is
    /// `X-Calyx-Herdr-Socket-Path` when non-empty, else
    /// `herdrDefaultSocketPath()`. Nil without a non-empty pane id or
    /// without a socket.
    private func resolveHerdrPaneRef(from headers: [String: String]) -> HerdrPaneRef? {
        guard let paneID = herdrPaneID(from: headers) else { return nil }
        let explicitSocket = header(named: "X-Calyx-Herdr-Socket-Path", in: headers)?
            .trimmingCharacters(in: .whitespaces)
        let socketPath: String?
        if let explicitSocket, !explicitSocket.isEmpty {
            socketPath = explicitSocket
        } else {
            socketPath = herdrDefaultSocketPath()
        }
        guard let socketPath else { return nil }
        return HerdrPaneRef(socketPath: socketPath, paneID: paneID)
    }

    private func herdrPaneID(from headers: [String: String]) -> String? {
        guard let paneID = header(named: "X-Calyx-Herdr-Pane-ID", in: headers)?
            .trimmingCharacters(in: .whitespaces), !paneID.isEmpty else {
            return nil
        }
        return paneID
    }

    /// A buffered response for `route(request:)`: a stream is read to its
    /// end and returned as one body.
    private static func collect(_ routed: RoutedResponse) async -> HTTPResponse {
        switch routed {
        case .buffered(let response):
            return response
        case .stream(let head, let body):
            var data = Data()
            for await chunk in body {
                data.append(chunk)
            }
            let base = HTTPParser.response(statusCode: head.statusCode, body: data)
            return HTTPResponse(
                statusCode: base.statusCode,
                statusMessage: base.statusMessage,
                headers: base.headers.merging(head.headers) { _, streamed in streamed },
                body: data
            )
        }
    }

    /// `body`, finished once `lifetime` completes.
    private static func bounded(_ body: AsyncStream<Data>, by lifetime: Task<Void, Never>) -> AsyncStream<Data> {
        AsyncStream { continuation in
            let forward = Task {
                for await chunk in body {
                    continuation.yield(chunk)
                }
                continuation.finish()
            }
            let watch = Task {
                await lifetime.value
                forward.cancel()
                continuation.finish()
            }
            continuation.onTermination = { _ in
                forward.cancel()
                watch.cancel()
            }
        }
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

    func start(token: String, preferredPort: Int = IPCEndpointReuse.defaultPort) async throws {
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
        // the listener actually resolved to (see
        // `LoopbackListenerBinder.bindListener(onPort:logLabel:)`), which
        // matches the requested port for the common non-zero case,
        // preserving the "well-known port" UX, but can differ when
        // `preferredPort` is `0` and the kernel silently assigns an
        // ephemeral slot instead of literally binding port `0` (see
        // `LoopbackListenerBinder.bindKernelAssignedListener`'s doc comment
        // for why that can happen even on this, the canonical-scan, path).
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
            guard let (nl, resolvedPort) = await LoopbackListenerBinder.bindListener(onPort: tryPort, logLabel: Self.listenerLogLabel) else {
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
        if let (nl, resolvedPort) = await bindKernelAssignedListener() {
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

    /// Asks the kernel for a free ephemeral loopback port and binds an
    /// `NWListener` to it. See
    /// `LoopbackListenerBinder.bindKernelAssignedListener(logLabel:)`.
    ///
    /// `internal` (not `private`) so `CalyxMCPServerTests` can exercise
    /// it directly via `@testable import` without needing to exhaust
    /// the whole canonical scan range first just to reach this path.
    func bindKernelAssignedListener() async -> (NWListener, Int)? {
        await LoopbackListenerBinder.bindKernelAssignedListener(logLabel: Self.listenerLogLabel)
    }

    /// Ask the kernel for a free ephemeral port on `127.0.0.1`. See
    /// `LoopbackListenerBinder.askKernelForFreeLoopbackPort()`.
    ///
    /// `internal` (not `private`) so `CalyxMCPServerTests` can call this
    /// directly via `@testable import` instead of maintaining its own
    /// duplicate copy of the same BSD-socket probe.
    func askKernelForFreeLoopbackPort() -> Int? {
        LoopbackListenerBinder.askKernelForFreeLoopbackPort()
    }

    /// Prefix of the binder's log lines and its probe queue label.
    private static let listenerLogLabel = "CalyxMCPServer"

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
        // Captured before any state reset below, most importantly
        // before `port = 0` a few lines down, so the removal always
        // checks the port+token this instance actually published.
        // Capturing both together (not just `port`) keeps this correct
        // even if a future change starts resetting `token` here too.
        let stoppedPort = port
        let stoppedToken = token
        listener?.cancel()
        listener = nil
        isRunning = false
        appPeerID = nil
        peerRegistrationTask?.cancel()
        peerRegistrationTask = nil
        port = 0
        AgentEndpointFile.remove(directory: agentEndpointDirectory, port: stoppedPort, token: stoppedToken)
        // Clears every native Agents sidebar row (hooks/title-heuristic)
        // — without this, disabling IPC (or a start()-triggered restart)
        // leaves stale rows on screen for panes the registry will never
        // hear from again. AgentStatusView returns to its "disabled"
        // placeholder only when this ALSO leaves no external (herdr) rows
        // behind: reset() deliberately never touches externalEntries (see
        // that property's own doc comment), and AgentSidebarGate keeps
        // showing rows while AgentRegistry.hasExternalEntries is true.
        agentRegistry.reset()
        // Synchronously drains every pending Cockpit approval request so
        // a stopped server never strands an MCP caller waiting on a
        // decision nobody can make anymore -- see
        // `CalyxMCPServerCockpitToolsTests.test_serverStop_expiresPendingApprovals`.
        approvalInbox.expireAll()
        // Clears every Always-Allow memory recorded this session so a
        // restarted server never silently auto-allows a request the
        // human never actually decided to trust across a stop/start
        // boundary -- see AgentHookApprovalMemory's own header comment.
        agentHookApprovalMemory.clearAll()
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
        /// The body cap of the request being received, decided from its
        /// header block (`requestBodyLimit(forHeaderString:)`).
        var bodyLimit = HTTPParser.maxBodySize
        /// True from a streamed response's head until its last chunk.
        var isStreaming = false
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
                    let (resolvedState, resolvedTotal) = HTTPParser.completeness(of: accumulator.data) { headerString in
                        accumulator.bodyLimit = self.requestBodyLimit(forHeaderString: headerString)
                        return accumulator.bodyLimit
                    }
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
            let httpRequest = try HTTPParser.parse(buffer, maxBodySize: accumulator.bodyLimit)
            if httpRequest.path == HTTPParser.calyxMCPPath {
                await serveCalyxMCP(connection: connection, request: httpRequest, accumulator: accumulator)
                return
            }
            let httpResponse = await self.dispatchRoute(connection: connection, request: httpRequest, accumulator: accumulator)
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

    /// Runs `route(request:)`, additionally wiring a connection-drop
    /// watch scoped to `POST /approval-request` ONLY (both method AND
    /// path -- a stray non-POST request to the same path just falls
    /// through to the plain `await route(request:)` path below, same as
    /// every other route, and gets its ordinary 404 with no Task+sentinel
    /// wrapping): that endpoint alone can suspend for up to
    /// `approvalRequestTimeoutMs` (~9.5 minutes)
    /// awaiting a human decision, so it alone needs to notice the peer
    /// disappearing mid-poll (the hook process getting killed by curl's
    /// own `-m` deadline or the CLI's hook-entry timeout) and cancel its
    /// own `route(request:)` Task — cancellation propagates into
    /// `approvalInbox.awaitDecision`'s cancellation handler, expiring
    /// the pending request and clearing its banner (see
    /// `routeApprovalRequest`'s own doc comment, point (c)). Every other
    /// route still runs via the plain `await route(request:)` path below
    /// completely unchanged — none of them block on a human, so none of
    /// them need this.
    ///
    /// THE REAL MECHANISM (empirically verified, replacing an earlier
    /// `connection.stateUpdateHandler`-based attempt that never actually
    /// fired): with no `receive()` outstanding on a connection,
    /// `NWConnection` does NOT report a peer's graceful FIN via
    /// `stateUpdateHandler` at all — a SIGKILLed curl process on loopback
    /// also produces a plain FIN, not a distinguishable error state. The
    /// only way this framework ever surfaces either is a `receive()`
    /// completing with `isComplete == true` or a non-nil `error`, which
    /// can only happen while a `receive()` call is actually outstanding.
    /// So this keeps a SENTINEL `connection.receive` call outstanding for
    /// the whole lifetime of `routeTask`'s suspension: once it completes
    /// with `isComplete`/`error` — and only while `accumulator.didRespond`
    /// is still `false` — it cancels `routeTask`. A sentinel completing
    /// AFTER `didRespond` (e.g. because `sendHTTPResponse`'s own
    /// `connection.cancel()` also completes this same outstanding
    /// receive) is a deliberate no-op, gated on the same `didRespond`
    /// flag `sendHTTPResponse` itself uses as its single source of truth.
    /// Any bytes the sentinel actually reads are discarded and the
    /// sentinel simply re-arms itself — this connection never supports
    /// pipelining (`Connection: close`), so there is nothing meaningful
    /// to parse out of a non-terminal read here, but the watch must stay
    /// outstanding afterward or a later genuine drop would go right back
    /// to being undetectable.
    private func dispatchRoute(
        connection: NWConnection, request: HTTPRequest, accumulator: ReceiveAccumulator
    ) async -> HTTPResponse {
        guard request.method == "POST", request.path == Self.approvalRequestPath else {
            return await route(request: request)
        }

        let routeTask = Task { @MainActor in
            await self.route(request: request)
        }

        armConnectionDropSentinel(
            connection: connection,
            isSettled: { accumulator.didRespond },
            onDrop: { routeTask.cancel() }
        )

        return await routeTask.value
    }

    /// Serves a `/calyx-mcp` request, whose response may be a stream. The
    /// connection-drop sentinel `dispatchRoute` arms for
    /// `/approval-request` watches this request too, for as long as its
    /// response is pending or streaming: a drop cancels the route's Task
    /// and ends `lifetime`, which finishes the stream and cancels whatever
    /// was producing it. A stream is written with chunked transfer
    /// encoding, one chunk per element, then the connection is closed.
    private func serveCalyxMCP(connection: NWConnection, request: HTTPRequest, accumulator: ReceiveAccumulator) async {
        let lifetime = Task<Void, Never> {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3600))
            }
        }
        let routeTask = Task { @MainActor in
            await self.routeStreaming(request: request, lifetime: lifetime)
        }
        armConnectionDropSentinel(
            connection: connection,
            isSettled: { accumulator.didRespond && !accumulator.isStreaming },
            onDrop: {
                routeTask.cancel()
                lifetime.cancel()
            }
        )

        switch await routeTask.value {
        case .buffered(let response):
            lifetime.cancel()
            sendHTTPResponse(connection: connection, httpResponse: response, accumulator: accumulator)
        case .stream(let head, let body):
            guard !accumulator.didRespond else {
                lifetime.cancel()
                return
            }
            accumulator.didRespond = true
            accumulator.isStreaming = true
            connection.send(content: HTTPParser.serializeStreamHead(head), completion: .idempotent)
            for await chunk in body {
                connection.send(content: HTTPParser.encodeChunk(chunk), completion: .idempotent)
            }
            lifetime.cancel()
            accumulator.isStreaming = false
            connection.send(content: HTTPParser.lastChunk, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }

    /// The body cap of the request whose header block is `headerString`:
    /// 32 MiB for `/calyx-mcp` carrying this server's bearer token, 1 MiB
    /// otherwise, so the larger cap is never available before
    /// authentication.
    private func requestBodyLimit(forHeaderString headerString: String) -> Int {
        let token = self.token
        return HTTPParser.bodyLimit(forHeaderString: headerString) { authorization in
            guard !token.isEmpty, let authorization, authorization.hasPrefix("Bearer ") else { return false }
            return String(authorization.dropFirst(7)) == token
        }
    }

    /// The sentinel receive `dispatchRoute` arms for `/approval-request`
    /// and `serveCalyxMCP` for `/calyx-mcp` — see `dispatchRoute`'s own
    /// doc comment for the full rationale. `isSettled` says whether the
    /// response is already complete, in which case a completing receive
    /// (including the one `sendHTTPResponse`'s own `connection.cancel()`
    /// completes) is a no-op; otherwise a terminal receive calls `onDrop`.
    /// Kept as its own recursive method (mirroring `receiveUntilComplete`'s
    /// shape) rather than inline, so the re-arm-on-non-terminal-data step
    /// reads as a plain recursive call instead of a nested closure
    /// capturing itself.
    private func armConnectionDropSentinel(
        connection: NWConnection,
        isSettled: @escaping @MainActor () -> Bool,
        onDrop: @escaping @MainActor () -> Void
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: HTTPParser.maxHeaderSize + HTTPParser.maxBodySize) { [weak self] _, _, isComplete, error in
            Task { @MainActor in
                guard let self, !isSettled() else { return }
                guard isComplete || error != nil else {
                    self.armConnectionDropSentinel(connection: connection, isSettled: isSettled, onDrop: onDrop)
                    return
                }
                onDrop()
            }
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
    ///   present and valid on the underlying HTTP request,
    ///   parsed by `routeMCP`'s `parseSurfaceID(from:)`. When non-`nil`,
    ///   the `initialize` case reports (and, if needed, (re)binds) that
    ///   surface's one true peer identity (see that call
    ///   site's own comment), and `tools/call`'s `register_peer`
    ///   unconditionally binds it to whatever peer it resolves to — both
    ///   via `agentRegistry.bindSurface` — so a pane's row gets its unread
    ///   badge lit even if it never calls a calyx-ipc tool itself (the
    ///   hook-derived binding in `AgentRegistry.handleHookEvent`
    ///   still runs independently, as a fallback that needs no
    ///   `X-Calyx-Surface-ID` header at all).
    func handleJSONRPC(
        data: Data,
        authToken: String?,
        surfaceID: UUID? = nil,
        agentKind: String? = nil
    ) async -> (statusCode: Int, body: Data?) {

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
            // Auto-register a peer ONLY for a surface-bound
            // connection (one carrying `X-Calyx-Surface-ID`). A
            // surfaceless connection (e.g. an external MCP client like
            // OpenCode) has no surface for a peer to ever be bound to —
            // auto-registering one for it on every `initialize` just
            // leaves an orphaned, unaddressable identity behind on every
            // reconnect, with no way to rename it back onto whatever
            // identity the client eventually self-registers via
            // `register_peer`. Such a client keeps the
            // "self-register immediately" instructions (see
            // `MCPRouter.instructions`) as its only path to a peer_id —
            // that's the intended, unchanged contract for it, not a gap.
            //
            // A surface-bound connection instead resolves
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
                    let clientName = extractClientName(from: request.params) ?? agentKind ?? AgentEntry.claudeCodeKind
                    let peer = await store.registerPeer(
                        name: clientName,
                        role: agentKind ?? AgentEntry.claudeCodeKind
                    )
                    peerID = peer.id
                    agentRegistry.bindSurface(surfaceID, toPeer: peer.id)
                }
                if let agentKind {
                    agentRegistry.handleMCPConnection(surfaceID: surfaceID, kind: agentKind)
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

        // terminal_* route — dispatched through `MCPCommandLogBridge`.
        if MCPRouter.isTerminalTool(name: toolName) {
            return await handleTerminalToolCall(
                id: id,
                toolName: toolName,
                params: params
            )
        }

        // Cockpit route — dispatched through `MCPCockpitBridge`.
        if MCPRouter.isCockpitTool(name: toolName) {
            return await handleCockpitToolCall(
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

    /// Enforces "1 surface = 1 peer identity". Before this fix,
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
        // so an omitted/empty argument here becomes "".
        let peer = await store.registerPeer(name: nameArg ?? "", role: roleArg ?? "")
        // Bind the connection's own surface to the freshly
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
            IPCMessageEventFeed.shared.record(IPCMessageEvent(
                id: message.id, from: message.from, to: message.to, content: message.content,
                sentAt: message.timestamp, isBroadcast: false
            ))
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
            // ONE feed event per broadcast, not one per recipient: Mission
            // Map fans a broadcast out to every other bound peer itself
            // (`MissionMapSnapshotBuilder`), so a per-recipient record
            // would draw every line once per recipient. A broadcast that
            // reached nobody has no message to record and draws nothing.
            if let first = messages.first {
                IPCMessageEventFeed.shared.record(IPCMessageEvent(
                    id: first.id, from: first.from, to: first.to, content: first.content,
                    sentAt: first.timestamp, isBroadcast: true
                ))
            }
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

    // MARK: - terminal_* Tool Dispatch

    /// Route a `terminal_*` tool call to `MCPCommandLogBridge`, mirroring
    /// `handleLSPToolCall`'s shape at a small scale: unlike the LSP
    /// bridge (optional, only live after `startLSP()`), the command-log
    /// bridge is always available (the lazily-built, cached
    /// `lazyCommandLogBridge`). `MCPCommandLogBridgeError` conforms to
    /// `LocalizedError`, so (unlike `handleLSPToolCall`'s per-case
    /// switch over `MCPLSPBridgeError`) a single generic `catch` can
    /// build the tool-error text straight from
    /// `error.localizedDescription`.
    private func handleTerminalToolCall(
        id: JSONRPCId,
        toolName: String,
        params: [String: AnyCodable]
    ) async -> (statusCode: Int, body: Data?) {
        let arguments = extractDict(params, "arguments") ?? [:]
        do {
            let text = try await lazyCommandLogBridge.handleToolCall(name: toolName, arguments: arguments)
            return toolSuccess(id: id, text: text)
        } catch {
            return toolError(id: id, text: error.localizedDescription)
        }
    }

    // MARK: - Cockpit Tool Dispatch

    /// Route a Cockpit tool call (`pane_list`/`pane_split`/`tab_create`)
    /// to `MCPCockpitBridge`, mirroring
    /// `handleTerminalToolCall`'s shape exactly: `MCPCockpitBridgeError`
    /// also conforms to `LocalizedError`, so a single generic `catch`
    /// builds the tool-error text from `error.localizedDescription`.
    private func handleCockpitToolCall(
        id: JSONRPCId,
        toolName: String,
        params: [String: AnyCodable]
    ) async -> (statusCode: Int, body: Data?) {
        let arguments = extractDict(params, "arguments") ?? [:]
        do {
            let text = try await lazyCockpitBridge.handleToolCall(name: toolName, arguments: arguments)
            return toolSuccess(id: id, text: text)
        } catch {
            return toolError(id: id, text: error.localizedDescription)
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

// MARK: - Session bearer

/// The server's bearer token, readable from any isolation domain.
/// Written on the main actor whenever `CalyxMCPServer.token` changes.
final class MCPSessionBearerToken: Sendable {
    private let storage = Mutex("")

    var value: String {
        get { storage.withLock { $0 } }
        set { storage.withLock { $0 = newValue } }
    }
}
