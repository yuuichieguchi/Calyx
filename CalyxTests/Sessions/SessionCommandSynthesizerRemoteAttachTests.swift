//
//  SessionCommandSynthesizerRemoteAttachTests.swift
//  CalyxTests
//
//  TDD Red phase, P5 (remote sessions), cycle 1: remote attach command
//  synthesis via ssh. Introduces two NEW symbols that do not exist yet
//  anywhere in the codebase -- SessionCommandSynthesizer.remoteAttachCommand
//  and SSHBinaryResolverProtocol/SSHBinaryResolver -- so this file is a
//  held-out compile-RED file per this codebase's established convention
//  (see SessionDaemonClientSessionStateBoundTimeoutSeamTests's header):
//  it is expected to FAIL TO COMPILE until the Green phase adds both.
//  That compile failure IS this file's RED evidence.
//
//  DESIGN, TWO SHELL LAYERS:
//  Exactly like attachCommand, ghostty wraps whatever `command` string we
//  configure in its own `/bin/sh -c "exec <command>"` (see
//  SessionCommandSynthesizer.swift's own header and
//  SessionCommandSynthesizerRuntimeStateDirFlagsTests's full ROUND 1/2/3
//  ghostty-exec-wrapping saga -- this is the canonical copy of that
//  narrative, not repeated here). remoteAttachCommand's synthesized
//  string is parsed by THAT local shell first (LAYER 1), which execs the
//  first word (the resolved ssh binary) with the remaining words as its
//  own argv. ssh then transmits its own trailing "command" argv to the
//  remote sshd, which invokes some POSIX shell remotely as that shell's
//  own -c argument (LAYER 2). Two structurally different shells parse
//  two structurally different strings, and this file's execution-based
//  tests emulate BOTH, exactly as SessionCommandSynthesizerRuntimeStateDirFlagsTests
//  already does for the single-layer local case.
//
//  WHY $HOME, NOT '~': an earlier plan sketch referenced the remote
//  binary as a single-quoted '~/.calyx/bin/calyx-session'. That is WRONG:
//  single quotes suppress tilde expansion AND $HOME parameter expansion
//  alike on every POSIX shell, so a single-quoted tilde is a literal
//  two-byte string, never a path, on the remote end. This file's design
//  instead leaves the literal text $HOME/.calyx/bin/calyx-session
//  UNQUOTED within the remote command line (a plain bareword, so the
//  REMOTE shell's own parameter expansion resolves it against the REMOTE
//  $HOME), while wrapping the ENTIRE remote command line as ONE
//  shSafeToken'd word for the LOCAL shell layer only -- that outer local
//  quoting is stripped away by the LOCAL shell before ssh ever transmits
//  the bytes onward, so it never touches how the REMOTE shell later
//  parses $HOME. sessionID/cwd/name are each wrapped in their OWN
//  shSafeToken call, scoped for the REMOTE shell's parsing (the second,
//  inner quoting layer), so they survive as single arguments to the
//  remote calyx-session binary without needing to be shell-safe in any
//  other sense.
//
//  WHY -t -- <host>: verified live against the system ssh (OpenSSH_10.2p1):
//    $ ssh -t -- -evilhost   ->  "hostname contains invalid characters"
//        (the -- guard makes ssh treat -evilhost as the DESTINATION
//        argument, which its own hostname validator then rejects for
//        starting with a dash -- not consumed as an option)
//    $ ssh -t -evilhost      ->  "Bad escape character 'vilhost'"
//        (no -- guard: ssh instead parses -evilhost as -e vilhost, an
//        ordinary short-option-with-argument -- so a leading dash in an
//        unguarded host string CAN inject an arbitrary ssh option)
//  This file's tests only assert what remoteAttachCommand itself
//  controls -- that -t and -- precede the host, and that a
//  dash-prefixed host still arrives as one intact, unsplit argv word
//  immediately after -- -- and rely on the live-verified system ssh
//  behavior above for why that ordering closes the option-injection gap.
//
//  Coverage:
//  - SSHBinaryResolver's production default resolves to the literal
//    absolute /usr/bin/ssh
//  - remoteAttachCommand never contains a leading exec word or an
//    /usr/bin/env wrapper (mirrors attachCommand's own retired-shape guard)
//  - execution proves the resolved ssh path is exec'd directly as the
//    command's first word (via captured $0), no wrapper word ahead of it
//  - execution proves -t then -- then host as three consecutive,
//    separate argv words delivered to ssh, including when host itself
//    starts with a dash
//  - remoteAttachCommand never emits --runtime-dir/--state-dir (those
//    are meaningless on the remote machine; the remote daemon resolves
//    its own defaults from the REMOTE $HOME)
//  - the remote command word references $HOME/.calyx/bin/calyx-session
//    unquoted (never a single-quoted tilde)
//  - full two-layer execution round trip: the captured remote command
//    line, run through a second /bin/sh -c with $HOME pointed at a
//    fixture directory containing a stub calyx-session, actually
//    invokes that stub (proving $HOME expansion works) with sessionID/
//    cwd/name surviving both layers intact
//  - metacharacter torture (spaces, quotes, Japanese, $(), backticks,
//    semicolons) in cwd/name/sessionID survives both layers intact and
//    is never itself executed as a second remote shell statement
//

