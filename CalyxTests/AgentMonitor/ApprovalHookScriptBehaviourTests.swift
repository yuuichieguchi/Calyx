//
//  ApprovalHookScriptBehaviourTests.swift
//  CalyxTests
//
//  Behaviour of `calyx-approval-hook`'s verification tail (spec C.2 J7,
//  J10; C.3 G3; C-D4 silence for every kind; C-D10 byte slicing), run as a
//  real `/bin/sh` child against a recording fake curl that prints a chosen
//  response body and exits with a chosen code, and a fake uuidgen with a
//  fixed nonce (FakeCurlScriptFixture.swift). Expected outputs are
//  computed here with CryptoKit (IPCWakeTestCrypto) over
//  "approval\n" + nonce + "\n" + body under the key whose blocks the
//  fixture wrote into agent-endpoint.json.
//
//  Default expectations of every run: exit 0, stderr empty, the test-owned
//  TMPDIR empty afterwards (both temp files removed), curl run once.
//
//  Coverage:
//  - a correctly signed body is printed byte for byte (allow, deny, 300
//    KiB, CR, quotes, backslashes, `$`, backticks, `%`, leading `-`,
//    several lines), for claude-code (no argument), codex and grok
//  - a signed empty body prints nothing, yet passes verification (the
//    final `tail -c +66` runs, observed through a recording `tail`)
//  - nothing is printed for: an unsigned allow (a port squatter), a
//    tampered body, a proof for another nonce, another key, upper-case
//    hex, no LF after the proof, a 64-byte body, a proof covering only
//    the first of three lines, a wake-domain proof
//  - curl 6/7/22/28/63 with a signed body print nothing
//  - a failing openssl, xxd, grep, head or tail prints nothing; a grep
//    that always succeeds does not turn an unsigned body into output
//  - key blocks missing or uuidgen failing: curl never runs
//  - secrecy: neither block nor the key appears in any recorded argv or
//    environment
//  - noise on every tool's stderr: stdout unchanged, stderr empty
//  - curl's argv carries `--max-filesize 1048641` and the nonce header;
//    a lower-case uuidgen output is sent and verified upper-case
//

import XCTest
@testable import Calyx

final class ApprovalHookScriptBehaviourTests: XCTestCase {

    private var tempDir: String!

