//
//  SessionCommandSynthesizerRuntimeStateDirFlagsTests.swift
//  CalyxTests
//
//  TDD Red phase (round 18, G5 flags migration): supersedes the former
//  SessionCommandSynthesizerHomeStampTests, which stamped the resolved
//  session root as a leading `/usr/bin/env HOME=<root>` word ahead of
//  the exec'd calyx-session binary. That stamp existed only to make the
//  attach process's own HOME-derived state-root resolution agree with
//  whatever SessionDaemonClient resolved for the same rootResolver (see
//  SessionRootResolver.swift's header) -- but the Rust CLI has carried
//  its own, more direct answer to the same problem since P2: global
//  `--runtime-dir`/`--state-dir` flags (calyx-session/crates/cli/src/cli.rs:15-20,
//  `global = true`, so every subcommand accepts them, not just `daemon`)
//  that `attach` both accepts and, when it auto-spawns the daemon,
//  forwards verbatim (calyx-session/crates/cli/src/commands/attach.rs's
//  `run` at lines 30-34 threading them through to `spawn_daemon`, which
//  at lines 193-224 passes `--runtime-dir`/`--state-dir` ahead of
//  `daemon` on the spawned child's own argv). Passing these two flags
//  directly says the same thing the HOME stamp said indirectly, without
//  needing an env override or an `/usr/bin/env` wrapper at all.
//
//  This also RETIRES the entire ghostty-exec-wrapping saga the old
//  HomeStampTests file fought through three rounds:
//  - ROUND 1: a bare `HOME=<root>` first word resolved as a cwd-relative
//    path, field-verified broken as `bash: .../HOME=/tmp/cxpane: No such
//    file or directory`.
//  - ROUND 2: a redundant leading `exec` PATH-searched as a literal
//    nonexistent program, field-verified broken as `bash: line 0: exec:
//    exec: not found`.
//  - ROUND 3: finally routing through `/usr/bin/env` to make the `HOME=`
//    word an actual env assignment rather than a literal argv word.
//  Once the session root travels as ordinary argv words to the binary
//  itself rather than as an env assignment ahead of it, the command's
//  first word is simply the absolute calyx-session binary path again,
//  exactly like the pre-HOME-stamp original. Ghostty wraps whatever
//  `command` string we configure itself as `<shell> -c "exec <command>"`
//  (`ghostty/src/termio/Exec.zig`'s `execCommand`, for the default
//  `.shell`-variant command Calyx always produces); its own single
//  `exec` finds and execs an absolute first word directly, with no
//  cwd-relative or PATH-search ambiguity, so there is no failure mode
//  left for this file to guard against the way the old ROUND 1/2/3 tests
//  did. (This is the canonical copy of this narrative -- other files
//  that reference this saga, including `SessionCommandSynthesizer.swift`
//  itself, point back here rather than repeating it.)
//
//  Verified by actually running the synthesized command through a real
//  `/bin/sh -c` emulating ghostty's own `exec <command>` wrapping,
//  substituting a small stub script (in place of the real calyx-session
//  binary) that dumps its own observed $HOME as the first captured
//  line, followed by its argv -- mirroring this file family's
//  established approach (SessionCommandSynthesizerTests,
//  SessionSpawnPlannerTests) of checking the property that actually
//  matters (what the exec'd process actually observes) rather than
//  string-matching one specific escaping/ordering shape. The captured
//  $HOME line now proves the OPPOSITE of what it proved under the old
//  HOME-stamp contract: that ambient HOME is left entirely untouched,
//  because the session root is conveyed as `--runtime-dir`/`--state-dir`
//  argv words, not an env override.
//
//  Existing-behavior guard: with no rootResolver override
//  (SessionRootResolver's default, real production use), the composed
//  `--runtime-dir`/`--state-dir` values equal `<real $HOME>/.calyx/{run,state}`
//  -- identical to the Rust CLI's own fallback
//  (calyx-session/crates/cli/src/commands/mod.rs:74's
//  `default_home_subdir`, NOT `daemon/src/session.rs` as an earlier
//  round's comment mistakenly cited), so this is behaviorally invisible
//  for normal users.
//
//  Coverage:
//  - attachCommand / reattachCommand never emit `/usr/bin/env` or a
//    `HOME=` word anywhere in the synthesized command
//  - both prepend `--runtime-dir <root>/.calyx/run --state-dir
//    <root>/.calyx/state` immediately before the `attach` subcommand,
//    and the exec'd process receives them as ordinary argv -- not as an
//    environment override; ambient $HOME plays no role at all
//  - with no rootResolver override, the composed paths equal
//    `<real $HOME>/.calyx/{run,state}` (regression guard against the
//    Rust CLI's own default)
//  - reattachCommand with no binary resolvable still returns nil,
//    unaffected by the flags migration
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

