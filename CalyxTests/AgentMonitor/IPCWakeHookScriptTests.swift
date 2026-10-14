//
//  IPCWakeHookScriptTests.swift
//  CalyxTests
//
//  Covers IPCWakeHookScript: the generated `calyx-ipc-wake-hook` /bin/sh
//  script (spec A.3 script listing, I10, I13, A.4). It long-polls
//  `POST /ipc-wake` with a fresh nonce and exits 2, with the note on
//  stderr, only when curl exited 0 AND the body is exactly two lines AND
//  line 2 matches `IPCWakeResponse.notePattern` in full AND the HMAC it
//  computes from the endpoint file's two blocks over nonce + "\n" + note
//  is 64 hex digits equal to line 1. Every other outcome is exit 0 with
//  nothing printed.
//
//  Two kinds of test:
//
//  1. String invariants over `IPCWakeHookScript.scriptBody`, read as
//     "executable lines": each line trimmed of whitespace, with blank
//     lines and `#` comment lines dropped (the shebang is such a line).
//     The one invariant that needs `IPCWakeResponse.notePattern` lives in
//     IPCWakeHookScriptPatternTests.
//  2. Behaviour, through FakeCurlScriptFixture: the installed script run
//     as a real `/bin/sh` child with a fake `curl` and a fake `uuidgen`
//     (fixed nonce) first on PATH, an endpoint file that carries the
//     blocks of a key the test knows, and, per test, recording wrappers
//     around the real tools or failing replacements for openssl, xxd or
//     grep. Expected proofs are computed in the test with CryptoKit
//     (IPCWakeTestCrypto). The child's TMPDIR is always a directory the
//     test owns.
//
//  Default expectation of a behaviour case: exit 0, stderr empty, stdout
//  empty, curl called once.
//

import XCTest
@testable import Calyx

final class IPCWakeHookScriptTests: XCTestCase {

    // MARK: - Properties

    private var tempDir: String!

    private let fixedNonce = "6F1C2A9E-0B7D-4E21-9A53-C4D8E7F00112"

    private let peerID = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!

    /// A real note, as `POST /ipc-wake` answers it.
    private var note: String {
        IPCWakeResponse(peerID: peerID, ticket: IPCWakeTicket(newCount: 1, senderCount: 1, unreadCount: 1)).note
    }

    /// Another valid note: 2 new messages from 2 peers.
    private var otherNote: String {
        IPCWakeResponse(peerID: peerID, ticket: IPCWakeTicket(newCount: 2, senderCount: 2, unreadCount: 2)).note
    }

    private let sampleStdin = #"{"hook_event_name":"Stop","session_id":"claude-1","stop_hook_active":true}"#

    private var paneEnv: [String: String] {
        ["CALYX_SURFACE_ID": "0E0C6C1B-5F0B-4C5E-9E3A-7C1B5D2F8A11"]
    }

