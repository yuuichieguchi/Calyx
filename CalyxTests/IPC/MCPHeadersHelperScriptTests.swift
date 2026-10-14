//
//  MCPHeadersHelperScriptTests.swift
//  CalyxTests
//
//  Feature C, J6 / C-D3 / C-D17 / spec note 4: `calyx-mcp-headers`, the
//  headers helper Claude Code (`headersHelper`) and Codex
//  (`http_headers_helper`) run to obtain the bearer header. Contract:
//  stdout is exactly `{"Authorization":"Bearer <token>"}` when
//  agent-endpoint.json passes J2 (readable, port/token/pid/pidStart, pid
//  alive, pidStart matches), otherwise exactly `{}`; always exit 0, empty
//  stderr, no trailing newline. No surface guard: Claude Code outside
//  Calyx uses calyx-ipc too. V3-2: Claude Code treats `{}` as "no
//  Authorization", and garbage/empty/non-zero as the same silently, but
//  `{}` is the documented clean form.
//
//  Behaviour cases run the installed script with the real /bin/sh and a
//  child environment of exactly HOME, PATH (and CALYX_ENDPOINT_FILE where
//  stated); CALYX_SURFACE_ID is never set.
//

import XCTest
@testable import Calyx

final class MCPHeadersHelperScriptTests: XCTestCase {

