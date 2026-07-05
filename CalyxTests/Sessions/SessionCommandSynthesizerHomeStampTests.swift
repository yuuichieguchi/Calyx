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
//  KNOWN CONSEQUENCE FOR GREEN (flagged, not fixed here): once Green
//  lands, the synthesized command's TEXT will start with "HOME=..."
//  rather than "exec ", which will break the literal
//  `command.hasPrefix("exec ")` assertions in
//  SessionCommandSynthesizerTests.test_attachCommand_basicForm_includesExecCreateIdCwdInOrder
//  and SessionSpawnPlannerTests.test_plan_enabledTabOrigin_returnsPersistentWithULIDSessionIDAndMatchingCommand
//  (both currently green, pre-existing, and deliberately left untouched
//  by this RED phase per this round's rules). Green must update those
//  two assertions to a check that tolerates a leading `HOME=... `
//  env-assignment word while still verifying the underlying invariant
//  they protect (direct exec, not a surviving shell wrapper) --
//  e.g. asserting `" exec "` appears in the command, or asserting the
//  first word after any leading `KEY=value` assignment tokens is
//  `exec`. Not this file's job to weaken pre-existing tests during RED.
//
//  Coverage:
//  - reattachCommand stamps HOME=<resolver's root> ahead of exec, and
//    the exec'd process actually observes that value as $HOME
//  - attachCommand (SessionSpawnPlanner's create-variant) does the same
//  - reattachCommand with no binary resolvable still returns nil,
//    unaffected by the new rootResolver parameter's presence/default
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

        try runShC(command)
        let lines = readCapturedLines(at: outputPath)

        XCTAssertEqual(lines.first, "HOME=/opt/calyx-fixture/spawn-home",
                       "attachCommand (SessionSpawnPlanner's create-variant, used for brand-new session " +
                       "spawns) must stamp the SAME rootResolver contract as reattachCommand, so a fresh " +
                       "spawn and a later reconnect/restore of the same session never disagree about the " +
                       "daemon's state root")
    }
}