    // MARK: - Lifecycle

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("IPCWakeHookScriptTests-" + UUID().uuidString).path
    }

    override func tearDown() {
        if let tempDir {
            try? FileManager.default.removeItem(atPath: tempDir)
        }
        tempDir = nil
        super.tearDown()
    }

    // MARK: - String helpers

    private var executableLines: [String] {
        IPCWakeHookScript.scriptBody
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    private var executableText: String {
        executableLines.joined(separator: "\n")
    }

    private func occurrences(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
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

    /// The executable lines of the curl command: the line starting with
    /// `curl ` and its backslash continuation lines, as written.
    private func curlLines(file: StaticString = #filePath, line: UInt = #line) throws -> [String] {
        let lines = executableLines
        var index = try firstIndex(of: "the curl invocation", file: file, line: line) { $0.hasPrefix("curl ") }
        var result: [String] = []
        while index < lines.count {
            result.append(lines[index])
            guard lines[index].hasSuffix("\\") else { break }
            index += 1
        }
        return result
    }

    /// The curl command joined into one string, continuation backslashes
    /// removed.
    private func curlCommand(file: StaticString = #filePath, line: UInt = #line) throws -> String {
        try curlLines(file: file, line: line)
            .map { $0.hasSuffix("\\") ? String($0.dropLast()).trimmingCharacters(in: .whitespaces) : $0 }
            .joined(separator: " ")
    }

    // MARK: - Behaviour helpers

    private typealias C = IPCWakeTestCrypto

    /// line 1 the proof under `key` over `nonce + "\n" + signedNote`, line
    /// 2 `bodyNote` (defaults to `signedNote`).
    private func signedBody(key: Data, nonce: String? = nil, note signedNote: String, bodyNote: String? = nil) -> Data {
        let proof = C.hmacHex(keyBytes: key, nonce: nonce ?? fixedNonce, note: signedNote)
        return Data((proof + "\n" + (bodyNote ?? signedNote)).utf8)
    }

    private enum TmpDirMode {
        case fresh
        case withSpace
        case regularFile
    }

    private struct WakeRun {
        let exitCode: Int32
        let stdout: String
        let stderr: String
        /// `ARGV curl ...` lines of the record directory.
        let curlInvocations: [String]
        /// Every record file concatenated (argv and env of every recorded
        /// tool, one file per invocation; see FakeCurlScriptFixture.swift).
        let record: String
        let tmpDir: String
        /// The entries of TMPDIR at the moment curl ran, nil when curl did
        /// not run.
        let entriesWhileCurlRan: [String]?
        /// The entries of TMPDIR after the script exited, nil when TMPDIR
        /// is not a directory.
        let entriesAfterExit: [String]?
        let fixture: FakeCurlScriptFixture
    }

    /// Builds a fixture whose endpoint file carries the blocks of
    /// `keyBytes` (nil: no blocks), a recording fake curl printing `body`
    /// and exiting `curlExitCode`, a fake uuidgen printing
    /// `uuidgenStdout` (nil: the real uuidgen, through a recording wrapper
    /// when `wrappers`), optional recording wrappers around the real tools,
    /// optional replacements; then runs the script once.
    private func runWakeScript(
        body: Data,
        keyBytes: Data?,
        env: [String: String]? = nil,
        curlExitCode: Int32 = 0,
        uuidgenStdout: String? = "6F1C2A9E-0B7D-4E21-9A53-C4D8E7F00112\n",
        uuidgenExitCode: Int32 = 0,
        wrappers: Bool = false,
        noise: Bool = false,
        replacements: [(name: String, exitCode: Int32, stdout: String)] = [],
        xxdIsCat: Bool = false,
        endpointText: String? = nil,
        removingEndpointFile: Bool = false,
        tmpDirMode: TmpDirMode = .fresh,
        kindArgument: String? = nil
    ) throws -> WakeRun {
        let fixture = try makeFakeCurlScriptFixture(
            rootDirectory: tempDir + "/" + UUID().uuidString,
            port: 41_834, token: "ipc-wake-hook-script-test-token",
            wakeKeyBytes: keyBytes,
            install: IPCWakeHookScript.install(toDirectory:)
        )
        let recordDirectory = fixture.rootDir + "/record.d"
        let listingPath = fixture.rootDir + "/tmp-listing-while-curl-ran.txt"
        let scriptTempDir = fixture.rootDir + (tmpDirMode == .withSpace ? "/script tmp" : "/script-tmp")
        if tmpDirMode == .regularFile {
            try Data("not a directory".utf8).write(to: URL(fileURLWithPath: scriptTempDir))
        } else {
            try FileManager.default.createDirectory(atPath: scriptTempDir, withIntermediateDirectories: true)
        }

        if wrappers || noise {
            try installRecordingWrappers(atDirectory: fixture.fakeBinDir, recordDirectory: recordDirectory, noise: noise)
        }
        try makeRecordingFakeCurl(
            atDirectory: fixture.fakeBinDir, recordDirectory: recordDirectory, stdoutBody: body, exitCode: curlExitCode,
            noise: noise, listDirectory: tmpDirMode == .regularFile ? nil : scriptTempDir, listingPath: listingPath
        )
        if let uuidgenStdout {
            try makeFakeUuidgen(
                atDirectory: fixture.fakeBinDir, stdout: uuidgenStdout, exitCode: uuidgenExitCode,
                recordDirectory: (wrappers || noise) ? recordDirectory : nil, noise: noise
            )
        }
        for replacement in replacements {
            try makeFailingTool(
                named: replacement.name, atDirectory: fixture.fakeBinDir,
                exitCode: replacement.exitCode, stdout: replacement.stdout
            )
        }
        if xxdIsCat {
            try writeFakeTool(named: "xxd", atDirectory: fixture.fakeBinDir, body: "exec /bin/cat")
        }
        if let endpointText {
            try Data(endpointText.utf8).write(to: URL(fileURLWithPath: fixture.endpointFilePath))
        }
        if removingEndpointFile {
            try FileManager.default.removeItem(atPath: fixture.endpointFilePath)
        }

        var childEnv = env ?? paneEnv
        childEnv["TMPDIR"] = scriptTempDir
        let result = try runFakeCurlHookScriptCapturingStderr(
            fixture, stdinJSON: sampleStdin, extraEnv: childEnv, kindArgument: kindArgument
        )

        let curlInvocations = recordedInvocations(of: "curl", inDirectory: recordDirectory)
        let listing = (try? String(contentsOfFile: listingPath, encoding: .utf8))
            .map { $0.split(separator: "\n").map(String.init) }
        return WakeRun(
            exitCode: result.exitCode, stdout: result.stdout, stderr: result.stderr,
            curlInvocations: curlInvocations,
            record: readRecordDirectory(recordDirectory),
            tmpDir: scriptTempDir,
            entriesWhileCurlRan: listing,
            entriesAfterExit: tmpDirMode == .regularFile
                ? nil : try FileManager.default.contentsOfDirectory(atPath: scriptTempDir),
            fixture: fixture
        )
    }

    /// Asserts the default "not a wake" outcome.
    private func assertNoWake(
        _ run: WakeRun, _ label: String, curlCalls: Int = 1,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(run.exitCode, 0, "[\(label)] must exit 0", file: file, line: line)
        XCTAssertEqual(run.stderr, "", "[\(label)] must print nothing on stderr", file: file, line: line)
        XCTAssertEqual(run.stdout, "", "[\(label)] must print nothing on stdout", file: file, line: line)
        XCTAssertEqual(run.curlInvocations.count, curlCalls, "[\(label)] curl invocations", file: file, line: line)
        if let after = run.entriesAfterExit {
            XCTAssertEqual(after, [String](), "[\(label)] no temp file may be left", file: file, line: line)
        }
    }

    /// The value of the header `name` in the one recorded curl argv.
    private func header(_ name: String, in run: WakeRun, file: StaticString = #filePath, line: UInt = #line) -> String? {
        guard let argv = run.curlInvocations.first else { return nil }
        let prefix = "[\(name): "
        guard let start = argv.range(of: prefix) else { return nil }
        let rest = argv[start.upperBound...]
        guard let end = rest.firstIndex(of: "]") else { return nil }
        return String(rest[..<end])
    }

    // MARK: - fileName and shebang

    func test_fileName_isCalyxIPCWakeHook() {
        XCTAssertEqual(IPCWakeHookScript.fileName, "calyx-ipc-wake-hook")
    }

    func test_scriptBody_startsWithTheShShebangLine() {
        XCTAssertTrue(IPCWakeHookScript.scriptBody.hasPrefix("#!/bin/sh\n"))
    }

    // MARK: - String invariants: exits and stderr

    func test_scriptBody_hasExactlyOneExit2_andEveryOtherExitIsExit0() throws {
        let lines = executableLines
        let text = executableText
        XCTAssertEqual(lines.filter { $0 == "exit 2" }.count, 1, "exactly one executable line is `exit 2`")
        XCTAssertEqual(occurrences(of: "exit 2", in: text), 1, "`exit 2` must not hide inside another line")

        let regex = try NSRegularExpression(pattern: #"(?<![A-Za-z0-9_])exit(?![A-Za-z0-9_])(?:[ \t]+([0-9]+))?"#)
        let nsText = text as NSString
        let statuses: [String?] = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length)).map {
            $0.range(at: 1).location == NSNotFound ? nil : nsText.substring(with: $0.range(at: 1))
        }
        XCTAssertEqual(statuses.filter { $0 == nil }.count, 0, "no bare `exit`")
        XCTAssertEqual(statuses.compactMap { $0 }.filter { $0 != "0" && $0 != "2" }, [String]())
        XCTAssertEqual(statuses.filter { $0 == "2" }.count, 1)
    }

    func test_scriptBody_firstExecutableLine_redirectsStderrToFd3AndSilencesIt() {
        XCTAssertEqual(executableLines.first, "exec 3>&2 2>/dev/null",
                       "stderr is saved on fd 3 and silenced before anything else runs")
    }

    func test_scriptBody_onlyTheNotePrintGoesToFd3_andTheNextLineIsExit2() throws {
        let lines = executableLines
        let fd3 = lines.indices.filter { lines[$0].contains(">&3") }
        XCTAssertEqual(fd3.count, 1, "exactly one executable line writes to fd 3. Got: \(fd3.map { lines[$0] })")
        let index = try XCTUnwrap(fd3.first)
        XCTAssertEqual(lines[index], #"printf '%s' "$note" >&3"#)
        XCTAssertEqual(lines.dropFirst(index + 1).first, "exit 2", "the line after the note print is `exit 2`")
    }

    func test_scriptBody_noExecutableLineOtherThanTheFirstWritesToFd2() {
        XCTAssertEqual(executableLines.dropFirst().filter { $0.contains(">&2") }, [String](),
                       "only the opening exec line may mention >&2")
    }

    func test_scriptBody_neverMentionsStopHookActiveInAnExecutableLine() {
        XCTAssertEqual(executableLines.filter { $0.contains("stop_hook_active") }, [String]())
    }

    // MARK: - String invariants: secrets and shell constructs

    func test_scriptBody_usesNoHereDocumentExportOrEval() throws {
        let regex = try NSRegularExpression(pattern: #"(?<![A-Za-z0-9_])(export|eval)(?![A-Za-z0-9_])"#)
        for line in executableLines {
            XCTAssertFalse(line.contains("<<"), "no here-document: \(line)")
            XCTAssertNil(regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                         "no export or eval: \(line)")
        }
    }

    func test_scriptBody_everyGrepLineIsLCAllCGrepEqx() {
        let grepLines = executableLines.filter { $0.contains("grep") }
        XCTAssertEqual(grepLines.count, 2, "two grep checks: the note shape and the 64-hex result. Got: \(grepLines)")
        for line in grepLines {
            XCTAssertTrue(line.contains("LC_ALL=C grep -Eqx '"), "every grep runs as `LC_ALL=C grep -Eqx '...'`: \(line)")
        }
    }

    func test_scriptBody_hexCheckLine_isExact() {
        XCTAssertTrue(executableLines.contains(
            #"if ! printf '%s\n' "$computed" | LC_ALL=C grep -Eqx '[0-9a-f]{64}'; then"#
        ), "the computed HMAC must be checked to be exactly 64 lowercase hex digits")
    }

    func test_scriptBody_blocksAppearOnlyInTheEmptyCheckOrAfterABuiltinPrintf() throws {
        let emptyCheck = #"if [ -z "$proof_inner" ] || [ -z "$proof_outer" ]; then"#
        XCTAssertTrue(executableLines.contains(emptyCheck))
        let regex = try NSRegularExpression(pattern: #"\$proof_(inner|outer)"#)
        for line in executableLines where line != emptyCheck {
            let ns = line as NSString
            for match in regex.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
                let before = ns.substring(to: match.range.location)
                XCTAssertTrue(before.hasSuffix(#"printf '%s' ""#),
                              "a block may only be handed to the builtin printf: \(line)")
            }
        }
        XCTAssertEqual(executableLines.filter { $0.contains("$proof_inner") }.count, 2)
        XCTAssertEqual(executableLines.filter { $0.contains("$proof_outer") }.count, 2)
    }

    func test_scriptBody_readsTheTwoBlocksWithSed() {
        XCTAssertTrue(executableLines.contains(
            #"proof_inner=$(sed -n 's/.*"wakeProofInner"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$endpoint_file")"#
        ))
        XCTAssertTrue(executableLines.contains(
            #"proof_outer=$(sed -n 's/.*"wakeProofOuter"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$endpoint_file")"#
        ))
    }

    // MARK: - String invariants: curl

    func test_scriptBody_curl_hasTheSpeccedFlags_fourHeaders_nonceLast() throws {
        XCTAssertEqual(executableLines.filter { $0.hasPrefix("curl ") }.count, 1)
        let command = try curlCommand()
        let tokens = command.split(separator: " ").map(String.init)
        XCTAssertTrue(tokens.contains("-s"), command)
        XCTAssertTrue(command.contains("-m \(IPCWakeHookTiming.curlTimeoutSeconds) "), command)
        XCTAssertTrue(command.contains("--max-filesize 1024 "), command)
        XCTAssertTrue(tokens.contains("--fail"), command)
        XCTAssertTrue(command.contains("-X POST"), command)
        let headers = try curlLines().filter { $0.hasPrefix("-H ") }
        XCTAssertEqual(headers, [
            #"-H "Authorization: Bearer $token" \"#,
            #"-H "X-Calyx-Surface-ID: ${CALYX_SESSION_ID:-$CALYX_SURFACE_ID}" \"#,
            #"-H "X-Calyx-Agent-Kind: $kind" \"#,
            #"-H "X-Calyx-Wake-Nonce: $nonce" \"#,
        ], "exactly four headers, the fourth carrying the nonce")
        XCTAssertEqual(occurrences(of: "-H ", in: command), 4)
        XCTAssertTrue(command.hasSuffix(#""http://127.0.0.1:$port/ipc-wake" > "$response_file" &"#), command)
        XCTAssertFalse(command.contains("--data") || tokens.contains("-d"), "no request body")
    }

    func test_scriptBody_maxFilesizeIsOnItsOwnLine() throws {
        let raw = IPCWakeHookScript.scriptBody.components(separatedBy: "\n").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        XCTAssertEqual(raw.filter { $0 == #"--max-filesize 1024 \"# }.count, 1,
                       "the curl command carries `--max-filesize 1024 \\` on its own line")
        XCTAssertEqual(try curlLines().dropFirst().first, #"--max-filesize 1024 \"#,
                       "right after the `curl -s -m ...` line")
    }

    // MARK: - String invariants: temp file and traps

    func test_scriptBody_mktempLine_isExact() throws {
        let mktempLines = executableLines.filter { $0.contains("mktemp") }
        XCTAssertEqual(mktempLines, [#"response_file=$(mktemp "${TMPDIR:-/tmp}/calyx-ipc-wake.XXXXXX") || exit 0"#])
    }

    func test_scriptBody_trapsExitAndTermHupInt_exactly() {
        let traps = executableLines.filter { $0.hasPrefix("trap ") }
        XCTAssertEqual(traps, [
            #"trap 'if [ -n "$response_file" ]; then rm -f "$response_file"; fi' EXIT"#,
            #"trap 'signalled=1; if [ -n "$curl_pid" ]; then kill "$curl_pid" 2>/dev/null; exit 0; fi' TERM HUP INT"#,
        ])
    }

    func test_scriptBody_uuidgenLines_areExact() {
        XCTAssertTrue(executableLines.contains("nonce=$(uuidgen) || exit 0"))
        XCTAssertTrue(executableLines.contains(#"nonce=$(printf '%s' "$nonce" | tr 'abcdef' 'ABCDEF')"#))
        XCTAssertTrue(executableLines.contains(#"if [ -z "$nonce" ]; then"#))
    }

    // MARK: - String invariants: order

    func test_scriptBody_runsItsStepsInTheSpeccedOrder() throws {
        let exec = try firstIndex(of: "the exec line") { $0 == "exec 3>&2 2>/dev/null" }
        let blockRead = try firstIndex(of: "the inner block read") { $0.hasPrefix("proof_inner=$(sed") }
        let responseFileInit = try firstIndex(of: "`response_file=`") { $0 == "response_file=" }
        let signalledInit = try firstIndex(of: "`signalled=0`") { $0 == "signalled=0" }
        let curlPIDInit = try firstIndex(of: "`curl_pid=`") { $0 == "curl_pid=" }
        let firstTrap = try firstIndex(of: "a trap") { $0.hasPrefix("trap ") }
        let exitTrap = try firstIndex(of: "the EXIT trap") { $0.hasPrefix("trap 'if") && $0.hasSuffix("' EXIT") }
        let termTrap = try firstIndex(of: "the TERM trap") {
            $0.hasPrefix("trap 'signalled") && $0.hasSuffix("' TERM HUP INT")
        }
        let drain = try firstIndex(of: "`cat > /dev/null`") { $0 == "cat > /dev/null" }
        let uuidgen = try firstIndex(of: "the uuidgen line") { $0.contains("uuidgen") }
        let mktemp = try firstIndex(of: "the mktemp line") { $0.contains("mktemp") }
        let curl = try firstIndex(of: "the curl line") { $0.hasPrefix("curl ") }
        let curlPIDAssign = try firstIndex(of: "`curl_pid=$!`") { $0 == "curl_pid=$!" }
        let wait = try firstIndex(of: "wait") { $0 == #"wait "$curl_pid""# }
        let curlExit = try firstIndex(of: "`curl_exit=$?`") { $0 == "curl_exit=$?" }
        let curlPIDReset = try firstIndex(of: "the `curl_pid=` reset", from: curlExit) { $0 == "curl_pid=" }
        let curlExitCheck = try firstIndex(of: "the curl exit check") { $0 == #"if [ "$curl_exit" != 0 ]; then"# }
        let firstRead = try firstIndex(of: "the first line reading the response file", from: curlExitCheck + 1) {
            $0.contains("$response_file")
        }
        let exit2 = try firstIndex(of: "`exit 2`") { $0 == "exit 2" }

        for (name, index) in [("response_file=", responseFileInit), ("signalled=0", signalledInit), ("curl_pid=", curlPIDInit)] {
            XCTAssertLessThan(blockRead, index, "the blocks are read before \(name)")
        }
        // Spec C.3 (G4) / J14: `response_file=` precedes the EXIT trap, and
        // AgentHookLongPoll.setup (signalled=0, curl_pid=, TERM trap) follows it.
        XCTAssertEqual(firstTrap, exitTrap, "the EXIT trap is the first trap")
        let initOrder: [(String, Int)] = [
            ("response_file=", responseFileInit), ("EXIT trap", exitTrap), ("signalled=0", signalledInit),
            ("curl_pid=", curlPIDInit), ("TERM trap", termTrap),
        ]
        for (earlier, later) in zip(initOrder, initOrder.dropFirst()) {
            XCTAssertEqual(earlier.1 + 1, later.1, "\(later.0) is the executable line right after \(earlier.0)")
        }
        let ordered: [(String, Int)] = [
            ("exec", exec), ("block read", blockRead), ("first trap", firstTrap), ("cat", drain),
            ("uuidgen", uuidgen), ("mktemp", mktemp), ("curl", curl), ("curl_pid=$!", curlPIDAssign),
            ("wait", wait), ("curl_exit=$?", curlExit), ("curl_pid= reset", curlPIDReset),
            ("curl exit check", curlExitCheck), ("first response read", firstRead), ("exit 2", exit2),
        ]
        for (earlier, later) in zip(ordered, ordered.dropFirst()) {
            XCTAssertLessThan(earlier.1, later.1, "\(earlier.0) must come before \(later.0)")
        }
        XCTAssertEqual(executableLines[firstRead], #"if [ "$(sed -n '$=' "$response_file")" != 2 ]; then"#,
                       "the first read of the response is the exact two-line check")
    }

    func test_scriptBody_curlExitCheckIsTheVeryNextLineAfterTheCurlPIDReset() throws {
        let curlExit = try firstIndex(of: "`curl_exit=$?`") { $0 == "curl_exit=$?" }
        let reset = try firstIndex(of: "the reset", from: curlExit) { $0 == "curl_pid=" }
        XCTAssertEqual(executableLines.dropFirst(reset + 1).first, #"if [ "$curl_exit" != 0 ]; then"#)
    }

    func test_scriptBody_signalledCheckSitsBetweenMktempAndCurl() throws {
        let lines = executableLines
        let mktemp = try firstIndex(of: "the mktemp call") { $0.contains("mktemp") }
        XCTAssertEqual(Array(lines.dropFirst(mktemp + 1).prefix(3)), [#"if [ "$signalled" = 1 ]; then"#, "exit 0", "fi"])
        XCTAssertTrue(lines.dropFirst(mktemp + 4).first?.hasPrefix("curl ") ?? false)
    }

    func test_scriptBody_recheckFollowsCurlPIDAssignment_andCurlExitFollowsWait() throws {
        let lines = executableLines
        let assign = try firstIndex(of: "`curl_pid=$!`") { $0 == "curl_pid=$!" }
        let wait = try firstIndex(of: "wait") { $0 == #"wait "$curl_pid""# }
        XCTAssertEqual(lines.dropFirst(assign + 1).first, #"if [ "$signalled" = 1 ]; then"#)
        XCTAssertEqual(lines.dropFirst(wait + 1).first, "curl_exit=$?")
    }

    // MARK: - Behaviour: a wake

    func test_run_signedBody_exitsTwo_stderrIsTheNote_stdoutEmpty() throws {
        let key = C.randomKeyBytes()
        let run = try runWakeScript(body: signedBody(key: key, note: note), keyBytes: key)

        XCTAssertEqual(run.exitCode, 2, "a body signed with the endpoint file's key wakes the pane")
        XCTAssertEqual(run.stderr, note, "stderr is the note byte for byte")
        XCTAssertEqual(run.stdout, "")
        XCTAssertEqual(run.curlInvocations.count, 1)
        XCTAssertEqual(header("X-Calyx-Wake-Nonce", in: run), fixedNonce, "the nonce header carries uuidgen's value")
        XCTAssertEqual(run.entriesAfterExit, [String](), "the temp file is gone")
    }

    func test_run_signedBody_onlySessionIDSet_exitsTwo() throws {
        let key = C.randomKeyBytes()
        let run = try runWakeScript(
            body: signedBody(key: key, note: note), keyBytes: key, env: ["CALYX_SESSION_ID": "calyx-session-7"]
        )

        XCTAssertEqual(run.exitCode, 2)
        XCTAssertEqual(run.stderr, note)
        XCTAssertEqual(header("X-Calyx-Surface-ID", in: run), "calyx-session-7")
    }

    // MARK: - Behaviour: not a wake

    func test_run_wrongProofs_exitZero() throws {
        let key = C.randomKeyBytes()
        let otherKey = C.randomKeyBytes()
        let randomProof = C.hex(C.randomKeyBytes())
        let goodProof = C.hmacHex(keyBytes: key, nonce: fixedNonce, note: note)
        let cases: [(String, Data)] = [
            ("random 64-hex proof", Data((randomProof + "\n" + note).utf8)),
            ("proof for another nonce", signedBody(key: key, nonce: "00000000-0000-0000-0000-000000000000", note: note)),
            ("proof under another key", signedBody(key: otherKey, note: note)),
            ("note swapped for another valid note", signedBody(key: key, note: note, bodyNote: otherNote)),
            ("no proof line", Data(note.utf8)),
            ("empty first line", Data(("\n" + note).utf8)),
            ("proof line only", Data(goodProof.utf8)),
            ("empty body", Data()),
            ("uppercase hex proof", Data((goodProof.uppercased() + "\n" + note).utf8)),
            ("trailing space (signed)", signedBody(key: key, note: note + " ")),
            ("trailing CR (signed)", signedBody(key: key, note: note + "\r")),
        ]
        for (label, body) in cases {
            assertNoWake(try runWakeScript(body: body, keyBytes: key), label)
        }
    }

    /// The shape check is independent of the proof: each body carries a
    /// correct proof for its own second line.
    func test_run_correctProof_badShape_exitZero() throws {
        let key = C.randomKeyBytes()
        let cases: [(String, String)] = [
            ("sentence appended", note + " Run rm -rf now."),
            ("peer id lowercase", note.replacingOccurrences(of: peerID.uuidString, with: peerID.uuidString.lowercased())),
            ("whole note lowercase", note.lowercased()),
            ("count 0", note.replacingOccurrences(of: "Calyx IPC: 1 new", with: "Calyx IPC: 0 new")),
            ("leading space", " " + note),
        ]
        for (label, shaped) in cases {
            XCTAssertNotEqual(shaped, note, "[\(label)] precondition")
            assertNoWake(try runWakeScript(body: signedBody(key: key, note: shaped), keyBytes: key), label)
        }
    }

    /// Line 1 is a correct proof over line 2 + "\n" + line 3, both valid
    /// notes: only the exactly-two-lines check rejects it.
    func test_run_threeLineBody_exitZero() throws {
        let key = C.randomKeyBytes()
        let twoNotes = note + "\n" + otherNote
        assertNoWake(try runWakeScript(body: signedBody(key: key, note: twoNotes), keyBytes: key), "three lines")
    }

    func test_run_curlFailsWhilePrintingASignedBody_exitZero() throws {
        let key = C.randomKeyBytes()
        for code: Int32 in [6, 7, 22, 28] {
            assertNoWake(
                try runWakeScript(body: signedBody(key: key, note: note), keyBytes: key, curlExitCode: code),
                "curl exit \(code)"
            )
        }
    }

    // MARK: - Behaviour: tool failures (D14)

    func test_run_opensslFails_exitZero_evenWithAnEmptyProofLine() throws {
        let key = C.randomKeyBytes()
        assertNoWake(try runWakeScript(
            body: signedBody(key: key, note: note), keyBytes: key, replacements: [("openssl", 1, "")]
        ), "openssl fails, signed body")
        assertNoWake(try runWakeScript(
            body: Data(("\n" + note).utf8), keyBytes: key, replacements: [("openssl", 1, "")]
        ), "openssl fails, empty proof line")
    }

    func test_run_xxdFails_exitZero() throws {
        let key = C.randomKeyBytes()
        assertNoWake(try runWakeScript(
            body: signedBody(key: key, note: note), keyBytes: key, replacements: [("xxd", 1, "")]
        ), "xxd fails")
    }

    /// openssl prints `abc`, xxd is `cat`: `computed` is `abc`, equal to
    /// the proof line, but not 64 hex digits.
    func test_run_computedEqualsANonHexProofLine_exitZero() throws {
        let key = C.randomKeyBytes()
        assertNoWake(try runWakeScript(
            body: Data(("abc\n" + note).utf8), keyBytes: key, replacements: [("openssl", 0, "abc\n")], xxdIsCat: true
        ), "computed == proof == abc")
    }

    func test_run_grepFails_exitZero() throws {
        let key = C.randomKeyBytes()
        assertNoWake(try runWakeScript(
            body: signedBody(key: key, note: note), keyBytes: key, replacements: [("grep", 2, "")]
        ), "grep fails")
    }

    // MARK: - Behaviour: uuidgen

    func test_run_uuidgenFailsOrPrintsNothing_neverRunsCurl() throws {
        let key = C.randomKeyBytes()
        let body = signedBody(key: key, note: note)
        assertNoWake(try runWakeScript(body: body, keyBytes: key, uuidgenStdout: "", uuidgenExitCode: 1),
                     "uuidgen exit 1", curlCalls: 0)
        assertNoWake(try runWakeScript(body: body, keyBytes: key, uuidgenStdout: "", uuidgenExitCode: 0),
                     "uuidgen empty output", curlCalls: 0)
    }

    func test_run_lowercaseUuidgen_isSentUppercase_andAnUppercaseSignatureWakes() throws {
        let key = C.randomKeyBytes()
        let run = try runWakeScript(
            body: signedBody(key: key, nonce: fixedNonce, note: note), keyBytes: key,
            uuidgenStdout: fixedNonce.lowercased() + "\n"
        )

        XCTAssertEqual(header("X-Calyx-Wake-Nonce", in: run), fixedNonce, "the nonce is upper-cased before it is sent")
        XCTAssertEqual(run.exitCode, 2, "the proof is checked against the upper-cased nonce")
        XCTAssertEqual(run.stderr, note)
    }

    // MARK: - Behaviour: endpoint file

    func test_run_endpointFileWithoutBlocks_neverRunsCurl() throws {
        let key = C.randomKeyBytes()
        assertNoWake(try runWakeScript(body: signedBody(key: key, note: note), keyBytes: nil),
                     "no blocks", curlCalls: 0)
    }

    func test_run_endpointFileWithOnlyOneBlock_neverRunsCurl() throws {
        let key = C.randomKeyBytes()
        let blocks = C.blocksHex(keyBytes: key)
        // pid/pidStart: the test host's own (C-D16), so the prologue's
        // liveness check passes and the missing block is what stops curl.
        let base = #""port":41834,"token":"ipc-wake-hook-script-test-token","pid":"#
            + String(TestHostLiveness.pid) + #","pidStart":""# + TestHostLiveness.startText + "\""
        for (label, text) in [
            ("only inner", "{" + base + #","wakeProofInner":""# + blocks.inner + "\"}"),
            ("only outer", "{" + base + #","wakeProofOuter":""# + blocks.outer + "\"}"),
        ] {
            assertNoWake(try runWakeScript(body: signedBody(key: key, note: note), keyBytes: key, endpointText: text),
                         label, curlCalls: 0)
        }
    }

    // MARK: - Behaviour: the prologue's guards

    func test_run_prologueGuards_neverRunCurl() throws {
        let key = C.randomKeyBytes()
        let body = signedBody(key: key, note: note)
        assertNoWake(try runWakeScript(body: body, keyBytes: key, env: [:]), "no surface or session id", curlCalls: 0)
        var herdr = paneEnv
        herdr["HERDR_PANE_ID"] = "herdr-pane-1"
        assertNoWake(try runWakeScript(body: body, keyBytes: key, env: herdr), "HERDR_PANE_ID", curlCalls: 0)
        var grok = paneEnv
        grok["GROK_HOOK_EVENT"] = "Stop"
        assertNoWake(try runWakeScript(body: body, keyBytes: key, env: grok), "GROK_HOOK_EVENT", curlCalls: 0)
        assertNoWake(try runWakeScript(body: body, keyBytes: key, removingEndpointFile: true),
                     "no endpoint file", curlCalls: 0)
    }

    // MARK: - Behaviour: secrets (I10, I13)

    func test_run_neitherBlockNorKeyAppearsInAnyRecordedArgvOrEnvironment() throws {
        let key = C.randomKeyBytes()
        let run = try runWakeScript(body: signedBody(key: key, note: note), keyBytes: key, wrappers: true)

        XCTAssertEqual(run.exitCode, 2, "precondition: the wrappers do not break the wake")
        XCTAssertEqual(run.stderr, note)
        for tool in ["sed", "tr", "uuidgen", "mktemp", "cat", "curl", "grep", "xxd", "openssl", "rm"] {
            XCTAssertFalse(recordedInvocations(of: tool, inDirectory: run.fixture.rootDir + "/record.d").isEmpty,
                           "precondition: \(tool) was recorded")
        }
        let blocks = C.blocksHex(keyBytes: key)
        let record = run.record.lowercased()
        XCTAssertFalse(record.contains(blocks.inner), "the inner block must not reach any argv or environment")
        XCTAssertFalse(record.contains(blocks.outer), "the outer block must not reach any argv or environment")
        XCTAssertFalse(record.contains(C.hex(key)), "the key must not appear either")
    }

    // MARK: - Behaviour: noise on stderr

    func test_run_noisyTools_stderrIsOnlyTheNote() throws {
        let key = C.randomKeyBytes()
        let wake = try runWakeScript(body: signedBody(key: key, note: note), keyBytes: key, noise: true)
        XCTAssertEqual(wake.exitCode, 2)
        XCTAssertEqual(wake.stderr, note, "tools printing to stderr must not reach the hook's stderr")
        XCTAssertTrue(wake.record.contains("ARGV curl"), "precondition: the noisy fake curl ran")

        let noWake = try runWakeScript(body: signedBody(key: C.randomKeyBytes(), note: note), keyBytes: key, noise: true)
        assertNoWake(noWake, "noisy tools, wrong key")
    }

    // MARK: - Behaviour: the temp file

    private func assertOneScriptTempFile(_ entries: [String]?, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(entries?.map { $0.hasPrefix("calyx-ipc-wake.") }, [true],
                       "while curl runs, TMPDIR holds exactly the script's one temp file. Got: \(entries ?? [])",
                       file: file, line: line)
    }

    func test_run_wake_keepsOneTempFileWhileCurlRuns_andRemovesIt() throws {
        let key = C.randomKeyBytes()
        let run = try runWakeScript(body: signedBody(key: key, note: note), keyBytes: key)
        XCTAssertEqual(run.exitCode, 2)
        assertOneScriptTempFile(run.entriesWhileCurlRan)
        XCTAssertEqual(run.entriesAfterExit, [String]())
    }

    func test_run_noWake_keepsOneTempFileWhileCurlRuns_andRemovesIt() throws {
        let key = C.randomKeyBytes()
        let run = try runWakeScript(body: Data(), keyBytes: key)
        assertNoWake(run, "empty body")
        assertOneScriptTempFile(run.entriesWhileCurlRan)
    }

    func test_run_TMPDIRWithASpace_works() throws {
        let key = C.randomKeyBytes()
        let run = try runWakeScript(body: signedBody(key: key, note: note), keyBytes: key, tmpDirMode: .withSpace)
        XCTAssertEqual(run.exitCode, 2)
        XCTAssertEqual(run.stderr, note)
        assertOneScriptTempFile(run.entriesWhileCurlRan)
        XCTAssertEqual(run.entriesAfterExit, [String]())
    }

    func test_run_mktempFails_neverRunsCurl() throws {
        let key = C.randomKeyBytes()
        let run = try runWakeScript(body: signedBody(key: key, note: note), keyBytes: key, tmpDirMode: .regularFile)
        assertNoWake(run, "mktemp fails", curlCalls: 0)
    }
}
