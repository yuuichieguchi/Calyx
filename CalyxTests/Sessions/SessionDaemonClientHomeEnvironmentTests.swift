//
//  SessionDaemonClientHomeEnvironmentTests.swift
//  CalyxTests
//
//  TDD Red phase (session-root-resolution fix round): SessionDaemonClient
//  passes `environment: nil` to every LSPCommandRunner.run(...) call
//  today (listAll/sessionState/kill/setMeta), so the calyx-session
//  subprocess spawned for each query inherits whatever ambient HOME
//  Calyx.app itself happens to have -- which the daemon's own CLI uses
//  to resolve its state root ($HOME/.calyx, see
//  calyx-session/crates/daemon/src/session.rs).
//  SessionCommandSynthesizerHomeStampTests covers the OTHER half of
//  this defect (the attach process's own HOME, stamped into the
//  synthesized shell command); this file covers the daemon-QUERY half,
//  so both halves resolve the IDENTICAL root via the same injectable
//  `SessionRootResolverProtocol` seam (see SessionRootResolverTests),
//  never independently -- which is the proven live failure mode this
//  whole round fixes: with mismatched HOMEs, a query against a session
//  that is genuinely alive and attached reports .unreachable.
//
//  This file targets a new `rootResolver:` init parameter on
//  `SessionDaemonClient`, which does NOT exist in the codebase yet.
//  Following this codebase's established convention for new-API RED
//  tests (see SessionDaemonClientBoundedListTests' header comment,
//  itself citing CalyxWindowControllerFullScreenTests), this file is
//  expected to FAIL TO COMPILE until the TDD Green phase adds it --
//  that compile failure IS this contract's RED evidence.
//
//  IMPORTANT FOR GREEN (verified by inspection of
//  SystemCommandRunner.augmentedEnvironment(base:), which does
//  `base ?? ProcessInfo.processInfo.environment` then overrides only
//  "PATH"): passing a bare `["HOME": root]` as the `environment:`
//  argument would make THAT single-key dictionary the non-nil `base`,
//  silently dropping every other ambient variable (LANG, USER, TERM,
//  ...) that `environment: nil` currently preserves via the `?? ambient`
//  fallback -- PATH alone would still get re-added by
//  augmentedEnvironment, but nothing else would. Green must build the
//  environment dict by copying `ProcessInfo.processInfo.environment`
//  and overriding just the "HOME" key (mirrring
//  `SystemCommandRunner.augmentedEnvironment(base:)`'s own copy-and-
//  override shape for PATH), not construct a bare single-key dict, so
//  today's full-ambient-inheritance behavior is preserved for every key
//  besides HOME.
//
//  Existing-behavior guard: with no HOME override (SessionRootResolver's
//  default, real production use), the resolved root equals the real
//  $HOME already ambiently inherited today, so normal users see no
//  behavioral change to what the daemon queries observe -- only a
//  mismatched-HOME environment (this fix's actual target) changes what
//  gets passed.
//
//  Coverage:
//  - listAll / sessionState / kill / setMeta ALL pass a non-nil
//    environment dict whose "HOME" key is the injected rootResolver's
//    resolved value, to the underlying commandRunner -- not nil
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

/// Records every environment dict `run(...)` was called with, standing
/// in for the real calyx-session subprocess call so the test can
/// inspect what SessionDaemonClient actually hands the command runner
/// without spawning a real process. An actor (mirrors LSPInstaller's
/// own `MockCommandRunner`) so the several awaited calls this test
/// drives sequentially can safely append to shared state.
private actor RecordingCommandRunner: LSPCommandRunner {
    private(set) var recordedEnvironments: [[String: String]?] = []

    func run(
        executable: String,
        arguments: [String],
        workingDirectory: URL?,
        environment: [String: String]?
    ) async throws -> CommandResult {
        recordedEnvironments.append(environment)
        return CommandResult(exitCode: 0, stdout: "[]", stderr: "")
    }

    func locate(_ executable: String) async -> URL? { nil }
}

final class SessionDaemonClientHomeEnvironmentTests: XCTestCase {

    func test_allFourOperations_passResolvedRootAsHOMEInEnvironment_notNil() async {
        let runner = RecordingCommandRunner()
        let client = SessionDaemonClient(
            resolver: FixedBinaryResolver(path: "/opt/calyx-fixture/bin/calyx-session"),
            commandRunner: runner,
            rootResolver: FakeRootResolver(root: "/opt/calyx-fixture/custom-home")
        )

        _ = await client.listAll()
        _ = await client.sessionState(id: "01ARZ3NDEKTSV4RRFFQ69G5FAV")
        await client.kill(id: "01ARZ3NDEKTSV4RRFFQ69G5FAV")
        await client.setMeta(id: "01ARZ3NDEKTSV4RRFFQ69G5FAV", key: "k", value: "v")

        let recorded = await runner.recordedEnvironments
        XCTAssertEqual(recorded.count, 4,
                       "listAll, sessionState, kill, and setMeta must each invoke the command runner exactly " +
                       "once for this test to have observed all four operations")
        for (index, env) in recorded.enumerated() {
            XCTAssertEqual(env?["HOME"], "/opt/calyx-fixture/custom-home",
                          "Call #\(index) must pass an explicit, non-nil environment carrying the injected " +
                          "rootResolver's resolved root as HOME -- an implicit-inherit nil risks disagreeing " +
                          "with whatever HOME the attach process on the other side of the same session was " +
                          "stamped with (see SessionCommandSynthesizerHomeStampTests)")
        }
    }
}
