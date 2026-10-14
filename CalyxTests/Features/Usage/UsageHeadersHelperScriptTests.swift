//
//  UsageHeadersHelperScriptTests.swift
//  CalyxTests
//
//  Feature C, G5 (J16 / J17, spec note 22): `calyx-usage-headers <port>`,
//  the command Claude Code's `otelHeadersHelper` runs for the usage
//  route's headers. Contract: stdout is byte-identical to
//  `usage-otel-credential.json` (next to agent-endpoint.json) when the first
//  argument equals the endpoint file's port and the endpoint file passes
//  `AgentEndpointFile.shellResolution` (writer alive); otherwise exactly
//  `{}`. Always exit 0, empty stderr. The usage token reaches stdout only
//  through `cat "$usage_file"`, so it never enters any argv or env.
//
//  Mirrors MCPHeadersHelperScriptTests. Behaviour cases run the installed
//  script with the real /bin/sh and a child environment of exactly HOME,
//  PATH (and CALYX_ENDPOINT_FILE where stated).
//

import XCTest
@testable import Calyx

final class UsageHeadersHelperScriptTests: XCTestCase {

    private var tempDir: String!
    /// The IPC bearer in agent-endpoint.json.
    private let ipcSecret = String(repeating: "0123456789abcdef", count: 4)
    /// The usage bearer in usage-otel-credential.json (distinct from the IPC one).
    private let usageSecret = String(repeating: "fedcba9876543210", count: 4)
    private let port = 41830

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

    private var body: String { UsageHeadersHelperScript.scriptBody }

