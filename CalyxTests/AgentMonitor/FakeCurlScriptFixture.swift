//
//  FakeCurlScriptFixture.swift
//  CalyxTests
//
//  Shared fake-curl PATH-shim + /bin/sh execution harness for driving an
//  installed hook script (calyx-agent-hook / calyx-approval-hook /
//  calyx-ipc-wake-hook) as a real child process, without a real network
//  round trip. Consolidates
//  three independent copies (ApprovalHookScriptTests,
//  ApprovalHookScriptHerdrGuardTests, AgentHookScriptHerdrGuardTests each
//  carried their own fake-curl generator and script-runner) that each had
//  to independently reimplement the real script's own contract: draining
//  whatever stdin it's given (harmless either way -- calyx-agent-hook
//  still forwards the caller's own stdin to curl via `--data-binary @-`;
//  calyx-approval-hook's curl instead reads a temp file and its
//  backgrounded stdin is /dev/null under POSIX job control, so this fake
//  curl's own stdin is empty for it), prepending PATH so the fake curl
//  resolves ahead of the real one, and building a HOME whose
//  `Library/Application Support/Calyx` layout matches exactly what the
//  script itself reads at invocation time. Without this, a future change
//  to any of those (e.g. the script's own curl invocation shape, or the
//  endpoint file's location) only gets caught by whichever copy a test
//  author happened to update, leaving the other two silently passing
//  against a stale harness. Mirrors TwoPaneSessionFixture.swift /
//  ReconnectFixture.swift's own precedent for extracting a
//  verbatim-duplicated test shape into one shared file.
//
//  calyx-ipc-wake-hook decides its exit code from the bytes curl printed
//  and reports on its own stderr, which the two older scripts never do.
//  Two additions serve it: `makeFakeCurl(stdoutBody:)` makes the fake curl
//  print a chosen response body, and
//  `runFakeCurlHookScriptCapturingStderr` returns the script's stderr
//  next to its exit code and stdout. `runFakeCurlHookScript` delegates to
//  it, so the process-spawning code exists once. Its temp file is
//  watched through TMPDIR, passed in `extraEnv`: the script creates it
//  with a `mktemp` template under `${TMPDIR:-/tmp}`, so no `mktemp` shim
//  is needed.
//
//  The recording wrappers (`installRecordingWrappers`,
//  `makeRecordingFakeCurl`, `makeFakeUuidgen(recordDirectory:)`) write
//  into a record DIRECTORY, one file per invocation
//  (`<recordDirectory>/<tool>.$$`), never into one shared file. The wake
//  hook's HMAC pipeline starts several wrapped tools at once (three `xxd`
//  and two `openssl`), and each record is many separate writes (the argv
//  header, one write per argument, the `env` output, `END`); appended to a
//  shared file those writes interleave mid-line and splice headers such
//  as `ARGV xxdARGV xxd [-r] ...`, so a line-anchored reader misses a tool
//  that did run. `$$` is the wrapper's own PID, which stays the same
//  across its `exec` and is unique among concurrently live processes, so
//  no two concurrent writers ever share a file. `readRecordDirectory`
//  and `recordedInvocations(of:inDirectory:)` concatenate every file.
//
//  Each call site still owns its own cleanup (matching
//  TwoPaneSessionFixture.swift's established discipline): this file only
//  builds the fixture and its fake curl, it does not manage any
//  XCTestCase's tearDown.
//

import Foundation
@testable import Calyx

/// A temp HOME with a working `agent-endpoint.json` under
/// `Library/Application Support/Calyx` and `install`'s script installed
/// into its `bin/` -- the exact HOME-relative layout every hook script
/// itself reads at invocation time (`$HOME/Library/Application
/// Support/Calyx/agent-endpoint.json`). `fakeBinDir` is a second,
/// separate directory a caller installs its own fake `curl` into (see
/// `makeFakeCurl`), then `runFakeCurlHookScript` prepends to PATH.
struct FakeCurlScriptFixture {
    let rootDir: String
    let home: String
    let appSupportDir: String
    let fakeBinDir: String
    let scriptPath: String
    /// The wake proof key whose two blocks agent-endpoint.json carries
    /// (`wakeProofInner`/`wakeProofOuter`), or nil when the file was
    /// written without them.
    let wakeKeyBytes: Data?