    private var tempDir: String!
    private let secret = String(repeating: "0123456789abcdef", count: 4)

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        try! FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: tempDir)
        tempDir = nil
        super.tearDown()
    }

    // MARK: - String pins

    private var body: String { MCPHeadersHelperScript.scriptBody }

    /// Non-empty lines that are not comments (the shebang excluded too).
    private var executableLines: [String] {
        body.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    func test_fileName() {
        XCTAssertEqual(MCPHeadersHelperScript.fileName, "calyx-mcp-headers")
    }

    func test_firstLine_isShebang() {
        XCTAssertEqual(body.components(separatedBy: "\n").first, "#!/bin/sh")
    }

    func test_firstExecutableLine_silencesStderr() {
        XCTAssertEqual(executableLines.first, "exec 2>/dev/null")
    }

    func test_exitTrap_printsEmptyObjectUnlessEmitted_beforeResolution() throws {
        let trap = #"trap 'if [ "$emitted" != 1 ]; then printf "{}"; fi' EXIT"#
        XCTAssertEqual(Array(executableLines.prefix(3)), ["exec 2>/dev/null", "emitted=0", trap])
        let trapRange = try XCTUnwrap(body.range(of: trap))
        let resolutionRange = try XCTUnwrap(body.range(of: AgentEndpointFile.shellResolution))
        XCTAssertLessThan(trapRange.lowerBound, resolutionRange.lowerBound)
    }

    func test_shellResolution_interpolatedExactlyOnce() {
        XCTAssertEqual(body.components(separatedBy: AgentEndpointFile.shellResolution).count - 1, 1)
    }

    func test_noPrologueGuards() {
        XCTAssertFalse(body.contains(AgentHookScriptPrologue.guards))
        let outsideResolution = body.replacingOccurrences(of: AgentEndpointFile.shellResolution, with: "")
        for marker in ["CALYX_SURFACE_ID", "CALYX_SESSION_ID", "HERDR_PANE_ID", "GROK_HOOK_EVENT", "kind="] {
            XCTAssertFalse(outsideResolution.contains(marker), "no guard may reference \(marker)")
        }
        XCTAssertFalse(body.contains("HERDR_PANE_ID"))
        XCTAssertFalse(body.contains("GROK_HOOK_EVENT"))
    }

    func test_singleAuthorizationPrintf_followedByFlagAndExit() throws {
        let lines = executableLines
        let printfs = lines.filter { $0.hasPrefix(#"printf '{"Authorization""#) }
        XCTAssertEqual(printfs, [#"printf '{"Authorization":"Bearer %s"}' "$token""#])
        let index = try XCTUnwrap(lines.firstIndex(of: #"printf '{"Authorization":"Bearer %s"}' "$token""#))
        XCTAssertEqual(Array(lines[index...]), [#"printf '{"Authorization":"Bearer %s"}' "$token""#, "emitted=1", "exit 0"],
                       "emitted=1 right after the printf, and exit 0 is the last line")
    }

    func test_forbiddenConstructs_absent() {
        for line in executableLines {
            for forbidden in ["curl", "<<", "export", "eval"] {
                XCTAssertFalse(line.contains(forbidden), "\(forbidden) in: \(line)")
            }
        }
    }

    func test_everyExit_isExitZero() throws {
        let regex = try NSRegularExpression(pattern: #"\bexit\b(?! 0\b)"#)
        for line in executableLines where !line.hasPrefix("trap ") {
            let range = NSRange(line.startIndex..., in: line)
            XCTAssertNil(regex.firstMatch(in: line, range: range), "non-zero/bare exit in: \(line)")
        }
    }

    // MARK: - install / remove

    func test_install_writes0755_andReturnsThePath() throws {
        let dir = tempDir + "/bin dir"
        let path = try MCPHeadersHelperScript.install(toDirectory: dir)
        XCTAssertEqual(path, dir + "/calyx-mcp-headers")
        XCTAssertEqual(FileManager.default.contents(atPath: path), Data(body.utf8))
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o755)
    }

    func test_remove_deletesTheScript_andIsANoOpWhenAbsent() throws {
        let dir = tempDir + "/bin"
        let path = try MCPHeadersHelperScript.install(toDirectory: dir)
        try Data("x".utf8).write(to: URL(fileURLWithPath: dir + "/calyx-agent-hook"))
        MCPHeadersHelperScript.remove(fromDirectory: dir)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir + "/calyx-agent-hook"), "only its own file")
        MCPHeadersHelperScript.remove(fromDirectory: dir)
        MCPHeadersHelperScript.remove(fromDirectory: tempDir + "/never-created")
    }

    // MARK: - Behaviour

    private struct Run { let exitCode: Int32; let stdout: String; let stderr: String }

    private func runHelper(
        endpointFile: String?, home: String? = nil, pathPrefix: String? = nil
    ) throws -> Run {
        let scriptPath = try MCPHeadersHelperScript.install(toDirectory: tempDir + "/bin")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [scriptPath]
        var env = ["HOME": home ?? (tempDir + "/emptyhome"), "PATH": (pathPrefix.map { $0 + ":" } ?? "") + "/usr/bin:/bin"]
        if let endpointFile { env["CALYX_ENDPOINT_FILE"] = endpointFile }
        process.environment = env
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let o = out.fileHandleForReading.readDataToEndOfFile()
        let e = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Run(exitCode: process.terminationStatus,
                   stdout: String(decoding: o, as: UTF8.self), stderr: String(decoding: e, as: UTF8.self))
    }

    private func writeEndpoint(
        directory: String, pid: Int32? = TestHostLiveness.pid, pidStart: String? = TestHostLiveness.startText
    ) throws -> String {
        try IPCWakeTestCrypto.writeEndpointFile(
            directory: directory, port: 41830, token: secret, keyBytes: IPCWakeTestCrypto.randomKeyBytes(),
            pid: pid, pidStart: pidStart
        )
        return directory + "/agent-endpoint.json"
    }

    private var expectedHeader: String { #"{"Authorization":"Bearer "# + secret + #""}"# }

    private func assertEmptyObject(_ run: Run, _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(run.stdout, "{}", label, file: file, line: line)
        XCTAssertEqual(run.exitCode, 0, label, file: file, line: line)
        XCTAssertEqual(run.stderr, "", label, file: file, line: line)
        XCTAssertFalse(run.stdout.contains(secret), label, file: file, line: line)
    }

    func test_liveHost_printsAuthorizationJSON() throws {
        XCTAssertFalse(TestHostLiveness.startText.isEmpty, "precondition")
        let run = try runHelper(endpointFile: try writeEndpoint(directory: tempDir + "/ep"))
        XCTAssertEqual(run.stdout, expectedHeader)
        XCTAssertEqual(run.exitCode, 0)
        XCTAssertEqual(run.stderr, "")
    }

    func test_liveHost_viaHomeFallback_whenEndpointVariableUnset() throws {
        let home = tempDir + "/home"
        _ = try writeEndpoint(directory: home + "/Library/Application Support/Calyx")
        let run = try runHelper(endpointFile: nil, home: home)
        XCTAssertEqual(run.stdout, expectedHeader)
        XCTAssertEqual(run.exitCode, 0)
        XCTAssertEqual(run.stderr, "")
    }

    func test_deadPid_printsEmptyObject() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try child.run()
        child.waitUntilExit()
        let run = try runHelper(endpointFile: try writeEndpoint(
            directory: tempDir + "/ep", pid: child.processIdentifier, pidStart: TestHostLiveness.startText))
        assertEmptyObject(run, "dead pid")
    }

    func test_wrongPidStart_printsEmptyObject() throws {
        let run = try runHelper(endpointFile: try writeEndpoint(
            directory: tempDir + "/ep", pidStart: "Thu Jan 1 00:00:00 1970"))
        assertEmptyObject(run, "wrong pidStart")
    }

    func test_missingFile_printsEmptyObject() throws {
        assertEmptyObject(try runHelper(endpointFile: tempDir + "/absent/agent-endpoint.json"), "missing file")
    }

    func test_missingFile_viaHomeFallback_printsEmptyObject() throws {
        assertEmptyObject(try runHelper(endpointFile: nil, home: tempDir + "/emptyhome"), "missing fallback file")
    }

    func test_missingPidKey_printsEmptyObject() throws {
        let run = try runHelper(endpointFile: try writeEndpoint(directory: tempDir + "/ep", pid: nil))
        assertEmptyObject(run, "missing pid")
    }

    func test_missingToken_printsEmptyObject() throws {
        let dir = tempDir + "/ep"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let json = #"{"port":41830,"pid":\#(TestHostLiveness.pid),"pidStart":"\#(TestHostLiveness.startText)"}"#
        try Data(json.utf8).write(to: URL(fileURLWithPath: dir + "/agent-endpoint.json"))
        assertEmptyObject(try runHelper(endpointFile: dir + "/agent-endpoint.json"), "missing token")
    }

    func test_tokenNeverInArgvOrEnvOfChildProcesses() throws {
        let fakeBin = tempDir + "/fakebin"
        let record = tempDir + "/record.d"
        try installRecordingWrappers(atDirectory: fakeBin, recordDirectory: record, names: ["sed"])
        try writeFakeTool(named: "ps", atDirectory: fakeBin, body: """
        { printf 'ARGV ps'; for a in "$@"; do printf ' [%s]' "$a"; done; printf '\\n'; /usr/bin/env; printf 'END\\n'; } >> "\(record)/ps.$$"
        exec /bin/ps "$@"
        """)
        let run = try runHelper(endpointFile: try writeEndpoint(directory: tempDir + "/ep"), pathPrefix: fakeBin)
        XCTAssertEqual(run.stdout, expectedHeader, "precondition: the wrappers do not break the helper")
        XCTAssertFalse(recordedInvocations(of: "sed", inDirectory: record).isEmpty, "precondition: sed recorded")
        XCTAssertFalse(recordedInvocations(of: "ps", inDirectory: record).isEmpty, "precondition: ps recorded")
        XCTAssertFalse(readRecordDirectory(record).contains(secret),
                       "the token must not reach any child argv or environment")
    }
}
