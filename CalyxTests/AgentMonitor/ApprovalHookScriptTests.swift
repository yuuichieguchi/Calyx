//
//  ApprovalHookScriptTests.swift
//  CalyxTests
//
//  Covers ApprovalHookScript: the `calyx-approval-hook` script
//  installed alongside `calyx-agent-hook` (see AgentHookScriptTests.swift,
//  which this mirrors). Unlike calyx-agent-hook's fire-and-forget async
//  POST, this script is invoked *synchronously* by a PermissionRequest
//  hook entry and its stdout becomes Claude Code's / Codex's actual
//  permission decision -- so its fail-safe behavior (never printing
//  "allow", always exiting 0) is the single most safety-critical string
//  invariant in this file.
//
//  Coverage:
//  - scriptBody guards on both CALYX_SURFACE_ID and CALYX_SESSION_ID being
//    unset, reads agent-endpoint.json, sends the required headers
//  - curl is bounded by ApprovalHookTiming.curlTimeoutSeconds (585) and
//    uses --fail so a non-2xx response is treated as a curl error
//  - a successful response body is printed verbatim via printf '%s'
//  - every curl failure path (any exit code other than 0/success,
//    including 7/connection-refused, which has its own dedicated case
//    arm) produces NO stdout output at all, verified by running the
//    installed script as a real child process against a fake curl on
//    PATH -- PermissionRequest has no interactive fallback body the way
//    the old PreToolUse "ask" contract did, so a lost connection or
//    unexpected curl failure must stay completely silent and let the
//    CLI's own confirmation prompt take over
//  - scriptBody never references the retired permissionDecision field
//    name, and never fabricates an "allow" decision anywhere
//  - curl exit 7 (connection refused / stale endpoint file) is silent
//  - every exit path in the script is exit 0
//  - install(toDirectory:) writes the script at 0755 with scriptBody's
//    exact content
//

import XCTest
@testable import Calyx

final class ApprovalHookScriptTests: XCTestCase {

    // MARK: - Properties

    private var tempDir: String!