    /// `<appSupportDir>/agent-endpoint.json`.
    var endpointFilePath: String { appSupportDir + "/agent-endpoint.json" }
}

/// Builds a `FakeCurlScriptFixture`. `rootDirectory` defaults to a fresh
/// temp directory; pass an explicit path (e.g. nested under a test
/// class's own already-cleaned-up tempDir) when the caller wants to own
/// cleanup itself rather than track this fixture's `rootDir` separately.
/// `port`/`token` are arbitrary -- nothing in this harness ever reads
/// `agent-endpoint.json` back through a real server, so any
/// distinct-enough values will do. The file is written by hand
/// (`IPCWakeTestCrypto.writeEndpointFile`, 0600) with the two wake proof
/// blocks of `wakeKeyBytes`, a fresh random 32-byte key unless given; pass
/// nil for a file with port and token only.
func makeFakeCurlScriptFixture(
    rootDirectory: String = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString).path,
    port: Int,
    token: String,
    wakeKeyBytes: Data? = IPCWakeTestCrypto.randomKeyBytes(),
    install: (String) throws -> String
) throws -> FakeCurlScriptFixture {
    let home = rootDirectory + "/home"
    let appSupportDir = home + "/Library/Application Support/Calyx"
    let fakeBinDir = rootDirectory + "/fakebin"
    try IPCWakeTestCrypto.writeEndpointFile(directory: appSupportDir, port: port, token: token, keyBytes: wakeKeyBytes)
    let scriptPath = try install(appSupportDir + "/bin")
    return FakeCurlScriptFixture(
        rootDir: rootDirectory, home: home, appSupportDir: appSupportDir,
        fakeBinDir: fakeBinDir, scriptPath: scriptPath, wakeKeyBytes: wakeKeyBytes
    )
}

/// Writes a fake `curl` executable at `<dir>/curl` that drains its own
/// stdin (whatever it is -- see this file's header comment for why that
/// differs between calyx-agent-hook and calyx-approval-hook -- so nothing
/// is ever left unread), optionally appends one "invoked" line to
/// `recordPath` per call, optionally prints `stdoutBody` on its stdout,
/// and exits with `exitCode` (0 by default).
///
/// `stdoutBody`, when non-nil, is printed byte for byte with no newline
/// added: it is written to `<dir>/curl-stdout-body` and the fake curl
/// `cat`s that file, so no character of the body is ever interpreted by
/// the shell. `nil` prints nothing, exactly as before this parameter
/// existed.
func makeFakeCurl(
    atDirectory dir: String,
    exitCode: Int32 = 0,
    recordingTo recordPath: String? = nil,
    stdoutBody: String? = nil
) throws {
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let curlPath = dir + "/curl"
    let recordLine = recordPath.map { "printf 'invoked\\n' >> \"\($0)\"\n" } ?? ""
    var stdoutLine = ""
    if let stdoutBody {
        let stdoutBodyPath = dir + "/curl-stdout-body"
        try Data(stdoutBody.utf8).write(to: URL(fileURLWithPath: stdoutBodyPath))
        stdoutLine = "cat \"\(stdoutBodyPath)\"\n"
    }
    let body = """
    #!/bin/sh
    cat > /dev/null
    \(recordLine)\(stdoutLine)exit \(exitCode)
    """
    try body.write(toFile: curlPath, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: curlPath)
}

/// Runs `fixture.scriptPath` as a real child `/bin/sh` process, with
/// `fixture.fakeBinDir` prepended to PATH (ahead of the real system PATH,
/// so `curl` resolves to the fake one while `sed` etc. still resolve
/// normally), `extraEnv` merged on top of the base HOME/PATH environment
/// (e.g. `CALYX_SURFACE_ID` so the script's own early guard doesn't
/// short-circuit before ever reaching curl, or `HERDR_PANE_ID` to drive
/// the herdr guard), and `kindArgument` passed as `$1` when non-nil.
/// Returns the script's exit code and stdout; see
/// `runFakeCurlHookScriptCapturingStderr` for its stderr as well.
@discardableResult
func runFakeCurlHookScript(
    _ fixture: FakeCurlScriptFixture,
    stdinJSON: String,
    extraEnv: [String: String] = [:],
    kindArgument: String? = nil
) throws -> (exitCode: Int32, stdout: String) {
    let result = try runFakeCurlHookScriptCapturingStderr(
        fixture, stdinJSON: stdinJSON, extraEnv: extraEnv, kindArgument: kindArgument
    )
    return (result.exitCode, result.stdout)
}