    private var executableLines: [String] {
        body.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    private let trap = #"trap 'if [ "$emitted" != 1 ]; then printf "{}"; fi' EXIT"#

    func test_fileName() {
        XCTAssertEqual(UsageHeadersHelperScript.fileName, "calyx-usage-headers")
    }

    func test_firstLine_isShebang() {
        XCTAssertEqual(body.components(separatedBy: "\n").first, "#!/bin/sh")
    }

    func test_executableLines_beforeResolution_exactOrder() throws {
        XCTAssertEqual(Array(executableLines.prefix(7)), [
            "exec 2>/dev/null", "emitted=0", trap,
            #"expected_port="$1""#,
            #"if [ -z "$expected_port" ]; then"#, "exit 0", "fi",
        ])
        let captureRange = try XCTUnwrap(body.range(of: #"expected_port="$1""#))
        let resolutionRange = try XCTUnwrap(body.range(of: AgentEndpointFile.shellResolution))
        XCTAssertLessThan(captureRange.lowerBound, resolutionRange.lowerBound,
                          "$1 must be captured before shellResolution's `set --`")
    }

    func test_executableLines_afterResolution_exactOrder() throws {
        let resolutionRange = try XCTUnwrap(body.range(of: AgentEndpointFile.shellResolution))
        let tail = String(body[resolutionRange.upperBound...])
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        XCTAssertEqual(tail, [
            #"if [ "$port" != "$expected_port" ]; then"#, "exit 0", "fi",
            #"usage_file="${endpoint_file%/*}/usage-otel-credential.json""#,
            #"if [ ! -r "$usage_file" ]; then"#, "exit 0", "fi",
            #"cat "$usage_file""#, "emitted=1", "exit 0",
        ])
    }

    func test_shellResolution_interpolatedExactlyOnce() {
        XCTAssertEqual(body.components(separatedBy: AgentEndpointFile.shellResolution).count - 1, 1)
    }

    func test_positionalParameter_readOnlyOnce() {
        let executable = executableLines.joined(separator: "\n")
        XCTAssertEqual(executable.components(separatedBy: "$1").count - 1, 1)
    }

    func test_noPrologueGuards() {
        XCTAssertFalse(body.contains(AgentHookScriptPrologue.guards))
    }

    func test_catOfUsageFile_exactlyOnce_followedByFlagAndExit() throws {
        let lines = executableLines
        XCTAssertEqual(lines.filter { $0 == #"cat "$usage_file""# }.count, 1)
        let index = try XCTUnwrap(lines.firstIndex(of: #"cat "$usage_file""#))
        XCTAssertEqual(Array(lines[index...]), [#"cat "$usage_file""#, "emitted=1", "exit 0"])
        XCTAssertEqual(lines.last, "exit 0")
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
        let path = try UsageHeadersHelperScript.install(toDirectory: dir)
        XCTAssertEqual(path, dir + "/calyx-usage-headers")
        XCTAssertEqual(FileManager.default.contents(atPath: path), Data(body.utf8))
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o755)
    }

    func test_remove_deletesTheScript_andIsANoOpWhenAbsent() throws {
        let dir = tempDir + "/bin"
        let path = try UsageHeadersHelperScript.install(toDirectory: dir)
        try Data("x".utf8).write(to: URL(fileURLWithPath: dir + "/calyx-mcp-headers"))
        UsageHeadersHelperScript.remove(fromDirectory: dir)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir + "/calyx-mcp-headers"), "only its own file")
        UsageHeadersHelperScript.remove(fromDirectory: dir)
        UsageHeadersHelperScript.remove(fromDirectory: tempDir + "/never-created")
    }

    // MARK: - Behaviour

    private struct Run { let exitCode: Int32; let stdout: Data; let stderr: String }

    private func runHelper(
        endpointFile: String?, arguments: [String]? = nil, home: String? = nil, pathPrefix: String? = nil
    ) throws -> Run {
        let scriptPath = try UsageHeadersHelperScript.install(toDirectory: tempDir + "/bin")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [scriptPath] + (arguments ?? [String(port)])
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
        return Run(exitCode: process.terminationStatus, stdout: o, stderr: String(decoding: e, as: UTF8.self))
    }

    /// Hand-written, independent of `UsageIngestCredentialStore`.
    private var usageHeaderBytes: Data { Data((#"{"Authorization":"Bearer "# + usageSecret + #""}"#).utf8) }

    /// Writes agent-endpoint.json (and, unless `usageFile` is false, usage-otel-credential.json) into `directory`.
    private func writeFixture(
        directory: String, pid: Int32? = TestHostLiveness.pid, pidStart: String? = TestHostLiveness.startText,
        usageFile: Bool = true
    ) throws -> String {
        try IPCWakeTestCrypto.writeEndpointFile(
            directory: directory, port: port, token: ipcSecret, keyBytes: IPCWakeTestCrypto.randomKeyBytes(),
            pid: pid, pidStart: pidStart)
        if usageFile {
            try usageHeaderBytes.write(to: URL(fileURLWithPath: directory + "/usage-otel-credential.json"))
        }
        return directory + "/agent-endpoint.json"
    }

    private func assertEmptyObject(_ run: Run, _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(String(decoding: run.stdout, as: UTF8.self), "{}", label, file: file, line: line)
        XCTAssertEqual(run.exitCode, 0, label, file: file, line: line)
        XCTAssertEqual(run.stderr, "", label, file: file, line: line)
    }

    private func assertHeaders(_ run: Run, _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(run.stdout, usageHeaderBytes, label, file: file, line: line)
        XCTAssertEqual(run.exitCode, 0, label, file: file, line: line)
        XCTAssertEqual(run.stderr, "", label, file: file, line: line)
    }

    func test_matchingPort_printsHeadersFileByteForByte() throws {
        XCTAssertFalse(TestHostLiveness.startText.isEmpty, "precondition")
        assertHeaders(try runHelper(endpointFile: try writeFixture(directory: tempDir + "/ep")), "matching port")
    }

    func test_matchingPort_withProductionEndpointWriter_printsHeaders() throws {
        let dir = tempDir + "/ep-prod"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try writeTestEndpointFile(port: port, token: ipcSecret, wakeProofKey: IPCWakeProofKey.random(), directory: dir)
        try usageHeaderBytes.write(to: URL(fileURLWithPath: dir + "/usage-otel-credential.json"))
        assertHeaders(try runHelper(endpointFile: dir + "/agent-endpoint.json"), "AgentEndpointFile.write fixture")
    }

    func test_matchingPort_viaHomeFallback_printsHeaders() throws {
        let home = tempDir + "/home"
        _ = try writeFixture(directory: home + "/Library/Application Support/Calyx")
        assertHeaders(try runHelper(endpointFile: nil, home: home), "HOME fallback")
    }

    func test_differentPort_printsEmptyObject() throws {
        let ep = try writeFixture(directory: tempDir + "/ep")
        assertEmptyObject(try runHelper(endpointFile: ep, arguments: ["41831"]), "other port")
        assertEmptyObject(try runHelper(endpointFile: ep, arguments: ["4183"]), "port prefix")
    }

    func test_differentPort_viaHomeFallback_printsEmptyObject() throws {
        let home = tempDir + "/home"
        _ = try writeFixture(directory: home + "/Library/Application Support/Calyx")
        assertEmptyObject(try runHelper(endpointFile: nil, arguments: ["41829"], home: home), "fallback, other port")
    }

    func test_noArgument_printsEmptyObject() throws {
        let ep = try writeFixture(directory: tempDir + "/ep")
        assertEmptyObject(try runHelper(endpointFile: ep, arguments: []), "no argument")
    }

    func test_emptyArgument_printsEmptyObject() throws {
        let ep = try writeFixture(directory: tempDir + "/ep")
        assertEmptyObject(try runHelper(endpointFile: ep, arguments: [""]), "empty argument")
    }

    func test_deadPid_printsEmptyObject() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try child.run()
        child.waitUntilExit()
        let pid = child.processIdentifier
        errno = 0
        XCTAssertEqual(kill(pid, 0), -1, "precondition: the child is reaped")
        XCTAssertEqual(errno, ESRCH, "precondition: no such process")
        let ep = try writeFixture(directory: tempDir + "/ep", pid: pid)
        assertEmptyObject(try runHelper(endpointFile: ep), "dead pid")
    }

    func test_wrongPidStart_printsEmptyObject() throws {
        let ep = try writeFixture(directory: tempDir + "/ep", pidStart: "Thu Jan 1 00:00:00 1970")
        assertEmptyObject(try runHelper(endpointFile: ep), "wrong pidStart")
    }

    func test_endpointFileMissing_printsEmptyObject() throws {
        let dir = tempDir + "/ep"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try usageHeaderBytes.write(to: URL(fileURLWithPath: dir + "/usage-otel-credential.json"))
        assertEmptyObject(try runHelper(endpointFile: dir + "/agent-endpoint.json"), "no endpoint file")
    }

    func test_endpointFileMissing_viaHomeFallback_printsEmptyObject() throws {
        let dir = tempDir + "/home/Library/Application Support/Calyx"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try usageHeaderBytes.write(to: URL(fileURLWithPath: dir + "/usage-otel-credential.json"))
        assertEmptyObject(try runHelper(endpointFile: nil, home: tempDir + "/home"), "fallback, no endpoint file")
    }

    func test_usageFileMissing_printsEmptyObject() throws {
        let ep = try writeFixture(directory: tempDir + "/ep", usageFile: false)
        assertEmptyObject(try runHelper(endpointFile: ep), "no usage headers file")
    }

    func test_usageFileMissing_viaHomeFallback_printsEmptyObject() throws {
        let home = tempDir + "/home"
        _ = try writeFixture(directory: home + "/Library/Application Support/Calyx", usageFile: false)
        assertEmptyObject(try runHelper(endpointFile: nil, home: home), "fallback, no usage headers file")
    }

    func test_usageFileNextToEndpointFile_notInHome() throws {
        // CALYX_ENDPOINT_FILE wins; a usage file only under HOME is not read.
        let home = tempDir + "/home"
        let homeDir = home + "/Library/Application Support/Calyx"
        try FileManager.default.createDirectory(atPath: homeDir, withIntermediateDirectories: true)
        try usageHeaderBytes.write(to: URL(fileURLWithPath: homeDir + "/usage-otel-credential.json"))
        let ep = try writeFixture(directory: tempDir + "/ep", usageFile: false)
        assertEmptyObject(try runHelper(endpointFile: ep, home: home), "usage file is looked up next to the endpoint file")
    }

    func test_usageSecretNeverInArgvOrEnvOfChildProcesses() throws {
        let fakeBin = tempDir + "/fakebin"
        let record = tempDir + "/record.d"
        try installRecordingWrappers(atDirectory: fakeBin, recordDirectory: record, names: ["sed", "cat"])
        try writeFakeTool(named: "ps", atDirectory: fakeBin, body: """
        { printf 'ARGV ps'; for a in "$@"; do printf ' [%s]' "$a"; done; printf '\\n'; /usr/bin/env; printf 'END\\n'; } >> "\(record)/ps.$$"
        exec /bin/ps "$@"
        """)
        let dir = tempDir + "/ep"
        let run = try runHelper(endpointFile: try writeFixture(directory: dir), pathPrefix: fakeBin)
        assertHeaders(run, "precondition: the wrappers do not break the helper")
        XCTAssertFalse(recordedInvocations(of: "sed", inDirectory: record).isEmpty, "precondition: sed recorded")
        XCTAssertFalse(recordedInvocations(of: "ps", inDirectory: record).isEmpty, "precondition: ps recorded")
        let cats = recordedInvocations(of: "cat", inDirectory: record)
        XCTAssertTrue(cats.contains("ARGV cat [\(dir)/usage-otel-credential.json]"),
                      "the usage file is read by cat by path: \(cats)")
        let records = readRecordDirectory(record)
        XCTAssertFalse(records.contains(usageSecret), "the usage token must not reach any child argv or environment")
        XCTAssertFalse(records.contains(ipcSecret), "the IPC token must not reach any child argv or environment")
    }
}
