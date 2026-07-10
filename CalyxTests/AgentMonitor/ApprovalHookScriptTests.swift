//
//  ApprovalHookScriptTests.swift
//  CalyxTests
//
//  TDD Red Phase for ApprovalHookScript: the `calyx-approval-hook` script
//  installed alongside `calyx-agent-hook` (see AgentHookScriptTests.swift,
//  which this mirrors). Unlike calyx-agent-hook's fire-and-forget async
//  POST, this script is invoked *synchronously* by a PreToolUse hook entry
//  and its stdout becomes Claude Code's / Codex's actual permission
//  decision -- so its fail-safe behavior (never printing "allow", always
//  exiting 0) is the single most safety-critical string invariant in this
//  file.
//
//  Coverage:
//  - scriptBody guards on both CALYX_SURFACE_ID and CALYX_SESSION_ID being
//    unset, reads agent-endpoint.json, sends the required headers
//  - curl is bounded by ApprovalHookTiming.curlTimeoutSeconds (585) and
//    uses --fail so a non-2xx response is treated as a curl error
//  - a successful response body is printed verbatim via printf '%s'
//  - fail_safe() prints the exact "ask" JSON for claude-code, prints
//    nothing for any other kind, and scriptBody never contains a
//    fabricated "allow" decision anywhere
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
                     "(routed to fail_safe), never printed to Claude Code as if it were a real decision")
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
        // code (7): it must produce no output at all, unlike every other
        // curl failure (which routes through fail_safe).
        guard let branchRange = body.range(of: #"7\)[\s\S]*?;;"#, options: .regularExpression) else {
            XCTFail("Script must have a case branch matching curl's connection-refused exit code (7)")
            return
        }
        let branch = String(body[branchRange])

        XCTAssertFalse(branch.contains("printf"),
                       "curl exit 7 (connection refused / stale endpoint file after a crash) must " +
                       "produce NO output")
        XCTAssertFalse(branch.contains("fail_safe"),
                       "curl exit 7 must not invoke fail_safe -- it is the one failure mode that stays silent")
    }

    // MARK: - scriptBody: fail_safe()

    func test_scriptBody_failSafe_claudePrintsAskJSON() {
        let body = ApprovalHookScript.scriptBody
        let expectedJSON = "{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"permissionDecision\":\"ask\"," +
            "\"permissionDecisionReason\":\"Calyx approval inbox unavailable\"}}"

        XCTAssertTrue(body.contains(expectedJSON),
                     "fail_safe() must print the exact ask-JSON literal for claude-code so a lost " +
                     "connection surfaces as an interactive approval prompt, never a silent bypass")
        XCTAssertTrue(body.contains("\"permissionDecision\":\"ask\""))
    }

    func test_scriptBody_failSafe_onlyPrintsForClaudeCodeKind() {
        let body = ApprovalHookScript.scriptBody

        guard let fnNameRange = body.range(of: "fail_safe()") else {
            XCTFail("Script must define a fail_safe() function")
            return
        }
        guard let openBrace = body.range(of: "{", range: fnNameRange.upperBound..<body.endIndex) else {
            XCTFail("fail_safe() must have a function body")
            return
        }
        guard let closeBrace = body.range(of: "\n}", range: openBrace.upperBound..<body.endIndex) else {
            XCTFail("fail_safe()'s function body must be closed with a matching '}'")
            return
        }
        let fnBody = String(body[openBrace.upperBound..<closeBrace.lowerBound])

        XCTAssertTrue(fnBody.contains("claude-code"),
                     "fail_safe must special-case kind == claude-code -- other kinds (codex, opencode) " +
                     "print nothing")
        XCTAssertTrue(fnBody.contains("printf"),
                     "fail_safe must print the ask-JSON body via printf when kind is claude-code")
    }

    func test_scriptBody_failSafe_neverPrintsAllow() {
        XCTAssertFalse(ApprovalHookScript.scriptBody.contains("permissionDecision\":\"allow"),
                      "The script must never fabricate an 'allow' decision anywhere -- a lost " +
                      "connection or any unexpected curl failure must fail closed (ask), not open")
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
}