/// `runFakeCurlHookScript` with the script's stderr returned too. The
/// child's environment is exactly HOME, PATH and `extraEnv`, nothing
/// inherited. Both pipes are read to EOF before `waitUntilExit()`, stdout
/// first: every script driven through this harness writes far less than
/// one pipe buffer to either stream, so the sequential reads cannot
/// block the child.
@discardableResult
func runFakeCurlHookScriptCapturingStderr(
    _ fixture: FakeCurlScriptFixture,
    stdinJSON: String,
    extraEnv: [String: String] = [:],
    kindArgument: String? = nil
) throws -> (exitCode: Int32, stdout: String, stderr: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = kindArgument.map { [fixture.scriptPath, $0] } ?? [fixture.scriptPath]
    let inheritedPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/local/bin"
    var env = ["HOME": fixture.home, "PATH": "\(fixture.fakeBinDir):\(inheritedPath)"]
    for (key, value) in extraEnv { env[key] = value }
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
    let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
    let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (
        process.terminationStatus,
        String(data: stdoutData, encoding: .utf8) ?? "",
        String(data: stderrData, encoding: .utf8) ?? ""
    )
}

// MARK: - calyx-ipc-wake-hook additions (slice A-5)

/// Writes an executable `/bin/sh` script named `name` into `dir` with
/// `body` after the shebang line.
func writeFakeTool(named name: String, atDirectory dir: String, body: String) throws {
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let path = dir + "/" + name
    try ("#!/bin/sh\n" + body + "\n").write(toFile: path, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
}

/// A fake `uuidgen` that prints `stdout` byte for byte (from a file, so no
/// character is interpreted by the shell) and exits with `exitCode`. With
/// `recordDirectory` it writes its argv and environment to its own file
/// there as the recording wrappers do; with `noise` it prints
/// `NOISE-uuidgen` to stderr.
func makeFakeUuidgen(
    atDirectory dir: String, stdout: String, exitCode: Int32 = 0,
    recordDirectory: String? = nil, noise: Bool = false
) throws {
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let stdoutPath = dir + "/uuidgen-stdout"
    try Data(stdout.utf8).write(to: URL(fileURLWithPath: stdoutPath))
    var body = ""
    if let recordDirectory {
        try FileManager.default.createDirectory(atPath: recordDirectory, withIntermediateDirectories: true)
        body += "{ printf 'ARGV uuidgen'; for a in \"$@\"; do printf ' [%s]' \"$a\"; done; printf '\\n'; "
            + "/usr/bin/env; printf 'END\\n'; } >> \"\(recordDirectory)/uuidgen.$$\"\n"
    }
    if noise { body += "printf 'NOISE-uuidgen\\n' >&2\n" }
    body += "/bin/cat \"\(stdoutPath)\"\nexit \(exitCode)"
    try writeFakeTool(named: "uuidgen", atDirectory: dir, body: body)
}

/// A replacement for `name` that drains its stdin, prints `stdout` (from a
/// file) and exits with `exitCode`: a failing `openssl`, `xxd` or `grep`.
func makeFailingTool(named name: String, atDirectory dir: String, exitCode: Int32, stdout: String = "") throws {
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let stdoutPath = dir + "/\(name)-stdout"
    try Data(stdout.utf8).write(to: URL(fileURLWithPath: stdoutPath))
    try writeFakeTool(
        named: name, atDirectory: dir,
        body: "/bin/cat > /dev/null\n/bin/cat \"\(stdoutPath)\"\nexit \(exitCode)"
    )
}

/// The real tools the wake hook and the approval hook run, by absolute path, for
/// `installRecordingWrappers`. `curl` is not here: the fake curl stands in
/// for it (`makeRecordingFakeCurl`).
let wakeHookRealTools: [String: String] = [
    "sed": "/usr/bin/sed", "grep": "/usr/bin/grep", "tr": "/usr/bin/tr",
    "uuidgen": "/usr/bin/uuidgen", "openssl": "/usr/bin/openssl", "xxd": "/usr/bin/xxd",
    "mktemp": "/usr/bin/mktemp", "cat": "/bin/cat", "rm": "/bin/rm",
    // The approval hook's verification tail also runs head and tail.
    "head": "/usr/bin/head", "tail": "/usr/bin/tail",
]

/// Puts a recording wrapper for each of `names` into `dir`. Each wrapper
/// writes `ARGV <name> [arg1] [arg2] ...` and then the output of
/// `/usr/bin/env` followed by `END` to its own file
/// `<recordDirectory>/<name>.$$` (see this file's header comment for why
/// one file per invocation), prints
/// `NOISE-<name>` to stderr when `noise` is true, then `exec`s the real
/// tool by absolute path with the same argv and stdin.
func installRecordingWrappers(
    atDirectory dir: String, recordDirectory: String, noise: Bool = false,
    names: [String] = ["sed", "grep", "tr", "uuidgen", "openssl", "xxd", "mktemp", "cat", "rm"]
) throws {
    try FileManager.default.createDirectory(atPath: recordDirectory, withIntermediateDirectories: true)
    for name in names {
        let real = try XCTUnwrapTool(wakeHookRealTools[name], name)
        let noiseLine = noise ? "printf 'NOISE-\(name)\\n' >&2\n" : ""
        try writeFakeTool(named: name, atDirectory: dir, body: """
        { printf 'ARGV \(name)'; for a in "$@"; do printf ' [%s]' "$a"; done; printf '\\n'; /usr/bin/env; printf 'END\\n'; } >> "\(recordDirectory)/\(name).$$"
        \(noiseLine)exec \(real) "$@"
        """)
    }
}

private struct UnknownToolError: Error { let name: String }

private func XCTUnwrapTool(_ value: String?, _ name: String) throws -> String {
    guard let value else { throw UnknownToolError(name: name) }
    return value
}

/// A fake `curl` that drains stdin, writes `ARGV curl [arg] ...` and its
/// environment to its own file `<recordDirectory>/curl.$$` (as the
/// recording wrappers do), optionally
/// lists `listDirectory` into `listingPath`, prints `NOISE-curl` to stderr
/// when `noise`, prints `stdoutBody` byte for byte and exits `exitCode`.
func makeRecordingFakeCurl(
    atDirectory dir: String,
    recordDirectory: String,
    stdoutBody: Data,
    exitCode: Int32 = 0,
    noise: Bool = false,
    listDirectory: String? = nil,
    listingPath: String? = nil,
    startedPath: String? = nil
) throws {
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(atPath: recordDirectory, withIntermediateDirectories: true)
    let bodyPath = dir + "/curl-stdout-body"
    try stdoutBody.write(to: URL(fileURLWithPath: bodyPath))
    var listLine = ""
    if let listDirectory, let listingPath {
        listLine = "/bin/ls -A \"\(listDirectory)\" > \"\(listingPath)\"\n"
    }
    let noiseLine = noise ? "printf 'NOISE-curl\\n' >&2\n" : ""
    // When requested, the very first action is an unconditional record, so
    // a curl that starts at all leaves a trace even if it is killed
    // immediately afterwards.
    var startedLine = ""
    if let startedPath {
        startedLine = "printf 'started\\n' >> \"\(startedPath)\"\n"
    }
    try writeFakeTool(named: "curl", atDirectory: dir, body: """
    \(startedLine)/bin/cat > /dev/null
    { printf 'ARGV curl'; for a in "$@"; do printf ' [%s]' "$a"; done; printf '\\n'; /usr/bin/env; printf 'END\\n'; } >> "\(recordDirectory)/curl.$$"
    \(listLine)\(noiseLine)/bin/cat "\(bodyPath)"
    exit \(exitCode)
    """)
}

/// Every record file in `recordDirectory` concatenated, in file-name
/// order (each file holds whole records, so records never split), or ""
/// when the directory is missing or empty. The order across files is not
/// invocation order; no reader depends on it.
func readRecordDirectory(_ recordDirectory: String) -> String {
    let names = ((try? FileManager.default.contentsOfDirectory(atPath: recordDirectory)) ?? []).sorted()
    return names
        .map { (try? String(contentsOfFile: recordDirectory + "/" + $0, encoding: .utf8)) ?? "" }
        .joined()
}

/// The `ARGV <tool> ...` lines of every record file in `recordDirectory`.
func recordedInvocations(of tool: String, inDirectory recordDirectory: String) -> [String] {
    readRecordDirectory(recordDirectory)
        .components(separatedBy: "\n")
        .filter { $0 == "ARGV \(tool)" || $0.hasPrefix("ARGV \(tool) ") }
}
