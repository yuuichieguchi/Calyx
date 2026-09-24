//
//  CalyxMCPServerApprovalRequestTests.swift
//  CalyxTests
//
//  Covers Stage B of the approval-inbox-for-CLI-agents
//  feature: the new `POST /approval-request` long-poll endpoint on
//  CalyxMCPServer. Mirrors CalyxMCPServerAgentEventTests' harness
//  (HTTPRequest construction + `await server.route(request:)` direct
//  drive, no sockets, isolated `agent-endpoint.json` directory) and
//  CalyxMCPServerCockpitToolsTests' injected-ApprovalInboxStore /
//  scheduler-yield / stop()-drain idioms.
//
//  Coverage:
//  - Bearer auth (401), body presence/size (400/413, cap checked before
//    decode), AgentHookToolCall decode failure (400), missing
//    X-Calyx-Surface-ID (400)
//  - R4: a valid-FORMAT surface UUID unknown to `approvalSurfaceExists`
//    (an injectable seam) short-circuits to 200 with an EMPTY body,
//    submitting nothing and posting no notification -- every OTHER
//    short-circuit below (toggle/kind/auto-approve/memory) never
//    reaches this check, so those tests are unaffected; only a test that
//    actually expects a submission needs `approvalSurfaceExists = { _ in
//    true }`
//  - Unknown X-Calyx-Agent-Kind and the agentHookApprovalEnabled toggle
//    being off each short-circuit to 200 with an EMPTY body and submit
//    nothing to the inbox
//  - A payload's hook_event_name must be exactly "PermissionRequest" to
//    enter the approval flow at all -- any other value (e.g. "PreToolUse",
//    a stale pre-migration hook's own event name) or a missing key both
//    short-circuit the same inert way (200, EMPTY body, no submission, no
//    notification)
//  - Global auto-approve short-circuits to 200 with an allow body,
//    without submitting
//  - an AgentHookApprovalMemory pane-scope hit short-circuits to 200 with
//    an allow body, without submitting -- checked after the global
//    auto-approve short-circuit and before submit; a miss still submits
//    and long-polls as before. server.stop()
//    also clears the injected agentHookApprovalMemory, same as it
//    already drains approvalInbox
//  - Otherwise: submits an ApprovalRequest(source: .agentHook(...)) and
//    long-polls approvalInbox.awaitDecision, mapping .allowed/.denied/
//    .expired to the AgentHookPermissionResponse body for the resolved
//    kind
//  - approvalRequestTimeoutMs (new injectable seam, default 570_000) and
//    ApprovalHookTiming's derived-constants ordering invariant
//  - Cancelling the Task running route(...) mid-poll, and server.stop()
//    mid-poll, both resolve the held route as expired / fail-safe and
//    drain the pending request
//  - Submitting a request posts exactly one user notification via the
//    existing NotificationManager.shared swap seam (see
//    SessionReconnectGiveUpTests.GiveUpNotificationSpy for the
//    established pattern this mirrors -- no new seam needed)
//

import XCTest
@testable import Calyx

@MainActor
final class CalyxMCPServerApprovalRequestTests: XCTestCase {

    // MARK: - Properties

    private var server: CalyxMCPServer!
    private let testToken = "approval-request-test-token"
    private let settingsSuiteName = "com.calyx.tests.CalyxMCPServerApprovalRequestTests"

    /// Test-isolated `agent-endpoint.json` directory, passed to every
    /// `CalyxMCPServer` instance in this suite via the required
    /// `agentEndpointDirectory` init parameter -- same rationale as
    /// CalyxMCPServerAgentEventTests: this suite never calls `start()`,
    /// but `tearDown`'s `server.stop()` still calls
    /// `AgentEndpointFile.remove(directory:port:token:)`.
    private var agentEndpointDir: String!

    // MARK: - Lifecycle

