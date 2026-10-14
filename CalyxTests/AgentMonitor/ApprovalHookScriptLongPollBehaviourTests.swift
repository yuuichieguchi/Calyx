//
//  ApprovalHookScriptLongPollBehaviourTests.swift
//  CalyxTests
//
//  Behaviour of `calyx-approval-hook` around the shared long-poll lines
//  (spec C.3 G4, slice 1), run as a real `/bin/sh` child against a
//  recording fake curl and a fake uuidgen (FakeCurlScriptFixture.swift).
//  The child's TMPDIR is a directory the test owns: the script's templated
//  `mktemp "${TMPDIR:-/tmp}/calyx-approval-*.XXXXXX"` honours it, which is
//  how the tests see its two temp files.
//
//  Coverage:
//  - while curl runs, TMPDIR holds exactly the payload and the response
//    temp file; after exit it is empty (success and curl failure)
//  - control: without a signal, the TERM test's fixture reaches curl
//  - a TERM received while the script is draining stdin (stdin still
//    open) exits 0 with no stdout and leaves no temp file once stdin
//    closes. That curl never starts is pinned statically instead (see the
//    comment on that test)
//

import XCTest
@testable import Calyx

final class ApprovalHookScriptLongPollBehaviourTests: XCTestCase {

    private var tempDir: String!

