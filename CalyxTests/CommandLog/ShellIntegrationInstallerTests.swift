//
//  ShellIntegrationInstallerTests.swift
//  CalyxTests
//
//  Covers the command-log shell integration installer. Pins
//  ShellIntegrationInstaller's install/remove/isInstalled file-management
//  contract (mirroring OpenCodePluginManagerTests' verified symlink-
//  following behavior, NOT literal rejection) plus the actual runtime
//  contract of the installed zsh scripts: real /bin/zsh processes, a
//  stub curl shim on PATH logging its own invocation args, and a fixture
//  agent-endpoint.json -- see AgentHookPipelineIntegrationTests' header
//  for why this codebase prefers this kind of mock-less, real-process
//  coverage for exactly this class of bug (a script that looks correct
//  in isolation but was never actually reachable/correct end-to-end).
//
//  Script bodies (zshenvBody/calyxZshBody/fishIntegrationBody) are
//  EMPTY-STRING STUBS this phase -- every test below that exercises real
//  script behavior is therefore expected, and required, to fail: no
//  lines ever land in the curl log, ZDOTDIR is never restored, no marker
//  file is ever sourced. Each such test pairs its behavioral assertion
//  with a precondition/non-empty guard that itself fails against the
//  stub, so none of this passes vacuously.
//

import XCTest
@testable import Calyx

final class ShellIntegrationInstallerTests: XCTestCase {

    // MARK: - Properties

    private var tempDir: URL!