    override func setUp() {
        super.setUp()
        CockpitSettings._testUseSuite(named: settingsSuiteName)
        agentEndpointDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).path
        server = CalyxMCPServer(agentEndpointDirectory: agentEndpointDir)
        server.agentRegistry = AgentRegistry()
        server.approvalInbox = ApprovalInboxStore()
        // R6 test hygiene: isolate Always-Allow memory from the shared
        // singleton by default, same rationale as `approvalInbox` above
        // -- individual tests below that need to assert on memory
        // reassign their own instance afterward, which simply overrides
        // this default.
        server.agentHookApprovalMemory = AgentHookApprovalMemory()
        server._testSetToken(testToken)
    }

    override func tearDown() {
        server.stop()
        server = nil
        if let agentEndpointDir {
            try? FileManager.default.removeItem(atPath: agentEndpointDir)
        }
        agentEndpointDir = nil
        CockpitSettings._testTeardownSuite(named: settingsSuiteName)
        super.tearDown()
    }

    // MARK: - Request-building helpers

    /// `hookEventName` defaults to `"PermissionRequest"` -- the only
    /// value `routeApprovalRequest` now advances the approval flow for
    /// -- so every existing call site below keeps exercising its own
    /// intended short-circuit/submission path without also needing to
    /// pass it explicitly. Pass `nil` to omit the `hook_event_name` key
    /// entirely, or an explicit override (e.g. `"PreToolUse"`, a stale
    /// pre-migration hook's own event name) to drive the inert
    /// hook-event-name-gate tests below.
    private func validToolCallBody(command: String = "ls -la /tmp", hookEventName: String? = "PermissionRequest") -> Data {
        let hookEventNameField = hookEventName.map { ",\"hook_event_name\":\"\($0)\"" } ?? ""
        return Data("""
        {"tool_name":"Bash","tool_input":{"command":"\(command)"}\(hookEventNameField)}
        """.utf8)
    }

    private func approvalRequestRequest(
        token: String?,
        surfaceIDHeader: String?,
        body: Data?,
        kindHeader: String? = nil
    ) -> HTTPRequest {
        var headers: [String: String] = [:]
        if let token { headers["Authorization"] = "Bearer \(token)" }
        if let surfaceIDHeader { headers["X-Calyx-Surface-ID"] = surfaceIDHeader }
        if let kindHeader { headers["X-Calyx-Agent-Kind"] = kindHeader }
        return HTTPRequest(method: "POST", path: "/approval-request", headers: headers, body: body)
    }

    /// Independently computes `AgentHookToolCall.decode`'s documented
    /// `payload` value (compact JSON of `tool_input`) from a plain
    /// dictionary literal, so assertions on `ApprovalRequest.payload`
    /// don't depend on re-deriving the decoder's own output.
    private func compactJSON(_ object: [String: Any]) throws -> String {
        try XCTUnwrap(String(data: try JSONSerialization.data(withJSONObject: object), encoding: .utf8))
    }

    // MARK: - Response-parsing helpers

    private func responseJSON(_ body: Data?) throws -> [String: Any] {
        let data = try XCTUnwrap(body, "response body must not be nil")
        let object = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(object as? [String: Any], "response body must be a JSON object")
    }

    /// Parses the PermissionRequest response shape
    /// (`hookSpecificOutput.decision.behavior`), replacing the older
    /// PreToolUse-era `hookSpecificOutput.permissionDecision` this helper
    /// used to read -- keeping the old name here would suggest a JSON
    /// field that no longer exists.
    private func permissionBehavior(fromResponseBody body: Data?) throws -> String {
        let json = try responseJSON(body)
        let hookSpecificOutput = try XCTUnwrap(json["hookSpecificOutput"] as? [String: Any])
        let decision = try XCTUnwrap(hookSpecificOutput["decision"] as? [String: Any])
        return try XCTUnwrap(decision["behavior"] as? String)
    }

    /// Bounded scheduler-yield loop, so a concurrently-spawned `Task`
    /// driving `server.route(request:)` has every reasonable opportunity
    /// to reach its `approvalInbox.awaitDecision` suspension point
    /// (having already called `approvalInbox.submit` synchronously,
    /// before that suspend) before the test proceeds to inspect
    /// `approvalInbox.pending` -- same pattern as
    /// MCPCockpitBridgeTests.yieldToScheduler / ApprovalInboxStoreTests's.
    private func yieldToScheduler() async {
        for _ in 0..<50 {
            await Task.yield()
        }
    }

    // MARK: - Authentication

    func test_route_missingOrWrongBearer_returns401() async {
        let cases: [(label: String, token: String?)] = [
            ("missing", nil),
            ("wrong", "wrong-token"),
        ]

        for testCase in cases {
            let request = approvalRequestRequest(
                token: testCase.token, surfaceIDHeader: UUID().uuidString, body: validToolCallBody()
            )

            let response = await server.route(request: request)

            XCTAssertEqual(response.statusCode, 401, "[\(testCase.label) bearer] must return 401")
            XCTAssertNil(response.body, "[\(testCase.label) bearer] a 401 must carry an empty body")
        }
    }

    // MARK: - Body validation

    func test_route_missingBody_returns400() async {
        let request = approvalRequestRequest(token: testToken, surfaceIDHeader: UUID().uuidString, body: nil)

        let response = await server.route(request: request)

        XCTAssertEqual(response.statusCode, 400)
    }

    func test_route_oversizedBody_returns413() async {
        // One byte over the 262_144 cap, composed at runtime -- the cap
        // must be checked BEFORE AgentHookToolCall.decode is even
        // attempted, mirroring routeCommandEvent's own ordering.
        let oversized = Data(repeating: 0x41, count: 262_145)
        let request = approvalRequestRequest(token: testToken, surfaceIDHeader: UUID().uuidString, body: oversized)

        let response = await server.route(request: request)

        XCTAssertEqual(response.statusCode, 413)
    }

    func test_route_malformedBody_returns400() async {
        let request = approvalRequestRequest(
            token: testToken, surfaceIDHeader: UUID().uuidString, body: Data("not json {{{".utf8)
        )

        let response = await server.route(request: request)

        XCTAssertEqual(response.statusCode, 400)
    }

    // MARK: - Surface ID validation

    func test_route_missingSurfaceID_returns400() async {
        let request = approvalRequestRequest(token: testToken, surfaceIDHeader: nil, body: validToolCallBody())

        let response = await server.route(request: request)

        XCTAssertEqual(response.statusCode, 400)
    }

    // MARK: - Stale/unknown surface guard (R4)

    /// A valid-FORMAT surface UUID that no live surface registry actually
    /// knows about (e.g. its pane was already closed, or the header is
    /// stale/forged) must short-circuit inert -- 200, an EMPTY body,
    /// nothing submitted to the inbox, and no notification posted --
    /// rather than submitting a request whose banner no window could
    /// ever show (see `ApprovalBannerModel.isVisible`: nothing owns a
    /// surface that doesn't exist) while its MCP-side caller (the hook
    /// script) long-polls for a decision nobody can ever make.
    ///
    /// `approvalSurfaceExists` is a new injectable seam (defaulting, in
    /// production, to a real surface-registry existence check) so this
    /// can be driven deterministically here without a live ghostty
    /// surface -- mirrors this codebase's other `CalyxMCPServer`
    /// dependency seams (`agentRegistry`/`approvalInbox`/
    /// `agentHookApprovalMemory`, etc.), each defaulted to the real
    /// thing and overridden by tests.
    func test_route_unknownSurface_returns200EmptyBody_submitsNothing_postsNoNotification() async throws {
        CockpitSettings.agentHookApprovalEnabled = true
        let approvalInbox = ApprovalInboxStore()
        server.approvalInbox = approvalInbox
        server.approvalSurfaceExists = { _ in false }

        let spy = ApprovalHookNotificationSpy()
        let originalManager = NotificationManager.shared
        NotificationManager.shared = spy
        defer { NotificationManager.shared = originalManager }

        let request = approvalRequestRequest(
            token: testToken, surfaceIDHeader: UUID().uuidString, body: validToolCallBody()
        )

        let response = await server.route(request: request)

        XCTAssertEqual(response.statusCode, 200,
                       "a surface unknown to the registry must still return 200, not an error status")
        XCTAssertNil(response.body, "a surface unknown to the registry must return an EMPTY body")
        XCTAssertTrue(approvalInbox.pending.isEmpty,
                      "a surface unknown to the registry must never submit a request to the inbox")
        XCTAssertEqual(spy.calls.count, 0, "a surface unknown to the registry must never post a notification")
    }

    // MARK: - Toggle / kind short-circuits

    func test_route_toggleOff_returns200EmptyBody_andSubmitsNothing() async {
        CockpitSettings.agentHookApprovalEnabled = false
        let approvalInbox = ApprovalInboxStore()
        server.approvalInbox = approvalInbox
        let request = approvalRequestRequest(
            token: testToken, surfaceIDHeader: UUID().uuidString, body: validToolCallBody()
        )

        let response = await server.route(request: request)

        XCTAssertEqual(response.statusCode, 200,
                       "agentHookApprovalEnabled being off must still return 200, not an error status")
        XCTAssertNil(response.body, "agentHookApprovalEnabled being off must return an EMPTY body")
        XCTAssertTrue(approvalInbox.pending.isEmpty,
                      "agentHookApprovalEnabled being off must never submit a request to the inbox")
    }

    func test_route_unknownKind_returns200EmptyBody_andSubmitsNothing() async {
        CockpitSettings.agentHookApprovalEnabled = true
        let approvalInbox = ApprovalInboxStore()
        server.approvalInbox = approvalInbox
        let request = approvalRequestRequest(
            token: testToken, surfaceIDHeader: UUID().uuidString, body: validToolCallBody(),
            kindHeader: "hermes"
        )

        let response = await server.route(request: request)

        XCTAssertEqual(response.statusCode, 200,
                       "an unrecognized X-Calyx-Agent-Kind must still return 200, not an error status")
        XCTAssertNil(response.body, "an unrecognized X-Calyx-Agent-Kind must return an EMPTY body")
        XCTAssertTrue(approvalInbox.pending.isEmpty,
                      "an unrecognized X-Calyx-Agent-Kind must never submit a request to the inbox, " +
                      "even with agentHookApprovalEnabled on")
    }

    // MARK: - hook_event_name gate (PermissionRequest only)

    /// A payload whose `hook_event_name` is anything other than
    /// `"PermissionRequest"` -- most notably `"PreToolUse"`, the event a
    /// pre-migration Calyx install's synchronous approval hook entry
    /// used to fire under -- must never enter the approval flow: 200, an
    /// EMPTY body, nothing submitted, no notification. `approvalSurfaceExists`
    /// is pinned to true (so the stale-surface guard can't short-circuit
    /// this for an unrelated reason).
    ///
    /// `approvalRequestTimeoutMs` is set short only to keep this test fast,
    /// NOT to make a missing gate observable through `response.body`: a
    /// not-yet-gated implementation would still submit the request and
    /// long-poll it to a `.expired` timeout, which renders the SAME empty
    /// body for claude-code as the intentional short-circuit (see
    /// `test_route_timeout_claude_returnsEmptyBody`) -- `response.body`
    /// being nil cannot distinguish the two. What does distinguish them is
    /// `XCTAssertEqual(spy.calls.count, 0, ...)` below: `routeApprovalRequest`
    /// posts its submission notification synchronously, before it ever
    /// suspends on the long-poll, so a not-yet-gated implementation that
    /// submitted would already show `spy.calls.count == 1` by the time this
    /// `await` returns, even though the returned body still looks
    /// identical. Do not remove that assertion as apparently redundant with
    /// the body/pending checks above it -- it is the one that actually
    /// catches a missing gate.
    func test_route_hookEventNamePreToolUse_returns200EmptyBody_submitsNothing_postsNoNotification() async throws {
        CockpitSettings.agentHookApprovalEnabled = true
        server.approvalRequestTimeoutMs = 50
        let approvalInbox = ApprovalInboxStore()
        server.approvalInbox = approvalInbox
        server.approvalSurfaceExists = { _ in true }

        let spy = ApprovalHookNotificationSpy()
        let originalManager = NotificationManager.shared
        NotificationManager.shared = spy
        defer { NotificationManager.shared = originalManager }

        let request = approvalRequestRequest(
            token: testToken, surfaceIDHeader: UUID().uuidString,
            body: validToolCallBody(hookEventName: "PreToolUse")
        )

        let response = await server.route(request: request)

        XCTAssertEqual(response.statusCode, 200,
                       "a stale PreToolUse-fired POST (pre-migration install) must still return 200, " +
                       "not an error status")
        XCTAssertNil(response.body, "hook_event_name other than PermissionRequest must return an EMPTY body")
        XCTAssertTrue(approvalInbox.pending.isEmpty, "must never submit a request to the inbox")
        XCTAssertEqual(spy.calls.count, 0, "must never post a notification")
    }

    /// A payload missing `hook_event_name` entirely must be treated the
    /// same as an unrecognized value -- inert, not a default allow-through.
    func test_route_hookEventNameMissing_returns200EmptyBody_submitsNothing_postsNoNotification() async throws {
        CockpitSettings.agentHookApprovalEnabled = true
        server.approvalRequestTimeoutMs = 50
        let approvalInbox = ApprovalInboxStore()
        server.approvalInbox = approvalInbox
        server.approvalSurfaceExists = { _ in true }

        let spy = ApprovalHookNotificationSpy()
        let originalManager = NotificationManager.shared
        NotificationManager.shared = spy
        defer { NotificationManager.shared = originalManager }

        let request = approvalRequestRequest(
            token: testToken, surfaceIDHeader: UUID().uuidString,
            body: validToolCallBody(hookEventName: nil)
        )

        let response = await server.route(request: request)

        XCTAssertEqual(response.statusCode, 200,
                       "a payload missing hook_event_name entirely must still return 200, not an error status")
        XCTAssertNil(response.body, "a missing hook_event_name must return an EMPTY body")
        XCTAssertTrue(approvalInbox.pending.isEmpty, "must never submit a request to the inbox")
        XCTAssertEqual(spy.calls.count, 0, "must never post a notification")
    }

    func test_route_globalAutoApproveOn_returnsAllowBody_withoutSubmitting() async throws {
        CockpitSettings.agentHookApprovalEnabled = true
        CockpitSettings.autoApproveEnabled = true
        let approvalInbox = ApprovalInboxStore()
        server.approvalInbox = approvalInbox
        let request = approvalRequestRequest(
            token: testToken, surfaceIDHeader: UUID().uuidString, body: validToolCallBody()
        )

        let response = await server.route(request: request)

        XCTAssertEqual(response.statusCode, 200)
        let decision = try permissionBehavior(fromResponseBody: response.body)
        XCTAssertEqual(decision, "allow",
                       "global cockpit auto-approve being on must return an ALLOW body for the default " +
                       "(claude-code) kind, without ever consulting the inbox")
        XCTAssertTrue(approvalInbox.pending.isEmpty,
                      "global cockpit auto-approve being on must never submit a request to the inbox")
    }

    // MARK: - AgentHookApprovalMemory consultation

    /// A pane-scoped Always-Allow memory hit (same surfaceID, kind,
    /// toolName as a prior "Always Allow" click) must short-circuit
    /// exactly like the global auto-approve toggle above -- 200, an
    /// ALLOW body for the resolved kind, and nothing submitted.
    func test_route_paneMemoryHit_returnsAllowBody_withoutSubmitting() async throws {
        CockpitSettings.agentHookApprovalEnabled = true
        let approvalInbox = ApprovalInboxStore()
        server.approvalInbox = approvalInbox
        let memory = AgentHookApprovalMemory()
        server.agentHookApprovalMemory = memory
        let surfaceID = UUID()
        memory.rememberPane(surfaceID: surfaceID, kind: AgentEntry.claudeCodeKind, toolName: "Bash")

        let request = approvalRequestRequest(
            token: testToken, surfaceIDHeader: surfaceID.uuidString, body: validToolCallBody()
        )

        let response = await server.route(request: request)

        XCTAssertEqual(response.statusCode, 200)
        let decision = try permissionBehavior(fromResponseBody: response.body)
        XCTAssertEqual(decision, "allow",
                       "a pane-scoped Always-Allow memory hit must return an ALLOW body immediately")
        XCTAssertTrue(approvalInbox.pending.isEmpty,
                      "a memory hit must never submit a request to the inbox")
    }

    /// A memory MISS (recorded for the same surface, but an unrelated
    /// tool) must never accidentally short-circuit -- the request must
    /// still submit and long-poll exactly like the existing pending flow.
    func test_route_memoryMiss_stillSubmitsAndLongPolls() async throws {
        CockpitSettings.agentHookApprovalEnabled = true
        let approvalInbox = ApprovalInboxStore()
        server.approvalInbox = approvalInbox
        let memory = AgentHookApprovalMemory()
        server.agentHookApprovalMemory = memory
        let surfaceID = UUID()
        memory.rememberPane(surfaceID: surfaceID, kind: AgentEntry.claudeCodeKind, toolName: "Write")
        // R4 seam: this test expects a genuine submission, so the
        // stale/unknown-surface guard must not short-circuit it.
        server.approvalSurfaceExists = { _ in true }

        let request = approvalRequestRequest(
            token: testToken, surfaceIDHeader: surfaceID.uuidString, body: validToolCallBody()
        )
        let task = Task { @MainActor in
            await self.server.route(request: request)
        }
        await yieldToScheduler()

        XCTAssertEqual(approvalInbox.pending.count, 1,
                       "a memory miss (recorded for a different tool) must still submit to the inbox and " +
                       "long-poll for a decision, same as the existing pending flow")

        let requestID = try XCTUnwrap(approvalInbox.pending.first?.id)
        approvalInbox.decide(id: requestID, .allowed)
        _ = await task.value
    }

    /// Mirrors `test_serverStop_expiresPendingHookApproval_returnsFailSafeBody`'s
    /// own rationale for `approvalInbox.expireAll()`: a stopped server
    /// must never leave a stale Always-Allow memory behind either.
    func test_serverStop_clearsAgentHookApprovalMemory() {
        let memory = AgentHookApprovalMemory()
        server.agentHookApprovalMemory = memory
        let surfaceID = UUID()
        memory.rememberPane(surfaceID: surfaceID, kind: AgentEntry.claudeCodeKind, toolName: "Bash")
        XCTAssertTrue(memory.isAutoAllowed(surfaceID: surfaceID, kind: AgentEntry.claudeCodeKind, toolName: "Bash"),
                     "precondition: the pane memory was recorded before stop()")

        server.stop()

        XCTAssertFalse(memory.isAutoAllowed(surfaceID: surfaceID, kind: AgentEntry.claudeCodeKind, toolName: "Bash"),
                       "server.stop() must clear the agent-hook approval memory, same as it drains approvalInbox")
    }

    // MARK: - Submission + decision mapping

    func test_route_pending_submitsAgentHookRequest_withSurfaceAndSummary() async throws {
        CockpitSettings.agentHookApprovalEnabled = true
        let approvalInbox = ApprovalInboxStore()
        server.approvalInbox = approvalInbox
        // R4 seam: this test expects a genuine submission, so the
        // stale/unknown-surface guard must not short-circuit it.
        server.approvalSurfaceExists = { _ in true }
        let surfaceID = UUID()
        let command = "ls -la /tmp"

        let request = approvalRequestRequest(
            token: testToken, surfaceIDHeader: surfaceID.uuidString, body: validToolCallBody(command: command)
        )
        let task = Task { @MainActor in
            await self.server.route(request: request)
        }
        await yieldToScheduler()

        XCTAssertEqual(approvalInbox.pending.count, 1,
                       "a genuine approval-required agent-hook call must submit exactly one request")
        let pendingRequest = try XCTUnwrap(approvalInbox.pending.first)
        XCTAssertEqual(pendingRequest.targetSurfaceID, surfaceID,
                       "targetSurfaceID must be the surface resolved from X-Calyx-Surface-ID")
        XCTAssertEqual(pendingRequest.payload, try compactJSON(["command": command]),
                       "payload must be AgentHookToolCall's decoded compact-JSON tool_input")

        switch pendingRequest.source {
        case .agentHook(let toolName, let kind, let summary, let offers):
            XCTAssertEqual(toolName, "Bash")
            XCTAssertEqual(kind, AgentEntry.claudeCodeKind,
                           "a missing X-Calyx-Agent-Kind header must default to claude-code, same as /agent-event")
            XCTAssertEqual(summary, command, "Bash's summary must be its tool_input.command")
            XCTAssertFalse(offers.cliOwnsPersistence,
                           "no CLI always-allow row was offered, so Calyx's own pane memory is the only " +
                           "persistence available")
        case .mcpTool:
            XCTFail("expected source .agentHook(...), got .mcpTool")
        case .agentQuestion:
            XCTFail("expected source .agentHook(...), got .agentQuestion")
        case .mcpApp:
            XCTFail("expected source .agentHook(...), got .mcpApp")
        }

        approvalInbox.decide(id: pendingRequest.id, .allowed)
        let response = await task.value

        XCTAssertEqual(response.statusCode, 200)
        let decision = try permissionBehavior(fromResponseBody: response.body)
        XCTAssertEqual(decision, "allow", "an .allowed decision must map to an ALLOW permission body")
    }

    func test_route_deny_returnsDenyBody() async throws {
        CockpitSettings.agentHookApprovalEnabled = true
        let approvalInbox = ApprovalInboxStore()
        server.approvalInbox = approvalInbox
        // R4 seam: this test expects a genuine submission, so the
        // stale/unknown-surface guard must not short-circuit it.
        server.approvalSurfaceExists = { _ in true }
        let request = approvalRequestRequest(
            token: testToken, surfaceIDHeader: UUID().uuidString, body: validToolCallBody()
        )
        let task = Task { @MainActor in
            await self.server.route(request: request)
        }
        await yieldToScheduler()

        let requestID = try XCTUnwrap(approvalInbox.pending.first?.id)
        approvalInbox.decide(id: requestID, .denied(.userRejected))
        let response = await task.value

        XCTAssertEqual(response.statusCode, 200)
        let decision = try permissionBehavior(fromResponseBody: response.body)
        XCTAssertEqual(decision, "deny", "a .denied decision must map to a DENY permission body")
    }

    // MARK: - Timeout

    func test_route_timeout_claude_returnsEmptyBody() async throws {
        CockpitSettings.agentHookApprovalEnabled = true
        server.approvalRequestTimeoutMs = 50
        let approvalInbox = ApprovalInboxStore()
        server.approvalInbox = approvalInbox
        // R4 seam: this test expects a genuine submission (which then
        // times out), so the stale/unknown-surface guard must not
        // short-circuit it.
        server.approvalSurfaceExists = { _ in true }
        let request = approvalRequestRequest(
            token: testToken, surfaceIDHeader: UUID().uuidString, body: validToolCallBody()
        )

        let response = await server.route(request: request)

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertNil(response.body,
                     "PermissionRequest has no fallback body for claude-code either -- a request that " +
                     "times out unanswered must map .expired -> an EMPTY body, never a fabricated decision")
        XCTAssertTrue(approvalInbox.pending.isEmpty, "a timed-out request must no longer be pending")
    }

    func test_route_timeout_codex_returnsEmptyBody() async {
        CockpitSettings.agentHookApprovalEnabled = true
        server.approvalRequestTimeoutMs = 50
        let approvalInbox = ApprovalInboxStore()
        server.approvalInbox = approvalInbox
        // R4 seam: this test expects a genuine submission (which then
        // times out), so the stale/unknown-surface guard must not
        // short-circuit it.
        server.approvalSurfaceExists = { _ in true }
        let request = approvalRequestRequest(
            token: testToken, surfaceIDHeader: UUID().uuidString, body: validToolCallBody(),
            kindHeader: "codex"
        )

        let response = await server.route(request: request)

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertNil(response.body,
                     "codex has no \"ask\" analog -- a timed-out codex request must map .expired -> an EMPTY body")
        XCTAssertTrue(approvalInbox.pending.isEmpty, "a timed-out request must no longer be pending")
    }

    func test_route_defaultTimeout_is570000ms() {
        let freshServer = CalyxMCPServer(agentEndpointDirectory: agentEndpointDir)

        XCTAssertEqual(freshServer.approvalRequestTimeoutMs, 570_000,
                       "the default approval-request long-poll timeout must be 570_000ms")
    }

    // MARK: - Derived timing constants

    func test_timing_constants_orderingInvariant() {
        XCTAssertEqual(ApprovalHookTiming.holdSeconds, 600)
        XCTAssertEqual(ApprovalHookTiming.serverTimeoutMs, 570_000)
        XCTAssertEqual(ApprovalHookTiming.curlTimeoutSeconds, 585)
        XCTAssertEqual(ApprovalHookTiming.hookEntryTimeoutSeconds, 600)

        XCTAssertLessThan(ApprovalHookTiming.serverTimeoutMs, ApprovalHookTiming.curlTimeoutSeconds * 1000,
                          "the server's own await timeout must resolve strictly before curl's -m deadline, " +
                          "or curl would appear to hang after the server already gave up")
        XCTAssertLessThan(ApprovalHookTiming.curlTimeoutSeconds * 1000, ApprovalHookTiming.hookEntryTimeoutSeconds * 1000,
                          "curl's own timeout must fire strictly before the hook config's own entry " +
                          "timeout, or Claude Code's hook runner would kill the process before curl " +
                          "returns the fail-safe body")
    }

    // MARK: - Cancellation

    func test_route_taskCancelledMidPoll_expiresPendingRequest() async throws {
        CockpitSettings.agentHookApprovalEnabled = true
        let approvalInbox = ApprovalInboxStore()
        server.approvalInbox = approvalInbox
        // R4 seam: this test expects a genuine submission, so the
        // stale/unknown-surface guard must not short-circuit it.
        server.approvalSurfaceExists = { _ in true }
        let request = approvalRequestRequest(
            token: testToken, surfaceIDHeader: UUID().uuidString, body: validToolCallBody()
        )

        let task = Task { @MainActor in
            await self.server.route(request: request)
        }
        await yieldToScheduler()
        XCTAssertEqual(approvalInbox.pending.count, 1,
                       "precondition: route must have submitted before we cancel its Task")

        task.cancel()
        let response = await task.value

        XCTAssertTrue(approvalInbox.pending.isEmpty,
                      "cancelling the Task running route(request:) must expire the pending request, " +
                      "removing its banner")
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertNil(response.body,
                     "a mid-poll cancellation resolves as expired, which has no fallback body under " +
                     "PermissionRequest for either CLI kind")
    }

    // MARK: - Server stop mid-poll

    func test_serverStop_expiresPendingHookApproval_returnsFailSafeBody() async throws {
        let cases: [(label: String, kindHeader: String?)] = [
            ("claude-code (default)", nil),
            ("codex", "codex"),
        ]

        for testCase in cases {
            CockpitSettings.agentHookApprovalEnabled = true
            let approvalInbox = ApprovalInboxStore()
            server.approvalInbox = approvalInbox
            // R4 seam: this test expects a genuine submission, so the
            // stale/unknown-surface guard must not short-circuit it.
            server.approvalSurfaceExists = { _ in true }
            let request = approvalRequestRequest(
                token: testToken, surfaceIDHeader: UUID().uuidString, body: validToolCallBody(),
                kindHeader: testCase.kindHeader
            )

            let task = Task { @MainActor in
                await self.server.route(request: request)
            }
            await yieldToScheduler()
            XCTAssertEqual(approvalInbox.pending.count, 1,
                           "[\(testCase.label)] precondition: route must submit before stop() drains it")

            server.stop()
            await yieldToScheduler()

            XCTAssertTrue(approvalInbox.pending.isEmpty,
                          "[\(testCase.label)] server.stop() must drain the pending hook-approval request")

            let response = await task.value
            XCTAssertEqual(response.statusCode, 200,
                           "[\(testCase.label)] the held route must still return 200 once stop() resolves it")
            XCTAssertNil(response.body,
                         "[\(testCase.label)] PermissionRequest has no fallback body for either CLI kind -- " +
                         "stop()'s fail-safe expiry must return an EMPTY body, never a fabricated decision")
        }
    }

    // MARK: - Notification on submission

    /// Mirrors `SessionReconnectGiveUpTests.GiveUpNotificationSpy`: a
    /// `NotificationManager` subclass swapped into the existing
    /// `NotificationManager.shared` DEBUG test seam to spy on
    /// `sendNotification` instead of going through
    /// `UNUserNotificationCenter` (a no-op in the test host regardless).
    /// No new seam on `CalyxMCPServer` is needed -- this existing one
    /// already lets a test observe every call `routeApprovalRequest`
    /// makes when it submits a new request.
    private final class ApprovalHookNotificationSpy: NotificationManager {
        private(set) var calls: [(title: String, body: String, tabID: UUID)] = []

        override func sendNotification(title: String, body: String, tabID: UUID) {
            calls.append((title: title, body: body, tabID: tabID))
        }
    }

    func test_route_submission_postsNotification() async throws {
        CockpitSettings.agentHookApprovalEnabled = true
        let approvalInbox = ApprovalInboxStore()
        server.approvalInbox = approvalInbox
        // R4 seam: this test expects a genuine submission, so the
        // stale/unknown-surface guard must not short-circuit it.
        server.approvalSurfaceExists = { _ in true }
        let surfaceID = UUID()

        let spy = ApprovalHookNotificationSpy()
        let originalManager = NotificationManager.shared
        NotificationManager.shared = spy
        defer { NotificationManager.shared = originalManager }

        let request = approvalRequestRequest(
            token: testToken, surfaceIDHeader: surfaceID.uuidString, body: validToolCallBody()
        )
        let task = Task { @MainActor in
            await self.server.route(request: request)
        }
        await yieldToScheduler()

        XCTAssertEqual(approvalInbox.pending.count, 1,
                       "precondition: the request must be pending before asserting on the notification it triggers")
        XCTAssertEqual(spy.calls.count, 1,
                       "submitting a new agent-hook approval request must post exactly one user notification")
        XCTAssertEqual(spy.calls.first?.tabID, surfaceID,
                       "the notification's tabID must be the resolved target surface, so acting on it can " +
                       "focus the right pane")
        XCTAssertFalse(spy.calls.first?.title.isEmpty ?? true, "the notification must carry a non-empty title")
        XCTAssertFalse(spy.calls.first?.body.isEmpty ?? true, "the notification must carry a non-empty body")

        // Drain the held route so this test doesn't leak a suspended Task.
        guard let requestID = approvalInbox.pending.first?.id else {
            task.cancel()
            _ = await task.value
            return
        }
        approvalInbox.decide(id: requestID, .allowed)
        _ = await task.value
    }

    /// R3 fix-pin: the notification `routeApprovalRequest` posts on
    /// submission embeds `call.summary` verbatim into its `body` -- must
    /// never leak a raw secret token through that string. `SecretRedactor`
    /// already exists and runs before text ever reaches `CommandLogStore`
    /// (see that type's own header comment); this pins that the SAME
    /// redaction must also apply at THIS notification call site.
    ///
    /// Scoping note (deliberately NOT pinned here): whether
    /// `AgentHookToolCall.decode` itself should redact -- baking it into
    /// every `summary`/`payload` everywhere, including the banner -- or
    /// only this one notification call site, is a separate design
    /// question this test does not settle. The approval banner must keep
    /// showing the tool call the human is being asked to approve
    /// VERBATIM (ControlCharacterDisplay already handles a different
    /// concern there -- terminal-control-character spoofing, not secret
    /// leakage), so this test deliberately scopes the fix to
    /// `NotificationManager.shared.sendNotification`'s `body` only.
    ///
    /// The token is composed at runtime from two non-secret-shaped
    /// halves (mirrors SecretRedactorTests' own convention) so no
    /// contiguous secret-format literal appears in this tracked file.
    func test_route_submission_notificationBody_redactsSecretToken() async throws {
        CockpitSettings.agentHookApprovalEnabled = true
        let approvalInbox = ApprovalInboxStore()
        server.approvalInbox = approvalInbox
        // R4 seam: this test expects a genuine submission, so the
        // stale/unknown-surface guard must not short-circuit it.
        server.approvalSurfaceExists = { _ in true }
        let surfaceID = UUID()

        let spy = ApprovalHookNotificationSpy()
        let originalManager = NotificationManager.shared
        NotificationManager.shared = spy
        defer { NotificationManager.shared = originalManager }

        // No embedded double quotes: `validToolCallBody` interpolates
        // `command` directly into a JSON string literal without
        // escaping, so a literal `"` here would corrupt the JSON body
        // and make AgentHookToolCall.decode reject it as malformed --
        // an unrelated false failure this fixture must avoid.
        let secretToken = "ghp_" + String(repeating: "a", count: 36)
        let command = "curl -H Authorization: Bearer \(secretToken) https://example.com"
        let request = approvalRequestRequest(
            token: testToken, surfaceIDHeader: surfaceID.uuidString, body: validToolCallBody(command: command)
        )
        let task = Task { @MainActor in
            await self.server.route(request: request)
        }
        await yieldToScheduler()

        XCTAssertEqual(approvalInbox.pending.count, 1,
                       "precondition: the request must be pending before asserting on the notification it triggers")
        XCTAssertEqual(spy.calls.count, 1)
        let body = try XCTUnwrap(spy.calls.first?.body)
        XCTAssertFalse(body.contains(secretToken), "the notification body must never contain the raw secret token")
        XCTAssertTrue(body.contains(SecretRedactor.marker),
                      "the notification body must contain SecretRedactor's own redaction marker in the " +
                      "token's place")

        guard let requestID = approvalInbox.pending.first?.id else {
            task.cancel()
            _ = await task.value
            return
        }
        approvalInbox.decide(id: requestID, .allowed)
        _ = await task.value
    }

    // MARK: - AskUserQuestion (.agentQuestion source)
    //
    // Claude Code's AskUserQuestion tool is recognized only for the
    // claude-code kind and answered through .agentQuestion, a source
    // distinct from the generic .agentHook banner every other tool call
    // uses. Every earlier short-circuit guard (kind allow-list,
    // hook-event-name gate, agentHookApprovalEnabled toggle,
    // approvalSurfaceExists) still applies unchanged; global
    // auto-approve and pane-scoped Always-Allow memory must NOT
    // short-circuit a question -- a human must always be asked.

    private func askUserQuestionBody(
        questionText: String = "Which shell?", hookEventName: String? = "PermissionRequest"
    ) -> Data {
        let hookEventNameField = hookEventName.map { ",\"hook_event_name\":\"\($0)\"" } ?? ""
        return Data("""
        {"tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"\(questionText)","options":[{"label":"zsh"},{"label":"bash"}]}]}\(hookEventNameField)}
        """.utf8)
    }

    func test_route_askUserQuestion_submitsAgentQuestionSource() async throws {
        CockpitSettings.agentHookApprovalEnabled = true
        let approvalInbox = ApprovalInboxStore()
        server.approvalInbox = approvalInbox
        server.approvalSurfaceExists = { _ in true }
        let surfaceID = UUID()

        let request = approvalRequestRequest(
            token: testToken, surfaceIDHeader: surfaceID.uuidString, body: askUserQuestionBody()
        )
        let task = Task { @MainActor in
            await self.server.route(request: request)
        }
        await yieldToScheduler()

        XCTAssertEqual(approvalInbox.pending.count, 1)
        let pendingRequest = try XCTUnwrap(approvalInbox.pending.first)
        XCTAssertEqual(pendingRequest.targetSurfaceID, surfaceID)

        switch pendingRequest.source {
        case .agentQuestion(let kind, let prompt):
            XCTAssertEqual(kind, AgentEntry.claudeCodeKind)
            XCTAssertEqual(prompt.questions.first?.text, "Which shell?")
        case .agentHook, .mcpTool, .mcpApp:
            XCTFail("expected source .agentQuestion(...)")
        }

        approvalInbox.decide(id: pendingRequest.id, .expired)
        _ = await task.value
    }

    func test_route_askUserQuestion_ignoresGlobalAutoApprove_stillSubmits() async throws {
        CockpitSettings.agentHookApprovalEnabled = true
        CockpitSettings.autoApproveEnabled = true
        let approvalInbox = ApprovalInboxStore()
        server.approvalInbox = approvalInbox
        server.approvalSurfaceExists = { _ in true }

        let request = approvalRequestRequest(
            token: testToken, surfaceIDHeader: UUID().uuidString, body: askUserQuestionBody()
        )
        let task = Task { @MainActor in
            await self.server.route(request: request)
        }
        await yieldToScheduler()

        XCTAssertEqual(approvalInbox.pending.count, 1,
                       "an AskUserQuestion call must always ask a human, even with global auto-approve on")

        approvalInbox.decide(id: try XCTUnwrap(approvalInbox.pending.first?.id), .expired)
        _ = await task.value
    }

    func test_route_askUserQuestion_ignoresPaneMemory_stillSubmits() async throws {
        CockpitSettings.agentHookApprovalEnabled = true
        let approvalInbox = ApprovalInboxStore()
        server.approvalInbox = approvalInbox
        server.approvalSurfaceExists = { _ in true }
        let memory = AgentHookApprovalMemory()
        server.agentHookApprovalMemory = memory
        let surfaceID = UUID()
        memory.rememberPane(surfaceID: surfaceID, kind: AgentEntry.claudeCodeKind, toolName: "AskUserQuestion")

        let request = approvalRequestRequest(
            token: testToken, surfaceIDHeader: surfaceID.uuidString, body: askUserQuestionBody()
        )
        let task = Task { @MainActor in
            await self.server.route(request: request)
        }
        await yieldToScheduler()

        XCTAssertEqual(approvalInbox.pending.count, 1,
                       "a pane-scoped Always-Allow memory hit for AskUserQuestion must never short-circuit a question")

        approvalInbox.decide(id: try XCTUnwrap(approvalInbox.pending.first?.id), .expired)
        _ = await task.value
    }

    func test_route_askUserQuestion_unknownSurface_returns200EmptyBody_submitsNothing() async throws {
        CockpitSettings.agentHookApprovalEnabled = true
        let approvalInbox = ApprovalInboxStore()
        server.approvalInbox = approvalInbox
        server.approvalSurfaceExists = { _ in false }

        let request = approvalRequestRequest(
            token: testToken, surfaceIDHeader: UUID().uuidString, body: askUserQuestionBody()
        )

        let response = await server.route(request: request)

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertNil(response.body)
        XCTAssertTrue(approvalInbox.pending.isEmpty,
                      "an AskUserQuestion call targeting a surface unknown to the registry must never submit, " +
                      "same guard as every other agent-hook call")
    }

    /// The toggle short-circuit applies to a question body exactly as it
    /// does to any other agent-hook body: 200, an EMPTY body, nothing
    /// submitted.
    func test_route_askUserQuestion_toggleOff_returns200EmptyBody_submitsNothing() async throws {
        CockpitSettings.agentHookApprovalEnabled = false
        let approvalInbox = ApprovalInboxStore()
        server.approvalInbox = approvalInbox

        let request = approvalRequestRequest(
            token: testToken, surfaceIDHeader: UUID().uuidString, body: askUserQuestionBody()
        )

        let response = await server.route(request: request)

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertNil(response.body)
        XCTAssertTrue(approvalInbox.pending.isEmpty,
                      "agentHookApprovalEnabled being off must short-circuit a question body too, submitting nothing")
    }

    /// An AskUserQuestion body whose `questions` decodes zero usable
    /// questions (no `question` text at all) still submits -- as the
    /// generic `.agentHook` source, gated on `isQuestionTool`, never
    /// auto-allowed by global auto-approve even though it's on.
    func test_route_askUserQuestion_undecodableQuestionText_globalAutoApproveOn_submitsAsAgentHook() async throws {
        CockpitSettings.agentHookApprovalEnabled = true
        CockpitSettings.autoApproveEnabled = true
        let approvalInbox = ApprovalInboxStore()
        server.approvalInbox = approvalInbox
        server.approvalSurfaceExists = { _ in true }

        let undecodableBody = Data("""
        {"tool_name":"AskUserQuestion","tool_input":{"questions":[{"options":[{"label":"zsh"}]}]},"hook_event_name":"PermissionRequest"}
        """.utf8)
        let request = approvalRequestRequest(
            token: testToken, surfaceIDHeader: UUID().uuidString, body: undecodableBody
        )
        let task = Task { @MainActor in
            await self.server.route(request: request)
        }
        await yieldToScheduler()

        XCTAssertEqual(approvalInbox.pending.count, 1,
                       "an AskUserQuestion body with no decodable question text must still submit, never be " +
                       "auto-allowed even with global auto-approve on")
        let pendingRequest = try XCTUnwrap(approvalInbox.pending.first)
        switch pendingRequest.source {
        case .agentHook(let toolName, let kind, _, _):
            XCTAssertEqual(toolName, "AskUserQuestion")
            XCTAssertEqual(kind, AgentEntry.claudeCodeKind)
        case .agentQuestion, .mcpTool, .mcpApp:
            XCTFail("a decode failure must fall back to the generic .agentHook source, never .agentQuestion")
        }

        approvalInbox.decide(id: pendingRequest.id, .denied(.userRejected))
        _ = await task.value
    }

    func test_route_askUserQuestion_answeredDecision_returnsExpectedBody() async throws {
        CockpitSettings.agentHookApprovalEnabled = true
        let approvalInbox = ApprovalInboxStore()
        server.approvalInbox = approvalInbox
        server.approvalSurfaceExists = { _ in true }

        let request = approvalRequestRequest(
            token: testToken, surfaceIDHeader: UUID().uuidString, body: askUserQuestionBody()
        )
        let task = Task { @MainActor in
            await self.server.route(request: request)
        }
        await yieldToScheduler()

        let pendingRequest = try XCTUnwrap(approvalInbox.pending.first)
        guard case .agentQuestion(_, let prompt) = pendingRequest.source else {
            XCTFail("expected .agentQuestion source")
            task.cancel()
            _ = await task.value
            return
        }
        let answers = AgentQuestionAnswers(prompt: prompt, entries: [.init(answer: .selectedOne("zsh"), notes: nil)])
        approvalInbox.decide(id: pendingRequest.id, .answered(answers))
        let response = await task.value

        XCTAssertEqual(response.statusCode, 200)
        let expectedBody = AgentHookPermissionResponse.body(kind: AgentEntry.claudeCodeKind, decision: .answered(answers))
        XCTAssertEqual(
            try responseJSON(response.body) as NSDictionary, try responseJSON(expectedBody) as NSDictionary,
            "route's .answered response body must equal AgentHookPermissionResponse.body(kind:decision:) exactly"
        )
    }

    func test_route_askUserQuestion_expiredDecision_returnsEmptyBody() async throws {
        CockpitSettings.agentHookApprovalEnabled = true
        let approvalInbox = ApprovalInboxStore()
        server.approvalInbox = approvalInbox
        server.approvalSurfaceExists = { _ in true }

        let request = approvalRequestRequest(
            token: testToken, surfaceIDHeader: UUID().uuidString, body: askUserQuestionBody()
        )
        let task = Task { @MainActor in
            await self.server.route(request: request)
        }
        await yieldToScheduler()

        approvalInbox.decide(id: try XCTUnwrap(approvalInbox.pending.first?.id), .expired)
        let response = await task.value

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertNil(response.body, "an expired AskUserQuestion decision must return an EMPTY body, same as any other claude-code expiry")
    }

    func test_route_askUserQuestion_timeout_returnsEmptyBody() async throws {
        CockpitSettings.agentHookApprovalEnabled = true
        server.approvalRequestTimeoutMs = 50
        let approvalInbox = ApprovalInboxStore()
        server.approvalInbox = approvalInbox
        server.approvalSurfaceExists = { _ in true }

        let request = approvalRequestRequest(
            token: testToken, surfaceIDHeader: UUID().uuidString, body: askUserQuestionBody()
        )

        let response = await server.route(request: request)

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertNil(response.body, "a timed-out AskUserQuestion request must return an EMPTY body")
        XCTAssertTrue(approvalInbox.pending.isEmpty)
    }

    func test_route_askUserQuestion_notification_titleAndRedactedBody() async throws {
        CockpitSettings.agentHookApprovalEnabled = true
        let approvalInbox = ApprovalInboxStore()
        server.approvalInbox = approvalInbox
        server.approvalSurfaceExists = { _ in true }

        let spy = ApprovalHookNotificationSpy()
        let originalManager = NotificationManager.shared
        NotificationManager.shared = spy
        defer { NotificationManager.shared = originalManager }

        // Composed at runtime from non-secret-shaped halves, mirroring
        // test_route_submission_notificationBody_redactsSecretToken --
        // no contiguous secret-format literal appears in this tracked file.
        let secretToken = "AIza" + String(repeating: "A", count: 35)
        let questionText = "Should I use the \(secretToken) API key?"
        let request = approvalRequestRequest(
            token: testToken, surfaceIDHeader: UUID().uuidString,
            body: askUserQuestionBody(questionText: questionText)
        )
        let task = Task { @MainActor in
            await self.server.route(request: request)
        }
        await yieldToScheduler()

        XCTAssertEqual(spy.calls.count, 1)
        XCTAssertEqual(spy.calls.first?.title, "\(AgentEntry.displayName(forKind: AgentEntry.claudeCodeKind)) asks a question")
        let body = try XCTUnwrap(spy.calls.first?.body)
        XCTAssertFalse(body.contains(secretToken), "the notification body must never contain the raw secret token")
        XCTAssertTrue(body.contains(SecretRedactor.marker),
                      "the notification body must contain SecretRedactor's own redaction marker in the token's place")

        guard let requestID = approvalInbox.pending.first?.id else {
            task.cancel()
            _ = await task.value
            return
        }
        approvalInbox.decide(id: requestID, .expired)
        _ = await task.value
    }

    /// A codex-kind body shaped exactly like an AskUserQuestion call
    /// (same `tool_name`/`tool_input.questions` shape) must still go the
    /// generic `.agentHook` route -- the question is recognized ONLY for
    /// the claude-code kind.
    func test_route_askUserQuestionShapedBody_codexKind_staysAgentHookSource() async throws {
        CockpitSettings.agentHookApprovalEnabled = true
        let approvalInbox = ApprovalInboxStore()
        server.approvalInbox = approvalInbox
        server.approvalSurfaceExists = { _ in true }

        let request = approvalRequestRequest(
            token: testToken, surfaceIDHeader: UUID().uuidString, body: askUserQuestionBody(),
            kindHeader: "codex"
        )
        let task = Task { @MainActor in
            await self.server.route(request: request)
        }
        await yieldToScheduler()

        let pendingRequest = try XCTUnwrap(approvalInbox.pending.first)
        switch pendingRequest.source {
        case .agentHook(let toolName, let kind, _, let offers):
            XCTAssertEqual(toolName, "AskUserQuestion")
            XCTAssertEqual(kind, AgentEntry.codexKind)
            XCTAssertEqual(offers.permissionUpdates, [], "codex must never carry permission updates")
            XCTAssertFalse(offers.cliOwnsPersistence)
        case .agentQuestion, .mcpTool, .mcpApp:
            XCTFail("a codex-kind AskUserQuestion-shaped body must never be recognized as a question -- " +
                    "only claude-code decodes it")
        }

        approvalInbox.decide(id: pendingRequest.id, .denied(.userRejected))
        _ = await task.value
    }

    // MARK: - permission_suggestions -> offers.permissionUpdates

    /// A claude-code Bash body carrying `permission_suggestions` and a
    /// `command` string must submit as `.agentHook` whose `offers` carry
    /// one permission update with the expected label, and
    /// `cliOwnsPersistence` true.
    func test_route_claudeCodeBashWithPermissionSuggestions_offersCarryOneUpdate_cliOwnsPersistence() async throws {
        CockpitSettings.agentHookApprovalEnabled = true
        let approvalInbox = ApprovalInboxStore()
        server.approvalInbox = approvalInbox
        server.approvalSurfaceExists = { _ in true }

        let body = Data("""
        {"tool_name":"Bash","tool_input":{"command":"rm -rf node_modules"},"permission_suggestions":[\
        {"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"rm -rf node_modules"}],"behavior":"allow","destination":"localSettings"}\
        ],"hook_event_name":"PermissionRequest"}
        """.utf8)
        let request = approvalRequestRequest(token: testToken, surfaceIDHeader: UUID().uuidString, body: body)
        let task = Task { @MainActor in
            await self.server.route(request: request)
        }
        await yieldToScheduler()

        let pendingRequest = try XCTUnwrap(approvalInbox.pending.first)
        guard case .agentHook(_, _, _, let offers) = pendingRequest.source else {
            XCTFail("expected .agentHook source")
            approvalInbox.decide(id: pendingRequest.id, .denied(.userRejected))
            _ = await task.value
            return
        }
        XCTAssertEqual(offers.permissionUpdates.count, 1)
        XCTAssertEqual(offers.permissionUpdates.first?.label,
                       "Yes, and don't ask again for Bash: rm -rf node_modules from this project")
        XCTAssertTrue(offers.cliOwnsPersistence)

        approvalInbox.decide(id: pendingRequest.id, .denied(.userRejected))
        _ = await task.value
    }

    /// `permission_suggestions` present at the top level but carrying only
    /// an entry with nothing to offer (an `addRules` with an empty `rules`
    /// array) must decode zero permission updates, so claude-code falls
    /// back to Calyx's own pane-scoped Always-Allow row.
    func test_route_claudeCodeBashWithOnlyUnusableSuggestions_cliOwnsPersistenceFalse() async throws {
        CockpitSettings.agentHookApprovalEnabled = true
        let approvalInbox = ApprovalInboxStore()
        server.approvalInbox = approvalInbox
        server.approvalSurfaceExists = { _ in true }

        let body = Data("""
        {"tool_name":"Bash","tool_input":{"command":"rm -rf node_modules"},"permission_suggestions":[\
        {"type":"addRules","rules":[],"behavior":"allow"}\
        ],"hook_event_name":"PermissionRequest"}
        """.utf8)
        let request = approvalRequestRequest(token: testToken, surfaceIDHeader: UUID().uuidString, body: body)
        let task = Task { @MainActor in
            await self.server.route(request: request)
        }
        await yieldToScheduler()

        let pendingRequest = try XCTUnwrap(approvalInbox.pending.first)
        guard case .agentHook(_, _, _, let offers) = pendingRequest.source else {
            XCTFail("expected .agentHook source")
            approvalInbox.decide(id: pendingRequest.id, .denied(.userRejected))
            _ = await task.value
            return
        }
        XCTAssertEqual(offers.permissionUpdates, [])
        XCTAssertFalse(offers.cliOwnsPersistence,
                       "the only suggestion decoded to nothing, so no CLI always-allow row was offered")

        approvalInbox.decide(id: pendingRequest.id, .denied(.userRejected))
        _ = await task.value
    }

    func test_route_codexBashWithPermissionSuggestions_offersAreNoneLikeEmpty() async throws {
        CockpitSettings.agentHookApprovalEnabled = true
        let approvalInbox = ApprovalInboxStore()
        server.approvalInbox = approvalInbox
        server.approvalSurfaceExists = { _ in true }

        let body = Data("""
        {"tool_name":"Bash","tool_input":{"command":"rm -rf node_modules"},"permission_suggestions":[\
        {"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"rm -rf node_modules"}],"behavior":"allow","destination":"localSettings"}\
        ],"hook_event_name":"PermissionRequest"}
        """.utf8)
        let request = approvalRequestRequest(
            token: testToken, surfaceIDHeader: UUID().uuidString, body: body, kindHeader: "codex"
        )
        let task = Task { @MainActor in
            await self.server.route(request: request)
        }
        await yieldToScheduler()

        let pendingRequest = try XCTUnwrap(approvalInbox.pending.first)
        guard case .agentHook(_, _, _, let offers) = pendingRequest.source else {
            XCTFail("expected .agentHook source")
            approvalInbox.decide(id: pendingRequest.id, .denied(.userRejected))
            _ = await task.value
            return
        }
        XCTAssertEqual(offers.permissionUpdates, [], "codex never accepts permission updates")
        XCTAssertFalse(offers.cliOwnsPersistence)

        approvalInbox.decide(id: pendingRequest.id, .denied(.userRejected))
        _ = await task.value
    }

    // MARK: - deciding .allowedWithPermissions / .interrupted

    func test_route_allowedWithPermissionsDecision_returnsEncoderBody() async throws {
        CockpitSettings.agentHookApprovalEnabled = true
        let approvalInbox = ApprovalInboxStore()
        server.approvalInbox = approvalInbox
        server.approvalSurfaceExists = { _ in true }

        let request = approvalRequestRequest(
            token: testToken, surfaceIDHeader: UUID().uuidString, body: validToolCallBody()
        )
        let task = Task { @MainActor in
            await self.server.route(request: request)
        }
        await yieldToScheduler()

        let pendingRequest = try XCTUnwrap(approvalInbox.pending.first)
        let offer = AgentPermissionOffer(
            label: "Yes, and always allow access to /tmp",
            entryJSON: try JSONSerialization.data(withJSONObject: ["type": "addDirectories", "directories": ["/tmp"]])
        )
        let expectedBody = try XCTUnwrap(
            AgentHookPermissionResponse.body(kind: AgentEntry.claudeCodeKind, decision: .allowedWithPermissions(offer))
        )

        approvalInbox.decide(id: pendingRequest.id, .allowedWithPermissions(offer))
        let response = await task.value

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(
            try responseJSON(response.body) as NSDictionary, try responseJSON(expectedBody) as NSDictionary,
            "route's .allowedWithPermissions response body must equal AgentHookPermissionResponse.body(kind:decision:) exactly"
        )
    }

    func test_route_interruptedChatAboutQuestionDecision_returnsEncoderBody() async throws {
        CockpitSettings.agentHookApprovalEnabled = true
        let approvalInbox = ApprovalInboxStore()
        server.approvalInbox = approvalInbox
        server.approvalSurfaceExists = { _ in true }

        let request = approvalRequestRequest(
            token: testToken, surfaceIDHeader: UUID().uuidString, body: validToolCallBody()
        )
        let task = Task { @MainActor in
            await self.server.route(request: request)
        }
        await yieldToScheduler()

        let pendingRequest = try XCTUnwrap(approvalInbox.pending.first)
        let expectedBody = try XCTUnwrap(
            AgentHookPermissionResponse.body(kind: AgentEntry.claudeCodeKind, decision: .interrupted(.chatAboutQuestion))
        )

        approvalInbox.decide(id: pendingRequest.id, .interrupted(.chatAboutQuestion))
        let response = await task.value

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(
            try responseJSON(response.body) as NSDictionary, try responseJSON(expectedBody) as NSDictionary,
            "route's .interrupted response body must equal AgentHookPermissionResponse.body(kind:decision:) exactly"
        )
    }
}
