//
//  SessionDaemonClientRuntimeDirArgsTests.swift
//  CalyxTests
//
//  TDD Red phase (round 18, G5 flags migration): supersedes the former
//  SessionDaemonClientHomeEnvironmentTests, which passed every
//  commandRunner.run(...) call a full ProcessInfo-copy environment with
//  only "HOME" overridden to the resolved session root -- see
//  SessionCommandSynthesizerRuntimeStateDirFlagsTests's header for the
//  full HOME-stamp-to-flags migration rationale shared by both halves
//  of this fix. The Rust CLI's global `--runtime-dir` flag
//  (calyx-session/crates/cli/src/cli.rs:15-16, `global = true`) is what
//  `ls`/`kill`/`meta` actually consult to find the daemon's socket
//  (`main.rs`'s dispatch at lines 21-24 passes only `parsed.runtime_dir`
//  through to each; `commands/mod.rs`'s `resolve_runtime_dir` at lines
//  60-64 and `socket_path` at lines 80-83) -- so the daemon-query half
//  of this fix moves from an env override to an explicit
//  `--runtime-dir <root>/.calyx/run` argument prepended before each
//  subcommand's own arguments, exactly mirroring the synthesized attach
//  command's own flags.
//
//  `--state-dir` is deliberately NOT part of any of these four calls:
//  `ls`/`kill`/`meta` never receive it at all (`main.rs`'s dispatch
//  passes only `runtime_dir` to each of those three); `state_dir` is
//  resolved once, daemon-internally, inside the (already-running, for
//  every one of these four calls) daemon process itself
//  (`commands/mod.rs:74`'s `default_home_subdir`).
//
//  This file replaces SessionDaemonClientHomeEnvironmentTests (which
//  asserted the OLD environment-copy-with-HOME-override contract, now
//  retired).
//
//  Coverage:
//  - listAll / sessionState / kill / setMeta each prepend
//    ["--runtime-dir", "<rootResolver's root>/.calyx/run"] before their
//    own subcommand arguments
//  - environment goes back to nil for all four -- no full-ProcessInfo-
//    copy override needed any more, since the session root now travels
//    as an argv word instead
//  - with no rootResolver override, the composed --runtime-dir value
//    equals <real $HOME>/.calyx/run (regression guard against the Rust
//    CLI's own default)
//

import XCTest
@testable import Calyx

private struct FixedBinaryResolver: SessionBinaryResolverProtocol {
    let path: String?
    func resolve() -> String? { path }
}

private struct FakeRootResolver: SessionRootResolverProtocol {
    let root: String
    func resolve() -> String { root }
}

/// Records every (arguments, environment) pair `run(...)` was called
/// with, standing in for the real calyx-session subprocess call so the
/// test can inspect what SessionDaemonClient actually hands the command
/// runner without spawning a real process. An actor (mirrors
/// LSPInstaller's own MockCommandRunner) so the several awaited calls
/// this test drives sequentially can safely append to shared state.
private actor RecordingCommandRunner: LSPCommandRunner {
    private(set) var recordedCalls: [(arguments: [String], environment: [String: String]?)] = []

    func run(
        executable: String,
        arguments: [String],
        workingDirectory: URL?,
        environment: [String: String]?
    ) async throws -> CommandResult {
        recordedCalls.append((arguments, environment))
        return CommandResult(exitCode: 0, stdout: "[]", stderr: "")
    }

    func locate(_ executable: String) async -> URL? { nil }
}

final class SessionDaemonClientRuntimeDirArgsTests: XCTestCase {

    func test_allFourOperations_prependRuntimeDirFlagBeforeSubcommand_environmentStaysNil() async {
        let runner = RecordingCommandRunner()
        let client = SessionDaemonClient(
            resolver: FixedBinaryResolver(path: "/opt/calyx-fixture/bin/calyx-session"),
            commandRunner: runner,
            rootResolver: FakeRootResolver(root: "/opt/calyx-fixture/custom-home")
        )
        let runtimeDirFlag = ["--runtime-dir", "/opt/calyx-fixture/custom-home/.calyx/run"]

        _ = await client.listAll()
        _ = await client.sessionState(id: "01ARZ3NDEKTSV4RRFFQ69G5FAV")
        await client.kill(id: "01ARZ3NDEKTSV4RRFFQ69G5FAV")
        await client.setMeta(id: "01ARZ3NDEKTSV4RRFFQ69G5FAV", key: "k", value: "v")

        let recorded = await runner.recordedCalls
        XCTAssertEqual(recorded.count, 4,
                       "listAll, sessionState, kill, and setMeta must each invoke the command runner exactly " +
                       "once for this test to have observed all four operations")

        XCTAssertEqual(recorded[0].arguments, runtimeDirFlag + ["ls", "--all", "--json"],
                       "listAll must prepend --runtime-dir <root>/.calyx/run before its ls --all --json " +
                       "subcommand arguments")
        XCTAssertEqual(recorded[1].arguments, runtimeDirFlag + ["ls", "--all", "--json"],
                       "sessionState must prepend --runtime-dir <root>/.calyx/run before the same ls --all " +
                       "--json subcommand it shares with listAll")
        XCTAssertEqual(recorded[2].arguments, runtimeDirFlag + ["kill", "01ARZ3NDEKTSV4RRFFQ69G5FAV"],
                       "kill must prepend --runtime-dir <root>/.calyx/run before its kill <id> subcommand " +
                       "arguments")
        XCTAssertEqual(recorded[3].arguments, runtimeDirFlag + ["meta", "set", "01ARZ3NDEKTSV4RRFFQ69G5FAV", "k=v"],
                       "setMeta must prepend --runtime-dir <root>/.calyx/run before its meta set <id> " +
                       "<key>=<value> subcommand arguments")

        for (index, call) in recorded.enumerated() {
            XCTAssertNil(call.environment,
                         "Call #\(index) must pass a nil environment -- the session root is now conveyed via " +
                         "the --runtime-dir argument, not an env override, so this client no longer needs its " +
                         "own full-ProcessInfo-copy environment at all")
        }
    }

    func test_defaultRootResolver_composesRealHOMECalyxRunDir() async {
        let runner = RecordingCommandRunner()
        // No rootResolver override: exercises the real production
        // default (SessionRootResolver()).
        let client = SessionDaemonClient(
            resolver: FixedBinaryResolver(path: "/opt/calyx-fixture/bin/calyx-session"),
            commandRunner: runner
        )

        _ = await client.listAll()

        let recorded = await runner.recordedCalls
        let expectedRoot = SessionRootResolver().resolve()
        XCTAssertEqual(recorded.first?.arguments,
                       ["--runtime-dir", expectedRoot + "/.calyx/run", "ls", "--all", "--json"],
                       "With no rootResolver override (real production use), the composed --runtime-dir " +
                       "value must equal <real $HOME>/.calyx/run -- identical to the Rust CLI's own " +
                       "default_home_subdir fallback (calyx-session/crates/cli/src/commands/mod.rs:74), so " +
                       "behavior is unchanged from today for every normal user")
    }
}
