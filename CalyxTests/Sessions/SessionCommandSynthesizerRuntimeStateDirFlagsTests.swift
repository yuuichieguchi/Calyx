//
//  SessionCommandSynthesizerHomeStampTests.swift
//  CalyxTests
//
//  TDD Red phase (session-root-resolution fix round): the Rust
//  calyx-session daemon/CLI resolves its on-disk state root
//  ($HOME/.calyx: run/sessiond.sock, state/) from the literal HOME env
//  var at process start (see calyx-session/crates/daemon/src/session.rs).
//  SessionCommandSynthesizer's synthesized attach command today leaves
//  HOME entirely to whatever ambient environment ghostty passes the
//  surface's `/bin/sh -c` invocation, so the exec'd `calyx-session
//  attach` process can resolve a DIFFERENT state root than the one
//  SessionDaemonClient queries against
//  (SessionDaemonClientHomeEnvironmentTests covers that other half) --
//  proven live: with mismatched HOMEs, a daemon query for a session
//  that is genuinely alive and attached reports it as unreachable.
//
//  The fix stamps the resolved root explicitly as a leading `HOME=`
//  shell env-assignment word ahead of `exec`, escaped through the same
//  shSafeToken() already applied to binaryPath/sessionID/cwd/name, via
//  a new injectable `SessionRootResolverProtocol` seam (mirrors
//  `SessionBinaryResolverProtocol`, see SessionRootResolverTests) --
//  so the attach process's own HOME can never disagree with whatever
//  SessionDaemonClient resolved for the same rootResolver, regardless
//  of ghostty's own env-passing policy.
//
//  This file targets a new `rootResolver:` parameter on BOTH
//  `attachCommand` (SessionSpawnPlanner's create-variant) and
//  `reattachCommand` (AppDelegate.createSurfaceWithPwd's restore path
//  and CalyxWindowController.performReconnect's reconnect path), NEITHER
//  of which exists in the codebase yet. Following this codebase's
//  established convention for new-API RED tests (see
//  SessionDaemonClientBoundedListTests' header comment, itself citing
//  CalyxWindowControllerFullScreenTests), this file is expected to FAIL
//  TO COMPILE until the TDD Green phase adds them -- that compile
//  failure IS this contract's RED evidence.
//
//  Verified by actually running the synthesized command through a real
//  `/bin/sh -c`, substituting a small stub script (in place of the real
//  calyx-session binary) that dumps its own observed $HOME as the first
//  captured line, followed by its argv -- mirroring this file family's
//  established approach (SessionCommandSynthesizerTests,
//  SessionSpawnPlannerTests) of checking the property that actually
//  matters (what the exec'd process actually observes) rather than
//  string-matching one specific escaping/ordering shape.
//
//  Existing-behavior guard: with no HOME override (SessionRootResolver's
//  default, real production use), the resolved root equals the real
//  $HOME already ambiently inherited today, so this is behaviorally
//  invisible for normal users -- only a mismatched-HOME environment
//  (this fix's actual target) changes the exec'd process's observed
//  $HOME.
//
//  KNOWN CONSEQUENCE FOR GREEN (flagged, not fixed here -- and since
//  overtaken by ROUND 2 below): once Green landed for ROUND 1, the
//  synthesized command's TEXT started with "HOME=..." rather than
//  "exec ". SessionCommandSynthesizerTests.test_attachCommand_basicForm_includesExecCreateIdCwdInOrder
//  and SessionSpawnPlannerTests.test_plan_enabledTabOrigin_returnsPersistentWithULIDSessionIDAndMatchingCommand
//  were updated at the time to tolerate that leading `HOME=... ` word
//  (`command.hasPrefix("HOME=") && command.contains(" exec ")`). ROUND
//  2 below now tightens those same two assertions further, since a
//  leading `HOME=` word turns out to be unusable in production.
//
//  ROUND 2 (ghostty first-word-exec compatibility fix): proven live in
//  a real pane that the ROUND 1 shape above (`HOME=<root> exec <bin>
//  ...`) breaks ghostty itself, independent of daemon/env correctness.
//  Ghostty resolves a pane's `command` config by treating the FIRST
//  WHITESPACE-DELIMITED WORD as the literal program to exec directly
//  (resolving a non-absolute first word against the pane's cwd), NOT
//  by handing the whole string to `/bin/sh -c` the way this file's own
//  `runShC` helper does. A leading `HOME=<root>` env-assignment word
//  becomes that first word, so ghostty tries (and fails) to execute a
//  nonexistent file literally named "HOME=<root>". Verbatim field
//  failure from a real pane:
//
//    bash: /Users/eguchiyuuichi/projects/Calyx/HOME=/tmp/cxpane: No such file or directory
//    bash: line 0: exec: /Users/eguchiyuuichi/projects/Calyx/HOME=/tmp/cxpane: cannot execute: No such file or directory
//
//  The fix keeps `exec` as the unconditional first word and moves the
//  env assignment after it, into `/usr/bin/env`: `exec /usr/bin/env
//  HOME=<root> <binaryPath> attach ...`.
//
//  ROUND 3 (ghostty exec-wrapping compatibility fix -- supersedes
//  ROUND 2's own fix): proven live in a real pane, AFTER the ROUND 2
//  shape above shipped, that ghostty does not hand our configured
//  `command` string to a shell unmodified at all -- it wraps whatever
//  we configure ITSELF as `<shell> -c "exec <command>"` (ghostty
//  supplies its own leading `exec`; verified directly against
//  `ghostty/src/termio/Exec.zig`'s `execCommand`, which for any
//  `.shell`-variant command -- the default when Calyx's synthesized
//  string carries no `direct:` prefix, see
//  `ghostty/src/config/Command.zig` -- builds
//  `/bin/bash --noprofile --norc -c "exec -l <command>"`, itself
//  further wrapped in `/usr/bin/login -flp <username> ...` on macOS).
//  This also retroactively explains ROUND 2's field failure above: a
//  word is only PATH-searched by the shell if it contains NO `/`; a
//  word containing a `/` is instead resolved as a path, relative to
//  the pane's cwd if not already absolute -- ordinary POSIX shell
//  semantics, nothing ghostty-specific. ROUND 2's own first word,
//  `HOME=/tmp/cxpane`, contains a `/` from its own value, so THAT is
//  what got resolved against the pane's cwd, not some ghostty-specific
//  "first word" rule. Because ROUND 2's fix additionally kept `exec`
//  as our OWN first word on top of ghostty's already-supplied one, the
//  actual full invocation became `exec exec /usr/bin/env ...`, and a
//  bare `exec` (no `/`) IS PATH-searched as a literal program named
//  "exec", which does not exist. Verbatim field failure from a real
//  pane, with the ROUND 2 `exec /usr/bin/env HOME=<root> ...` shape
//  (what both attachCommand and reattachCommand still emit as of this
//  RED phase):
//
//    bash: line 0: exec: exec: not found
//
//  The fix drops our own leading `exec` entirely -- ghostty already
//  supplies it via its own wrapping -- so the synthesized command
//  itself must start with `/usr/bin/env` instead: `/usr/bin/env
//  HOME=<root> <binaryPath> attach ...`. `/usr/bin/env` is immune to
//  both failure modes above: it is already absolute (no cwd-relative
//  ambiguity) and it is not a second `exec` word (so ghostty's own
//  single `exec` finds and execs it directly).
//
//  `assertFirstWordIsExec` is replaced by `assertFirstWordIsUsrBinEnv`
//  below (asserting `/usr/bin/env` instead of `exec`), and this file's
//  two execution-based stamp tests now run the synthesized command
//  through `runShCEmulatingGhosttyWrapping`, which reproduces ghostty's
//  ACTUAL wrapping (`/bin/sh -c "exec <command>"`, with a deliberately
//  wrong ambient `$HOME` set on the child process) instead of running
//  the bare command directly -- this locks in the in-app-observed
//  contract, not just what a bare `/bin/sh -c <command>` happens to
//  do. RED today: current production code still emits a leading `exec`
//  of its own, so the emulated wrapper produces `exec exec ...` and
//  fails exactly like the real pane, before the dumper script ever
//  gets to run and capture anything.
//
//  Coverage:
//  - reattachCommand stamps HOME=<resolver's root> ahead of the
//    binary, and the exec'd process actually observes that value as
//    $HOME even when ghostty's own wrapping supplies a different
//    ambient $HOME
//  - attachCommand (SessionSpawnPlanner's create-variant) does the same
//  - reattachCommand with no binary resolvable still returns nil,
//    unaffected by the new rootResolver parameter's presence/default
//  - (ROUND 3) both commands' first whitespace-delimited word is
//    exactly `/usr/bin/env` -- the ghostty exec-wrapping compatibility
//    constraint above
//

