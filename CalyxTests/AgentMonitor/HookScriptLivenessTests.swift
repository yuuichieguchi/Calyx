//
//  HookScriptLivenessTests.swift
//  CalyxTests
//
//  Spec Feature C, J2: every sender checks, before it sends the token,
//  that the Calyx process that wrote agent-endpoint.json is alive
//  (`kill -0 pid`) and is the same process (`pidStart` equals the
//  normalised `TZ=UTC LC_ALL=C ps -p pid -o lstart=`). A missing key, a
//  dead pid, another user's pid or a different start time all mean: no
//  curl, exit 0, nothing on stdout.
//
//  Real child processes throughout: the three /bin/sh hook scripts
//  (calyx-agent-hook, calyx-approval-hook, calyx-ipc-wake-hook) through
//  FakeCurlScriptFixture, and the zsh/fish shell-integration `_calyx_post`
//  through real /bin/zsh and fish with a stub curl. The OpenCode plugin
//  and pi extension are pinned by text: no existing test launches bun or
//  node for them (spec C.4), and bun is not installed.
//
//  Five cases per sender:
//  (i)   dead pid (a reaped child)              -> no curl
//  (ii)  own pid, altered pidStart              -> no curl
//  (iii) pid 1 with launchd's real start time   -> no curl (kill -0 EPERM)
//  (iv)  own pid + own start time               -> curl exactly once
//  (v)   pid missing / pidStart missing / both  -> no curl
//
//  The expected start texts come from TestHostLiveness (`/bin/ps`,
//  computed independently of production code).
//

import XCTest
@testable import Calyx

final class HookScriptLivenessTests: XCTestCase {