    // MARK: - Lifecycle

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).path
        try! FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: tempDir)
        tempDir = nil
        super.tearDown()
    }

    // MARK: - fileName

    func test_fileName_isCalyxApprovalHook() {
        XCTAssertEqual(ApprovalHookScript.fileName, "calyx-approval-hook")
    }

    // MARK: - scriptBody: guard / kind / endpoint file

    func test_scriptBody_guardsOnMissingSurfaceAndSessionID() {
        let body = ApprovalHookScript.scriptBody

        XCTAssertTrue(body.contains("[ -z \"$CALYX_SURFACE_ID\" ] && [ -z \"$CALYX_SESSION_ID\" ]"),
                     "Script must guard on BOTH CALYX_SURFACE_ID and CALYX_SESSION_ID being unset " +
                     "(a plain, non-Calyx-launched terminal must be unaffected)")
    }

    func test_scriptBody_kindDefaultsToClaudeCode() {
        XCTAssertTrue(ApprovalHookScript.scriptBody.contains("kind=\"${1:-claude-code}\""),
                     "Script must default the agent kind ($1) to claude-code, matching " +
                     "Claude Code's own hooks.json entries, which invoke it with no argv")
    }

    func test_scriptBody_referencesAgentEndpointFile() {
        let body = ApprovalHookScript.scriptBody

        XCTAssertTrue(body.contains("agent-endpoint.json"),
                     "Script must read port/token from agent-endpoint.json on every invocation, " +
                     "never a value baked in at install time")
        XCTAssertTrue(body.contains("port=$(sed"), "Script must sed-extract the port field")
        XCTAssertTrue(body.contains("token=$(sed"), "Script must sed-extract the token field")
    }

    func test_scriptBody_readsEndpointPathFromCalyxEndpointFileWithLiteralFallback() {
        XCTAssertTrue(
            ApprovalHookScript.scriptBody.contains(
                "endpoint_file=\"${CALYX_ENDPOINT_FILE:-\(AgentEndpointFile.shellFallbackPath)}\""
            ),
            "Script must read CALYX_ENDPOINT_FILE (injected by GhosttySurfaceController, scoped to " +
            "wherever Calyx actually wrote agent-endpoint.json), falling back to the literal " +
            "$HOME-relative path for a pane launched before that injection existed"
        )
    }

    // MARK: - scriptBody: headers

    func test_scriptBody_sendsAuthorizationHeaderWithBearerToken() {
        XCTAssertTrue(ApprovalHookScript.scriptBody.contains("Authorization: Bearer $token"),
                     "Script must authenticate its POST with the token read from agent-endpoint.json")
    }

    func test_scriptBody_sendsSurfaceIDHeaderPreferringSessionID() {
        XCTAssertTrue(ApprovalHookScript.scriptBody.contains("X-Calyx-Surface-ID: ${CALYX_SESSION_ID:-$CALYX_SURFACE_ID}"),
                     "Script must send X-Calyx-Surface-ID, preferring CALYX_SESSION_ID (survives " +
                     "ghostty surface reconnect) over CALYX_SURFACE_ID")
    }

    func test_scriptBody_sendsAgentKindHeader() {
        XCTAssertTrue(ApprovalHookScript.scriptBody.contains("X-Calyx-Agent-Kind: $kind"),
                     "Script must send the X-Calyx-Agent-Kind header so the server can attribute " +
                     "the approval request to the right CLI")
    }

    func test_scriptBody_forwardsStdinViaDataBinary() {
        XCTAssertTrue(ApprovalHookScript.scriptBody.contains("--data-binary @-"),
                     "Script must forward the hook's stdin JSON verbatim via --data-binary")
    }

    // MARK: - scriptBody: curl timeout / fail flag / endpoint

    func test_scriptBody_curlUsesDerivedTimeout() {
        XCTAssertTrue(ApprovalHookScript.scriptBody.contains("-m \(ApprovalHookTiming.curlTimeoutSeconds)"),
                     "curl's -m timeout must be derived from ApprovalHookTiming.curlTimeoutSeconds (585), " +
                     "not a separately hardcoded number, so the nesting invariant it documents can't " +
                     "silently drift out of sync")
    }

    func test_scriptBody_curlUsesFailFlag() {
        XCTAssertTrue(ApprovalHookScript.scriptBody.contains("--fail"),
                     "curl must use --fail so a non-2xx server response is treated as a curl error " +
                     "(silent, exactly like any other curl failure), never printed to Claude Code as if " +
                     "it were a real decision")
    }

    func test_scriptBody_postsToApprovalRequestEndpoint() {
        XCTAssertTrue(ApprovalHookScript.scriptBody.contains("/approval-request"),
                     "Script must POST to the /approval-request endpoint, not /agent-event")
    }

    // MARK: - scriptBody: response handling

    func test_scriptBody_printsResponseBodyVerbatim() {
        XCTAssertTrue(ApprovalHookScript.scriptBody.contains("printf '%s'"),
                     "The captured response body must be printed verbatim via printf '%s' -- echo can " +
                     "mangle a body starting with '-' or containing backslash escape sequences")
    }

    func test_scriptBody_connectionRefused_isSilent() {
        let body = ApprovalHookScript.scriptBody

        // Isolate the case-branch keyed on curl's connection-refused exit
        // code (7): its own case arm must never call printf. Execution-
        // level confirmation that this branch actually produces no stdout
        // lives in test_scriptBody_curlNonZeroExit_producesNoStdout below,
        // whose own sweep includes exit code 7.
        guard let branchRange = body.range(of: #"7\)[\s\S]*?;;"#, options: .regularExpression) else {
            XCTFail("Script must have a case branch matching curl's connection-refused exit code (7)")
            return
        }
        let branch = String(body[branchRange])

        XCTAssertFalse(branch.contains("printf"),
                       "curl exit 7 (connection refused / stale endpoint file after a crash) must " +
                       "produce NO output")
    }

    // MARK: - scriptBody: fail-safe paths produce no output (execution-based)

    /// Every curl exit code other than 0 (success, handled elsewhere) --
    /// including exit 7 (connection refused / stale endpoint file after a
    /// crash), which has its own dedicated case arm, not just the
    /// wildcard catch-all -- must produce NO stdout at all, proven here by
    /// real `/bin/sh` execution against a fake curl (see
    /// FakeCurlScriptFixture.swift), not by string-matching scriptBody.
    /// Covers a representative spread of curl's own error codes (couldn't
    /// resolve host, timeout, --fail's own rejection of a non-2xx
    /// response, connection refused, etc.) for both the default
    /// (claude-code) and codex argv shapes, since PermissionRequest's
    /// fail-safe silence applies to every CLI kind, not just claude-code.
    func test_scriptBody_curlNonZeroExit_producesNoStdout() throws {
        let nonZeroExitCodes: [Int32] = [1, 6, 7, 22, 28, 35, 52, 56]
        let kindArguments: [String?] = [nil, "codex"]

        for kindArgument in kindArguments {
            for exitCode in nonZeroExitCodes {
                let label = "kind=\(kindArgument ?? "claude-code (default)"), curl exit \(exitCode)"
                let fixture = try makeFakeCurlScriptFixture(
                    rootDirectory: tempDir + "/\(kindArgument ?? "default")-\(exitCode)",
                    port: 41_833, token: "fail-safe-execution-test-token",
                    install: ApprovalHookScript.install(toDirectory:)
                )
                try makeFakeCurl(atDirectory: fixture.fakeBinDir, exitCode: exitCode)

                let result = try runFakeCurlHookScript(
                    fixture, stdinJSON: #"{"tool_name":"Bash","tool_input":{"command":"ls"}}"#,
                    extraEnv: ["CALYX_SURFACE_ID": UUID().uuidString], kindArgument: kindArgument
                )

                XCTAssertEqual(result.exitCode, 0, "[\(label)] the script itself must still exit 0")
                XCTAssertEqual(result.stdout, "",
                               "[\(label)] a curl failure must produce NO stdout output at all -- the hook " +
                               "must never fabricate a decision when its own connection to Calyx failed")
            }
        }
    }

    func test_scriptBody_neverContainsPermissionDecisionLiteral() {
        XCTAssertFalse(ApprovalHookScript.scriptBody.contains("permissionDecision"),
                      "The script must never reference the retired PreToolUse permissionDecision field " +
                      "name -- PermissionRequest's fail-safe path is silence (no output), not a " +
                      "fabricated JSON body")
    }

    func test_scriptBody_failSafe_neverPrintsAllow() {
        XCTAssertFalse(ApprovalHookScript.scriptBody.contains("\"allow\""),
                      "The script must never fabricate an 'allow' decision anywhere -- a lost " +
                      "connection or any unexpected curl failure must fail closed (silent), never open")
    }

    // MARK: - scriptBody: every path exits 0

    func test_scriptBody_everyPathExitsZero() {
        let body = ApprovalHookScript.scriptBody
        let exitStatements = body
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("exit") }

        XCTAssertFalse(exitStatements.isEmpty, "Script must contain at least one exit statement")
        for statement in exitStatements {
            XCTAssertEqual(statement, "exit 0",
                           "Every exit path must be exit 0 -- a failed or unreachable POST, or a " +
                           "non-2xx response, must never break the hook chain nor propagate a " +
                           "nonzero status. Found: \(statement)")
        }
    }

    // MARK: - install()

    func test_install_writesExecutableScript() throws {
        let scriptPath = try ApprovalHookScript.install(toDirectory: tempDir)

        XCTAssertTrue(FileManager.default.fileExists(atPath: scriptPath),
                     "install() must write the script to the returned path")
        XCTAssertTrue(scriptPath.hasPrefix(tempDir),
                     "install() must place the script inside the given directory")

        let attrs = try FileManager.default.attributesOfItem(atPath: scriptPath)
        let permissions = (attrs[.posixPermissions] as? NSNumber)?.uint16Value
        XCTAssertEqual(permissions, 0o755, "Installed script must be executable (0755)")

        let content = try String(contentsOfFile: scriptPath, encoding: .utf8)
        XCTAssertEqual(content, ApprovalHookScript.scriptBody,
                       "Installed script content must match scriptBody")
    }

    /// `calyx-approval-hook` is executed directly by an agent CLI, so a
    /// lost executable bit breaks approval with no visible signal.
    /// `ApprovalHookScript.install` shares its write path with
    /// `AgentHookScript.installScript`, which passes
    /// `restoreModeOnNoWrite: true` -- a reinstall whose bytes end up
    /// identical to what's already on disk must still repair a mode that
    /// drifted behind Calyx's back (a plain `chmod`), since a reinstall
    /// is the only repair path available to the user for a drifted mode
    /// on a Calyx-owned file.
    func test_install_reinstallWithIdenticalContent_restoresDriftedMode() throws {
        let scriptPath = try ApprovalHookScript.install(toDirectory: tempDir)

        XCTAssertEqual(chmod(scriptPath, 0o644), 0, "precondition: simulate mode drift outside install()")

        var statBefore = stat()
        XCTAssertEqual(stat(scriptPath, &statBefore), 0)
        XCTAssertEqual(statBefore.st_mode & ~S_IFMT, 0o644, "precondition: mode must actually be drifted")

        _ = try ApprovalHookScript.install(toDirectory: tempDir)

        var statAfter = stat()
        XCTAssertEqual(stat(scriptPath, &statAfter), 0)
        XCTAssertEqual(statAfter.st_mode & ~S_IFMT, 0o755,
                       "a reinstall with byte-identical content must still restore the drifted mode to 0755")
    }
}
