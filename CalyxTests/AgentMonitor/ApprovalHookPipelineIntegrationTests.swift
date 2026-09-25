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
    /// the script with no arguments at all.
    @discardableResult
    private nonisolated static func runHookScript(
        scriptPath: String,
        home: String,
        stdinJSON: String,
        surfaceID: UUID?,
        kindArgument: String? = nil
    ) async throws -> (exitCode: Int32, stdout: String) {
        let inheritedPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/local/bin"

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
        try AgentEndpointFile.write(port: stalePort, token: testToken, directory: appSupportDir)

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

    /// Handle returned by `runHookScriptCapturingPID`: the spawned
    /// script's own pid, available as soon as `Process.run()` returns --
    /// well before the script's `curl` call has even resolved -- plus a
    /// `Task` the caller can await later for its final
    /// `(exitCode, stdout)`. Unlike `runHookScript` above (which blocks
    /// until the whole child process tree has exited before returning
    /// anything), this lets a test locate and kill the script's own curl
    /// child WHILE the script is still blocked reading
    /// `/approval-request`'s long-poll response.
    private struct RunningHookScript {
        let pid: Int32
        let result: Task<(exitCode: Int32, stdout: String), Never>
    }

    /// `Process`/`Pipe`/`FileHandle` are all `Sendable` in this SDK
    /// (`Process`/`Pipe` bridge to `NSTask`/`NSPipe`, both confirmed
    /// `Sendable` -- verified against the installed SDK), so capturing
    /// them across the `Task.detached` boundary below is safe under
    /// Swift 6 strict concurrency; unlike `runHookScript`'s `self`-sending
    /// concern (see its own doc comment), nothing non-Sendable is
    /// captured here.
    private nonisolated static func runHookScriptCapturingPID(
        scriptPath: String, home: String, stdinJSON: String, surfaceID: UUID?
    ) throws -> RunningHookScript {
        let inheritedPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/local/bin"
        var env = ["HOME": home, "PATH": inheritedPath]
        if let surfaceID {
            env["CALYX_SURFACE_ID"] = surfaceID.uuidString
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [scriptPath]
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

        let pid = process.processIdentifier
        let resultTask = Task.detached(priority: .userInitiated) {
            let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            _ = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (exitCode: process.terminationStatus, stdout: String(data: stdoutData, encoding: .utf8) ?? "")
        }

        return RunningHookScript(pid: pid, result: resultTask)
    }

    /// Breadth-first search of `ancestorPID`'s process-tree descendants
    /// for the first process whose `comm` (bare executable name, no
    /// arguments) is `processName`, polling up to `timeout` since the
    /// descendant may not have forked yet the instant this is first
    /// called. `sh -c 'x=$(curl ...)'` was confirmed empirically (spawn a
    /// backgrounded `sh -c 'x=$(sleep 5)'` and inspect `ps -o pid,ppid,comm`)
    /// to fork an intermediate subshell before `curl` itself runs --
    /// `curl` is a GRANDCHILD of the script's own pid, not a direct
    /// child -- so a single-level `pgrep -P <sh pid>` alone is not
    /// enough; this walks the whole descendant tree instead.
    private nonisolated static func findDescendantProcess(
        ofAncestor ancestorPID: Int32, commandName processName: String, timeout: TimeInterval = 3.0
    ) async -> Int32? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let found = descendantMatching(ofAncestor: ancestorPID, commandName: processName) {
                return found
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return nil
    }

    private nonisolated static func descendantMatching(ofAncestor ancestorPID: Int32, commandName processName: String) -> Int32? {
        var frontier = childPIDs(ofParent: ancestorPID)
        var visited = Set<Int32>()
        while !frontier.isEmpty {
            let current = frontier.removeFirst()
            guard !visited.contains(current) else { continue }
            visited.insert(current)
            if processCommandName(ofPID: current) == processName {
                return current
            }
            frontier.append(contentsOf: childPIDs(ofParent: current))
        }
        return nil
    }

    private nonisolated static func childPIDs(ofParent pid: Int32) -> [Int32] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-P", String(pid)]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let output = String(data: data, encoding: .utf8) else { return [] }
        return output.split(separator: "\n").compactMap { Int32($0) }
    }

    private nonisolated static func processCommandName(ofPID pid: Int32) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-p", String(pid), "-o", "comm="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let output = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : (trimmed as NSString).lastPathComponent
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

        let curlPID = await Self.findDescendantProcess(ofAncestor: running.pid, commandName: "curl")
        let killPID = try XCTUnwrap(curlPID, "must locate the script's own curl child process to kill it")

        XCTAssertEqual(kill(killPID, SIGKILL), 0, "must be able to SIGKILL the located curl child")

        let clearedPromptly = await waitForPendingEmpty(timeout: 5.0)
        XCTAssertTrue(clearedPromptly,
                      "killing the hook's curl mid-poll must clear the pending request within 5s -- well " +
                      "under the 30s approvalRequestTimeoutMs above -- rather than leaving it pending until " +
                      "that timeout")

        let (exitCode, stdout) = await running.result.value
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

        let curlPID = await Self.findDescendantProcess(ofAncestor: running.pid, commandName: "curl")
        let observedCurlPID = try XCTUnwrap(curlPID, "must locate the script's own curl child before killing the script")

        XCTAssertEqual(kill(running.pid, SIGTERM), 0, "must be able to SIGTERM the script's own /bin/sh process")

        let clearedPromptly = await waitForPendingEmpty(timeout: 5.0)
        XCTAssertTrue(clearedPromptly,
                      "SIGTERM to the script itself must clear the pending request within 5s -- well under " +
                      "the 30s approvalRequestTimeoutMs above -- by also killing its curl child rather than " +
                      "leaving it orphaned until curl's own 585s -m deadline")

        // Poll rather than a single immediate check: the trap's `kill` and
        // the OS actually reaping the process are not the same instant.
        let curlGone = await Self.waitUntilProcessGone(pid: observedCurlPID, timeout: 3.0)
        XCTAssertTrue(curlGone,
                      "the script's own curl child must not survive as an orphan once the script itself is " +
                      "killed -- the trap must kill it explicitly")

        let (exitCode, stdout) = await running.result.value
        XCTAssertEqual(exitCode, 0, "the hook script's own trap must still exit 0 on SIGTERM")
        XCTAssertEqual(stdout, "",
                       "no decision is ever made in this test, so a killed script must never print anything")
    }

    /// Polls until `pid` no longer identifies a live process (either
    /// exited or reaped), used to confirm curl doesn't linger as an
    /// orphan after the fix kills it.
    private nonisolated static func waitUntilProcessGone(pid: Int32, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if kill(pid, 0) != 0 { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return kill(pid, 0) != 0
    }
}