import XCTest
@testable import Calyx

private struct FakeSSHResolver: SSHBinaryResolverProtocol {
    let path: String
    func resolve() -> String { path }
}

private struct RoundTripCaptureFailure: Error, CustomStringConvertible {
    let description: String
}

final class SessionCommandSynthesizerRemoteAttachTests: XCTestCase {

    // MARK: - Shared helpers

    private func uniqueTempPath(_ label: String) -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("\(label)-\(UUID().uuidString)")
            .path
    }

    /// Writes a `#!/bin/sh` script at `scriptPath` (creating any missing
    /// intermediate directories, so a nested fixture path like
    /// `<fixtureHome>/.calyx/bin/calyx-session` works directly) that
    /// appends its own observed `$0` as the FIRST captured line, then
    /// each of its own arguments one per line after that -- mirrors
    /// SessionCommandSynthesizerRuntimeStateDirFlagsTests'
    /// makeHomeAndArgvDumperScript, substituting $0 for $HOME since what
    /// this file needs to prove is "was I exec'd directly, via exactly
    /// this path", not "what HOME did I observe".
    private func makeSelfPathAndArgvDumperScript(at scriptPath: String, outputPath: String) throws {
        try FileManager.default.createDirectory(
            atPath: (scriptPath as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        let body = "#!/bin/sh\nprintf '%s\\n' \"$0\" >> \"\(outputPath)\"\n" +
            "for a in \"$@\"; do printf '%s\\n' \"$a\" >> \"\(outputPath)\"; done\n"
        try body.write(toFile: scriptPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath)
    }

    private func readCapturedLines(at outputPath: String) -> [String] {
        guard let data = FileManager.default.contents(atPath: outputPath),
              let text = String(data: data, encoding: .utf8), !text.isEmpty else {
            return []
        }
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines
    }

    /// Runs `command` the way ghostty ACTUALLY invokes a pane's
    /// configured `command`: `/bin/sh -c "exec <command>"`. Mirrors
    /// SessionCommandSynthesizerRuntimeStateDirFlagsTests' own
    /// runShCEmulatingGhosttyWrapping (duplicated here per this
    /// codebase's established per-file fixture-duplication convention).
    private func runShCEmulatingGhosttyWrapping(_ command: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "exec " + command]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
    }

    /// Runs `remoteCommandLine` (LAYER 2) via a plain, non-exec `/bin/sh
    /// -c`, standing in for whatever POSIX shell sshd invokes on the
    /// remote machine, with `home` standing in for the REMOTE $HOME --
    /// deliberately never this test process's own ambient $HOME, so a
    /// stub found and invoked under `home` proves the remote command's
    /// $HOME reference actually drove the lookup.
    private func runRemoteCommandLine(_ remoteCommandLine: String, home: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", remoteCommandLine]
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = home
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
    }

    /// Full two-layer round trip: synthesizes remoteAttachCommand with a
    /// stubbed ssh (so LAYER 1 argv can be captured instead of making a
    /// real network connection), runs it through the ghostty-emulating
    /// local shell, extracts the single captured remote-command-line
    /// argv word, then runs THAT through a second, independent
    /// /bin/sh -c with $HOME pointed at a fresh fixture directory
    /// containing a stub calyx-session (LAYER 2), and returns what that
    /// remote stub itself observed.
    private func roundTripRemoteAttachCommand(
        host: String, sessionID: String, cwd: String, name: String? = nil
    ) throws -> (remoteSelfPath: String, remoteArgv: [String]) {
        let sshStubPath = uniqueTempPath("ssh-argv-dumper")
        let sshOutputPath = uniqueTempPath("ssh-argv-capture")
        let fixtureHome = uniqueTempPath("calyx-fixture-remote-home")
        let remoteOutputPath = uniqueTempPath("calyx-session-remote-argv-capture")
        defer {
            try? FileManager.default.removeItem(atPath: sshStubPath)
            try? FileManager.default.removeItem(atPath: sshOutputPath)
            try? FileManager.default.removeItem(atPath: fixtureHome)
            try? FileManager.default.removeItem(atPath: remoteOutputPath)
        }
        try makeSelfPathAndArgvDumperScript(at: sshStubPath, outputPath: sshOutputPath)
        let remoteCalyxSessionPath = fixtureHome + "/.calyx/bin/calyx-session"
        try makeSelfPathAndArgvDumperScript(at: remoteCalyxSessionPath, outputPath: remoteOutputPath)

        let command = SessionCommandSynthesizer.remoteAttachCommand(
            host: host, sessionID: sessionID, cwd: cwd, name: name,
            sshResolver: FakeSSHResolver(path: sshStubPath)
        )
        try runShCEmulatingGhosttyWrapping(command)
        let sshLines = readCapturedLines(at: sshOutputPath)
        guard let remoteCommandLine = sshLines.last else {
            throw RoundTripCaptureFailure(description: "ssh stub was never invoked; no argv captured")
        }

        try runRemoteCommandLine(remoteCommandLine, home: fixtureHome)
        let remoteLines = readCapturedLines(at: remoteOutputPath)
        guard let remoteSelfPath = remoteLines.first else {
            throw RoundTripCaptureFailure(description: "remote calyx-session stub was never invoked " +
                                           "-- $HOME likely failed to expand to the fixture home")
        }
        return (remoteSelfPath, Array(remoteLines.dropFirst()))
    }

    // MARK: - SSHBinaryResolver production default

    func test_SSHBinaryResolver_defaultProduction_resolvesToLiteralUsrBinSSH() {
        XCTAssertEqual(SSHBinaryResolver().resolve(), "/usr/bin/ssh",
                       "The production default must be the literal absolute ssh binary path -- ghostty's " +
                       "own exec wrapping requires a program-first, absolute first word, exactly like " +
                       "attachCommand's binaryPath contract")
    }

    // MARK: - First word / process identity

    func test_remoteAttachCommand_neverStartsWithExecWordOrEnvAssignment() {
        let command = SessionCommandSynthesizer.remoteAttachCommand(
            host: "build-box.example.com", sessionID: "01ARZ3NDEKTSV4RRFFQ69G5FAV", cwd: "/home/dev/repo"
        )
        XCTAssertFalse(command.hasPrefix("exec "),
                       "A leading exec word PATH-searches as a literal nonexistent program under " +
                       "ghostty's own exec wrapping -- field-verified broken (\"exec: exec: not found\"), " +
                       "see SessionCommandSynthesizerRuntimeStateDirFlagsTests's ROUND 2 narrative")
        XCTAssertFalse(command.hasPrefix("/usr/bin/env"),
                       "A leading /usr/bin/env word is the retired HOME-stamp mechanism; the remote " +
                       "command must be program-first, exactly like attachCommand/reattachCommand")
    }

    func test_remoteAttachCommand_execution_sshPathIsExecedDirectlyAsFirstWord_noWrapperWordAheadOfIt() throws {
        let sshStubPath = uniqueTempPath("ssh-argv-dumper")
        let outputPath = uniqueTempPath("ssh-argv-capture")
        defer {
            try? FileManager.default.removeItem(atPath: sshStubPath)
            try? FileManager.default.removeItem(atPath: outputPath)
        }
        try makeSelfPathAndArgvDumperScript(at: sshStubPath, outputPath: outputPath)

        let command = SessionCommandSynthesizer.remoteAttachCommand(
            host: "build-box.example.com", sessionID: "01ARZ3NDEKTSV4RRFFQ69G5FAV", cwd: "/home/dev/repo",
            sshResolver: FakeSSHResolver(path: sshStubPath)
        )
        try runShCEmulatingGhosttyWrapping(command)
        let lines = readCapturedLines(at: outputPath)

        XCTAssertEqual(lines.first, sshStubPath,
                       "The resolved ssh path must be exec'd directly as the command's first word -- $0 " +
                       "inside the stub must equal exactly the resolved path, with no leading exec/env " +
                       "wrapper word ahead of it")
    }

    // MARK: - -t / -- guard and host argv shape

    func test_remoteAttachCommand_execution_ptyFlagAndDoubleDashPrecedeHostAsSeparateArgvWords() throws {
        let sshStubPath = uniqueTempPath("ssh-argv-dumper")
        let outputPath = uniqueTempPath("ssh-argv-capture")
        defer {
            try? FileManager.default.removeItem(atPath: sshStubPath)
            try? FileManager.default.removeItem(atPath: outputPath)
        }
        try makeSelfPathAndArgvDumperScript(at: sshStubPath, outputPath: outputPath)

        let command = SessionCommandSynthesizer.remoteAttachCommand(
            host: "build-box.example.com", sessionID: "01ARZ3NDEKTSV4RRFFQ69G5FAV", cwd: "/home/dev/repo",
            sshResolver: FakeSSHResolver(path: sshStubPath)
        )
        try runShCEmulatingGhosttyWrapping(command)
        let argv = Array(readCapturedLines(at: outputPath).dropFirst())

        XCTAssertEqual(Array(argv.prefix(3)), ["-t", "--", "build-box.example.com"],
                       "ssh must receive -t (PTY allocation) then -- (end-of-options guard) then the host " +
                       "as its own argv word immediately after -- so a host string can never be misparsed " +
                       "as an ssh option")
    }

    func test_remoteAttachCommand_execution_hostStartingWithDash_survivesAsSingleIntactArgvWordAfterDoubleDash() throws {
        let sshStubPath = uniqueTempPath("ssh-argv-dumper")
        let outputPath = uniqueTempPath("ssh-argv-capture")
        defer {
            try? FileManager.default.removeItem(atPath: sshStubPath)
            try? FileManager.default.removeItem(atPath: outputPath)
        }
        try makeSelfPathAndArgvDumperScript(at: sshStubPath, outputPath: outputPath)

        let maliciousHost = "-oProxyCommand=touch /tmp/pwned"
        let command = SessionCommandSynthesizer.remoteAttachCommand(
            host: maliciousHost, sessionID: "01ARZ3NDEKTSV4RRFFQ69G5FAV", cwd: "/home/dev/repo",
            sshResolver: FakeSSHResolver(path: sshStubPath)
        )
        try runShCEmulatingGhosttyWrapping(command)
        let argv = Array(readCapturedLines(at: outputPath).dropFirst())

        XCTAssertEqual(Array(argv.prefix(3)), ["-t", "--", maliciousHost],
                       "A host string starting with - must survive as ONE intact argv word placed " +
                       "immediately after the -- guard -- live-verified: `ssh -t -- -evilhost` parses " +
                       "-evilhost as the destination (\"hostname contains invalid characters\"), while " +
                       "`ssh -t -evilhost` (no --) parses it as an option instead (\"Bad escape character " +
                       "'vilhost'\"), so -- 's presence and position is what ssh itself relies on to " +
                       "reject option-injection")
    }

    // MARK: - No local runtime-dir/state-dir flags in the remote command

    func test_remoteAttachCommand_neverContainsLocalRuntimeDirOrStateDirFlags() {
        let command = SessionCommandSynthesizer.remoteAttachCommand(
            host: "build-box.example.com", sessionID: "01ARZ3NDEKTSV4RRFFQ69G5FAV", cwd: "/home/dev/repo"
        )
        XCTAssertFalse(command.contains("--runtime-dir"),
                       "The remote daemon must resolve its own --runtime-dir default from the REMOTE " +
                       "$HOME -- a LOCAL path stamped here would be nonsense on the remote machine")
        XCTAssertFalse(command.contains("--state-dir"),
                       "Same as --runtime-dir: the remote daemon resolves its own --state-dir default; " +
                       "local paths never travel over ssh")
    }

    // MARK: - $HOME reference shape (never a single-quoted tilde)

    func test_remoteAttachCommand_remoteCommandReferencesHomeCalyxBinCalyxSessionUnquoted() {
        let command = SessionCommandSynthesizer.remoteAttachCommand(
            host: "build-box.example.com", sessionID: "01ARZ3NDEKTSV4RRFFQ69G5FAV", cwd: "/home/dev/repo"
        )
        XCTAssertTrue(command.contains("$HOME/.calyx/bin/calyx-session"),
                       "The remote binary must be referenced as the literal text $HOME (a REMOTE-shell " +
                       "parameter expansion), never as a single-quoted '~/.calyx/bin/calyx-session' -- " +
                       "single quotes suppress both tilde expansion and $HOME parameter expansion on the " +
                       "remote shell alike, which is exactly the wrong design this contract rules out")
        XCTAssertFalse(command.contains("'~/.calyx/bin/calyx-session'"),
                       "A single-quoted tilde never expands on the remote shell -- this is the WRONG " +
                       "shape an earlier plan sketch proposed, explicitly ruled out here")
    }

    // MARK: - Full two-layer round trip (happy path)

    func test_remoteAttachCommand_execution_fullRoundTrip_remoteShellExpandsHomeAndArgvSurvivesBothLayers() throws {
        let result = try roundTripRemoteAttachCommand(
            host: "build-box.example.com",
            sessionID: "01ARZ3NDEKTSV4RRFFQ69G5FAV",
            cwd: "/home/dev/repo",
            name: "my session"
        )
        XCTAssertTrue(result.remoteSelfPath.hasSuffix("/.calyx/bin/calyx-session"),
                       "The remote stub must have been found and exec'd via the $HOME-expanded path " +
                       "(proving $HOME resolved against the fixture remote home, not this test process's " +
                       "own ambient $HOME)")
        XCTAssertEqual(result.remoteArgv,
                       ["attach", "01ARZ3NDEKTSV4RRFFQ69G5FAV", "--create", "--cwd", "/home/dev/repo",
                        "--name", "my session"],
                       "sessionID/cwd/name must survive both the local-layer and remote-layer quoting " +
                       "intact as their own argv words, with no --runtime-dir/--state-dir flags present")
    }

    // MARK: - Metacharacter torture, both layers

    func test_remoteAttachCommand_execution_cwdWithSpacesQuoteAndJapaneseSurvivesBothLayersIntact() throws {
        let cwd = "/home/dev/My Repo's Folder/日本語"
        let result = try roundTripRemoteAttachCommand(
            host: "build-box.example.com", sessionID: "01ARZ3NDEKTSV4RRFFQ69G5FAV", cwd: cwd
        )
        XCTAssertEqual(result.remoteArgv, ["attach", "01ARZ3NDEKTSV4RRFFQ69G5FAV", "--create", "--cwd", cwd],
                       "cwd containing spaces, a single quote, and Japanese characters must survive BOTH " +
                       "the local /bin/sh -c layer and the remote shell layer byte-for-byte")
    }

    func test_remoteAttachCommand_execution_nameWithSpacesQuoteAndJapaneseSurvivesBothLayersIntact() throws {
        let name = "私の session's \"name\""
        let result = try roundTripRemoteAttachCommand(
            host: "build-box.example.com", sessionID: "01ARZ3NDEKTSV4RRFFQ69G5FAV", cwd: "/home/dev/repo",
            name: name
        )
        XCTAssertEqual(result.remoteArgv,
                       ["attach", "01ARZ3NDEKTSV4RRFFQ69G5FAV", "--create", "--cwd", "/home/dev/repo",
                        "--name", name],
                       "name containing spaces, a single quote, a double quote, and Japanese characters " +
                       "must survive both layers intact")
    }

    func test_remoteAttachCommand_execution_sessionIDWithSemicolonCannotInjectASecondRemoteShellStatement() throws {
        let marker = uniqueTempPath("calyx-remote-injection-marker")
        defer { try? FileManager.default.removeItem(atPath: marker) }
        let maliciousSessionID = "01ARZ3; touch \(marker); #"

        let result = try roundTripRemoteAttachCommand(
            host: "build-box.example.com", sessionID: maliciousSessionID, cwd: "/home/dev/repo"
        )
        XCTAssertEqual(result.remoteArgv,
                       ["attach", maliciousSessionID, "--create", "--cwd", "/home/dev/repo"],
                       "sessionID containing ; must survive as ONE intact argument to calyx-session on " +
                       "the remote shell, not be split into separate statements")
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker),
                       "A sessionID containing ; must not break out of its own remote-shell quoting and " +
                       "inject a second statement executed by the remote shell -- the marker file must " +
                       "never be created")
    }

    func test_remoteAttachCommand_execution_cwdWithDollarParenAndBackticksSurviveBothLayersUnexpanded() throws {
        let markerA = uniqueTempPath("calyx-remote-injection-marker-a")
        let markerB = uniqueTempPath("calyx-remote-injection-marker-b")
        defer {
            try? FileManager.default.removeItem(atPath: markerA)
            try? FileManager.default.removeItem(atPath: markerB)
        }
        let cwd = "/home/dev/$(touch \(markerA))/`touch \(markerB)`"

        let result = try roundTripRemoteAttachCommand(
            host: "build-box.example.com", sessionID: "01ARZ3NDEKTSV4RRFFQ69G5FAV", cwd: cwd
        )
        XCTAssertEqual(result.remoteArgv, ["attach", "01ARZ3NDEKTSV4RRFFQ69G5FAV", "--create", "--cwd", cwd],
                       "$() and backtick command substitution syntax embedded in cwd must remain INERT " +
                       "literal bytes through both quoting layers -- if either were evaluated, the " +
                       "captured cwd would differ from the literal input string")
        XCTAssertFalse(FileManager.default.fileExists(atPath: markerA),
                       "$(touch <marker>) inside cwd must never actually run on the remote shell")
        XCTAssertFalse(FileManager.default.fileExists(atPath: markerB),
                       "`touch <marker>` (backtick form) inside cwd must never actually run on the remote shell")
    }
}
