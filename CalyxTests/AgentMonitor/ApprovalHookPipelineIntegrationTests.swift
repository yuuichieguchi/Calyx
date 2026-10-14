//
//  ApprovalHookPipelineIntegrationTests.swift
//  CalyxTests
//
//  Stage D — mock-less, end-to-end coverage for the full
//  calyx-approval-hook pipeline: the real INSTALLED script, run as a
//  real child `/bin/sh` process, POSTing into a real `CalyxMCPServer`
//  bound to a real loopback `NWListener`, with the child's own STDOUT
//  bytes asserted directly. Mirrors AgentHookPipelineIntegrationTests'
//  harness (temp HOME, real bound port, isolated agentEndpointDirectory,
//  CockpitSettings._testUseSuite isolation from
//  CalyxMCPServerApprovalRequestTests) plus one addition that harness
//  didn't need: `/approval-request` is a long-poll, so the script's
//  `curl` call blocks until a human decides (or the server's own
//  timeout fires) -- `runHookScript` therefore runs the child process
//  on a detached background Task, so the awaiting test method can
//  concurrently poll the injected `ApprovalInboxStore` and call
//  `decide(id:_:)` while the script is still blocked reading its
//  response, exactly like a real PermissionRequest hook invocation
//  blocking on a real human's decision.
//
//  Every individual layer already has passing coverage elsewhere in
//  this test target: `ApprovalHookScriptTests` covers scriptBody's exact
//  string contract, `CalyxMCPServerApprovalRequestTests` drives
//  `routeApprovalRequest` directly via `route(request:)`. This file
//  exists because that layered coverage can't catch a real installation
//  or wiring defect (e.g. the script never actually being installed
//  where a CLI's hook can invoke it, or a header/body mismatch between
//  what curl actually sends and what the server actually parses) --
//  see AgentHookPipelineIntegrationTests' own header comment for the
//  fuller rationale, which applies identically here.
//
//  Coverage: allow/deny decisions print the exact permission JSON for
//  both claude-code (default) and codex kinds; the agentHookApprovalEnabled
//  toggle being off prints nothing and never submits; an unanswered
//  request times out to nothing for both claude-code and codex (neither
//  has an "ask" analog under PermissionRequest); a stale
//  agent-endpoint.json pointing at a closed port is silent (curl exit 7);
//  and CALYX_SURFACE_ID/CALYX_SESSION_ID both unset never even attempts
//  the POST. Every case asserts exit 0 -- the hook script must never
//  break its caller's hook chain. R5: SIGKILLing the script's own curl
//  child mid-poll (a real process-tree kill, not a simulated
//  cancellation) must clear the pending request promptly, well before
//  the server's own approval-request timeout, and the script must still
//  exit 0.
//
//  Spec C.4 additions (slice 2): a fake responder on the endpoint port
//  answering an unsigned allow prints nothing (claude-code and grok); an
//  endpoint file with another key's blocks prints nothing while the
//  server still consumes the decision; a correctly signed answer over the
//  cap prints nothing (curl's --max-filesize).
//

import XCTest
import Darwin
@testable import Calyx

/// A PermissionRequest hook stdin JSON (`Bash` / `tool_input.command:
/// "ls"`), shared by every test below. `hook_event_name` must be exactly
/// `"PermissionRequest"` -- `routeApprovalRequest`'s own gate (see
/// `CalyxMCPServer.swift`) short-circuits any other value (including a
/// missing key) to an inert 200 with an empty body, submitting nothing,
/// so a fixture missing this key would silently defeat every test below
/// that expects a real pending request or a real decision body. File-scope
/// (not a class property) so referencing it from inside an `async let`
/// initializer never needs to send this file's `@MainActor`-isolated,
/// non-Sendable `XCTestCase` instance itself just to read an otherwise-
/// constant string.
private let bashLsStdin = """
{"tool_name":"Bash","tool_input":{"command":"ls"},"hook_event_name":"PermissionRequest"}
"""

@MainActor
final class ApprovalHookPipelineIntegrationTests: XCTestCase {

    // MARK: - Properties

    private var server: CalyxMCPServer!
    private var approvalInbox: ApprovalInboxStore!
    private var tempHome: String!
    private var appSupportDir: String!
    private var scriptPath: String!
    private let testToken = "approval-hook-pipeline-test-token"
    private let settingsSuiteName = "com.calyx.tests.ApprovalHookPipelineIntegrationTests"

    // MARK: - Lifecycle

    override func setUp() async throws {
        try await super.setUp()
        CockpitSettings._testUseSuite(named: settingsSuiteName)

        tempHome = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).path
        appSupportDir = tempHome + "/Library/Application Support/Calyx"
        try FileManager.default.createDirectory(atPath: appSupportDir, withIntermediateDirectories: true)