import XCTest
@testable import Calyx

private struct FakeBinaryResolver: SessionBinaryResolverProtocol {
    let path: String?
    func resolve() -> String? { path }
}

private struct FakeRootResolver: SessionRootResolverProtocol {
    let root: String
    func resolve() -> String { root }
}

final class SessionCommandSynthesizerHomeStampTests: XCTestCase {

    // MARK: - Shared helpers (mirrors SessionCommandSynthesizerTests' own)

    private func uniqueTempPath(_ label: String) -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("\(label)-\(UUID().uuidString)")
            .path
    }

    /// Writes a `#!/bin/sh` script that appends its own observed `$HOME`
    /// as the FIRST captured line, then each of its own arguments one
    /// per line after that -- so a single captured-output file proves
    /// both "which HOME the exec'd process saw" and "which argv it
    /// received" from one real `/bin/sh -c` run.
    private func makeHomeAndArgvDumperScript(at scriptPath: String, outputPath: String) throws {
        let body = "#!/bin/sh\nprintf 'HOME=%s\\n' \"$HOME\" >> \"\(outputPath)\"\nfor a in \"$@\"; do printf '%s\\n' \"$a\" >> \"\(outputPath)\"; done\n"
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
    /// configured `command`: wrapped by ghostty itself as `/bin/sh -c
    /// "exec <command>"` (see `assertFirstWordIsUsrBinEnv`'s doc
    /// comment for the verified real wrapping this simplifies), with
    /// `ambientHome` standing in for whatever unrelated `$HOME` value
    /// ghostty's own environment happens to carry into the pane --
    /// deliberately different from the rootResolver's stamped root, so
    /// a passing assertion on the captured `$HOME` proves the stamped
    /// value actually won, not that the two coincidentally already
    /// matched.
    private func runShCEmulatingGhosttyWrapping(_ command: String, ambientHome: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "exec " + command]
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = ambientHome
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
    }

    /// ROUND 3 (ghostty exec-wrapping compatibility): asserts the
    /// command's first whitespace-delimited word is exactly
    /// `/usr/bin/env`.
    ///
    /// Verbatim field failures from a real pane, across two
    /// independent fix rounds:
    ///
    ///   ROUND 1 -> ROUND 2 fix (our own command's first word was a
    ///   bare `HOME=<root>` env-assignment):
    ///
    ///     bash: /Users/eguchiyuuichi/projects/Calyx/HOME=/tmp/cxpane: No such file or directory
    ///     bash: line 0: exec: /Users/eguchiyuuichi/projects/Calyx/HOME=/tmp/cxpane: cannot execute: No such file or directory
    ///
    ///   ROUND 2 -> ROUND 3 fix (our own command additionally started
    ///   with its own leading `exec`):
    ///
    ///     bash: line 0: exec: exec: not found
    ///
    /// Ghostty wraps whatever `command` string we configure ITSELF as
    /// `<shell> -c "exec <command>"` -- verified directly against
    /// `ghostty/src/termio/Exec.zig`'s `execCommand`, which for a
    /// `.shell`-variant command (the default; Calyx never adds a
    /// `direct:` prefix) builds `/bin/bash --noprofile --norc -c
    /// "exec -l <command>"`. Ghostty supplies its own leading `exec`;
    /// it does NOT hand our string to a shell unmodified the way this
    /// file's own `runShCEmulatingGhosttyWrapping` helper does only to
    /// verify the env-stamp/argv side of the contract. Within
    /// that shell invocation, ordinary POSIX shell word semantics
    /// apply to exec's target word -- nothing ghostty-specific: a word
    /// containing NO `/` is searched via `PATH`; a word containing a
    /// `/` is NOT searched via `PATH` and is instead resolved as a
    /// path, relative to the pane's cwd if not already absolute. The
    /// first field failure above came from our own command starting
    /// with a bare `HOME=/tmp/cxpane` word (which contains a `/` from
    /// its own value), so it got resolved against the pane's cwd
    /// instead of exec'd directly. The second field failure came from
    /// keeping `exec` as our OWN first word on top of ghostty's
    /// already-supplied one: the full invocation became `exec exec
    /// /usr/bin/env ...`, and a bare `exec` (no `/`) IS searched via
    /// `PATH` as a literal program named "exec", which does not exist.
    /// `/usr/bin/env` is immune to both failure modes: it is already
    /// absolute (no cwd-relative ambiguity) and it is not a second
    /// `exec` word, so ghostty's own single `exec` finds and execs it
    /// directly.
    private func assertFirstWordIsUsrBinEnv(
        _ command: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        let firstWord = command.split(separator: " ", maxSplits: 1).first.map(String.init)
        XCTAssertEqual(firstWord, "/usr/bin/env",
                       "The command's first whitespace-delimited word must be exactly \"/usr/bin/env\" -- " +
                       "ghostty wraps our command itself as `<shell> -c \"exec <command>\"`, so our OWN " +
                       "command must never start with a second `exec` of its own (PATH-searched as a " +
                       "literal nonexistent program) nor a bare non-absolute word like a leading HOME=... " +
                       "env-assignment (resolved against the pane's cwd instead of exec'd)",
                       file: file, line: line)
    }

    // MARK: - reattachCommand

    func test_reattachCommand_stampsResolverRootAsHOME_execdProcessObservesIt() throws {
        let binaryPath = uniqueTempPath("calyx-session-dumper")
        let outputPath = uniqueTempPath("calyx-home-argv-capture")
        defer {
            try? FileManager.default.removeItem(atPath: binaryPath)
            try? FileManager.default.removeItem(atPath: outputPath)
        }
        try makeHomeAndArgvDumperScript(at: binaryPath, outputPath: outputPath)

        let rootResolver = FakeRootResolver(root: "/opt/calyx-fixture/custom-home")
        guard let command = SessionCommandSynthesizer.reattachCommand(
            sessionID: "01ARZ3NDEKTSV4RRFFQ69G5FAV",
            cwd: "/Users/dev/repo",
            resolver: FakeBinaryResolver(path: binaryPath),
            rootResolver: rootResolver
        ) else {
            XCTFail("With a resolvable binary path, reattachCommand must not return nil")
            return
        }

        assertFirstWordIsUsrBinEnv(command)

        try runShCEmulatingGhosttyWrapping(command, ambientHome: "/tmp/calyx-wrong-ambient-home")
        let lines = readCapturedLines(at: outputPath)

        XCTAssertEqual(lines.first, "HOME=/opt/calyx-fixture/custom-home",
                       "The exec'd calyx-session process must observe the injected rootResolver's root as " +
                       "its own $HOME, regardless of whatever ambient HOME the surrounding shell had -- this " +
                       "is what keeps the attach process's own state-root resolution in agreement with " +
                       "whatever SessionDaemonClient resolved for the same rootResolver")
        XCTAssertEqual(Array(lines.dropFirst()),
                       ["attach", "01ARZ3NDEKTSV4RRFFQ69G5FAV", "--create", "--cwd", "/Users/dev/repo"],
                       "The rest of the attach argv must be unaffected by the new HOME stamp")
    }

    func test_reattachCommand_noBinaryResolvable_stillReturnsNil() {
        let command = SessionCommandSynthesizer.reattachCommand(
            sessionID: "01ARZ3NDEKTSV4RRFFQ69G5FAV",
            cwd: "/Users/dev/repo",
            resolver: FakeBinaryResolver(path: nil),
            rootResolver: FakeRootResolver(root: "/opt/calyx-fixture/custom-home")
        )
        XCTAssertNil(command,
                     "With no binary resolvable, reattachCommand must still return nil regardless of " +
                     "rootResolver -- the new parameter must not change this pre-existing degrade-gracefully " +
                     "contract")
    }

    // MARK: - attachCommand (SessionSpawnPlanner's create-variant)

    func test_attachCommand_stampsResolverRootAsHOME_execdProcessObservesIt() throws {
        let binaryPath = uniqueTempPath("calyx-session-dumper")
        let outputPath = uniqueTempPath("calyx-home-argv-capture")
        defer {
            try? FileManager.default.removeItem(atPath: binaryPath)
            try? FileManager.default.removeItem(atPath: outputPath)
        }
        try makeHomeAndArgvDumperScript(at: binaryPath, outputPath: outputPath)

        let command = SessionCommandSynthesizer.attachCommand(
            binaryPath: binaryPath,
            sessionID: "01ARZ3NDEKTSV4RRFFQ69G5FAV",
            cwd: "/Users/dev/repo",
            rootResolver: FakeRootResolver(root: "/opt/calyx-fixture/spawn-home")
        )

        assertFirstWordIsUsrBinEnv(command)

        try runShCEmulatingGhosttyWrapping(command, ambientHome: "/tmp/calyx-wrong-ambient-home")
        let lines = readCapturedLines(at: outputPath)

        XCTAssertEqual(lines.first, "HOME=/opt/calyx-fixture/spawn-home",
                       "attachCommand (SessionSpawnPlanner's create-variant, used for brand-new session " +
                       "spawns) must stamp the SAME rootResolver contract as reattachCommand, so a fresh " +
                       "spawn and a later reconnect/restore of the same session never disagree about the " +
                       "daemon's state root")
    }
}
