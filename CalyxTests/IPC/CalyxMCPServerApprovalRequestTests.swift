//
//  CalyxMCPServerApprovalRequestTests.swift
//  CalyxTests
//
//  TDD Red Phase for Stage B of the approval-inbox-for-CLI-agents
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
//  - Unknown X-Calyx-Agent-Kind and the agentHookApprovalEnabled toggle
//    being off each short-circuit to 200 with an EMPTY body and submit
//    nothing to the inbox
//  - Global auto-approve short-circuits to 200 with an allow body,
//    without submitting
//  - Stage E: an AgentHookApprovalMemory hit (pane OR cross scope)
//    short-circuits to 200 with an allow body, without submitting --
//    checked after the global auto-approve short-circuit and before
//    submit; a miss still submits and long-polls as before. server.stop()
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

    /// Test-isolated `agent-endpoint.json` directory -- same rationale as
    /// CalyxMCPServerAgentEventTests: this suite never calls `start()`,
    /// but `tearDown`'s `server.stop()` still calls
    /// `AgentEndpointFile.remove(directory:)`.
    private var agentEndpointDir: String!

    // MARK: - Lifecycle

    override func setUp() {
        super.setUp()
        CockpitSettings._testUseSuite(named: settingsSuiteName)
        agentEndpointDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).path
        server = CalyxMCPServer()
        server.agentEndpointDirectory = agentEndpointDir
        server.agentRegistry = AgentRegistry()
        server.approvalInbox = ApprovalInboxStore()
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

    private func validToolCallBody(command: String = "ls -la /tmp") -> Data {
        Data("""
        {"tool_name":"Bash","tool_input":{"command":"\(command)"}}
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

    private func permissionDecision(fromResponseBody body: Data?) throws -> String {
        let json = try responseJSON(body)
        let hookSpecificOutput = try XCTUnwrap(json["hookSpecificOutput"] as? [String: Any])
        return try XCTUnwrap(hookSpecificOutput["permissionDecision"] as? String)
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
        let decision = try permissionDecision(fromResponseBody: response.body)
        XCTAssertEqual(decision, "allow",
                       "global cockpit auto-approve being on must return an ALLOW body for the default " +
                       "(claude-code) kind, without ever consulting the inbox")
        XCTAssertTrue(approvalInbox.pending.isEmpty,
                      "global cockpit auto-approve being on must never submit a request to the inbox")
    }

    // MARK: - Stage E: AgentHookApprovalMemory consultation

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
        let decision = try permissionDecision(fromResponseBody: response.body)
        XCTAssertEqual(decision, "allow",
                       "a pane-scoped Always-Allow memory hit must return an ALLOW body immediately")
        XCTAssertTrue(approvalInbox.pending.isEmpty,
                      "a memory hit must never submit a request to the inbox")
    }

    /// A cross-scoped Always-Allow memory hit (same kind+toolName,
    /// regardless of surface) must short-circuit the same way, even for
    /// a surfaceID that memory has never seen before.
    func test_route_crossMemoryHit_returnsAllowBody_withoutSubmitting() async throws {
        CockpitSettings.agentHookApprovalEnabled = true
        let approvalInbox = ApprovalInboxStore()
        server.approvalInbox = approvalInbox
        let memory = AgentHookApprovalMemory()
        server.agentHookApprovalMemory = memory
        memory.rememberCross(kind: AgentEntry.claudeCodeKind, toolName: "Bash")

        let request = approvalRequestRequest(
            token: testToken, surfaceIDHeader: UUID().uuidString, body: validToolCallBody()
        )

        let response = await server.route(request: request)

        XCTAssertEqual(response.statusCode, 200)
        let decision = try permissionDecision(fromResponseBody: response.body)
        XCTAssertEqual(decision, "allow",
                       "a cross-scoped Always-Allow memory hit must return an ALLOW body immediately, " +
                       "regardless of which surface the request targets")
        XCTAssertTrue(approvalInbox.pending.isEmpty,
                      "a memory hit must never submit a request to the inbox")
    }

    /// A memory MISS (recorded only for an unrelated tool) must never
    /// accidentally short-circuit -- the request must still submit and
    /// long-poll exactly like the existing pending flow.
    func test_route_memoryMiss_stillSubmitsAndLongPolls() async throws {
        CockpitSettings.agentHookApprovalEnabled = true
        let approvalInbox = ApprovalInboxStore()
        server.approvalInbox = approvalInbox
        let memory = AgentHookApprovalMemory()
        server.agentHookApprovalMemory = memory
        memory.rememberCross(kind: AgentEntry.claudeCodeKind, toolName: "Write")

        let request = approvalRequestRequest(
            token: testToken, surfaceIDHeader: UUID().uuidString, body: validToolCallBody()
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
        case .agentHook(let toolName, let kind, let summary):
            XCTAssertEqual(toolName, "Bash")
            XCTAssertEqual(kind, AgentEntry.claudeCodeKind,
                           "a missing X-Calyx-Agent-Kind header must default to claude-code, same as /agent-event")
            XCTAssertEqual(summary, command, "Bash's summary must be its tool_input.command")
        case .mcpTool:
            XCTFail("expected source .agentHook(...), got .mcpTool")
        }

        approvalInbox.decide(id: pendingRequest.id, .allowed)
        let response = await task.value

        XCTAssertEqual(response.statusCode, 200)
        let decision = try permissionDecision(fromResponseBody: response.body)
        XCTAssertEqual(decision, "allow", "an .allowed decision must map to an ALLOW permission body")
    }

    func test_route_deny_returnsDenyBody() async throws {
        CockpitSettings.agentHookApprovalEnabled = true
        let approvalInbox = ApprovalInboxStore()
        server.approvalInbox = approvalInbox
        let request = approvalRequestRequest(
            token: testToken, surfaceIDHeader: UUID().uuidString, body: validToolCallBody()
        )
        let task = Task { @MainActor in
            await self.server.route(request: request)
        }
        await yieldToScheduler()

        let requestID = try XCTUnwrap(approvalInbox.pending.first?.id)
        approvalInbox.decide(id: requestID, .denied)
        let response = await task.value

        XCTAssertEqual(response.statusCode, 200)
        let decision = try permissionDecision(fromResponseBody: response.body)
        XCTAssertEqual(decision, "deny", "a .denied decision must map to a DENY permission body")
    }

    // MARK: - Timeout

    func test_route_timeout_claude_returnsAskBody() async throws {
        CockpitSettings.agentHookApprovalEnabled = true
        server.approvalRequestTimeoutMs = 50
        let approvalInbox = ApprovalInboxStore()
        server.approvalInbox = approvalInbox
        let request = approvalRequestRequest(
            token: testToken, surfaceIDHeader: UUID().uuidString, body: validToolCallBody()
        )

        let response = await server.route(request: request)

        XCTAssertEqual(response.statusCode, 200)
        let decision = try permissionDecision(fromResponseBody: response.body)
        XCTAssertEqual(decision, "ask",
                       "a claude-code request that times out unanswered must map .expired -> \"ask\"")
        XCTAssertTrue(approvalInbox.pending.isEmpty, "a timed-out request must no longer be pending")
    }

    func test_route_timeout_codex_returnsEmptyBody() async {
        CockpitSettings.agentHookApprovalEnabled = true
        server.approvalRequestTimeoutMs = 50
        let approvalInbox = ApprovalInboxStore()
        server.approvalInbox = approvalInbox
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
        let freshServer = CalyxMCPServer()

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
        let decision = try permissionDecision(fromResponseBody: response.body)
        XCTAssertEqual(decision, "ask",
                       "a mid-poll cancellation resolves as expired, mapped to \"ask\" for the default claude-code kind")
    }

    // MARK: - Server stop mid-poll

    func test_serverStop_expiresPendingHookApproval_returnsFailSafeBody() async throws {
        let cases: [(label: String, kindHeader: String?, expectedDecision: String?)] = [
            ("claude-code (default)", nil, "ask"),
            ("codex", "codex", nil),
        ]

        for testCase in cases {
            CockpitSettings.agentHookApprovalEnabled = true
            let approvalInbox = ApprovalInboxStore()
            server.approvalInbox = approvalInbox
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
            if let expectedDecision = testCase.expectedDecision {
                let decision = try permissionDecision(fromResponseBody: response.body)
                XCTAssertEqual(decision, expectedDecision, "[\(testCase.label)]")
            } else {
                XCTAssertNil(response.body,
                             "[\(testCase.label)] codex has no \"ask\" analog -- stop()'s fail-safe expiry " +
                             "must return an EMPTY body, not a decision JSON")
            }
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
}