        approvalInbox = ApprovalInboxStore()
        server = CalyxMCPServer(agentEndpointDirectory: appSupportDir)
        server.agentRegistry = AgentRegistry()
        server.approvalInbox = approvalInbox
        // R6 test hygiene: isolate Always-Allow memory from the shared
        // singleton, same rationale as `approvalInbox` above.
        server.agentHookApprovalMemory = AgentHookApprovalMemory()
        // R4 seam: every test in this suite submits with an arbitrary
        // UUID() surface no live app registers -- this suite is not
        // exercising the new unknown-surface short-circuit, so treat
        // every surface as live.
        server.approvalSurfaceExists = { _ in true }
        // Randomized preferred port, same rationale as
        // AgentHookPipelineIntegrationTests.setUp: this suite only needs
        // *some* running server on the port the script itself reads back
        // out of agent-endpoint.json at call time.
        try await server.start(token: testToken, preferredPort: Int.random(in: 49_152...65_000))

        scriptPath = try ApprovalHookScript.install(toDirectory: appSupportDir + "/bin")
    }

    override func tearDown() {
        server.stop()
        server = nil
        approvalInbox = nil
        if let tempHome {
            try? FileManager.default.removeItem(atPath: tempHome)
        }
        tempHome = nil
        CockpitSettings._testTeardownSuite(named: settingsSuiteName)
        super.tearDown()
    }

    // MARK: - Helpers

    /// Runs the installed `calyx-approval-hook` script as a real child
    /// process (`/bin/sh <script> [kindArgument]`), piping `stdinJSON` to
    /// its stdin and capturing its stdout verbatim. `nonisolated static`
    /// (taking `scriptPath`/`home` explicitly rather than reading them
    /// off `self`) so a call site can `async let` it without the Swift 6
    /// strict-concurrency checker flagging "sending main actor-isolated
    /// self into async let" -- the actual process spawn +
    /// `waitUntilExit()` runs on a detached background Task regardless,
    /// specifically so a long-poll case -- where the script's curl call
    /// blocks until a concurrent `approvalInbox.decide(id:_:)` resolves
    /// it -- doesn't require the calling test's own MainActor context to
    /// be free: the caller can `async let` this, then concurrently
    /// poll/decide, then await the result, exactly like a real hook
    /// blocking on a real human decision.
    ///
    /// `surfaceID` sets `CALYX_SURFACE_ID` when non-nil; `nil` (used only
    /// by the missing-surface-env test) leaves it entirely unset,
    /// matching a plain (non-Calyx) terminal invocation. `kindArgument`,
    /// when non-nil, is passed as the script's `$1` (e.g. `"codex"`) --
    /// nil matches Claude Code's own installed hook entry, which invokes
    /// the script with no arguments at all. `pathPrefix`, when non-nil, is
    /// put ahead of the inherited PATH (a fixed-nonce fake `uuidgen`).
    @discardableResult
    private nonisolated static func runHookScript(
        scriptPath: String,
        home: String,
        stdinJSON: String,
        surfaceID: UUID?,
        kindArgument: String? = nil,
        pathPrefix: String? = nil
    ) async throws -> (exitCode: Int32, stdout: String) {
        let systemPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/local/bin"
        let inheritedPath = pathPrefix.map { "\($0):\(systemPath)" } ?? systemPath

        var arguments = [scriptPath]
        if let kindArgument {
            arguments.append(kindArgument)
        }

        var env = ["HOME": home, "PATH": inheritedPath]
        if let surfaceID {
            env["CALYX_SURFACE_ID"] = surfaceID.uuidString
        }

        return try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = arguments
            process.environment = env

            let stdinPipe = Pipe()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardInput = stdinPipe
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            try process.run()
            stdinPipe.fileHandleForWriting.write(Data(stdinJSON.utf8))
            stdinPipe.fileHandleForWriting.closeFile()

            // Read to EOF before waitUntilExit() so a full pipe buffer
            // (not a concern for these small/empty bodies, but matching
            // the safe ordering regardless) can never deadlock the child.
            let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            _ = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            return (process.terminationStatus, String(data: stdoutData, encoding: .utf8) ?? "")
        }.value
    }

    /// Polls `approvalInbox.pending` for up to `timeout` seconds -- the
    /// script's own curl call is a real network round-trip through a
    /// real `NWListener`, so the submitted request can land a few
    /// milliseconds after `runHookScript` is invoked.
    private func waitForPendingRequest(timeout: TimeInterval = 2.0) async -> ApprovalRequest? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let request = approvalInbox.pending.first { return request }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return approvalInbox.pending.first
    }

    /// Re-parses `stdout` as JSON and extracts
    /// `hookSpecificOutput.decision.behavior` -- the PermissionRequest
    /// hook-response shape (see `AgentHookPermissionResponse`), replacing
    /// the older PreToolUse-era `hookSpecificOutput.permissionDecision`
    /// this helper used to read -- rather than string-comparing the raw
    /// body, the exact key ordering/spacing JSONSerialization produces is
    /// an implementation detail this test must not depend on. Mirrors
    /// `CalyxMCPServerApprovalRequestTests.permissionBehavior(fromResponseBody:)`.
    private func permissionBehavior(fromStdout stdout: String) throws -> String {
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(stdout.utf8)) as? [String: Any],
            "stdout must be a JSON object, got: \(stdout)"
        )
        let hookSpecificOutput = try XCTUnwrap(object["hookSpecificOutput"] as? [String: Any])
        let decision = try XCTUnwrap(hookSpecificOutput["decision"] as? [String: Any])
        return try XCTUnwrap(decision["behavior"] as? String)
    }

    // MARK: - Allow / deny decisions

    func test_allowDecision_printsAllowJSON_exitZero() async throws {
        CockpitSettings.agentHookApprovalEnabled = true
        let surfaceID = UUID()
        // Read these two Sendable String values out of `self` BEFORE the
        // `async let` below -- referencing `scriptPath`/`tempHome`
        // directly inside the async-let initializer would require
        // sending this non-Sendable XCTestCase instance itself into
        // that concurrently-running initializer just to read them.
        let hookScriptPath = scriptPath!
        let hookHome = tempHome!

        async let hookResult = Self.runHookScript(
            scriptPath: hookScriptPath, home: hookHome, stdinJSON: bashLsStdin, surfaceID: surfaceID
        )

        let pendingRequest = await waitForPendingRequest()
        let request = try XCTUnwrap(
            pendingRequest, "the script's real POST must reach the injected approval inbox"
        )
        XCTAssertEqual(request.targetSurfaceID, surfaceID)
        XCTAssertEqual(request.payload, "{\"command\":\"ls\"}",
                       "payload must be the compact JSON of tool_input")
        switch request.source {
        case .agentHook(let toolName, let kind, let summary, _):
            XCTAssertEqual(toolName, "Bash")
            XCTAssertEqual(kind, AgentEntry.claudeCodeKind,
                           "no kind argument was passed -- the script's own $1 default is claude-code")
            XCTAssertEqual(summary, "ls")
        case .mcpTool:
            XCTFail("expected .agentHook source, got .mcpTool")
        case .agentQuestion:
            XCTFail("expected .agentHook source, got .agentQuestion")
        case .mcpApp:
            XCTFail("expected .agentHook source, got .mcpApp")
        }

        approvalInbox.decide(id: request.id, .allowed)
        let (exitCode, stdout) = try await hookResult

        XCTAssertEqual(exitCode, 0, "the hook script must always exit 0")
        XCTAssertEqual(try permissionBehavior(fromStdout: stdout), "allow")
    }

    func test_denyDecision_printsDenyJSON_exitZero() async throws {
        CockpitSettings.agentHookApprovalEnabled = true
        let surfaceID = UUID()
        let hookScriptPath = scriptPath!
        let hookHome = tempHome!

        async let hookResult = Self.runHookScript(
            scriptPath: hookScriptPath, home: hookHome, stdinJSON: bashLsStdin, surfaceID: surfaceID
        )

        let pendingRequest = await waitForPendingRequest()
        let request = try XCTUnwrap(pendingRequest)
        approvalInbox.decide(id: request.id, .denied(.userRejected))
        let (exitCode, stdout) = try await hookResult

        XCTAssertEqual(exitCode, 0)
        XCTAssertEqual(try permissionBehavior(fromStdout: stdout), "deny")
    }

    // MARK: - allowedWithPermissions decision

    /// The script's stdout for an `.allowedWithPermissions` decision must
    /// equal `AgentHookPermissionResponse.body(kind:decision:)` exactly,
    /// the same real-installation-and-wiring proof
    /// `test_answeredDecision_printsUpdatedInputAnswersJSON_exitZero`
    /// already gives `.answered`.
    func test_allowedWithPermissionsDecision_printsUpdatedPermissionsJSON_exitZero() async throws {
        CockpitSettings.agentHookApprovalEnabled = true
        let surfaceID = UUID()
        let hookScriptPath = scriptPath!
        let hookHome = tempHome!
        let permissionBashStdin = """
        {"tool_name":"Bash","tool_input":{"command":"ls"},"permission_suggestions":[\
        {"type":"addDirectories","directories":["/tmp"],"destination":"session"}],"hook_event_name":"PermissionRequest"}
        """

        async let hookResult = Self.runHookScript(
            scriptPath: hookScriptPath, home: hookHome, stdinJSON: permissionBashStdin, surfaceID: surfaceID
        )

        let pendingRequest = await waitForPendingRequest()
        let request = try XCTUnwrap(pendingRequest)
        guard case .agentHook(_, _, _, let offers) = request.source else {
            XCTFail("expected .agentHook source, got \(request.source)")
            return
        }
        let offer = try XCTUnwrap(offers.permissionUpdates.first, "the script's real POST must decode the permission_suggestions entry")
        let expectedBody = try XCTUnwrap(AgentHookPermissionResponse.body(kind: AgentEntry.claudeCodeKind, decision: .allowedWithPermissions(offer)))

        approvalInbox.decide(id: request.id, .allowedWithPermissions(offer))
        let (exitCode, stdout) = try await hookResult

        XCTAssertEqual(exitCode, 0, "the hook script must always exit 0")
        let stdoutObject = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(stdout.utf8)) as? [String: Any])
        let expectedObject = try XCTUnwrap(try JSONSerialization.jsonObject(with: expectedBody) as? [String: Any])
        XCTAssertEqual(stdoutObject as NSDictionary, expectedObject as NSDictionary,
                       "the script's stdout must equal AgentHookPermissionResponse.body(kind:decision:) exactly")
    }

    // MARK: - denied(.userRejected) decision

    func test_deniedUserRejectedDecision_printsClaudeCodeRejectedMessage_exitZero() async throws {
        CockpitSettings.agentHookApprovalEnabled = true
        let surfaceID = UUID()
        let hookScriptPath = scriptPath!
        let hookHome = tempHome!

        async let hookResult = Self.runHookScript(
            scriptPath: hookScriptPath, home: hookHome, stdinJSON: bashLsStdin, surfaceID: surfaceID
        )

        let pendingRequest = await waitForPendingRequest()
        let request = try XCTUnwrap(pendingRequest)
        approvalInbox.decide(id: request.id, .denied(.userRejected))
        let (exitCode, stdout) = try await hookResult

        XCTAssertEqual(exitCode, 0)
        let stdoutObject = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(stdout.utf8)) as? [String: Any])
        let hookSpecificOutput = try XCTUnwrap(stdoutObject["hookSpecificOutput"] as? [String: Any])
        let decision = try XCTUnwrap(hookSpecificOutput["decision"] as? [String: Any])
        XCTAssertEqual(decision["message"] as? String, AgentHookPermissionResponse.claudeCodeRejectedMessage)
    }

    // MARK: - AskUserQuestion: .answered decision

    func test_answeredDecision_printsUpdatedInputAnswersJSON_exitZero() async throws {
        CockpitSettings.agentHookApprovalEnabled = true
        let surfaceID = UUID()
        let hookScriptPath = scriptPath!
        let hookHome = tempHome!
        let askUserQuestionStdin = """
        {"tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Which shell?","options":[{"label":"zsh"},{"label":"bash"}]}]},"hook_event_name":"PermissionRequest"}
        """

        async let hookResult = Self.runHookScript(
            scriptPath: hookScriptPath, home: hookHome, stdinJSON: askUserQuestionStdin, surfaceID: surfaceID
        )

        let pendingRequest = await waitForPendingRequest()
        let request = try XCTUnwrap(
            pendingRequest, "the script's real POST must reach the injected approval inbox"
        )
        guard case .agentQuestion(let kind, let prompt) = request.source else {
            XCTFail("expected .agentQuestion source, got \(request.source)")
            return
        }
        XCTAssertEqual(kind, AgentEntry.claudeCodeKind)

        let answers = AgentQuestionAnswers(prompt: prompt, entries: [.init(answer: .selectedOne("zsh"), notes: nil)])
        let expectedBody = try XCTUnwrap(AgentHookPermissionResponse.body(kind: AgentEntry.claudeCodeKind, decision: .answered(answers)))

        approvalInbox.decide(id: request.id, .answered(answers))
        let (exitCode, stdout) = try await hookResult

        XCTAssertEqual(exitCode, 0, "the hook script must always exit 0")

        let stdoutObject = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(stdout.utf8)) as? [String: Any])
        let expectedObject = try XCTUnwrap(try JSONSerialization.jsonObject(with: expectedBody) as? [String: Any])
        XCTAssertEqual(stdoutObject as NSDictionary, expectedObject as NSDictionary,
                       "the script's stdout must equal AgentHookPermissionResponse.body(kind:decision:) exactly")

        let hookSpecificOutput = try XCTUnwrap(stdoutObject["hookSpecificOutput"] as? [String: Any])
        let decision = try XCTUnwrap(hookSpecificOutput["decision"] as? [String: Any])
        let updatedInput = try XCTUnwrap(decision["updatedInput"] as? [String: Any])
        XCTAssertNotNil(updatedInput["answers"], "stdout must contain hookSpecificOutput.decision.updatedInput.answers")
    }

    // MARK: - Toggle off

    func test_toggleOff_printsNothing_exitZero() async throws {
        CockpitSettings.agentHookApprovalEnabled = false

        let (exitCode, stdout) = try await Self.runHookScript(
            scriptPath: scriptPath, home: tempHome, stdinJSON: bashLsStdin, surfaceID: UUID()
        )

        XCTAssertEqual(exitCode, 0)
        XCTAssertEqual(stdout, "", "agentHookApprovalEnabled being off must print nothing")
        XCTAssertTrue(approvalInbox.pending.isEmpty,
                      "agentHookApprovalEnabled being off must never submit a request to the inbox")
    }

    // MARK: - Timeout expiry

    /// `waitForPendingRequest()` before awaiting the script's own result is
    /// what makes this a real test of the expiry PATH, not merely of the
    /// stdout string an unrelated gate (e.g. a hookEventName mismatch)
    /// would ALSO leave empty: only a request that actually cleared every
    /// upstream gate (kind, hookEventName, the enabled toggle) ever
    /// becomes pending in the first place, so observing it pending proves
    /// this run reached the long-poll before the 1s server timeout below
    /// resolves it to `.expired`.
    func test_timeoutExpiry_claude_printsNothing() async throws {
        CockpitSettings.agentHookApprovalEnabled = true
        server.approvalRequestTimeoutMs = 1_000
        let surfaceID = UUID()
        let hookScriptPath = scriptPath!
        let hookHome = tempHome!

        async let hookResult = Self.runHookScript(
            scriptPath: hookScriptPath, home: hookHome, stdinJSON: bashLsStdin, surfaceID: surfaceID
        )

        let pendingRequest = await waitForPendingRequest()
        XCTAssertNotNil(pendingRequest,
                        "the script's real POST must reach the injected approval inbox before it can time " +
                        "out -- otherwise this run never exercised the expiry path at all")

        let (exitCode, stdout) = try await hookResult

        XCTAssertEqual(exitCode, 0, "the hook script must always exit 0")
        XCTAssertEqual(stdout, "",
                       "an unanswered claude-code request must time out to an EMPTY body -- " +
                       "PermissionRequest has no \"ask\" analog, unlike the old PreToolUse contract")
    }

    /// Mirrors `test_timeoutExpiry_claude_printsNothing`'s own rationale
    /// for polling `waitForPendingRequest()` before awaiting the script's
    /// result.
    func test_timeoutExpiry_codex_printsNothing() async throws {
        CockpitSettings.agentHookApprovalEnabled = true
        server.approvalRequestTimeoutMs = 1_000
        let surfaceID = UUID()
        let hookScriptPath = scriptPath!
        let hookHome = tempHome!

        async let hookResult = Self.runHookScript(
            scriptPath: hookScriptPath, home: hookHome, stdinJSON: bashLsStdin, surfaceID: surfaceID,
            kindArgument: "codex"
        )

        let pendingRequest = await waitForPendingRequest()
        XCTAssertNotNil(pendingRequest,
                        "the script's real POST must reach the injected approval inbox before it can time " +
                        "out -- otherwise this run never exercised the expiry path at all")

        let (exitCode, stdout) = try await hookResult

        XCTAssertEqual(exitCode, 0)
        XCTAssertEqual(stdout, "", "codex has no \"ask\" analog -- an unanswered codex request prints nothing")
    }

    // MARK: - Server not running (stale endpoint file)

    func test_serverNotRunning_staleEndpointFile_printsNothing() async throws {
        CockpitSettings.agentHookApprovalEnabled = true
        // Start then stop the server (setUp already started it), then
        // rewrite agent-endpoint.json by hand pointing at the
        // now-closed port -- stop() itself removes the file, mirroring
        // real production behavior only up to a crash: a crash leaves
        // the file behind pointing at a dead port, which this
        // reconstructs explicitly.
        let stalePort = server.port
        server.stop()
        try writeTestEndpointFile(port: stalePort, token: testToken, wakeProofKey: IPCWakeProofKey.random(), directory: appSupportDir)

        let (exitCode, stdout) = try await Self.runHookScript(
            scriptPath: scriptPath, home: tempHome, stdinJSON: bashLsStdin, surfaceID: UUID()
        )

        XCTAssertEqual(exitCode, 0, "a dead port must still exit 0")
        XCTAssertEqual(stdout, "", "curl's connection-refused (exit 7) path is silent, not fail_safe()")
    }

    // MARK: - Missing surface env

    func test_missingSurfaceEnv_printsNothing_neverContactsServer() async throws {
        CockpitSettings.agentHookApprovalEnabled = true

        let (exitCode, stdout) = try await Self.runHookScript(
            scriptPath: scriptPath, home: tempHome, stdinJSON: bashLsStdin, surfaceID: nil
        )

        XCTAssertEqual(exitCode, 0)
        XCTAssertEqual(stdout, "")
        XCTAssertTrue(approvalInbox.pending.isEmpty,
                      "with neither CALYX_SURFACE_ID nor CALYX_SESSION_ID set, the script must exit " +
                      "before ever attempting the POST")
    }

    // MARK: - Codex kind, allow decision

    func test_codexKind_allowDecision_printsAllowJSON() async throws {
        CockpitSettings.agentHookApprovalEnabled = true
        let surfaceID = UUID()
        let hookScriptPath = scriptPath!
        let hookHome = tempHome!

        async let hookResult = Self.runHookScript(
            scriptPath: hookScriptPath, home: hookHome, stdinJSON: bashLsStdin, surfaceID: surfaceID,
            kindArgument: "codex"
        )

        let pendingRequest = await waitForPendingRequest()
        let request = try XCTUnwrap(pendingRequest)
        switch request.source {
        case .agentHook(_, let kind, _, _):
            XCTAssertEqual(kind, AgentEntry.codexKind)
        case .mcpTool:
            XCTFail("expected .agentHook source, got .mcpTool")
        case .agentQuestion:
            XCTFail("expected .agentHook source, got .agentQuestion")
        case .mcpApp:
            XCTFail("expected .agentHook source, got .mcpApp")
        }

        approvalInbox.decide(id: request.id, .allowed)
        let (exitCode, stdout) = try await hookResult

        XCTAssertEqual(exitCode, 0)
        XCTAssertEqual(try permissionBehavior(fromStdout: stdout), "allow",
                       "codex must get a real allow body on a genuine decision, not an empty fail-safe body")
    }

    // MARK: - Connection drop mid-poll (R5)

    /// Starts the installed script through the shared
    /// `HookScriptProcessTree.startHookScript` and returns its pid (known
    /// as soon as `Process.run()` returns, well before the script's curl
    /// has even started) plus a Task yielding its exit code, stdout and
    /// stderr. Unlike `runHookScript` above (which blocks until the whole
    /// child process tree has exited), this lets a test locate and kill
    /// the script's own curl WHILE the script is still blocked reading
    /// `/approval-request`'s long-poll response. The environment is
    /// HOME, the inherited PATH and, when given, CALYX_SURFACE_ID.
    private nonisolated static func runHookScriptCapturingPID(
        scriptPath: String, home: String, stdinJSON: String, surfaceID: UUID?
    ) throws -> HookScriptProcessTree.RunningScript {
        let inheritedPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/local/bin"
        var env = ["HOME": home, "PATH": inheritedPath]
        if let surfaceID {
            env["CALYX_SURFACE_ID"] = surfaceID.uuidString
        }
        return try HookScriptProcessTree.startHookScript(scriptPath: scriptPath, environment: env, stdin: stdinJSON)
    }

    /// Polls `approvalInbox.pending` for up to `timeout` seconds,
    /// mirroring `waitForPendingRequest`'s polling shape but for the
    /// opposite condition (emptiness rather than presence).
    private func waitForPendingEmpty(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if approvalInbox.pending.isEmpty { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return approvalInbox.pending.isEmpty
    }

    /// R5 fix-pin: nothing today cancels `routeApprovalRequest`'s Task
    /// promptly when the hook's own curl child dies mid-poll (e.g. the
    /// CLI process itself getting killed) -- the pending request lingers
    /// until `approvalRequestTimeoutMs` elapses, stranding its banner and
    /// notification for however long that timeout is set to.
    /// `approvalRequestTimeoutMs` is set to a moderate 30s here (not the
    /// ~9.5-minute production default) so this test's OWN 5s bound below
    /// clearly distinguishes "cleared early because the connection drop
    /// was detected" from "cleared because the 30s timeout coincidentally
    /// also elapsed" -- and so a failing run (nothing clears it early) fails
    /// in seconds, not after hanging out a long timeout.
    func test_curlKilledMidPoll_clearsPendingRequestPromptly_shExitsZero() async throws {
        CockpitSettings.agentHookApprovalEnabled = true
        server.approvalRequestTimeoutMs = 30_000
        let surfaceID = UUID()
        let hookScriptPath = scriptPath!
        let hookHome = tempHome!

        let running = try Self.runHookScriptCapturingPID(
            scriptPath: hookScriptPath, home: hookHome, stdinJSON: bashLsStdin, surfaceID: surfaceID
        )

        let pendingRequest = await waitForPendingRequest()
        XCTAssertNotNil(pendingRequest,
                        "the script's real POST must reach the injected approval inbox before its curl child is killed")

        let curlPID = await HookScriptProcessTree.findDescendantProcess(ofAncestor: running.pid, commandName: "curl")
        let killPID = try XCTUnwrap(curlPID, "must locate the script's own curl child process to kill it")

        XCTAssertEqual(kill(killPID, SIGKILL), 0, "must be able to SIGKILL the located curl child")

        let clearedPromptly = await waitForPendingEmpty(timeout: 5.0)
        XCTAssertTrue(clearedPromptly,
                      "killing the hook's curl mid-poll must clear the pending request within 5s -- well " +
                      "under the 30s approvalRequestTimeoutMs above -- rather than leaving it pending until " +
                      "that timeout")

        let (exitCode, stdout, _) = await running.result.value
        XCTAssertEqual(exitCode, 0, "the hook script must always exit 0, even when its own curl child is killed")
        XCTAssertEqual(stdout, "",
                       "no decision is ever made in this test, so the long-poll can only resolve by the " +
                       "connection drop this test triggers -- a SIGKILLed curl can't exit 0 (the only case " +
                       "the script's own case statement ever prints anything), so stdout must be empty, " +
                       "never a fabricated allow/deny/ask body")
    }

    /// R-orphan-curl fix-pin, the actual production repro this fix
    /// addresses: unlike `test_curlKilledMidPoll_...` above (which kills
    /// the script's curl CHILD directly, proving the server-side drop
    /// detection itself works), this test kills the SCRIPT ITSELF
    /// (`running.pid`, the `/bin/sh` process) with `SIGTERM` -- exactly
    /// what Claude Code does to a still-running PermissionRequest hook
    /// process when the user answers the SAME permission prompt directly
    /// in the CLI instead of waiting on Calyx (Node's `child_process.kill()`
    /// default signal). Before this fix, `curl` was a child of a
    /// `response=$(curl ...)` command substitution subshell the SIGTERM
    /// never reached, so it survived as an orphan (reparented to PID 1,
    /// empirically confirmed) and kept its long-poll connection open for
    /// up to its own 585s `-m` deadline -- invisible to
    /// `dispatchRoute`'s connection-drop sentinel, which only notices a
    /// CLOSED socket. This test proves both halves of the fix: SIGTERM to
    /// the script also kills its curl child (no orphan survives), and
    /// that closed connection is what lets `waitForPendingEmpty` observe
    /// the pending request clearing well within this test's own 5s
    /// bound, the same shape as the direct-curl-kill test above.
    func test_scriptKilledMidPoll_alsoKillsCurlChild_andClearsPendingRequestPromptly() async throws {
        CockpitSettings.agentHookApprovalEnabled = true
        server.approvalRequestTimeoutMs = 30_000
        let surfaceID = UUID()
        let hookScriptPath = scriptPath!
        let hookHome = tempHome!

        let running = try Self.runHookScriptCapturingPID(
            scriptPath: hookScriptPath, home: hookHome, stdinJSON: bashLsStdin, surfaceID: surfaceID
        )

        let pendingRequest = await waitForPendingRequest()
        XCTAssertNotNil(pendingRequest,
                        "the script's real POST must reach the injected approval inbox before the script " +
                        "itself is killed")

        let curlPID = await HookScriptProcessTree.findDescendantProcess(ofAncestor: running.pid, commandName: "curl")
        let observedCurlPID = try XCTUnwrap(curlPID, "must locate the script's own curl child before killing the script")

        XCTAssertEqual(kill(running.pid, SIGTERM), 0, "must be able to SIGTERM the script's own /bin/sh process")

        let clearedPromptly = await waitForPendingEmpty(timeout: 5.0)
        XCTAssertTrue(clearedPromptly,
                      "SIGTERM to the script itself must clear the pending request within 5s -- well under " +
                      "the 30s approvalRequestTimeoutMs above -- by also killing its curl child rather than " +
                      "leaving it orphaned until curl's own 585s -m deadline")

        // Poll rather than a single immediate check: the trap's `kill` and
        // the OS actually reaping the process are not the same instant.
        let curlGone = await HookScriptProcessTree.waitUntilProcessGone(pid: observedCurlPID, timeout: 3.0)
        XCTAssertTrue(curlGone,
                      "the script's own curl child must not survive as an orphan once the script itself is " +
                      "killed -- the trap must kill it explicitly")

        let (exitCode, stdout, _) = await running.result.value
        XCTAssertEqual(exitCode, 0, "the hook script's own trap must still exit 0 on SIGTERM")
        XCTAssertEqual(stdout, "",
                       "no decision is ever made in this test, so a killed script must never print anything")
    }

    // MARK: - Unverifiable answers (spec C.1 item 3, C.4)

    /// A process holding the endpoint port answers with an unsigned allow:
    /// the script prints nothing, for claude-code (no argument) and grok.
    /// The file keeps this server's token and key blocks; only the port
    /// points at the fake responder.
    func test_squatterAnsweringUnsignedAllow_printsNothing() async throws {
        let blocks = try XCTUnwrap(IPCWakeTestCrypto.readEndpointBlocks(directory: appSupportDir))
        let allow = Data(#"{"hookSpecificOutput":{"decision":{"behavior":"allow"}}}"#.utf8)
        for kind in [String?.none, "grok"] {
            let responder = try LoopbackOneShotResponder(body: allow)
            responder.serveOnce()
            try writeEndpointFile(port: responder.port, inner: blocks.inner, outer: blocks.outer)

            let (exitCode, stdout) = try await Self.runHookScript(
                scriptPath: scriptPath, home: tempHome, stdinJSON: bashLsStdin, surfaceID: UUID(), kindArgument: kind
            )
            let served = await responder.waitUntilServed(timeout: 10)

            XCTAssertTrue(served, "[\(kind ?? "claude-code")] precondition: the script's curl reached the responder")
            XCTAssertEqual(exitCode, 0)
            XCTAssertEqual(stdout, "", "[\(kind ?? "claude-code")] an unsigned allow is never printed")
        }
    }

    /// The endpoint file names this server's port and token but another
    /// key's blocks (a stale or forged file): the server signs the user's
    /// allow with its own key, the script cannot verify it and prints
    /// nothing, and the request was still answered (the decision was
    /// consumed on the server side).
    func test_endpointFileWithAnotherKeysBlocks_printsNothing_requestStillAnswered() async throws {
        CockpitSettings.agentHookApprovalEnabled = true
        let other = IPCWakeTestCrypto.blocksHex(keyBytes: IPCWakeTestCrypto.randomKeyBytes())
        try writeEndpointFile(port: server.port, inner: other.inner, outer: other.outer)
        let hookScriptPath = scriptPath!
        let hookHome = tempHome!

        async let hookResult = Self.runHookScript(
            scriptPath: hookScriptPath, home: hookHome, stdinJSON: bashLsStdin, surfaceID: UUID()
        )

        let pendingRequest = await waitForPendingRequest()
        let request = try XCTUnwrap(pendingRequest, "the request reaches the real server")
        approvalInbox.decide(id: request.id, .allowed)
        let (exitCode, stdout) = try await hookResult

        XCTAssertEqual(exitCode, 0)
        XCTAssertEqual(stdout, "", "a proof under the server's key does not verify against another key's blocks")
        XCTAssertTrue(approvalInbox.pending.isEmpty, "the user's allow was consumed: the request is answered")
    }

    /// A correctly signed answer over the cap (1.2 MB body): curl stops at
    /// `--max-filesize 1048641` and the script prints nothing.
    func test_signedAnswerOverTheCap_printsNothing() async throws {
        let blocks = try XCTUnwrap(IPCWakeTestCrypto.readEndpointBlocks(directory: appSupportDir))
        let nonceFile = tempHome + "/fixed-nonce-bin"
        let nonce = "6F1C2A9E-0B7D-4E21-9A53-C4D8E7F00112"
        try makeFakeUuidgen(atDirectory: nonceFile, stdout: nonce + "\n")
        let body = Data(repeating: UInt8(ascii: "x"), count: 1_200 * 1_024)
        let message = Data(("approval\n" + nonce + "\n").utf8) + body
        let proof = IPCWakeTestCrypto.hmacHex(keyBytes: server.wakeProofKey.bytes, message: message)
        let responder = try LoopbackOneShotResponder(body: Data((proof + "\n").utf8) + body)
        responder.serveOnce()
        try writeEndpointFile(port: responder.port, inner: blocks.inner, outer: blocks.outer)

        let (exitCode, stdout) = try await Self.runHookScript(
            scriptPath: scriptPath, home: tempHome, stdinJSON: bashLsStdin, surfaceID: UUID(),
            pathPrefix: nonceFile
        )
        let served = await responder.waitUntilServed(timeout: 10)

        XCTAssertTrue(served, "precondition: the script's curl reached the responder")
        XCTAssertEqual(exitCode, 0)
        XCTAssertEqual(stdout, "", "an answer over 65 + 4 * 262144 bytes is never printed, even correctly signed")
    }

    /// Rewrites agent-endpoint.json by hand with `port`, this suite's token,
    /// the test host's liveness identifier and the given blocks.
    private func writeEndpointFile(port: Int, inner: String, outer: String) throws {
        // pid/pidStart: the test host's own liveness identifier (C-D16), so
        // the prologue's liveness check passes and the case under test runs.
        let dict: [String: Any] = [
            "port": port, "token": testToken, "wakeProofInner": inner, "wakeProofOuter": outer,
            "pid": Int(TestHostLiveness.pid), "pidStart": TestHostLiveness.startText,
        ]
        let data = try JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
        try data.write(to: URL(fileURLWithPath: appSupportDir + "/agent-endpoint.json"))
    }
}