    private let stdinJSON = #"{"tool_name":"Bash","tool_input":{"command":"ls"}}"#

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ApprovalHookScriptLongPollBehaviourTests-" + UUID().uuidString).path
    }

    override func tearDown() {
        if let tempDir {
            try? FileManager.default.removeItem(atPath: tempDir)
        }
        tempDir = nil
        super.tearDown()
    }

    private struct Prepared {
        let fixture: FakeCurlScriptFixture
        let recordDirectory: String
        let listingPath: String
        let scriptTmp: String
        /// Written by the fake curl as its very first action.
        let curlStartedPath: String
        var environment: [String: String] {
            let inheritedPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
            return [
                "HOME": fixture.home, "PATH": "\(fixture.fakeBinDir):\(inheritedPath)",
                "TMPDIR": scriptTmp, "CALYX_SURFACE_ID": "0E0C6C1B-5F0B-4C5E-9E3A-7C1B5D2F8A11",
            ]
        }
    }

    private func prepare(curlBody: String, curlExitCode: Int32) throws -> Prepared {
        let fixture = try makeFakeCurlScriptFixture(
            rootDirectory: tempDir + "/" + UUID().uuidString, port: 41_835, token: "long-poll-behaviour-token",
            install: ApprovalHookScript.install(toDirectory:)
        )
        let recordDirectory = fixture.rootDir + "/record.d"
        let listingPath = fixture.rootDir + "/tmp-listing-while-curl-ran.txt"
        let scriptTmp = fixture.rootDir + "/script-tmp"
        let curlStartedPath = fixture.rootDir + "/curl-started.txt"
        try FileManager.default.createDirectory(atPath: scriptTmp, withIntermediateDirectories: true)
        try makeRecordingFakeCurl(
            atDirectory: fixture.fakeBinDir, recordDirectory: recordDirectory, stdoutBody: Data(curlBody.utf8),
            exitCode: curlExitCode, listDirectory: scriptTmp, listingPath: listingPath,
            startedPath: curlStartedPath
        )
        try makeFakeUuidgen(atDirectory: fixture.fakeBinDir, stdout: Self.fixedNonce + "\n")
        return Prepared(
            fixture: fixture, recordDirectory: recordDirectory, listingPath: listingPath, scriptTmp: scriptTmp,
            curlStartedPath: curlStartedPath
        )
    }

    private static let fixedNonce = "6F1C2A9E-0B7D-4E21-9A53-C4D8E7F00112"

    /// `prepare`, with the fake curl printing `proof LF body`: the proof is
    /// HMAC-SHA256 under the fixture's key over "approval\n" + nonce + "\n"
    /// + body. The fixture is built first so its key is known.
    private func prepare(signedCurlBody body: String, curlExitCode: Int32) throws -> Prepared {
        let prepared = try prepare(curlBody: "", curlExitCode: curlExitCode)
        let keyBytes = try XCTUnwrap(prepared.fixture.wakeKeyBytes)
        let proof = IPCWakeTestCrypto.hmacHex(
            keyBytes: keyBytes, message: Data(("approval\n" + Self.fixedNonce + "\n" + body).utf8)
        )
        try makeRecordingFakeCurl(
            atDirectory: prepared.fixture.fakeBinDir, recordDirectory: prepared.recordDirectory,
            stdoutBody: Data((proof + "\n" + body).utf8), exitCode: curlExitCode,
            listDirectory: prepared.scriptTmp, listingPath: prepared.listingPath,
            startedPath: prepared.curlStartedPath
        )
        return prepared
    }

    private func entries(_ directory: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []).sorted()
    }

    private func assertTwoTempFiles(_ listing: [String], _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(listing.count, 2, "[\(label)] exactly two temp files. Got: \(listing)", file: file, line: line)
        XCTAssertEqual(listing.filter { $0.hasPrefix("calyx-approval-payload.") }.count, 1,
                       "[\(label)] one payload file. Got: \(listing)", file: file, line: line)
        XCTAssertEqual(listing.filter { $0.hasPrefix("calyx-approval-response.") }.count, 1,
                       "[\(label)] one response file. Got: \(listing)", file: file, line: line)
    }

    // MARK: - Temp files

    func test_run_tempFilesLiveUnderTMPDIRWhileCurlRuns_andAreRemovedOnEveryCurlOutcome() throws {
        let body = #"{"hookSpecificOutput":{"decision":{"behavior":"deny"}}}"#
        for (label, exitCode, expectedStdout) in [("curl exit 0", Int32(0), body), ("curl exit 22", Int32(22), "")] {
            // Signed for the fake uuidgen's nonce with the fixture's key
            // (spec C.3 G3), so exit 0 prints the body after the proof line.
            let prepared = try prepare(signedCurlBody: body, curlExitCode: exitCode)
            let result = try runFakeCurlHookScript(
                prepared.fixture, stdinJSON: stdinJSON,
                extraEnv: ["CALYX_SURFACE_ID": UUID().uuidString, "TMPDIR": prepared.scriptTmp]
            )
            XCTAssertEqual(result.exitCode, 0, label)
            XCTAssertEqual(result.stdout, expectedStdout, label)
            XCTAssertEqual(recordedInvocations(of: "curl", inDirectory: prepared.recordDirectory).count, 1, label)
            let listing = (try? String(contentsOfFile: prepared.listingPath, encoding: .utf8))
                .map { $0.split(separator: "\n").map(String.init) } ?? []
            assertTwoTempFiles(listing, label)
            XCTAssertEqual(entries(prepared.scriptTmp), [String](), "[\(label)] no temp file is left")
        }
    }

    // MARK: - TERM before curl

    func test_run_termWhileDrainingStdin_exitsZero_noStdout_leavesNoTempFile() async throws {
        // Control: the same fixture (key blocks present, fake uuidgen
        // succeeding) does reach curl when no signal is sent, so an absent
        // start record below can only be the signalled check's doing.
        let control = try prepare(curlBody: #"{"hookSpecificOutput":{}}"#, curlExitCode: 0)
        let controlResult = try runFakeCurlHookScript(
            control.fixture, stdinJSON: stdinJSON,
            extraEnv: ["CALYX_SURFACE_ID": UUID().uuidString, "TMPDIR": control.scriptTmp]
        )
        XCTAssertEqual(controlResult.exitCode, 0, "control run")
        XCTAssertEqual(try? String(contentsOfFile: control.curlStartedPath, encoding: .utf8), "started\n",
                       "control: without a signal the same fixture starts curl exactly once")

        let prepared = try prepare(curlBody: #"{"hookSpecificOutput":{}}"#, curlExitCode: 0)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [prepared.fixture.scriptPath]
        process.environment = prepared.environment
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice
        // Every wait on the child is bounded (see the fulfillment below):
        // its exit is observed through terminationHandler and its stdout is
        // read to EOF on a GCD queue, never by blocking a Swift concurrency
        // thread, so a stall on the host side fails this test instead of
        // hanging the whole run.
        let exited = XCTestExpectation(description: "the script's process exits")
        process.terminationHandler = { _ in exited.fulfill() }
        let stdoutReadEnd = stdoutPipe.fileHandleForReading
        let stdoutFDAtStart = Self.fdIdentity(stdoutReadEnd.fileDescriptor)
        let stdoutCollector = StdoutCollector()
        let stdoutDrained = XCTestExpectation(description: "the script's stdout reaches EOF")
        try process.run()
        let pid = process.processIdentifier
        DispatchQueue.global(qos: .userInitiated).async {
            stdoutCollector.set(stdoutReadEnd.readDataToEndOfFile())
            stdoutDrained.fulfill()
        }

        // stdin stays open: the script is past both mktemp calls once both
        // files exist in TMPDIR, and then blocks in cat.
        stdinPipe.fileHandleForWriting.write(Data(stdinJSON.utf8))
        var bothFilesExist = false
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if entries(prepared.scriptTmp).count == 2 { bothFilesExist = true; break }
            try await Task.sleep(for: .milliseconds(20))
        }
        if bothFilesExist {
            kill(pid, SIGTERM)
        }
        stdinPipe.fileHandleForWriting.closeFile()
        let waitResult = await XCTWaiter().fulfillment(of: [exited, stdoutDrained], timeout: 10)
        guard waitResult == .completed else {
            let probeErrno = kill(pid, 0) == 0 ? "exists (0)" : "errno \(errno)"
            XCTFail("the script did not finish within 10s after stdin closed (result \(waitResult.rawValue)): " +
                    "exit observed=\(!process.isRunning), stdout EOF=\(stdoutCollector.isSet), " +
                    "kill(pid, 0)=\(probeErrno), stdout read fd at start=\(stdoutFDAtStart), " +
                    "now=\(Self.fdIdentity(stdoutReadEnd.fileDescriptor)), " +
                    "TMPDIR=\(entries(prepared.scriptTmp))")
            if process.isRunning { kill(pid, SIGKILL) }
            return
        }
        let exitCode = process.terminationStatus
        let stdout = String(data: stdoutCollector.data, encoding: .utf8) ?? ""

        XCTAssertTrue(bothFilesExist,
                      "precondition: both templated temp files must appear under TMPDIR before cat. Got: " +
                      "\(entries(prepared.scriptTmp))")
        guard bothFilesExist else { return }
        XCTAssertEqual(exitCode, 0, "a TERM during cat ends the script with exit 0")
        XCTAssertEqual(stdout, "")
        // "curl never starts" is a structural property, pinned by the static
        // adjacency tests (AgentHookLongPollTests and
        // ApprovalHookScriptTests.test_scriptBody_signalledCheckSitsRightBeforeCurl).
        // A behaviour test cannot observe it: without guardBeforeCurl, the
        // afterCurl re-check's TERM reaches the forked child before it execs
        // the fake curl, so even a record written as curl's first action
        // never appears. The two absence checks below are a harmless extra.
        XCTAssertFalse(FileManager.default.fileExists(atPath: prepared.curlStartedPath),
                       "no curl start record after a TERM during cat")
        XCTAssertEqual(recordedInvocations(of: "curl", inDirectory: prepared.recordDirectory), [String](),
                       "no curl invocation record after a TERM during cat")
        XCTAssertEqual(entries(prepared.scriptTmp), [String](), "the EXIT trap removes both temp files")
    }

    /// `<inode>/<mode>` of `fd` for the timeout diagnostics, or the errno
    /// when `fstat` fails: a changed value means the descriptor number was
    /// closed and reused while the reader waited on it.
    private static func fdIdentity(_ fd: Int32) -> String {
        var info = stat()
        guard fstat(fd, &info) == 0 else { return "fstat errno \(errno)" }
        return "\(info.st_ino)/\(String(info.st_mode, radix: 8))"
    }
}

/// The child's stdout, written once by the GCD reader and read by the
/// test after both expectations are fulfilled.
private final class StdoutCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Data?
    func set(_ data: Data) { lock.withLock { stored = data } }
    var data: Data { lock.withLock { stored ?? Data() } }
    var isSet: Bool { lock.withLock { stored != nil } }
}