    private var tempDir: String!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("HookScriptLivenessTests-" + UUID().uuidString).path
        try! FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let tempDir { try? FileManager.default.removeItem(atPath: tempDir) }
        tempDir = nil
        super.tearDown()
    }

    // MARK: - Liveness inputs

    private enum Liveness: CustomStringConvertible {
        case deadPid, alteredStart, pidOne, own, pidMissing, startMissing, bothMissing

        static let negatives: [Liveness] = [.deadPid, .alteredStart, .pidOne, .pidMissing, .startMissing, .bothMissing]

        var description: String {
            switch self {
            case .deadPid: return "dead pid"
            case .alteredStart: return "own pid, altered pidStart"
            case .pidOne: return "pid 1"
            case .own: return "own pid and start time"
            case .pidMissing: return "pid missing"
            case .startMissing: return "pidStart missing"
            case .bothMissing: return "pid and pidStart missing"
            }
        }
    }

    /// The pid of a child that has exited and been reaped, confirmed dead
    /// with kill(pid, 0) == ESRCH.
    private func deadPid() throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try process.run()
        process.waitUntilExit()
        let pid = process.processIdentifier
        let result = kill(pid, 0)
        let error = errno
        XCTAssertEqual(result, -1, "precondition: the reaped child's pid is not alive")
        XCTAssertEqual(error, ESRCH, "precondition: the reaped child's pid does not exist")
        return pid
    }

    /// (pid, pidStart) for the endpoint file; nil omits the key.
    private func values(_ liveness: Liveness) throws -> (pid: Int32?, pidStart: String?) {
        let own = TestHostLiveness.startText
        XCTAssertFalse(own.isEmpty, "precondition: ps reported the test host's start time")
        switch liveness {
        case .deadPid:
            return (try deadPid(), own)
        case .alteredStart:
            // Same shape, a different year: a reused pid's start time.
            return (TestHostLiveness.pid, String(own.dropLast(4)) + "1999")
        case .pidOne:
            let launchd = try XCTUnwrap(TestHostLiveness.startText(ofPid: 1), "precondition: ps reports pid 1")
            let result = kill(1, 0)
            let error = errno
            XCTAssertEqual(result, -1, "precondition: the test host cannot signal pid 1")
            XCTAssertEqual(error, EPERM, "precondition: pid 1 exists but is not signalable (EPERM), so only the kill -0 EPERM path can stop this case")
            return (1, launchd)
        case .own:
            return (TestHostLiveness.pid, own)
        case .pidMissing:
            return (nil, own)
        case .startMissing:
            return (TestHostLiveness.pid, nil)
        case .bothMissing:
            return (nil, nil)
        }
    }

    // MARK: - /bin/sh hook scripts

    private struct ScriptRun {
        let exitCode: Int32
        let stdout: String
        let curlInvocations: [String]
        let record: String
    }

    private func runScript(
        _ install: (String) throws -> String, stdin: String, liveness: Liveness, kindArgument: String? = nil
    ) throws -> ScriptRun {
        let v = try values(liveness)
        let fixture = try makeFakeCurlScriptFixture(
            rootDirectory: tempDir + "/" + UUID().uuidString,
            port: 41_877, token: "liveness-test-token",
            pid: v.pid, pidStart: v.pidStart,
            install: install
        )
        let recordDirectory = fixture.rootDir + "/record.d"
        try makeRecordingFakeCurl(atDirectory: fixture.fakeBinDir, recordDirectory: recordDirectory, stdoutBody: Data())
        let scriptTmp = fixture.rootDir + "/script-tmp"
        try FileManager.default.createDirectory(atPath: scriptTmp, withIntermediateDirectories: true)
        let result = try runFakeCurlHookScriptCapturingStderr(
            fixture, stdinJSON: stdin,
            extraEnv: ["CALYX_SURFACE_ID": UUID().uuidString, "TMPDIR": scriptTmp],
            kindArgument: kindArgument
        )
        return ScriptRun(
            exitCode: result.exitCode, stdout: result.stdout,
            curlInvocations: recordedInvocations(of: "curl", inDirectory: recordDirectory),
            record: readRecordDirectory(recordDirectory)
        )
    }

    private let agentStdin = #"{"hook_event_name":"Stop","session_id":"liveness-1"}"#
    private let approvalStdin =
        #"{"hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"ls"}}"#

    private func scripts() -> [(name: String, install: (String) throws -> String, stdin: String)] {
        [
            ("calyx-agent-hook", AgentHookScript.install(toDirectory:), agentStdin),
            ("calyx-approval-hook", ApprovalHookScript.install(toDirectory:), approvalStdin),
            ("calyx-ipc-wake-hook", IPCWakeHookScript.install(toDirectory:), agentStdin),
        ]
    }

    func test_shScripts_negativeLiveness_neverRunCurl_exit0_noStdout() throws {
        for script in scripts() {
            for liveness in Liveness.negatives {
                let run = try runScript(script.install, stdin: script.stdin, liveness: liveness)
                XCTAssertEqual(run.curlInvocations.count, 0, "[\(script.name), \(liveness)] curl must not run")
                XCTAssertEqual(run.exitCode, 0, "[\(script.name), \(liveness)] must exit 0")
                XCTAssertEqual(run.stdout, "", "[\(script.name), \(liveness)] must print nothing")
            }
        }
    }

    /// Canary: with the test host's own identifier every script reaches
    /// curl exactly once, so the negative cases above fail for the
    /// liveness reason and not because the fixture is broken.
    func test_shScripts_ownLiveness_runCurlExactlyOnce() throws {
        for script in scripts() {
            let run = try runScript(script.install, stdin: script.stdin, liveness: .own)
            XCTAssertEqual(run.curlInvocations.count, 1, "[\(script.name)] curl must run exactly once")
        }
    }

    /// `set --` in shellResolution clobbers `$1`; the kind must already be
    /// resolved by then, so the curl still carries the kind argument.
    func test_agentHook_ownLiveness_keepsTheKindArgumentAfterTheLivenessCheck() throws {
        let run = try runScript(AgentHookScript.install(toDirectory:), stdin: agentStdin, liveness: .own,
                                kindArgument: "codex")
        XCTAssertEqual(run.curlInvocations.count, 1, "precondition: curl ran")
        XCTAssertTrue(run.record.contains("[X-Calyx-Agent-Kind: codex]"),
                      "the kind header must still be codex, got: \(run.curlInvocations)")
    }

    // MARK: - zsh / fish shell integration

    private var curlLogPath: String { tempDir + "/shell-curl.log" }

    private func installStubCurl() throws -> String {
        let binDir = tempDir + "/shell-bin"
        try writeFakeTool(named: "curl", atDirectory: binDir, body: "echo \"$@\" >> \"\(curlLogPath)\"\nexit 0")
        return binDir
    }

    private func curlLogLines() -> [String] {
        guard let text = try? String(contentsOfFile: curlLogPath, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    /// Writes the endpoint file for `liveness` and returns its path.
    private func writeShellEndpoint(_ liveness: Liveness) throws -> String {
        let v = try values(liveness)
        let dir = tempDir + "/endpoint-" + UUID().uuidString
        try IPCWakeTestCrypto.writeEndpointFile(
            directory: dir, port: 41_878, token: "shell-liveness-token", keyBytes: nil, pid: v.pid, pidStart: v.pidStart
        )
        return dir + "/agent-endpoint.json"
    }

    /// Mirrors ShellIntegrationInstallerTests.locateExecutable: widens
    /// PATH with the Homebrew and /usr/local prefixes.
    private func locateExecutable(named name: String) throws -> String? {
        let inherited = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for dir in ["/opt/homebrew/bin", "/usr/local/bin"] + inherited.split(separator: ":").map(String.init) {
            let candidate = dir + "/" + name
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// Sources `body` from a file in an interactive shell (`-i`, so the
    /// body's interactive guard passes) and calls `_calyx_post` once,
    /// synchronously (its curl is not backgrounded). Clears the curl log
    /// first and returns the shell's exit code.
    @discardableResult
    private func runShellPost(interpreter: String, extraArgs: [String], body: String, endpointFile: String) throws -> Int32 {
        try? FileManager.default.removeItem(atPath: curlLogPath)
        let binDir = try installStubCurl()
        let bodyPath = tempDir + "/integration-" + UUID().uuidString
        try body.write(toFile: bodyPath, atomically: true, encoding: .utf8)
        let home = tempDir + "/shell-home"
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        let inheritedPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: interpreter)
        process.arguments = extraArgs + ["-i", "-c", "source '\(bodyPath)'; _calyx_post '{}'"]
        process.environment = [
            "HOME": home,
            "PATH": "\(binDir):\(inheritedPath)",
            "CALYX_SURFACE_ID": UUID().uuidString,
            "CALYX_ENDPOINT_FILE": endpointFile,
            "XDG_CONFIG_HOME": home + "/.config",
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    private func assertShellLiveness(interpreter: String, extraArgs: [String], body: String, label: String) throws {
        for liveness in Liveness.negatives {
            try runShellPost(interpreter: interpreter, extraArgs: extraArgs, body: body,
                             endpointFile: try writeShellEndpoint(liveness))
            XCTAssertEqual(curlLogLines(), [String](), "[\(label), \(liveness)] curl must not run")
        }
        try runShellPost(interpreter: interpreter, extraArgs: extraArgs, body: body,
                         endpointFile: try writeShellEndpoint(.own))
        let lines = curlLogLines()
        XCTAssertEqual(lines.count, 1, "[\(label), own] curl must run exactly once (canary), got \(lines)")
        XCTAssertTrue(lines.first?.contains("http://127.0.0.1:41878/command-event") ?? false,
                      "[\(label), own] curl must target the endpoint's port, got \(lines)")
    }

    func test_zsh_calyxPost_onlyPostsForTheLiveMatchingProcess() throws {
        try assertShellLiveness(interpreter: "/bin/zsh", extraArgs: ["-f"],
                                body: ShellIntegrationInstaller.calyxZshBody, label: "zsh")
    }

    func test_fish_calyxPost_onlyPostsForTheLiveMatchingProcess() throws {
        guard let fish = try locateExecutable(named: "fish") else {
            throw XCTSkip("fish is not installed on this host")
        }
        try assertShellLiveness(interpreter: fish, extraArgs: ["--no-config"],
                                body: ShellIntegrationInstaller.fishIntegrationBody, label: "fish")
    }

    func test_zshAndFish_bodiesUseTheSpecifiedLivenessIdioms() {
        let zsh = ShellIntegrationInstaller.calyxZshBody
        XCTAssertTrue(zsh.contains("builtin kill -0"), "zsh must use the builtin kill -0")
        XCTAssertTrue(zsh.contains(#"${(j: :)${=$(TZ=UTC LC_ALL=C command ps -p "$pid" -o lstart=)}}"#),
                      "zsh must normalise ps lstart with ${(j: :)${=...}}")
        XCTAssertTrue(zsh.contains("\"pidStart\""))
        let fish = ShellIntegrationInstaller.fishIntegrationBody
        XCTAssertTrue(fish.contains("command kill -0"), "fish must use command kill -0")
        XCTAssertTrue(fish.contains("string split -n ' '") && fish.contains("string join ' '"),
                      "fish must normalise ps lstart with string split -n ' ' | string join ' '")
        XCTAssertTrue(fish.contains("TZ=UTC LC_ALL=C"), "fish must run ps in UTC / C locale")
        XCTAssertTrue(fish.contains("\"pidStart\""))
    }

    // MARK: - OpenCode plugin / pi extension (text pins)

    private func ranges(of needle: String, in text: String) -> [Range<String.Index>] {
        var result: [Range<String.Index>] = []
        var searchStart = text.startIndex
        while let r = text.range(of: needle, range: searchStart..<text.endIndex) {
            result.append(r)
            searchStart = r.upperBound
        }
        return result
    }

    private func assertJSLiveness(_ body: String, label: String, expectedFetches: Int) {
        for needle in ["\"pidStart\"", "TZ: \"UTC\"", "LC_ALL: \"C\"", "process.kill(", "spawnSync(",
                       "\"lstart=\"", "function liveEndpoint"] {
            XCTAssertTrue(body.contains(needle), "[\(label)] must contain \(needle)")
        }
        XCTAssertTrue(body.contains(#"spawnSync("ps""#), "[\(label)] must run ps through spawnSync")
        let fetches = ranges(of: "fetch(", in: body)
        XCTAssertEqual(fetches.count, expectedFetches, "[\(label)] precondition: fetch call count")
        let calls = ranges(of: "liveEndpoint(", in: body).filter { r in
            !body[..<r.lowerBound].hasSuffix("function ")
        }
        var previous = body.startIndex
        for (index, fetch) in fetches.enumerated() {
            let guarded = calls.contains { $0.lowerBound >= previous && $0.upperBound <= fetch.lowerBound }
            XCTAssertTrue(guarded, "[\(label)] fetch #\(index + 1) must be preceded by a liveEndpoint() call " +
                          "after the previous fetch")
            previous = fetch.upperBound
        }
    }

    func test_openCodePlugin_checksLivenessBeforeEveryFetch() {
        assertJSLiveness(OpenCodePluginManager.scriptBody, label: "OpenCode", expectedFetches: 1)
    }

    func test_piExtension_checksLivenessBeforeEveryFetch() {
        assertJSLiveness(PiExtensionManager.scriptBody, label: "pi", expectedFetches: 4)
    }
}