    // MARK: - Lifecycle

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShellIntegrationInstallerTests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        tempDir = nil
        super.tearDown()
    }

    private var installRoot: URL { tempDir.appendingPathComponent("shell-integration") }

    // MARK: - install / remove / isInstalled basics

    func test_install_writesThreeFilesWithExactBodiesAt0644() throws {
        _ = try ShellIntegrationInstaller.install(toDirectory: installRoot)

        let paths: [(URL, String)] = [
            (ShellIntegrationInstaller.zshenvPath(in: installRoot), ShellIntegrationInstaller.zshenvBody),
            (ShellIntegrationInstaller.calyxZshPath(in: installRoot), ShellIntegrationInstaller.calyxZshBody),
            (ShellIntegrationInstaller.fishIntegrationPath(in: installRoot), ShellIntegrationInstaller.fishIntegrationBody),
        ]

        for (path, expectedBody) in paths {
            let content = try String(contentsOf: path, encoding: .utf8)
            XCTAssertEqual(content, expectedBody, "\(path.lastPathComponent) must be written verbatim")

            let attrs = try FileManager.default.attributesOfItem(atPath: path.path)
            let permissions = (attrs[.posixPermissions] as? NSNumber)?.intValue
            XCTAssertEqual(
                permissions, 0o644,
                "\(path.lastPathComponent) is sourced, never executed directly -- 0644, not AgentHookScript's 0755"
            )
        }
    }

    func test_install_idempotent_reinstallOverwritesWithSameContent() throws {
        _ = try ShellIntegrationInstaller.install(toDirectory: installRoot)
        _ = try ShellIntegrationInstaller.install(toDirectory: installRoot)

        let content = try String(
            contentsOf: ShellIntegrationInstaller.zshenvPath(in: installRoot), encoding: .utf8
        )
        XCTAssertEqual(content, ShellIntegrationInstaller.zshenvBody,
                       "reinstalling must overwrite with the same fixed body, not append or duplicate")
    }

    /// Calyx owns these three files outright (they are never partially
    /// user-authored, unlike a dotfile Calyx only injects an entry into),
    /// so `ConfigFileUtils.withExclusiveConfig` is called with
    /// `restoreModeOnNoWrite: true` -- a reinstall whose bytes end up
    /// identical to what's already on disk must still repair a mode that
    /// drifted behind Calyx's back (a plain `chmod`, or a backup/restore
    /// tool that recreated the file), since a reinstall is the only
    /// repair path available to the user for a drifted mode on a
    /// Calyx-owned file.
    func test_install_reinstallWithIdenticalContent_restoresDriftedMode() throws {
        _ = try ShellIntegrationInstaller.install(toDirectory: installRoot)

        let zshenvPath = ShellIntegrationInstaller.zshenvPath(in: installRoot)
        XCTAssertEqual(chmod(zshenvPath.path, 0o600), 0, "precondition: simulate mode drift outside install()")

        var statBefore = stat()
        XCTAssertEqual(stat(zshenvPath.path, &statBefore), 0)
        XCTAssertEqual(statBefore.st_mode & ~S_IFMT, 0o600, "precondition: mode must actually be drifted")

        _ = try ShellIntegrationInstaller.install(toDirectory: installRoot)

        var statAfter = stat()
        XCTAssertEqual(stat(zshenvPath.path, &statAfter), 0)
        XCTAssertEqual(statAfter.st_mode & ~S_IFMT, 0o644,
                       "a reinstall with byte-identical content must still restore the drifted mode to 0644")
    }

    func test_install_returnsTheRootDirectory() throws {
        let returned = try ShellIntegrationInstaller.install(toDirectory: installRoot)
        // Compares `.path` rather than the `URL` values directly:
        // `URL.appendingPathComponent` (no explicit `isDirectory:` hint)
        // probes the filesystem to decide `hasDirectoryPath`, so a fresh
        // `installRoot` access AFTER `install()` created the directory
        // tree is not `Equatable`-equal to the very URL passed in as
        // `install`'s own argument (constructed before the directory
        // existed) -- `.path` sidesteps that representational quirk
        // entirely.
        XCTAssertEqual(
            returned.path, installRoot.path,
            "install must return the root directory unchanged, so callers can chain straight into " +
            "CalyxShellIntegrationEnvironment.apply(rootDirectory:)"
        )
    }

    func test_isInstalled_reflectsInstallState() throws {
        XCTAssertFalse(ShellIntegrationInstaller.isInstalled(inDirectory: installRoot),
                       "nothing installed yet -- must not be reported as installed")

        _ = try ShellIntegrationInstaller.install(toDirectory: installRoot)

        XCTAssertTrue(ShellIntegrationInstaller.isInstalled(inDirectory: installRoot),
                      "after install, all three files exist -- must be reported as installed")

        try ShellIntegrationInstaller.remove(fromDirectory: installRoot)

        XCTAssertFalse(ShellIntegrationInstaller.isInstalled(inDirectory: installRoot),
                       "after remove, must no longer be reported as installed")
    }

    func test_remove_deletesAllThreeInstalledFiles() throws {
        _ = try ShellIntegrationInstaller.install(toDirectory: installRoot)

        // Precondition: install must have actually created the files --
        // guards against remove()'s own assertions below passing
        // vacuously (files that were never created can't meaningfully be
        // asserted "gone after remove").
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: ShellIntegrationInstaller.zshenvPath(in: installRoot).path),
            "precondition: install must create zsh/.zshenv"
        )

        try ShellIntegrationInstaller.remove(fromDirectory: installRoot)

        for path in [
            ShellIntegrationInstaller.zshenvPath(in: installRoot),
            ShellIntegrationInstaller.calyxZshPath(in: installRoot),
            ShellIntegrationInstaller.fishIntegrationPath(in: installRoot),
        ] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: path.path),
                           "\(path.lastPathComponent) must be deleted by remove()")
        }
    }

    // MARK: - Symlink handling
    //
    // OpenCodePluginManagerTests' actual, verified contract:
    // install() FOLLOWS a symlink at the destination path and overwrites
    // the real target, leaving the symlink itself intact -- NOT
    // rejection. ConfigFileUtils.resolveConfigPath is the shared
    // primitive every config/script installer in this codebase uses for
    // this, so ShellIntegrationInstaller follows the same real
    // precedent rather than the plan's shorthand "symlink rejected"
    // phrasing.

    func test_install_symlinkAtZshenvDestination_followsAndOverwritesRealFileKeepingLinkIntact() throws {
        let zshDir = installRoot.appendingPathComponent("zsh")
        try FileManager.default.createDirectory(at: zshDir, withIntermediateDirectories: true)
        let realFile = tempDir.appendingPathComponent("real-zshenv")
        FileManager.default.createFile(atPath: realFile.path, contents: Data("# stale content".utf8))
        let destinationPath = zshDir.appendingPathComponent(".zshenv")
        try FileManager.default.createSymbolicLink(at: destinationPath, withDestinationURL: realFile)

        _ = try ShellIntegrationInstaller.install(toDirectory: installRoot)

        let realContent = try String(contentsOf: realFile, encoding: .utf8)
        XCTAssertEqual(realContent, ShellIntegrationInstaller.zshenvBody,
                       "install() must overwrite the real file reached through the symlink")

        let attrsAfter = try FileManager.default.attributesOfItem(atPath: destinationPath.path)
        XCTAssertEqual(attrsAfter[.type] as? FileAttributeType, .typeSymbolicLink,
                       "the symlink at .zshenv's destination path must survive the install")
    }

    func test_remove_symlinkAtZshenvDestination_removesRealFileKeepingLinkIntact() throws {
        let zshDir = installRoot.appendingPathComponent("zsh")
        try FileManager.default.createDirectory(at: zshDir, withIntermediateDirectories: true)
        let realFile = tempDir.appendingPathComponent("real-zshenv")
        FileManager.default.createFile(atPath: realFile.path, contents: Data(ShellIntegrationInstaller.zshenvBody.utf8))
        let destinationPath = zshDir.appendingPathComponent(".zshenv")
        try FileManager.default.createSymbolicLink(at: destinationPath, withDestinationURL: realFile)

        try ShellIntegrationInstaller.remove(fromDirectory: installRoot)

        XCTAssertFalse(FileManager.default.fileExists(atPath: realFile.path),
                       "remove() must delete the real file reached through the symlink")
        let attrsAfter = try FileManager.default.attributesOfItem(atPath: destinationPath.path)
        XCTAssertEqual(attrsAfter[.type] as? FileAttributeType, .typeSymbolicLink,
                       "the symlink itself must survive remove() (now dangling)")
    }

    // MARK: - zsh -n / fish -n syntax checks
    //
    // An empty-string stub body is TRIVIALLY valid syntax for both zsh
    // and fish (zero statements), so each syntax check below is paired
    // with a non-empty guard that itself fails against the stub --
    // otherwise this whole section would pass vacuously against an
    // empty stub forever, even if a later regression reintroduced
    // a syntax error.

    private func syntaxCheckExitCode(interpreter: String, body: String) throws -> Int32 {
        let scriptFile = tempDir.appendingPathComponent("syntax-check-\(UUID().uuidString)")
        try body.write(to: scriptFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: scriptFile) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: interpreter)
        process.arguments = ["-n", scriptFile.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    func test_zshenvBody_isNonEmptyAndPassesZshSyntaxCheck() throws {
        XCTAssertFalse(ShellIntegrationInstaller.zshenvBody.isEmpty,
                       "zshenvBody must contain the real ZDOTDIR-restore/source chain")

        let exitCode = try syntaxCheckExitCode(interpreter: "/bin/zsh", body: ShellIntegrationInstaller.zshenvBody)
        XCTAssertEqual(exitCode, 0, "zshenvBody must be syntactically valid zsh (`zsh -n`)")
    }

    func test_calyxZshBody_isNonEmptyAndPassesZshSyntaxCheck() throws {
        XCTAssertFalse(ShellIntegrationInstaller.calyxZshBody.isEmpty,
                       "calyxZshBody must contain the real preexec/precmd hook registration")

        let exitCode = try syntaxCheckExitCode(interpreter: "/bin/zsh", body: ShellIntegrationInstaller.calyxZshBody)
        XCTAssertEqual(exitCode, 0, "calyxZshBody must be syntactically valid zsh (`zsh -n`)")
    }

    func test_fishIntegrationBody_isNonEmptyAndPassesFishSyntaxCheck() throws {
        XCTAssertFalse(ShellIntegrationInstaller.fishIntegrationBody.isEmpty,
                       "fishIntegrationBody must contain the real fish integration")

        guard let fishPath = try locateExecutable(named: "fish") else {
            throw XCTSkip("fish is not installed on this host")
        }

        let exitCode = try syntaxCheckExitCode(interpreter: fishPath, body: ShellIntegrationInstaller.fishIntegrationBody)
        XCTAssertEqual(exitCode, 0, "fishIntegrationBody must be syntactically valid fish (`fish -n`)")
    }

    func test_calyxZshBody_readsEndpointPathFromCalyxEndpointFileWithLiteralFallback() {
        XCTAssertTrue(
            ShellIntegrationInstaller.calyxZshBody.contains(
                "local endpoint_file=\"${CALYX_ENDPOINT_FILE:-\(AgentEndpointFile.shellFallbackPath)}\""
            ),
            "calyxZshBody must read CALYX_ENDPOINT_FILE (injected by GhosttySurfaceController, scoped " +
            "to wherever Calyx actually wrote agent-endpoint.json), falling back to the literal " +
            "$HOME-relative path for a pane launched before that injection existed"
        )
    }

    func test_fishIntegrationBody_readsEndpointPathFromCalyxEndpointFileWithLiteralFallback() {
        let body = ShellIntegrationInstaller.fishIntegrationBody
        XCTAssertTrue(body.contains("set -l endpoint_file \"$CALYX_ENDPOINT_FILE\""),
                     "fishIntegrationBody must first try CALYX_ENDPOINT_FILE (injected by " +
                     "GhosttySurfaceController); fish has no ${VAR:-default}, so it needs its own " +
                     "explicit fallback step")
        XCTAssertTrue(
            body.contains(
                "test -n \"$endpoint_file\"; or set endpoint_file \"\(AgentEndpointFile.shellFallbackPath)\""
            ),
            "fishIntegrationBody must fall back to the literal $HOME-relative path when " +
            "CALYX_ENDPOINT_FILE is unset, mirroring the existing surface_id fallback shape"
        )
    }

    /// `/usr/bin/which <name>`, matching SystemCommandRunner.locate's own
    /// mechanism for finding an optionally-installed tool -- except PATH
    /// is widened first with `/opt/homebrew/bin` and `/usr/local/bin`
    /// ahead of the inherited PATH (same ordering
    /// `SystemCommandRunner.augmentedPATH()` uses for its own safety-net
    /// entries), since Xcode runs the XCTest host with a sanitized
    /// `/usr/bin:/bin:/usr/sbin:/sbin` that omits both, making a
    /// Homebrew- or /usr/local-installed `fish` invisible to a plain
    /// `which` otherwise. Every other inherited environment variable
    /// passes through unchanged; only PATH is overridden.
    private func locateExecutable(named name: String) throws -> String? {
        let inheritedPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let widenedPath = (["/opt/homebrew/bin", "/usr/local/bin"] + inheritedPath.split(separator: ":").map(String.init))
            .joined(separator: ":")
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = widenedPath

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [name]
        process.environment = env
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (path?.isEmpty ?? true) ? nil : path
    }

    // MARK: - Real zsh process behavior (the decisive test)
    //
    // Mock-less, end-to-end coverage of the installed zsh integration:
    // installs the real (currently-empty-stub) scripts, points a real
    // /bin/zsh -i at them, and observes a stub curl shim's own logged
    // invocation args -- same rationale as AgentHookPipelineIntegrationTests'
    // header (layered unit coverage elsewhere cannot catch "the script
    // was never actually reachable/correct end-to-end").

    private var curlLogPath: URL { tempDir.appendingPathComponent("curl.log") }

    /// Installs a stub `curl` at `<tempDir>/bin/curl` that appends its
    /// own argv (space-joined) as one line per invocation to
    /// `curlLogPath`, then exits 0. Returns the directory to prepend to
    /// PATH so shell command lookup finds this stub ahead of the real
    /// curl.
    private func installStubCurl() throws -> URL {
        let binDir = tempDir.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        let stub = """
        #!/bin/sh
        echo "$@" >> "\(curlLogPath.path)"
        exit 0
        """
        let stubPath = binDir.appendingPathComponent("curl")
        try stub.write(to: stubPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stubPath.path)
        return binDir
    }

    /// Runs an interactive `/bin/zsh -i`, feeding `command` over STDIN
    /// (then closing it, so EOF cleanly ends the session) rather than
    /// via `-c`, with `ZDOTDIR` pointing at the installed integration,
    /// the stub curl shim prepended to PATH, and `agent-endpoint.json`
    /// written under a fresh temp HOME. `extraEnv` merges in on top
    /// (e.g. CALYX_SURFACE_ID).
    ///
    /// MUST feed the command over stdin, not `-c`: verified empirically
    /// (`man zsh`'s own INVOCATION section confirms this too -- `-c`
    /// takes its argument "rather than reading commands from a script or
    /// standard input") that zsh's `preexec`/`precmd` hooks are NEVER
    /// invoked for a `-c` string, regardless of `-i` -- they're wired to
    /// the interactive read-eval-print loop that only `-c`'s alternative
    /// (reading from stdin) drives. A `-c`-based harness would make
    /// every "real zsh process" test below pass or fail for the wrong
    /// reason (zero curl invocations ever, independent of whether
    /// calyx.zsh is correct) rather than actually exercising the hooks.
    /// Every existing call site already appends a trailing `"; exit"` --
    /// stripped here and replaced with a plain EOF (closing stdin),
    /// since an explicit `exit` typed as its own interactive line would
    /// itself fire `preexec` (posting a spurious extra start event for
    /// the literal command `exit`).
    @discardableResult
    private func runInteractiveZsh(command: String, extraEnv: [String: String]) throws -> Int32 {
        let stubBinDir = try installStubCurl()
        let inheritedPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/local/bin"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-i"]
        var env: [String: String] = [
            "HOME": tempDir.path,
            "PATH": "\(stubBinDir.path):\(inheritedPath)",
            "ZDOTDIR": ShellIntegrationInstaller.zshenvPath(in: installRoot).deletingLastPathComponent().path,
        ]
        for (key, value) in extraEnv { env[key] = value }
        process.environment = env
        let stdinPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        try process.run()
        let stdinScript = stdinScript(forCommand: command)
        if let data = stdinScript.data(using: .utf8), !data.isEmpty {
            try stdinPipe.fileHandleForWriting.write(contentsOf: data)
        }
        try stdinPipe.fileHandleForWriting.close()
        process.waitUntilExit()
        return process.terminationStatus
    }

    /// Strips a trailing `"; exit"` suffix (or a bare `"exit"`) from
    /// `command`, since terminating via EOF (closing stdin) replaces the
    /// need for an explicit interactively-typed `exit` -- see
    /// `runInteractiveZsh`'s own doc comment for why typing `exit` as
    /// its own line would itself fire `preexec`. Returns an empty string
    /// (no stdin content at all, immediate EOF) for a bare `"exit"`.
    private func stdinScript(forCommand command: String) -> String {
        let exitSuffix = "; exit"
        if command == "exit" {
            return ""
        }
        if command.hasSuffix(exitSuffix) {
            return String(command.dropLast(exitSuffix.count)) + "\n"
        }
        return command + "\n"
    }

    /// Polls `curlLogPath` for up to `timeout` seconds, since the real
    /// integration backgrounds+disowns its curl call (`&!`) -- the log
    /// write can land after the zsh process itself has already exited.
    private func waitForCurlLogLines(minCount: Int, timeout: TimeInterval = 2.0) async -> [String] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let lines = currentCurlLogLines()
            if lines.count >= minCount { return lines }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return currentCurlLogLines()
    }

    private func currentCurlLogLines() -> [String] {
        guard let content = try? String(contentsOf: curlLogPath, encoding: .utf8) else { return [] }
        return content.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    private func jsonBody(fromCurlLogLine line: String) -> [String: Any]? {
        guard let start = line.firstIndex(of: "{"), let end = line.lastIndex(of: "}"), start < end else { return nil }
        guard let data = line[start...end].data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func writeFixtureEndpoint(port: Int, token: String) throws {
        let appSupportDir = tempDir.appendingPathComponent("Library/Application Support/Calyx")
        try AgentEndpointFile.write(port: port, token: token, directory: appSupportDir.path)
    }

    func test_realZshSession_singleCommand_postsMatchingStartAndEndEvents() async throws {
        _ = try ShellIntegrationInstaller.install(toDirectory: installRoot)
        let fixturePort = Int.random(in: 49_152...65_000)
        let fixtureToken = "shell-integration-test-token"
        try writeFixtureEndpoint(port: fixturePort, token: fixtureToken)
        let surfaceID = UUID()

        try runInteractiveZsh(command: "true; exit", extraEnv: ["CALYX_SURFACE_ID": surfaceID.uuidString])

        let lines = await waitForCurlLogLines(minCount: 2)
        XCTAssertGreaterThanOrEqual(
            lines.count, 2,
            "a single `true` command run interactively must post exactly a start and an end event -- " +
            "found \(lines.count)"
        )

        let startLine = try XCTUnwrap(lines.first { $0.contains("\"phase\":\"start\"") },
                                      "must log one curl invocation whose body has phase=start")
        let endLine = try XCTUnwrap(lines.first { $0.contains("\"phase\":\"end\"") },
                                    "must log one curl invocation whose body has phase=end")

        XCTAssertTrue(startLine.contains("Bearer \(fixtureToken)"),
                     "the start POST's Authorization header must carry the fixture token")
        XCTAssertTrue(startLine.contains("http://127.0.0.1:\(fixturePort)/command-event"),
                     "the start POST must target the fixture endpoint's own port")
        XCTAssertTrue(startLine.contains("X-Calyx-Surface-ID: \(surfaceID.uuidString)"),
                     "the start POST must carry the CALYX_SURFACE_ID as X-Calyx-Surface-ID")

        let startBody = try XCTUnwrap(jsonBody(fromCurlLogLine: startLine), "start POST body must be valid JSON")
        let endBody = try XCTUnwrap(jsonBody(fromCurlLogLine: endLine), "end POST body must be valid JSON")

        let startCmdID = try XCTUnwrap(startBody["cmd_id"] as? String)
        let endCmdID = try XCTUnwrap(endBody["cmd_id"] as? String)
        XCTAssertEqual(startCmdID, endCmdID, "the start and end events for one command must share the same cmd_id")

        let commandB64 = try XCTUnwrap(startBody["command_b64"] as? String)
        let decodedCommand = try XCTUnwrap(Data(base64Encoded: commandB64).flatMap { String(data: $0, encoding: .utf8) })
        XCTAssertEqual(decodedCommand, "true", "command_b64 must decode to the exact command text")

        let exitCode = try XCTUnwrap(endBody["exit_code"] as? Int)
        XCTAssertEqual(exitCode, 0, "`true` exits 0")

        let nowMillis = Date().timeIntervalSince1970 * 1000
        for body in [startBody, endBody] {
            let ts = try XCTUnwrap((body["ts"] as? NSNumber)?.doubleValue, "ts must be present and numeric")
            XCTAssertTrue(
                ts > nowMillis - 60_000 && ts < nowMillis + 5_000,
                "ts must be a plausible epoch-millisecond value close to \"now\", got \(ts) vs now \(nowMillis)"
            )
        }
    }

    func test_realZshSession_nonZeroExitCommand_postsMatchingExitCode() async throws {
        // The decisive test above only ever exercises
        // `true` (exit 0) -- a hook that hardcoded/ignored the real exit
        // code would pass it just as well. `(exit 3)` (a subshell that
        // exits with a specific non-zero code) proves the pipeline
        // actually threads the real `$?` through end-to-end.
        _ = try ShellIntegrationInstaller.install(toDirectory: installRoot)
        try writeFixtureEndpoint(port: Int.random(in: 49_152...65_000), token: "unused-token")
        let surfaceID = UUID()

        try runInteractiveZsh(command: "(exit 3); exit", extraEnv: ["CALYX_SURFACE_ID": surfaceID.uuidString])

        let lines = await waitForCurlLogLines(minCount: 2)
        let endLine = try XCTUnwrap(lines.first { $0.contains("\"phase\":\"end\"") },
                                    "must log one curl invocation whose body has phase=end")
        let endBody = try XCTUnwrap(jsonBody(fromCurlLogLine: endLine), "end POST body must be valid JSON")
        let exitCode = try XCTUnwrap(endBody["exit_code"] as? Int)
        XCTAssertEqual(exitCode, 3, "the end event's exit_code must be the command's real, non-zero exit status")
    }

    func test_realZshSession_emptyInteraction_postsNothing() async throws {
        _ = try ShellIntegrationInstaller.install(toDirectory: installRoot)
        try writeFixtureEndpoint(port: Int.random(in: 49_152...65_000), token: "unused-token")
        let sanitySurfaceID = UUID()

        // Precondition: the same integration DOES post for a real
        // command, proving the assertion below is caused specifically by
        // the empty interaction and not some other pipeline failure.
        // Drains for BOTH events (start + end) before removing the log --
        // draining only the first (start) risks the backgrounded+disowned
        // end POST for THIS sanity command landing after the log is
        // deleted and the real (empty-interaction) scenario below has
        // already started polling, corrupting that scenario's own "must
        // post nothing" assertion with a stray leftover line.
        try runInteractiveZsh(command: "true; exit", extraEnv: ["CALYX_SURFACE_ID": sanitySurfaceID.uuidString])
        let sanityLines = await waitForCurlLogLines(minCount: 2)
        // guard, not just an assertion: when the sanity precondition
        // fails, the curl log file was never created, so continuing on to
        // remove it below would throw a second, unrelated "no such file"
        // failure that obscures this one.
        guard sanityLines.count >= 2 else {
            XCTFail("precondition: a real command must post both a start and an end event")
            return
        }

        try FileManager.default.removeItem(at: curlLogPath)
        let surfaceID = UUID()

        try runInteractiveZsh(command: "exit", extraEnv: ["CALYX_SURFACE_ID": surfaceID.uuidString])

        let lines = await waitForCurlLogLines(minCount: 1, timeout: 0.5)
        XCTAssertTrue(lines.isEmpty,
                     "an empty Enter (no preexec fired) must never post an end event -- found \(lines.count)")
    }

    func test_realZshSession_surfaceAndSessionIDBothUnset_postsNothing() async throws {
        _ = try ShellIntegrationInstaller.install(toDirectory: installRoot)
        try writeFixtureEndpoint(port: Int.random(in: 49_152...65_000), token: "unused-token")
        let sanitySurfaceID = UUID()

        // Same sanity-precondition shape (and same minCount: 2 drain
        // rationale) as the empty-interaction test above.
        try runInteractiveZsh(command: "true; exit", extraEnv: ["CALYX_SURFACE_ID": sanitySurfaceID.uuidString])
        let sanityLines = await waitForCurlLogLines(minCount: 2)
        guard sanityLines.count >= 2 else {
            XCTFail("precondition: a real command must post both a start and an end event")
            return
        }

        try FileManager.default.removeItem(at: curlLogPath)

        try runInteractiveZsh(command: "true; exit", extraEnv: [:])

        let lines = await waitForCurlLogLines(minCount: 1, timeout: 0.5)
        XCTAssertTrue(lines.isEmpty,
                     "with both CALYX_SURFACE_ID and CALYX_SESSION_ID unset (a plain, non-Calyx zsh), " +
                     "the hooks must never post -- found \(lines.count)")
    }

    // MARK: - ZDOTDIR chain restoration

    func test_realZshSession_restoresOriginalZdotdirAndSourcesItsZshenv() async throws {
        _ = try ShellIntegrationInstaller.install(toDirectory: installRoot)

        let userZdotdir = tempDir.appendingPathComponent("user-zdotdir")
        try FileManager.default.createDirectory(at: userZdotdir, withIntermediateDirectories: true)
        let markerLog = tempDir.appendingPathComponent("marker.log")
        let zdotdirLog = tempDir.appendingPathComponent("zdotdir.log")
        let markerZshenv = """
        echo MARKER_SOURCED >> "\(markerLog.path)"
        """
        try markerZshenv.write(to: userZdotdir.appendingPathComponent(".zshenv"), atomically: true, encoding: .utf8)

        try runInteractiveZsh(
            command: "echo \"$ZDOTDIR\" > \"\(zdotdirLog.path)\"; exit",
            extraEnv: ["CALYX_ZSH_ZDOTDIR": userZdotdir.path]
        )

        let loggedZdotdir = (try? String(contentsOf: zdotdirLog, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(
            loggedZdotdir, userZdotdir.path,
            "Calyx's own .zshenv must restore ZDOTDIR to the user's original value from CALYX_ZSH_ZDOTDIR " +
            "before anything else runs"
        )

        let markerContent = try? String(contentsOf: markerLog, encoding: .utf8)
        XCTAssertEqual(
            markerContent?.trimmingCharacters(in: .whitespacesAndNewlines), "MARKER_SOURCED",
            "once ZDOTDIR is restored, the user's own real .zshenv (at the restored ZDOTDIR) must be sourced"
        )
    }

    // MARK: - Real fish process behavior (direct event-emission harness)
    //
    // fish's own fish_preexec/fish_postexec events normally fire only
    // during real interactive command execution, which needs a pty --
    // unavailable in this sandbox (verified: `script`, Python's pty
    // module, and piping a command over stdin to `fish -i` all failed to
    // trigger them). `emit <event> <args...>` is fish's own mechanism for
    // firing any --on-event handler directly and synchronously (verified
    // against a scratch handler outside this file) -- this drives
    // _calyx_preexec exactly as fish's own event system would for a real
    // command, without needing a pty. `fish -i -c '...'` (the interactive
    // flag combined with -c) makes `status --is-interactive` report true
    // (verified empirically), so fishIntegrationBody's own top-line guard
    // doesn't early-return before the event handlers are even defined.
    //
    // A multi-line $argv[1] (a real multi-line command,
    // e.g. pasted or continued with a backslash) broke the whitespace-
    // only guard -- `test -n (string trim -- "$argv[1]")` splits a
    // multi-line command-substitution result across several `test`
    // arguments, which fish's `test` rejects with "unexpected argument",
    // printed straight to the user's terminal, with `_calyx_cmd_active`
    // left unset because the rejected `test` call made `or return 0`
    // fire regardless. Fixed by capturing the trimmed value into a
    // variable first, then testing that variable.

    /// Installs the real fish integration script and sources it directly
    /// (no XDG_DATA_DIRS/vendor_conf.d auto-discovery needed for this
    /// harness -- see this section's own header), then emits
    /// fish_preexec with `command` as $argv[1] and echoes
    /// `_calyx_cmd_active`'s resulting value. The internal `sleep 1`
    /// before the fish process itself exits is required, not cosmetic:
    /// verified empirically that a backgrounded+disowned curl call
    /// launched from inside a `fish -i -c` process does not reliably
    /// finish writing before the parent process exits without it.
    @discardableResult
    private func runFishDirectPreexec(
        fishPath: String, command: String, extraEnv: [String: String]
    ) throws -> (stdout: String, stderr: String) {
        _ = try ShellIntegrationInstaller.install(toDirectory: installRoot)
        let stubBinDir = try installStubCurl()
        let inheritedPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/local/bin"
        let fishIntegrationFile = ShellIntegrationInstaller.fishIntegrationPath(in: installRoot)

        let script = """
        source \(fishIntegrationFile.path)
        emit fish_preexec "\(command)"
        echo "ACTIVE=$_calyx_cmd_active"
        sleep 1
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: fishPath)
        process.arguments = ["-i", "-c", script]
        var env: [String: String] = [
            "HOME": tempDir.path,
            "PATH": "\(stubBinDir.path):\(inheritedPath)",
        ]
        for (key, value) in extraEnv { env[key] = value }
        process.environment = env
        process.standardInput = FileHandle.nullDevice
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return (
            String(data: stdoutData, encoding: .utf8) ?? "",
            String(data: stderrData, encoding: .utf8) ?? ""
        )
    }

    func test_realFishSession_multiLineCommand_setsTrackingStateAndPostsStartWithoutError() async throws {
        guard let fishPath = try locateExecutable(named: "fish") else {
            throw XCTSkip("fish is not installed on this host")
        }
        try writeFixtureEndpoint(port: Int.random(in: 49_152...65_000), token: "unused-token")

        let (stdout, stderr) = try runFishDirectPreexec(
            fishPath: fishPath,
            command: "echo hello\necho world",
            extraEnv: ["CALYX_SESSION_ID": UUID().uuidString]
        )

        XCTAssertFalse(
            stderr.contains("unexpected argument"),
            "a multi-line $argv[1] must not trip the whitespace-only guard's `test` call -- stderr: \(stderr)"
        )
        XCTAssertTrue(
            stdout.contains("ACTIVE=1"),
            "a real (non-whitespace) multi-line command must still set _calyx_cmd_active -- stdout: \(stdout)"
        )

        let lines = await waitForCurlLogLines(minCount: 1)
        XCTAssertTrue(
            lines.contains { $0.contains("\"phase\":\"start\"") },
            "the multi-line command must still post a start event -- curl log: \(lines)"
        )
    }

    func test_realFishSession_whitespaceOnlyCommand_postsNothingAndLeavesTrackingInactive() async throws {
        guard let fishPath = try locateExecutable(named: "fish") else {
            throw XCTSkip("fish is not installed on this host")
        }
        try writeFixtureEndpoint(port: Int.random(in: 49_152...65_000), token: "unused-token")

        let (stdout, stderr) = try runFishDirectPreexec(
            fishPath: fishPath,
            command: "   ",
            extraEnv: ["CALYX_SESSION_ID": UUID().uuidString]
        )

        XCTAssertFalse(stderr.contains("unexpected argument"), "stderr: \(stderr)")
        XCTAssertFalse(
            stdout.contains("ACTIVE=1"),
            "a whitespace-only $argv[1] must return before setting _calyx_cmd_active -- stdout: \(stdout)"
        )

        let lines = await waitForCurlLogLines(minCount: 1, timeout: 0.5)
        XCTAssertTrue(lines.isEmpty, "a whitespace-only $argv[1] must never post an event -- found \(lines)")
    }

    // MARK: - fish postexec: stopped-job detection posts a separate suspended flag
    //
    // fish's own $status inside fish_postexec keeps the PREVIOUS real
    // command's value across a Ctrl-Z suspend (measured on a real pty,
    // /opt/homebrew/bin/fish -i --no-config: a fresh shell reports 0, a
    // shell with a prior failure reports that prior code) -- unlike
    // zsh, whose native $? already becomes 128 + signal after a
    // suspend, which AgentRegistry.handlePaneCommandFinished recognizes
    // directly as a stop-signal exit_code. That method also accepts an
    // explicit suspended flag as its other route to the same exclusion,
    // and that is the route fish uses: since $status never reflects a
    // suspend on its own, _calyx_postexec must detect a stopped job
    // itself and add that flag, leaving exit_code to keep carrying
    // fish's real $status unmodified -- otherwise a suspended pane
    // settles to .done and its still-pending approval request expires
    // out from under the agent.
    //
    // fish has no `jobs --stopped` filter, but `jobs` prints a State
    // column (`running` / `stopped`) and omits its header inside a
    // command substitution -- verified directly against the installed
    // fish binary. A background job SIGSTOP'd with no controlling
    // terminal still shows up as `stopped` in that output (job
    // bookkeeping is fish's own, not terminal-driven; only the
    // interactive keypress that would SEND SIGTSTP needs a pty, not the
    // resulting process state), so the execution tests below drive this
    // with a real backgrounded-then-SIGSTOP'd `sleep`, no pty required
    // -- reusing this file's own established pty-free `emit` technique
    // for firing fish_preexec/fish_postexec.

    /// Extracts the body of `function _calyx_postexec --on-event
    /// fish_postexec ... end` from `fishIntegrationBody`. Anchored on
    /// the exact signature line, capturing non-greedily up to the next
    /// bare `end` line -- safe because `_calyx_postexec` is the last
    /// construct in the body and its own statements contain no nested
    /// `if`/`for` block, so no nested `end` could be mistaken for its
    /// own closing line. Matches against the string's own runtime
    /// value, where Swift's multi-line-literal indentation stripping
    /// has already put `function`/`end` at column 0 -- not the 4-space
    /// indentation the same text has inside this source file.
    private func fishPostexecFunctionBody() throws -> String {
        let body = ShellIntegrationInstaller.fishIntegrationBody
        let pattern = #"function _calyx_postexec --on-event fish_postexec\n(.*?)\nend"#
        let regex = try NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators])
        let range = NSRange(body.startIndex..., in: body)
        let match = try XCTUnwrap(
            regex.firstMatch(in: body, range: range),
            "fishIntegrationBody must define `function _calyx_postexec --on-event fish_postexec ... end`"
        )
        let bodyRange = try XCTUnwrap(Range(match.range(at: 1), in: body))
        return String(body[bodyRange])
    }

    /// Extracts the body of `_calyx_precmd() { ... }` from
    /// `calyxZshBody`, the zsh counterpart to
    /// `fishPostexecFunctionBody()` above -- same non-greedy, anchored
    /// extraction, safe for the same reason (no nested `{`/`}` inside
    /// `_calyx_precmd`'s own statements).
    private func zshPrecmdFunctionBody() throws -> String {
        let body = ShellIntegrationInstaller.calyxZshBody
        let pattern = #"_calyx_precmd\(\) \{\n(.*?)\n\}"#
        let regex = try NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators])
        let range = NSRange(body.startIndex..., in: body)
        let match = try XCTUnwrap(
            regex.firstMatch(in: body, range: range),
            "calyxZshBody must define `_calyx_precmd() { ... }`"
        )
        let bodyRange = try XCTUnwrap(Range(match.range(at: 1), in: body))
        return String(body[bodyRange])
    }

    func test_fishIntegrationBody_postexec_consultsJobsForAStoppedState() throws {
        let postexecBody = try fishPostexecFunctionBody()

        XCTAssertTrue(
            postexecBody.contains("jobs"),
            "_calyx_postexec must consult fish's own `jobs` builtin to detect a merely-suspended " +
            "(not exited) job -- fish has no --stopped filter, so jobs' own output must be inspected directly"
        )
        XCTAssertTrue(
            postexecBody.contains("stopped"),
            "_calyx_postexec must check jobs' own State column for its literal `stopped` value -- " +
            "the only value that distinguishes a suspended job from a running or absent one"
        )
    }

    func test_fishIntegrationBody_postexec_postsSuspendedFlagAndNeverOverwritesStatus() throws {
        let postexecBody = try fishPostexecFunctionBody()

        XCTAssertTrue(
            postexecBody.contains("suspended"),
            "_calyx_postexec must post a separate suspended flag when a stopped job is detected -- fish's own " +
            "$status cannot itself distinguish a suspend from the previous command's real exit code"
        )
        XCTAssertFalse(
            postexecBody.contains("146"),
            "_calyx_postexec must never substitute a stop-signal number into exit_code -- the real $status is " +
            "always posted as-is, with a suspend reported separately"
        )
    }

    func test_calyxZshBody_precmd_keepsRelayingRawStatusWithNoRedundantJobStateCheck() throws {
        let precmdBody = try zshPrecmdFunctionBody()

        XCTAssertTrue(
            precmdBody.contains("local code=$?"),
            "_calyx_precmd must keep relaying the shell's own raw $? unconditionally -- zsh already " +
            "reports 128 + signal natively for a suspended job (measured on a real pty), so it needs " +
            "no job-state check of its own"
        )
        XCTAssertFalse(
            precmdBody.contains("jobs"),
            "_calyx_precmd must not grow fish's own stopped-job detection -- that would duplicate " +
            "zsh's native 128+signal reporting for no benefit"
        )
    }

    // MARK: - fish postexec: real stopped-job classification (no pty)

    /// Sources the real fishIntegrationBody, fires fish_preexec (so
    /// _calyx_cmd_active/_calyx_cmd_id are set exactly as a real
    /// command would leave them), backgrounds a long-lived `sleep` --
    /// SIGSTOP'd first when `stopJob` is true -- then fires
    /// fish_postexec, mirroring `runFishDirectPreexec`'s own `emit`-
    /// based technique. `emit` resets $status to 0 for the handler it
    /// invokes (verified directly: a deliberate `false` immediately
    /// before `emit` still reads $status as 0 inside the handler), so
    /// both scenarios below post exit_code 0 -- the discriminator
    /// between them is the separate suspended flag, present only when
    /// `stopJob` is true, never the exit code itself. The trailing
    /// `sleep 1` and final `kill -9` mirror `runFishDirectPreexec`'s own
    /// rationale and cleanup; SIGKILL was verified to terminate a
    /// SIGSTOP'd process immediately, without needing SIGCONT first.
    @discardableResult
    private func runFishPostexecWithBackgroundJob(
        fishPath: String, stopJob: Bool, extraEnv: [String: String]
    ) throws -> (stdout: String, stderr: String) {
        _ = try ShellIntegrationInstaller.install(toDirectory: installRoot)
        let stubBinDir = try installStubCurl()
        let inheritedPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/local/bin"
        let fishIntegrationFile = ShellIntegrationInstaller.fishIntegrationPath(in: installRoot)

        let stopStep = stopJob ? "kill -STOP $_calyx_test_job_pid" : "true"
        let script = """
        source \(fishIntegrationFile.path)
        emit fish_preexec "sleep 300"
        sleep 300 &
        set -g _calyx_test_job_pid $last_pid
        sleep 0.2
        \(stopStep)
        sleep 0.2
        emit fish_postexec "sleep 300"
        sleep 1
        kill -9 $_calyx_test_job_pid 2>/dev/null
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: fishPath)
        process.arguments = ["-i", "-c", script]
        var env: [String: String] = [
            "HOME": tempDir.path,
            "PATH": "\(stubBinDir.path):\(inheritedPath)",
        ]
        for (key, value) in extraEnv { env[key] = value }
        process.environment = env
        process.standardInput = FileHandle.nullDevice
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return (
            String(data: stdoutData, encoding: .utf8) ?? "",
            String(data: stderrData, encoding: .utf8) ?? ""
        )
    }

    func test_realFishSession_postexecWithStoppedJob_postsSuspendedFlagAndRawStatus() async throws {
        guard let fishPath = try locateExecutable(named: "fish") else {
            throw XCTSkip("fish is not installed on this host")
        }
        try writeFixtureEndpoint(port: Int.random(in: 49_152...65_000), token: "unused-token")

        let (_, stderr) = try runFishPostexecWithBackgroundJob(
            fishPath: fishPath, stopJob: true, extraEnv: ["CALYX_SESSION_ID": UUID().uuidString]
        )
        XCTAssertFalse(
            stderr.contains("Unknown command"), "stderr must not show a broken harness script -- stderr: \(stderr)"
        )

        let lines = await waitForCurlLogLines(minCount: 2)
        let endLine = try XCTUnwrap(
            lines.first { $0.contains("\"phase\":\"end\"") },
            "a stopped-job postexec must still post an end event -- curl log: \(lines)"
        )
        let endBody = try XCTUnwrap(jsonBody(fromCurlLogLine: endLine), "end POST body must be valid JSON")
        let exitCode = try XCTUnwrap(endBody["exit_code"] as? Int)
        XCTAssertEqual(
            exitCode, 0,
            "a stopped job must post the RAW $status (0, per emit's own reset -- see " +
            "runFishPostexecWithBackgroundJob's own doc comment), never a substituted stop-signal number"
        )
        XCTAssertEqual(
            endBody["suspended"] as? Bool, true,
            "a stopped (not exited) job must post a separate suspended:true flag -- fish's own $status cannot " +
            "itself distinguish a suspend from the previous command's real exit code"
        )
    }

    func test_realFishSession_postexecWithRunningJobOnly_postsRawExitCode() async throws {
        guard let fishPath = try locateExecutable(named: "fish") else {
            throw XCTSkip("fish is not installed on this host")
        }
        try writeFixtureEndpoint(port: Int.random(in: 49_152...65_000), token: "unused-token")

        let (_, stderr) = try runFishPostexecWithBackgroundJob(
            fishPath: fishPath, stopJob: false, extraEnv: ["CALYX_SESSION_ID": UUID().uuidString]
        )
        XCTAssertFalse(
            stderr.contains("Unknown command"), "stderr must not show a broken harness script -- stderr: \(stderr)"
        )

        let lines = await waitForCurlLogLines(minCount: 2)
        let endLine = try XCTUnwrap(
            lines.first { $0.contains("\"phase\":\"end\"") },
            "postexec must post an end event -- curl log: \(lines)"
        )
        let endBody = try XCTUnwrap(jsonBody(fromCurlLogLine: endLine), "end POST body must be valid JSON")
        let exitCode = try XCTUnwrap(endBody["exit_code"] as? Int)
        XCTAssertEqual(
            exitCode, 0,
            "a merely-backgrounded but still-RUNNING (never stopped) job must not trip the stop-signal " +
            "override -- only jobs' own `stopped` State should, not the mere presence of a background job"
        )
        XCTAssertNil(
            endBody["suspended"],
            "the suspended flag must be omitted entirely when nothing is stopped, not merely false -- only " +
            "jobs' own `stopped` State should ever add it"
        )
    }
}
