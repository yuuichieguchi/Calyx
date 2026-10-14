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
//  - a successful, correctly signed response body is printed byte for
//    byte (the body after the proof line)
//  - every curl failure path (any exit code other than 0/success,
//    including 7/connection-refused) produces NO stdout output at all, verified by running the
//    installed script as a real child process against a fake curl on
//    PATH -- PermissionRequest has no interactive fallback body the way
//    the old PreToolUse "ask" contract did, so a lost connection or
//    unexpected curl failure must stay completely silent and let the
//    CLI's own confirmation prompt take over
//  - scriptBody never references the retired permissionDecision field
//    name, and never fabricates an "allow" decision anywhere
//  - curl exit 7 (connection refused / stale endpoint file) is silent
//  - every exit path in the script is exit 0
//  - spec C.3 (G4), slice 1: `exec 2>/dev/null` first, one EXIT trap
//    removing both templated temp files, the shared long-poll lines
//  - spec C.3 (G3), slice 2: the nonce is sent as the fifth header,
//    `--max-filesize 1048641`, and the verification tail of the spec
//    listing replaces `response=$(cat ...)` and the `case`; stdout is
//    written by the final `tail -c +66 "$response_file"` only
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
        let body = ApprovalHookScript.scriptBody

        // NOT --data-binary @-: curl runs backgrounded (see
        // test_scriptBody_curlRunsBackgroundedWithTrapAndWait below), and a
        // backgrounded command's stdin is NOT the script's own by default
        // under POSIX sh job-control rules -- empirically confirmed to
        // silently post an EMPTY body. Stdin is drained into its own temp
        // file first (`cat > "$payload_file"`) and curl reads it back via
        // `--data-binary @"$payload_file"` instead.
        XCTAssertFalse(body.contains("--data-binary @-"),
                       "Script must NOT use --data-binary @- once curl is backgrounded -- a backgrounded " +
                       "command does not inherit the script's own stdin under POSIX sh job control, so this " +
                       "would silently post an empty body")
        XCTAssertTrue(body.contains("cat > \"$payload_file\""),
                     "Script must drain stdin into its own temp file before backgrounding curl")
        XCTAssertTrue(body.contains("--data-binary @\"$payload_file\""),
                     "Backgrounded curl must forward the hook's stdin JSON verbatim via the drained temp file")
    }

    // MARK: - Executable-line helpers

    /// The lines of scriptBody a shell would execute: each line trimmed of
    /// whitespace, with blank lines and `#` comment lines dropped (the
    /// shebang is such a line). Order is preserved.
    private var executableLines: [String] {
        ApprovalHookScript.scriptBody
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    private func firstIndex(
        of description: String,
        from start: Int = 0,
        file: StaticString = #filePath,
        line: UInt = #line,
        where predicate: (String) -> Bool
    ) throws -> Int {
        let lines = executableLines
        let found = start <= lines.count ? lines[start...].firstIndex(where: predicate) : nil
        return try XCTUnwrap(
            found, "the script must have an executable line that is \(description)", file: file, line: line
        )
    }

    /// The EXIT trap of spec C.3 (G4): one trap removes both temp files on
    /// every exit path, the TERM trap's `exit 0` included.
    private let exitTrapLine =
        #"trap 'if [ -n "$payload_file" ]; then rm -f "$payload_file"; fi; if [ -n "$response_file" ]; then rm -f "$response_file"; fi' EXIT"#

    /// The TERM/HUP/INT trap of `AgentHookLongPoll.setup`: no `rm -f`, the
    /// EXIT trap removes the files.
    private let termTrapLine =
        #"trap 'signalled=1; if [ -n "$curl_pid" ]; then kill "$curl_pid" 2>/dev/null; exit 0; fi' TERM HUP INT"#

    private let payloadMktempLine =
        #"payload_file=$(mktemp "${TMPDIR:-/tmp}/calyx-approval-payload.XXXXXX") || exit 0"#

    private let responseMktempLine =
        #"response_file=$(mktemp "${TMPDIR:-/tmp}/calyx-approval-response.XXXXXX") || exit 0"#

    // MARK: - scriptBody: stderr (J10)

    func test_scriptBody_firstExecutableLine_discardsStderr() {
        XCTAssertEqual(executableLines.first, "exec 2>/dev/null",
                       "J10: the first executable line discards stderr, so tool noise and shell " +
                       "'command not found' messages never reach the CLI")
        XCTAssertEqual(executableLines.filter { $0.hasPrefix("exec ") }, ["exec 2>/dev/null"],
                       "exactly one exec line")
    }

    // MARK: - scriptBody: curl backgrounded with trap + wait (orphan-curl fix)

    /// R-orphan-curl fix-pin: when Claude Code kills this script's own
    /// `/bin/sh` process (e.g. SIGTERM, because the user answered the SAME
    /// permission prompt directly in the CLI while this script was still
    /// blocked in its long-poll), a FOREGROUNDED `curl` would survive as an
    /// orphan and keep its long-poll connection open until its own `-m`
    /// deadline. Backgrounding curl (`&`) and trapping TERM/HUP/INT to kill
    /// its pid closes that gap. Spec C.3 (G4): the TERM trap no longer
    /// removes the temp files itself; the EXIT trap does on every path.
    func test_scriptBody_curlRunsBackgroundedWithTrapAndWait() throws {
        let lines = executableLines

        XCTAssertEqual(lines.filter { $0.hasPrefix("trap ") }, [exitTrapLine, termTrapLine],
                       "exactly two traps: the EXIT trap removing both temp files, then the TERM/HUP/INT " +
                       "trap that kills curl and exits 0 without any rm -f of its own")
        XCTAssertEqual(lines.filter { $0 == "curl_pid=$!" }.count, 1,
                       "Script must capture the backgrounded curl's own pid for the trap to kill")

        let assign = try firstIndex(of: "`curl_pid=$!`") { $0 == "curl_pid=$!" }
        XCTAssertEqual(Array(lines.dropFirst(assign + 1).prefix(7)), [
            #"if [ "$signalled" = 1 ]; then"#,
            #"kill "$curl_pid" 2>/dev/null"#,
            "exit 0",
            "fi",
            #"wait "$curl_pid""#,
            "curl_exit=$?",
            "curl_pid=",
        ], "the re-check right after curl_pid=$! kills curl and exits 0 (no rm -f: the EXIT trap removes " +
           "the files), then wait, curl_exit=$? and the curl_pid= reset follow")

        let urlLine = try firstIndex(of: "the backgrounded URL line") {
            $0.hasSuffix(#"> "$response_file" &"#)
        }
        XCTAssertEqual(lines[urlLine], #""http://127.0.0.1:$port/approval-request" > "$response_file" &"#,
                       "curl must run BACKGROUNDED (trailing &), writing its response to a temp file")
        XCTAssertEqual(lines.dropFirst(urlLine + 1).first, "curl_pid=$!",
                       "the line after the &-terminated URL line is curl_pid=$!")
    }

    func test_scriptBody_initsAndTrapsAreAdjacentInTheSpeccedOrder() throws {
        let lines = executableLines
        let start = try firstIndex(of: "`payload_file=`") { $0 == "payload_file=" }
        XCTAssertEqual(Array(lines.dropFirst(start).prefix(6)), [
            "payload_file=",
            "response_file=",
            exitTrapLine,
            "signalled=0",
            "curl_pid=",
            termTrapLine,
        ], "both file variables are emptied, the EXIT trap is set, then AgentHookLongPoll.setup " +
           "(signalled=0, curl_pid=, TERM trap) follows, so no trap ever reads an inherited value")
    }

    func test_scriptBody_usesSeparateTemplatedTempFilesForPayloadAndResponse() {
        XCTAssertEqual(executableLines.filter { $0.contains("mktemp") }, [payloadMktempLine, responseMktempLine],
                       "two templated mktemp calls under ${TMPDIR:-/tmp}, payload first, each failing safe " +
                       "with || exit 0 (the EXIT trap removes whatever was created)")
    }

    func test_scriptBody_rmOnlyAppearsInTheExitTrap() {
        XCTAssertEqual(executableLines.filter { $0.contains("rm -f") }, [exitTrapLine],
                       "the only rm -f is the EXIT trap's; no explicit rm -f \"$payload_file\" \"$response_file\" " +
                       "remains on any path")
        XCTAssertFalse(ApprovalHookScript.scriptBody.contains(#"rm -f "$payload_file" "$response_file""#))
    }

    func test_scriptBody_signalledCheckSitsRightBeforeCurl() throws {
        let lines = executableLines
        let curl = try firstIndex(of: "the curl line") { $0.hasPrefix("curl ") }
        XCTAssertGreaterThanOrEqual(curl, 3)
        XCTAssertEqual(Array(lines[(curl - 3)..<curl]), [#"if [ "$signalled" = 1 ]; then"#, "exit 0", "fi"],
                       "AgentHookLongPoll.guardBeforeCurl sits right before the curl line, so a signal " +
                       "received during cat never starts curl")
    }

    func test_scriptBody_readsBlocksComputesNonceAndSendsItAsTheFifthHeader() throws {
        let lines = executableLines
        XCTAssertEqual(lines.filter { $0.hasPrefix("proof_inner=") || $0.hasPrefix("proof_outer=") }, [
            #"proof_inner=$(sed -n 's/.*"wakeProofInner"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$endpoint_file")"#,
            #"proof_outer=$(sed -n 's/.*"wakeProofOuter"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$endpoint_file")"#,
        ])
        XCTAssertTrue(lines.contains(#"if [ -z "$proof_inner" ] || [ -z "$proof_outer" ]; then"#))
        XCTAssertTrue(lines.contains("nonce=$(uuidgen) || exit 0"))
        XCTAssertTrue(lines.contains(#"nonce=$(printf '%s' "$nonce" | tr 'abcdef' 'ABCDEF')"#))
        XCTAssertTrue(lines.contains(#"if [ -z "$nonce" ]; then"#))
        XCTAssertEqual(lines.filter { $0.hasPrefix("-H ") }, [
            #"-H "Authorization: Bearer $token" \"#,
            #"-H "X-Calyx-Surface-ID: ${CALYX_SESSION_ID:-$CALYX_SURFACE_ID}" \"#,
            #"-H "X-Calyx-Agent-Kind: $kind" \"#,
            #"-H "Content-Type: application/json" \"#,
            #"-H "X-Calyx-Approval-Nonce: $nonce" \"#,
        ], "five headers, the nonce header fifth (spec C.3 G3)")
    }

    func test_scriptBody_curlCapsTheResponseAtTheSignedMaximum() throws {
        let lines = executableLines
        let curl = try firstIndex(of: "the curl line") { $0.hasPrefix("curl ") }
        let url = try firstIndex(of: "the URL line") { $0.hasSuffix(#"> "$response_file" &"#) }
        let maxFilesize = lines.indices.filter { lines[$0].contains("--max-filesize") }
        XCTAssertEqual(maxFilesize.count, 1, "one --max-filesize option")
        if let index = maxFilesize.first {
            XCTAssertEqual(lines[index], #"--max-filesize 1048641 \"#,
                           "65 + 4 * 262144 (spec C-D9), on its own continuation line")
            XCTAssertTrue(curl < index && index < url, "the option belongs to the curl command")
        }
    }

    /// The executable lines after afterCurl's final `curl_pid=` reset, as
    /// listed in spec C.3 (G3), to the end of the script.
    private let verificationTail: [String] = [
        #"if [ "$curl_exit" != 0 ]; then"#,
        "exit 0",
        "fi",
        #"proof=$(head -c 64 "$response_file")"#,
        #"if ! printf '%s\n' "$proof" | LC_ALL=C grep -Eqx '[0-9a-f]{64}'; then"#,
        "exit 0",
        "fi",
        #"if [ "$(head -c 65 "$response_file" | tail -c 1 | xxd -p)" != "0a" ]; then"#,
        "exit 0",
        "fi",
        "computed=$(",
        "{",
        #"printf '%s' "$proof_outer" | xxd -r -p"#,
        "{",
        #"printf '%s' "$proof_inner" | xxd -r -p"#,
        #"printf 'approval\n%s\n' "$nonce""#,
        #"tail -c +66 "$response_file""#,
        "} | openssl dgst -sha256 -binary",
        "} | openssl dgst -sha256 -binary | xxd -p -c 64",
        ")",
        #"if ! printf '%s\n' "$computed" | LC_ALL=C grep -Eqx '[0-9a-f]{64}'; then"#,
        "exit 0",
        "fi",
        #"if [ "$computed" != "$proof" ]; then"#,
        "exit 0",
        "fi",
        #"tail -c +66 "$response_file""#,
        "exit 0",
    ]

    func test_scriptBody_endsWithTheVerificationTail_rightAfterAfterCurl() throws {
        let lines = executableLines
        let reset = try XCTUnwrap(lines.lastIndex(of: "curl_pid="), "afterCurl's curl_pid= reset")
        XCTAssertEqual(Array(lines[(reset + 1)...]), verificationTail,
                       "spec C.3 (G3): the curl_exit check follows afterCurl at once, then the proof checks, " +
                       "and the final tail is the only stdout write")
    }

    func test_scriptBody_responseNeverEntersAShellVariable() {
        let body = ApprovalHookScript.scriptBody
        XCTAssertFalse(body.contains("response=$(cat"), "C-D10: the body is never read into a variable")
        XCTAssertFalse(body.contains(#"printf '%s' "$response""#))
        XCTAssertFalse(body.contains(#"case "$curl_exit""#), "the case on curl_exit is gone")
        XCTAssertFalse(executableLines.contains { $0.contains("$response\"") || $0.hasPrefix("response=") })
        XCTAssertFalse(body.contains("sed -n '$='"), "C-D10: byte positions, not line counts")
    }

    func test_scriptBody_responseFileIsReadOnlyByHeadAndTail() {
        let readers = executableLines.filter { $0.contains(#""$response_file""#) && !$0.hasPrefix("response_file=") }
        for line in readers where !line.hasPrefix("trap ") && !line.hasSuffix(#"> "$response_file" &"#) {
            XCTAssertTrue(line.contains(#"head -c"#) || line.contains(#"tail -c +66"#),
                          "the response file is read only by head -c and tail -c +66. Found: \(line)")
        }
        XCTAssertEqual(executableLines.filter { $0 == #"tail -c +66 "$response_file""# }.count, 2,
                       "one tail feeds the HMAC, the other is the final stdout write")
    }

    func test_scriptBody_everyGrepIsLocaleFixedExtendedQuietWholeLine() {
        let greps = executableLines.filter { $0.contains("grep") }
        XCTAssertEqual(greps.count, 2, "the proof and the computed HMAC are each checked once")
        for line in greps {
            XCTAssertTrue(line.contains("LC_ALL=C grep -Eqx '[0-9a-f]{64}'"), "found: \(line)")
        }
    }

    func test_scriptBody_keyBlocksOnlyTravelThroughPrintfPipes() {
        for variable in ["$proof_inner", "$proof_outer"] {
            for line in executableLines where line.contains(variable) {
                let allowed = line.hasPrefix(String(variable.dropFirst()) + "=$(sed ")
                    || line == #"if [ -z "$proof_inner" ] || [ -z "$proof_outer" ]; then"#
                    || line == "printf '%s' \"\(variable)\" | xxd -r -p"
                XCTAssertTrue(allowed, "\(variable) may appear only after printf '%s' \" (or its sed read and " +
                              "empty check). Found: \(line)")
            }
        }
    }

    func test_scriptBody_hasNoHeredocExportOrEval() {
        for line in executableLines {
            XCTAssertFalse(line.contains("<<"), "no heredoc. Found: \(line)")
            XCTAssertFalse(line.hasPrefix("export ") || line.contains(" export "), "no export. Found: \(line)")
            XCTAssertFalse(line.hasPrefix("eval ") || line.contains(" eval "), "no eval. Found: \(line)")
        }
    }

    func test_scriptBody_hasNoExitTwo() {
        XCTAssertFalse(executableLines.contains { $0.hasPrefix("exit") && $0 != "exit 0" },
                       "the approval hook never exits with another status")
        XCTAssertFalse(executableLines.contains("exit 2"))
    }

    func test_scriptBody_runsItsStepsInTheSpeccedOrder() throws {
        let steps: [(String, (String) -> Bool)] = [
            ("exec 2>/dev/null", { $0 == "exec 2>/dev/null" }),
            ("the prologue's first guard", { $0.hasPrefix(#"if [ -z "$CALYX_SURFACE_ID" ]"#) }),
            ("the port/token empty check", { $0 == #"if [ -z "$port" ] || [ -z "$token" ]; then"# }),
            ("payload_file=", { $0 == "payload_file=" }),
            ("response_file=", { $0 == "response_file=" }),
            ("the EXIT trap", { $0.hasSuffix("' EXIT") }),
            ("signalled=0", { $0 == "signalled=0" }),
            ("the TERM trap", { $0.hasSuffix("' TERM HUP INT") }),
            ("the payload mktemp", { $0.contains("calyx-approval-payload.") }),
            ("the response mktemp", { $0.contains("calyx-approval-response.") }),
            ("cat > \"$payload_file\"", { $0 == #"cat > "$payload_file""# }),
            ("the inner block read", { $0.hasPrefix("proof_inner=$(sed") }),
            ("the uuidgen line", { $0 == "nonce=$(uuidgen) || exit 0" }),
            ("the signalled guard", { $0 == #"if [ "$signalled" = 1 ]; then"# }),
            ("curl", { $0.hasPrefix("curl ") }),
            ("curl_pid=$!", { $0 == "curl_pid=$!" }),
            ("wait", { $0 == #"wait "$curl_pid""# }),
            ("curl_exit=$?", { $0 == "curl_exit=$?" }),
            ("the curl_pid= reset", { $0 == "curl_pid=" }),
            ("the curl_exit check", { $0 == #"if [ "$curl_exit" != 0 ]; then"# }),
            ("proof=$(head -c 64", { $0 == #"proof=$(head -c 64 "$response_file")"# }),
            ("the proof grep", { $0.hasPrefix(#"if ! printf '%s\n' "$proof" | LC_ALL=C grep -Eqx"#) }),
            ("the LF check", { $0.contains(#"| tail -c 1 | xxd -p)" != "0a" ]"#) }),
            ("computed=$(", { $0 == "computed=$(" }),
            ("the computed grep", { $0.hasPrefix(#"if ! printf '%s\n' "$computed" | LC_ALL=C grep -Eqx"#) }),
            ("the HMAC comparison", { $0 == #"if [ "$computed" != "$proof" ]; then"# }),
            ("the final tail", { $0 == #"tail -c +66 "$response_file""# }),
        ]
        var previous = -1
        var previousName = "start"
        for (name, predicate) in steps {
            let index = try firstIndex(of: name, from: previous + 1, where: predicate)
            XCTAssertGreaterThan(index, previous, "\(previousName) must come before \(name)")
            previous = index
            previousName = name
        }
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

    func test_scriptBody_printsTheVerifiedBodyWithTailNotPrintf() {
        XCTAssertFalse(executableLines.contains { $0.contains("echo") },
                       "nothing is printed with echo, which can mangle a body starting with '-'")
        XCTAssertEqual(Array(executableLines.suffix(2)), [#"tail -c +66 "$response_file""#, "exit 0"],
                       "the verified body is copied byte for byte by the last command before exit 0")
    }

    func test_scriptBody_noUnpipedPrintf_noStdoutBeforeTheCurlExitCheck() throws {
        let unpipedPrints = executableLines.filter {
            ($0.contains("printf") || $0.contains("echo")) && !$0.contains("|")
        }
        XCTAssertEqual(unpipedPrints, [#"printf 'approval\n%s\n' "$nonce""#],
                       "the only unpiped printf is the HMAC message prefix, inside the computed=$( group " +
                       "whose output is piped into openssl")
        let check = try firstIndex(of: "the curl_exit check") { $0 == #"if [ "$curl_exit" != 0 ]; then"# }
        XCTAssertFalse(executableLines[..<check].contains { $0.contains("head -c") || $0.contains("tail -c") },
                       "the response file is not read before curl's exit status is checked")
    }

    /// Success path by real execution: a one-line JSON body from curl
    /// (exit 0) is printed byte for byte, and both temp files are gone.
    func test_run_curlSucceeds_signedBody_printsTheBodyByteForByte() throws {
        let body = #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"a \\ b -n"}}}"#
        let nonce = "6F1C2A9E-0B7D-4E21-9A53-C4D8E7F00112"
        let fixture = try makeFakeCurlScriptFixture(
            rootDirectory: tempDir + "/success", port: 41_833, token: "success-path-test-token",
            install: ApprovalHookScript.install(toDirectory:)
        )
        let keyBytes = try XCTUnwrap(fixture.wakeKeyBytes)
        let proof = IPCWakeTestCrypto.hmacHex(keyBytes: keyBytes, message: Data(("approval\n" + nonce + "\n" + body).utf8))
        try makeFakeCurl(atDirectory: fixture.fakeBinDir, exitCode: 0, stdoutBody: proof + "\n" + body)
        try makeFakeUuidgen(atDirectory: fixture.fakeBinDir, stdout: nonce + "\n")
        let scriptTmp = fixture.rootDir + "/script-tmp"
        try FileManager.default.createDirectory(atPath: scriptTmp, withIntermediateDirectories: true)

        let result = try runFakeCurlHookScript(
            fixture, stdinJSON: #"{"tool_name":"Bash","tool_input":{"command":"ls"}}"#,
            extraEnv: ["CALYX_SURFACE_ID": UUID().uuidString, "TMPDIR": scriptTmp]
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, body, "the body after the proof line is printed verbatim, no newline added")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: scriptTmp), [String](),
                       "both temp files are created under TMPDIR and removed on exit")
    }

    func test_scriptBody_noCaseOnCurlExit_everyNonZeroExitLeavesAtOnce() throws {
        // Connection refused (7) has no arm of its own any more: every
        // non-zero curl exit takes the same `exit 0` right after afterCurl.
        let body = ApprovalHookScript.scriptBody
        XCTAssertNil(body.range(of: #"7\)[\s\S]*?;;"#, options: .regularExpression), "no case arm for exit 7")
        XCTAssertFalse(executableLines.contains { $0.hasPrefix("case ") || $0 == "esac" })
        let check = try firstIndex(of: "the curl_exit check") { $0 == #"if [ "$curl_exit" != 0 ]; then"# }
        XCTAssertEqual(Array(executableLines.dropFirst(check + 1).prefix(2)), ["exit 0", "fi"])
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
