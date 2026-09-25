//
//  FakeCurlScriptFixture.swift
//  CalyxTests
//
//  Shared fake-curl PATH-shim + /bin/sh execution harness for driving an
//  installed hook script (calyx-agent-hook / calyx-approval-hook) as a
//  real child process, without a real network round trip. Consolidates
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
}

/// Builds a `FakeCurlScriptFixture`. `rootDirectory` defaults to a fresh
/// temp directory; pass an explicit path (e.g. nested under a test
/// class's own already-cleaned-up tempDir) when the caller wants to own
/// cleanup itself rather than track this fixture's `rootDir` separately.
/// `port`/`token` are arbitrary -- nothing in this harness ever reads
/// `agent-endpoint.json` back through a real server, so any
/// distinct-enough values will do.
func makeFakeCurlScriptFixture(
    rootDirectory: String = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString).path,
    port: Int,
    token: String,
    install: (String) throws -> String
) throws -> FakeCurlScriptFixture {
    let home = rootDirectory + "/home"
    let appSupportDir = home + "/Library/Application Support/Calyx"
    let fakeBinDir = rootDirectory + "/fakebin"
    try AgentEndpointFile.write(port: port, token: token, directory: appSupportDir)
    let scriptPath = try install(appSupportDir + "/bin")
    return FakeCurlScriptFixture(
        rootDir: rootDirectory, home: home, appSupportDir: appSupportDir,
        fakeBinDir: fakeBinDir, scriptPath: scriptPath
    )
}

/// Writes a fake `curl` executable at `<dir>/curl` that drains its own
/// stdin (whatever it is -- see this file's header comment for why that
/// differs between calyx-agent-hook and calyx-approval-hook -- so nothing
/// is ever left unread), optionally appends one "invoked" line to
/// `recordPath` per call, and exits with `exitCode` (0 by default).
func makeFakeCurl(atDirectory dir: String, exitCode: Int32 = 0, recordingTo recordPath: String? = nil) throws {
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let curlPath = dir + "/curl"
    let recordLine = recordPath.map { "printf 'invoked\\n' >> \"\($0)\"\n" } ?? ""
    let body = """
    #!/bin/sh
    cat > /dev/null
    \(recordLine)exit \(exitCode)
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
@discardableResult
func runFakeCurlHookScript(
    _ fixture: FakeCurlScriptFixture,
    stdinJSON: String,
    extraEnv: [String: String] = [:],
    kindArgument: String? = nil
) throws -> (exitCode: Int32, stdout: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = kindArgument.map { [fixture.scriptPath, $0] } ?? [fixture.scriptPath]
    let inheritedPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/local/bin"
    var env = ["HOME": fixture.home, "PATH": "\(fixture.fakeBinDir):\(inheritedPath)"]
    for (key, value) in extraEnv { env[key] = value }
    process.environment = env

    let stdinPipe = Pipe()
    let stdoutPipe = Pipe()
    process.standardInput = stdinPipe
    process.standardOutput = stdoutPipe
    process.standardError = Pipe()

    try process.run()
    stdinPipe.fileHandleForWriting.write(Data(stdinJSON.utf8))
    stdinPipe.fileHandleForWriting.closeFile()
    let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(data: stdoutData, encoding: .utf8) ?? "")
}