    private static let nonce = "6F1C2A9E-0B7D-4E21-9A53-C4D8E7F00112"
    private let stdinJSON = #"{"tool_name":"Bash","tool_input":{"command":"ls"},"hook_event_name":"PermissionRequest"}"#
    private let kinds: [String?] = [nil, "codex", "grok"]
    private let allowBody = Data(#"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}"#.utf8)
    private let denyBody = Data(#"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"no"}}}"#.utf8)

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ApprovalHookScriptBehaviourTests-" + UUID().uuidString).path
    }

    override func tearDown() {
        if let tempDir {
            try? FileManager.default.removeItem(atPath: tempDir)
        }
        tempDir = nil
        super.tearDown()
    }

    // MARK: - Harness

    private struct Prepared {
        let fixture: FakeCurlScriptFixture
        let recordDirectory: String
        let scriptTmp: String
    }

    private struct Outcome {
        let exitCode: Int32
        let stdout: String
        let stderr: String
        let curlCalls: Int
        let tmpEntries: [String]
        let records: String
    }

    /// Proof line (HMAC under `keyBytes` over "approval\n" + nonce + "\n" +
    /// body, lowercase hex) + LF + body.
    private static func signed(_ body: Data, keyBytes: Data, nonce: String = nonce) -> Data {
        let message = Data(("approval\n" + nonce + "\n").utf8) + body
        return Data((IPCWakeTestCrypto.hmacHex(keyBytes: keyBytes, message: message) + "\n").utf8) + body
    }

    private static func proof(_ body: Data, keyBytes: Data, nonce: String = nonce) -> String {
        IPCWakeTestCrypto.hmacHex(keyBytes: keyBytes, message: Data(("approval\n" + nonce + "\n").utf8) + body)
    }

    /// Builds a fixture (with key blocks unless `withBlocks` is false), a
    /// recording fake curl printing `response(keyBytes)` and exiting
    /// `curlExit`, a fake uuidgen printing `uuidgenStdout` and exiting
    /// `uuidgenExit`, then `extraSetup(fakeBinDir, recordDirectory)`.
    private func prepare(
        response: (Data) -> Data,
        curlExit: Int32 = 0,
        withBlocks: Bool = true,
        uuidgenStdout: String = nonce + "\n",
        uuidgenExit: Int32 = 0,
        noise: Bool = false,
        extraSetup: (String, String) throws -> Void = { _, _ in }
    ) throws -> Prepared {
        let root = tempDir + "/" + UUID().uuidString
        let keyBytes = IPCWakeTestCrypto.randomKeyBytes()
        let fixture = try makeFakeCurlScriptFixture(
            rootDirectory: root, port: 41_837, token: "approval-behaviour-token",
            wakeKeyBytes: withBlocks ? keyBytes : nil, install: ApprovalHookScript.install(toDirectory:)
        )
        let recordDirectory = root + "/record.d"
        let scriptTmp = root + "/script-tmp"
        try FileManager.default.createDirectory(atPath: scriptTmp, withIntermediateDirectories: true)
        try makeRecordingFakeCurl(
            atDirectory: fixture.fakeBinDir, recordDirectory: recordDirectory,
            stdoutBody: response(keyBytes), exitCode: curlExit, noise: noise
        )
        try makeFakeUuidgen(
            atDirectory: fixture.fakeBinDir, stdout: uuidgenStdout, exitCode: uuidgenExit,
            recordDirectory: recordDirectory, noise: noise
        )
        try extraSetup(fixture.fakeBinDir, recordDirectory)
        return Prepared(fixture: fixture, recordDirectory: recordDirectory, scriptTmp: scriptTmp)
    }

    private func run(_ prepared: Prepared, kind: String?) throws -> Outcome {
        let result = try runFakeCurlHookScriptCapturingStderr(
            prepared.fixture, stdinJSON: stdinJSON,
            extraEnv: ["CALYX_SURFACE_ID": "0E0C6C1B-5F0B-4C5E-9E3A-7C1B5D2F8A11", "TMPDIR": prepared.scriptTmp],
            kindArgument: kind
        )
        return Outcome(
            exitCode: result.exitCode, stdout: result.stdout, stderr: result.stderr,
            curlCalls: recordedInvocations(of: "curl", inDirectory: prepared.recordDirectory).count,
            tmpEntries: ((try? FileManager.default.contentsOfDirectory(atPath: prepared.scriptTmp)) ?? []).sorted(),
            records: readRecordDirectory(prepared.recordDirectory)
        )
    }

    private func assertDefaults(
        _ outcome: Outcome, curlCalls: Int = 1, _ label: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(outcome.exitCode, 0, "[\(label)] exit 0", file: file, line: line)
        XCTAssertEqual(outcome.stderr, "", "[\(label)] stderr is empty", file: file, line: line)
        XCTAssertEqual(outcome.tmpEntries, [String](), "[\(label)] both temp files are removed", file: file, line: line)
        XCTAssertEqual(outcome.curlCalls, curlCalls, "[\(label)] curl calls", file: file, line: line)
    }

    private func kindLabel(_ kind: String?) -> String { kind ?? "claude-code" }

    /// Runs `response` for every kind and asserts stdout is `expected`.
    private func assertStdout(
        _ expected: String, response: @escaping (Data) -> Data, curlExit: Int32 = 0, _ label: String,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        for kind in kinds {
            let outcome = try run(try prepare(response: response, curlExit: curlExit), kind: kind)
            let caseLabel = "\(label), \(kindLabel(kind))"
            assertDefaults(outcome, caseLabel, file: file, line: line)
            XCTAssertEqual(outcome.stdout, expected, "[\(caseLabel)] stdout", file: file, line: line)
        }
    }

    // MARK: - Signed bodies are printed byte for byte

    func test_signedAllowAndDeny_arePrintedByteForByte() throws {
        let allow = allowBody, deny = denyBody
        try assertStdout(String(decoding: allow, as: UTF8.self), response: { Self.signed(allow, keyBytes: $0) }, "signed allow")
        try assertStdout(String(decoding: deny, as: UTF8.self), response: { Self.signed(deny, keyBytes: $0) }, "signed deny")
    }

    func test_signed300KiBBody_isPrintedByteForByte() throws {
        let filler = String(repeating: "0123456789abcdef", count: 300 * 1024 / 16)
        let body = Data(#"{"hookSpecificOutput":{"decision":{"behavior":"deny","message":""#.utf8)
            + Data(filler.utf8) + Data(#""}}}"#.utf8)
        XCTAssertGreaterThan(body.count, 300 * 1024)
        try assertStdout(String(decoding: body, as: UTF8.self), response: { Self.signed(body, keyBytes: $0) }, "300 KiB")
    }

    func test_signedBodyWithShellSpecialBytes_isPrintedByteForByte() throws {
        let bodies = [
            "-n {\"m\":\"a\\rb\r\\\\ \\\" 'q' $HOME `id` %s %n %%\"}",
            "-e \\c\\n\\t $(id) ${HOME}",
            "line1\nline2\n\nline4\n",
            "\r\n",
        ]
        for text in bodies {
            let body = Data(text.utf8)
            try assertStdout(text, response: { Self.signed(body, keyBytes: $0) }, "special bytes \(text.debugDescription)")
        }
    }

    func test_signedEmptyBody_printsNothing_butPassesVerification() throws {
        for kind in kinds {
            let tailNames = ["tail"]
            let prepared = try prepare(response: { Self.signed(Data(), keyBytes: $0) }) { bin, record in
                try installRecordingWrappers(atDirectory: bin, recordDirectory: record, names: tailNames)
            }
            let outcome = try run(prepared, kind: kind)
            assertDefaults(outcome, "signed empty, \(kindLabel(kind))")
            XCTAssertEqual(outcome.stdout, "")
            let finalTails = recordedInvocations(of: "tail", inDirectory: prepared.recordDirectory)
                .filter { $0.hasPrefix("ARGV tail [-c] [+66] ") }
            XCTAssertEqual(finalTails.count, 2,
                           "[\(kindLabel(kind))] a verified empty body runs tail -c +66 twice: once into the HMAC, " +
                           "once as the (empty) output")
        }
    }

    func test_tamperedBody_runsTheFinalTailOnlyForTheHMAC() throws {
        let allow = allowBody
        let prepared = try prepare(response: { key in
            Data((Self.proof(allow, keyBytes: key) + "\n").utf8) + Data(#"{"x":1}"#.utf8)
        }) { bin, record in
            try installRecordingWrappers(atDirectory: bin, recordDirectory: record, names: ["tail"])
        }
        let outcome = try run(prepared, kind: nil)
        assertDefaults(outcome, "tampered with recording tail")
        XCTAssertEqual(outcome.stdout, "")
        XCTAssertEqual(recordedInvocations(of: "tail", inDirectory: prepared.recordDirectory)
            .filter { $0.hasPrefix("ARGV tail [-c] [+66] ") }.count, 1,
                       "an HMAC mismatch stops before the output tail")
    }

    // MARK: - Unverifiable answers print nothing (C-D4: every kind)

    func test_unverifiableAnswers_printNothing_forEveryKind() throws {
        let allow = allowBody
        let otherNonce = "00000000-1111-2222-3333-444444444444"
        let cases: [(String, (Data) -> Data)] = [
            ("unsigned allow (squatter)", { _ in allow }),
            ("tampered body", { key in
                Data((Self.proof(allow, keyBytes: key) + "\n").utf8)
                    + Data(String(decoding: allow, as: UTF8.self).replacingOccurrences(of: "allow", with: "alloW").utf8)
            }),
            ("proof for another nonce", { key in Self.signed(allow, keyBytes: key, nonce: otherNonce) }),
            ("another key", { _ in Self.signed(allow, keyBytes: IPCWakeTestCrypto.randomKeyBytes()) }),
            ("upper-case hex", { key in Data((Self.proof(allow, keyBytes: key).uppercased() + "\n").utf8) + allow }),
            ("no LF after the proof", { key in Data(Self.proof(allow, keyBytes: key).utf8) + allow }),
            ("64-byte body", { key in Data(Self.proof(allow, keyBytes: key).utf8) }),
            ("proof covers only the first of three lines", { key in
                let first = Data("line1".utf8)
                return Data((Self.proof(first, keyBytes: key) + "\n").utf8) + Data("line1\nline2\nline3".utf8)
            }),
            ("wake-domain proof", { key in
                let wake = IPCWakeTestCrypto.hmacHex(keyBytes: key, message: Data((Self.nonce + "\n").utf8) + allow)
                return Data((wake + "\n").utf8) + allow
            }),
            ("signed empty with a trailing LF body", { key in
                Data((Self.proof(Data(), keyBytes: key) + "\n").utf8) + Data("\n".utf8)
            }),
        ]
        for (label, response) in cases {
            try assertStdout("", response: response, label)
        }
    }

    func test_curlFailures_withASignedBody_printNothing() throws {
        let allow = allowBody
        for code: Int32 in [6, 7, 22, 28, 63] {
            try assertStdout("", response: { Self.signed(allow, keyBytes: $0) }, curlExit: code, "curl exit \(code)")
        }
    }

    // MARK: - Tool failures

    func test_failingVerificationTool_printsNothing() throws {
        let allow = allowBody
        for tool in ["openssl", "xxd", "grep", "head", "tail"] {
            for kind in kinds {
                let prepared = try prepare(response: { Self.signed(allow, keyBytes: $0) }) { bin, _ in
                    try makeFailingTool(named: tool, atDirectory: bin, exitCode: 1)
                }
                let outcome = try run(prepared, kind: kind)
                assertDefaults(outcome, "failing \(tool), \(kindLabel(kind))")
                XCTAssertEqual(outcome.stdout, "", "[failing \(tool), \(kindLabel(kind))] nothing is printed")
            }
        }
    }

    func test_grepThatAlwaysSucceeds_doesNotTurnAnUnsignedBodyIntoOutput() throws {
        let allow = allowBody
        let cases: [(String, (Data) -> Data)] = [
            ("unsigned allow", { _ in allow }),
            ("64 garbage hex-looking bytes, LF, allow", { _ in
                Data((String(repeating: "z", count: 64) + "\n").utf8) + allow
            }),
        ]
        for (label, response) in cases {
            let prepared = try prepare(response: response) { bin, _ in
                try makeFailingTool(named: "grep", atDirectory: bin, exitCode: 0)
            }
            let outcome = try run(prepared, kind: nil)
            assertDefaults(outcome, "grep always 0, \(label)")
            XCTAssertEqual(outcome.stdout, "", "[\(label)] the HMAC comparison still rejects it")
        }
    }

    // MARK: - curl never runs

    func test_missingBlocks_orFailingUuidgen_curlNeverRuns() throws {
        let allow = allowBody
        let setups: [(String, () throws -> Prepared)] = [
            ("blocks missing", { try self.prepare(response: { _ in allow }, withBlocks: false) }),
            ("uuidgen exits 1", { try self.prepare(response: { _ in allow }, uuidgenExit: 1) }),
            ("uuidgen prints nothing", { try self.prepare(response: { _ in allow }, uuidgenStdout: "") }),
        ]
        for (label, setup) in setups {
            for kind in kinds {
                let outcome = try run(try setup(), kind: kind)
                assertDefaults(outcome, curlCalls: 0, "\(label), \(kindLabel(kind))")
                XCTAssertEqual(outcome.stdout, "")
            }
        }
    }

    // MARK: - Secrecy and noise

    func test_secrecy_neitherBlockNorKeyAppearsInAnyArgvOrEnvironment() throws {
        let allow = allowBody
        var keyHex = ""
        let prepared = try prepare(response: { key in
            keyHex = IPCWakeTestCrypto.hex(key)
            return Self.signed(allow, keyBytes: key)
        }) { bin, record in
            try installRecordingWrappers(
                atDirectory: bin, recordDirectory: record,
                names: ["sed", "grep", "tr", "openssl", "xxd", "mktemp", "cat", "rm", "head", "tail"]
            )
        }
        let outcome = try run(prepared, kind: nil)
        assertDefaults(outcome, "secrecy")
        XCTAssertEqual(outcome.stdout, String(decoding: allow, as: UTF8.self),
                       "precondition: the verification ran to the end")
        XCTAssertGreaterThanOrEqual(recordedInvocations(of: "openssl", inDirectory: prepared.recordDirectory).count, 2,
                                    "precondition: the HMAC pipeline ran through the recording openssl")
        let keyBytes = try XCTUnwrap(prepared.fixture.wakeKeyBytes)
        let blocks = IPCWakeTestCrypto.blocksHex(keyBytes: keyBytes)
        XCTAssertFalse(outcome.records.isEmpty)
        XCTAssertFalse(outcome.records.contains(blocks.inner), "the inner block is in no argv or environment")
        XCTAssertFalse(outcome.records.contains(blocks.outer), "the outer block is in no argv or environment")
        XCTAssertFalse(outcome.records.contains(keyHex), "the key is in no argv or environment")
    }

    func test_noiseOnEveryToolsStderr_leavesStdoutUnchanged_andStderrEmpty() throws {
        let allow = allowBody
        for kind in kinds {
            let prepared = try prepare(response: { Self.signed(allow, keyBytes: $0) }, noise: true) { bin, record in
                try installRecordingWrappers(
                    atDirectory: bin, recordDirectory: record, noise: true,
                    names: ["sed", "grep", "tr", "openssl", "xxd", "mktemp", "cat", "rm", "head", "tail"]
                )
            }
            let outcome = try run(prepared, kind: kind)
            assertDefaults(outcome, "noise, \(kindLabel(kind))")
            XCTAssertEqual(outcome.stdout, String(decoding: allow, as: UTF8.self), "[noise, \(kindLabel(kind))]")
        }
    }

    // MARK: - curl's argv

    func test_curlArgv_carriesMaxFilesizeAndTheUppercaseNonceHeader() throws {
        let allow = allowBody
        let lowercase = Self.nonce.lowercased()
        let prepared = try prepare(response: { Self.signed(allow, keyBytes: $0) }, uuidgenStdout: lowercase + "\n")
        let outcome = try run(prepared, kind: "codex")
        assertDefaults(outcome, "argv")
        let argv = try XCTUnwrap(recordedInvocations(of: "curl", inDirectory: prepared.recordDirectory).first)
        XCTAssertTrue(argv.contains(" [--max-filesize] [1048641] "), "65 + 4 * 262144. Got: \(argv)")
        XCTAssertTrue(argv.contains(" [-H] [X-Calyx-Approval-Nonce: \(Self.nonce)] "),
                      "the nonce is sent upper-case. Got: \(argv)")
        XCTAssertEqual(outcome.stdout, String(decoding: allow, as: UTF8.self),
                       "a lower-case uuidgen output is verified against the upper-case nonce the server signed")
    }
}