final class SessionCommandSynthesizerRuntimeStateDirFlagsTests: XCTestCase {

    // MARK: - Shared helpers (mirrors SessionCommandSynthesizerTests' own)

    private func uniqueTempPath(_ label: String) -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("\(label)-\(UUID().uuidString)")
            .path
    }

    /// Writes a `#!/bin/sh` script that appends its own observed `$HOME`
    /// as the FIRST captured line, then each of its own arguments one
    /// per line after that -- so a single captured-output file proves
    /// both "did ambient HOME leak through unmodified" and "which argv
    /// it received" from one real `/bin/sh -c` run.
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
    /// "exec <command>"`, with `ambientHome` standing in for whatever
    /// unrelated `$HOME` value ghostty's own environment happens to
    /// carry into the pane -- deliberately different from the
    /// rootResolver's root, so a captured `$HOME` line still equal to
    /// `ambientHome` proves the session root travels as argv, never as
    /// an env override.
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

    /// Plain, non-ghostty-emulating `/bin/sh -c` run, for the
    /// default-rootResolver regression guard below, which only cares
    /// about the composed argv, not ambient-HOME independence.
    private func runShC(_ command: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
    }

    /// Asserts `command` contains neither an `/usr/bin/env` wrapper nor
    /// a `HOME=` word anywhere -- both retired by this round's flags
    /// migration (see this file's header for why).
    private func assertContainsNoEnvWrapperOrHomeStamp(
        _ command: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertFalse(command.contains("/usr/bin/env"),
                       "The synthesized command must never wrap itself in /usr/bin/env any more -- the " +
                       "session root now travels as --runtime-dir/--state-dir argv words directly to the " +
                       "binary, so the command's first word must simply be the binary path itself",
                       file: file, line: line)
        XCTAssertFalse(command.contains("HOME="),
                       "The synthesized command must never contain a HOME= word anywhere -- stamping HOME " +
                       "was the old mechanism this round retires in favor of explicit --runtime-dir/--state-dir " +
                       "flags",
                       file: file, line: line)
    }

    // MARK: - reattachCommand: shape

    func test_reattachCommand_containsNoEnvWrapperOrHomeStamp() throws {
        let binaryPath = uniqueTempPath("calyx-session-dumper")
        guard let command = SessionCommandSynthesizer.reattachCommand(
            sessionID: "01ARZ3NDEKTSV4RRFFQ69G5FAV",
            cwd: "/Users/dev/repo",
            resolver: FakeBinaryResolver(path: binaryPath),
            rootResolver: FakeRootResolver(root: "/opt/calyx-fixture/custom-home")
        ) else {
            XCTFail("With a resolvable binary path, reattachCommand must not return nil")
            return
        }
        assertContainsNoEnvWrapperOrHomeStamp(command)
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
                     "rootResolver -- the flags migration must not change this pre-existing " +
                     "degrade-gracefully contract")
    }

    // MARK: - attachCommand: shape

    func test_attachCommand_containsNoEnvWrapperOrHomeStamp() {
        let command = SessionCommandSynthesizer.attachCommand(
            binaryPath: "/usr/local/bin/calyx-session",
            sessionID: "01ARZ3NDEKTSV4RRFFQ69G5FAV",
            cwd: "/Users/dev/repo",
            rootResolver: FakeRootResolver(root: "/opt/calyx-fixture/custom-home")
        )
        assertContainsNoEnvWrapperOrHomeStamp(command)
    }

    // MARK: - reattachCommand: execution proves argv-based flags, ambient HOME irrelevant

    func test_reattachCommand_prependsRuntimeAndStateDirFlagsBeforeAttach_ambientHOMEIrrelevant() throws {
        let binaryPath = uniqueTempPath("calyx-session-dumper")
        let outputPath = uniqueTempPath("calyx-home-argv-capture")
        defer {
            try? FileManager.default.removeItem(atPath: binaryPath)
            try? FileManager.default.removeItem(atPath: outputPath)
        }
        try makeHomeAndArgvDumperScript(at: binaryPath, outputPath: outputPath)

        guard let command = SessionCommandSynthesizer.reattachCommand(
            sessionID: "01ARZ3NDEKTSV4RRFFQ69G5FAV",
            cwd: "/Users/dev/repo",
            resolver: FakeBinaryResolver(path: binaryPath),
            rootResolver: FakeRootResolver(root: "/opt/calyx-fixture/custom-home")
        ) else {
            XCTFail("With a resolvable binary path, reattachCommand must not return nil")
            return
        }

        try runShCEmulatingGhosttyWrapping(command, ambientHome: "/tmp/calyx-wrong-ambient-home")
        let lines = readCapturedLines(at: outputPath)

        XCTAssertEqual(lines.first, "HOME=/tmp/calyx-wrong-ambient-home",
                       "The exec'd calyx-session process's own $HOME must be left completely untouched -- " +
                       "whatever ambient HOME the surrounding shell had, unmodified -- because the session " +
                       "root now travels as --runtime-dir/--state-dir argv words, never as an env override")
        XCTAssertEqual(Array(lines.dropFirst()),
                       ["--runtime-dir", "/opt/calyx-fixture/custom-home/.calyx/run",
                        "--state-dir", "/opt/calyx-fixture/custom-home/.calyx/state",
                        "attach", "01ARZ3NDEKTSV4RRFFQ69G5FAV", "--create", "--cwd", "/Users/dev/repo"],
                       "The two global flags must appear as the process's own leading argv, immediately " +
                       "before the attach subcommand and its own arguments, mirroring the exact global-flags-" +
                       "before-subcommand order the Rust CLI itself uses (calyx-session/crates/cli/src/commands/attach.rs's " +
                       "own spawn_daemon, which builds --runtime-dir <dir> --state-dir <dir> daemon in that order)")
    }

    // MARK: - attachCommand: execution proves argv-based flags, ambient HOME irrelevant

    func test_attachCommand_prependsRuntimeAndStateDirFlagsBeforeAttach_ambientHOMEIrrelevant() throws {
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

        try runShCEmulatingGhosttyWrapping(command, ambientHome: "/tmp/calyx-wrong-ambient-home")
        let lines = readCapturedLines(at: outputPath)

        XCTAssertEqual(lines.first, "HOME=/tmp/calyx-wrong-ambient-home",
                       "attachCommand (SessionSpawnPlanner's create-variant, used for brand-new session " +
                       "spawns) must leave ambient $HOME just as untouched as reattachCommand does")
        XCTAssertEqual(Array(lines.dropFirst()),
                       ["--runtime-dir", "/opt/calyx-fixture/spawn-home/.calyx/run",
                        "--state-dir", "/opt/calyx-fixture/spawn-home/.calyx/state",
                        "attach", "01ARZ3NDEKTSV4RRFFQ69G5FAV", "--create", "--cwd", "/Users/dev/repo"],
                       "attachCommand must stamp the SAME rootResolver contract as reattachCommand via argv " +
                       "flags, so a fresh spawn and a later reconnect/restore of the same session never " +
                       "disagree about the daemon's state root")
    }

    // MARK: - Regression guard: no override matches the Rust CLI's own default

    func test_attachCommand_defaultRootResolver_composesRealHOMECalyxRunAndStateDirs() throws {
        let binaryPath = uniqueTempPath("calyx-session-dumper")
        let outputPath = uniqueTempPath("calyx-argv-capture")
        defer {
            try? FileManager.default.removeItem(atPath: binaryPath)
            try? FileManager.default.removeItem(atPath: outputPath)
        }
        try makeHomeAndArgvDumperScript(at: binaryPath, outputPath: outputPath)

        // No rootResolver override: exercises the real production
        // default (SessionRootResolver()).
        let command = SessionCommandSynthesizer.attachCommand(
            binaryPath: binaryPath, sessionID: "01ARZ3NDEKTSV4RRFFQ69G5FAV", cwd: "/Users/dev/repo"
        )

        try runShC(command)
        let lines = readCapturedLines(at: outputPath)
        let expectedRoot = SessionRootResolver().resolve()

        XCTAssertEqual(Array(lines.dropFirst()),
                       ["--runtime-dir", expectedRoot + "/.calyx/run",
                        "--state-dir", expectedRoot + "/.calyx/state",
                        "attach", "01ARZ3NDEKTSV4RRFFQ69G5FAV", "--create", "--cwd", "/Users/dev/repo"],
                       "With no rootResolver override (real production use), the composed --runtime-dir/" +
                       "--state-dir paths must equal <real $HOME>/.calyx/{run,state} -- identical to the " +
                       "Rust CLI's own default_home_subdir fallback (calyx-session/crates/cli/src/commands/mod.rs:74), " +
                       "so behavior is unchanged from today for every normal user")
    }
}
