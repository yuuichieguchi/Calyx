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
//  response, exactly like a real PreToolUse hook invocation blocking on
//  a real human's decision.
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
//  request times out to "ask" (claude-code) / nothing (codex); a stale
//  agent-endpoint.json pointing at a closed port is silent (curl exit 7);
//  and CALYX_SURFACE_ID/CALYX_SESSION_ID both unset never even attempts
//  the POST. Every case asserts exit 0 -- the hook script must never
//  break its caller's hook chain.
//

import XCTest
@testable import Calyx

/// A PreToolUse hook stdin JSON (`Bash` / `tool_input.command: "ls"`),
/// shared by every test below. File-scope (not a class property) so
/// referencing it from inside an `async let` initializer never needs to
/// send this file's `@MainActor`-isolated, non-Sendable `XCTestCase`
/// instance itself just to read an otherwise-constant string.
private let bashLsStdin = """
{"tool_name":"Bash","tool_input":{"command":"ls"}}
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
        server = CalyxMCPServer()
        server.agentRegistry = AgentRegistry()
        server.agentEndpointDirectory = appSupportDir
        server.approvalInbox = approvalInbox
        // Randomized preferred port, same rationale as
        // AgentHookPipelineIntegrationTests.setUp: this suite only needs
        // *some* running server on the port the script itself reads back
        // out of agent-endpoint.json at call time.
        try server.start(token: testToken, preferredPort: Int.random(in: 49_152...65_000))

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
    /// `hookSpecificOutput.permissionDecision`, rather than
    /// string-comparing the raw body -- the exact key ordering/spacing
    /// JSONSerialization produces is an implementation detail this test
    /// must not depend on.
    private func permissionDecision(fromStdout stdout: String) throws -> String {
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(stdout.utf8)) as? [String: Any],
            "stdout must be a JSON object, got: \(stdout)"
        )
        let hookSpecificOutput = try XCTUnwrap(object["hookSpecificOutput"] as? [String: Any])
        return try XCTUnwrap(hookSpecificOutput["permissionDecision"] as? String)
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
        case .agentHook(let toolName, let kind, let summary):
            XCTAssertEqual(toolName, "Bash")
            XCTAssertEqual(kind, AgentEntry.claudeCodeKind,
                           "no kind argument was passed -- the script's own $1 default is claude-code")
            XCTAssertEqual(summary, "ls")
        case .mcpTool:
            XCTFail("expected .agentHook source, got .mcpTool")
        }

        approvalInbox.decide(id: request.id, .allowed)
        let (exitCode, stdout) = try await hookResult

        XCTAssertEqual(exitCode, 0, "the hook script must always exit 0")
        XCTAssertEqual(try permissionDecision(fromStdout: stdout), "allow")
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
        approvalInbox.decide(id: request.id, .denied)
        let (exitCode, stdout) = try await hookResult

        XCTAssertEqual(exitCode, 0)
        XCTAssertEqual(try permissionDecision(fromStdout: stdout), "deny")
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

    func test_timeoutExpiry_claude_printsAskJSON() async throws {
        CockpitSettings.agentHookApprovalEnabled = true
        server.approvalRequestTimeoutMs = 500

        let (exitCode, stdout) = try await Self.runHookScript(
            scriptPath: scriptPath, home: tempHome, stdinJSON: bashLsStdin, surfaceID: UUID()
        )

        XCTAssertEqual(exitCode, 0)
        XCTAssertEqual(try permissionDecision(fromStdout: stdout), "ask",
                       "an unanswered claude-code request must time out to \"ask\", never \"allow\"")
    }

    func test_timeoutExpiry_codex_printsNothing() async throws {
        CockpitSettings.agentHookApprovalEnabled = true
        server.approvalRequestTimeoutMs = 500

        let (exitCode, stdout) = try await Self.runHookScript(
            scriptPath: scriptPath, home: tempHome, stdinJSON: bashLsStdin, surfaceID: UUID(), kindArgument: "codex"
        )

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
        case .agentHook(_, let kind, _):
            XCTAssertEqual(kind, AgentEntry.codexKind)
        case .mcpTool:
            XCTFail("expected .agentHook source, got .mcpTool")
        }

        approvalInbox.decide(id: request.id, .allowed)
        let (exitCode, stdout) = try await hookResult

        XCTAssertEqual(exitCode, 0)
        XCTAssertEqual(try permissionDecision(fromStdout: stdout), "allow",
                       "codex must get a real allow body on a genuine decision, not fail_safe()'s empty body")
    }
}
