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
//  HOME=<root> <binaryPath> attach ...`. This file's two execution
//  tests below now ALSO assert (via `assertFirstWordIsExec`) that the
//  command's first word is exactly `exec` -- RED against the ROUND 1
//  `HOME=<root> exec ...` shape still in production code as of this
//  RED phase.
//
//  Coverage:
//  - reattachCommand stamps HOME=<resolver's root> ahead of exec, and
//    the exec'd process actually observes that value as $HOME
//  - attachCommand (SessionSpawnPlanner's create-variant) does the same
//  - reattachCommand with no binary resolvable still returns nil,
//    unaffected by the new rootResolver parameter's presence/default
//  - (ROUND 2) both commands' first whitespace-delimited word is
//    exactly `exec` -- the ghostty compatibility constraint above
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

    /// ROUND 2 (ghostty first-word-exec compatibility): asserts the
    /// command's first whitespace-delimited word is exactly `exec`.
    ///
    /// Verbatim field failure from a real pane, with the pre-fix
    /// `HOME=<root> exec <bin> ...` shape (what both attachCommand and
    /// reattachCommand emit as of this RED phase):
    ///
    ///   bash: /Users/eguchiyuuichi/projects/Calyx/HOME=/tmp/cxpane: No such file or directory
    ///   bash: line 0: exec: /Users/eguchiyuuichi/projects/Calyx/HOME=/tmp/cxpane: cannot execute: No such file or directory
    ///
    /// Ghostty resolves a pane's `command` config by treating the
    /// FIRST WHITESPACE-DELIMITED WORD as the literal program to exec
    /// directly, resolving a non-absolute first word against the
    /// pane's cwd -- NOT by handing the whole string to `/bin/sh -c`
    /// (that's this file's own `runShC` helper, used only to verify
    /// the env-stamp/argv side of the contract in a real shell). A
    /// leading `HOME=<root>` env-assignment word becomes that first
    /// word, so ghostty tries to execute a nonexistent file literally
    /// named "HOME=<root>" and the pane dies instantly. First-word-exec
    /// is therefore load-bearing for ghostty independent of whether the
    /// HOME stamp itself takes effect when run through a real shell.
    private func assertFirstWordIsExec(
        _ command: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        let firstWord = command.split(separator: " ", maxSplits: 1).first.map(String.init)
        XCTAssertEqual(firstWord, "exec",
                       "The command's first whitespace-delimited word must be exactly \"exec\" -- ghostty " +
                       "execs the pane command's first word directly (not via /bin/sh -c), so any other " +
                       "first word (e.g. a leading HOME=... env-assignment) makes ghostty try to execute a " +
                       "nonexistent file and the pane dies instantly",
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

        assertFirstWordIsExec(command)

        try runShC(command)
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

        assertFirstWordIsExec(command)

        try runShC(command)
        let lines = readCapturedLines(at: outputPath)

        XCTAssertEqual(lines.first, "HOME=/opt/calyx-fixture/spawn-home",
                       "attachCommand (SessionSpawnPlanner's create-variant, used for brand-new session " +
                       "spawns) must stamp the SAME rootResolver contract as reattachCommand, so a fresh " +
                       "spawn and a later reconnect/restore of the same session never disagree about the " +
                       "daemon's state root")
    }
}
