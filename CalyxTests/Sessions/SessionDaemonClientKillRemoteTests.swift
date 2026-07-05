//
//  SessionDaemonClientKillRemoteTests.swift
//  CalyxTests
//
//  P5 (remote sessions) RED phase, BUG 1 (five-angle convergence review
//  finding): CalyxWindowController.killSessionIfPersistent never
//  consults SessionRef.host, so closing a remote pane always kills via
//  the LOCAL daemon client -- a silent no-op against a session whose
//  daemon lives entirely on the remote host, orphaning it forever and
//  contradicting the close=kill contract every local pane already gets.
//
//  THIS FILE (contract 1a, client level): SessionDaemonClient must gain
//  a `killRemote(host: String, sessionID: String) async` operation that
//  shells `ssh -- <host> "$HOME/.calyx/bin/calyx-session kill
//  <sessionID>"` (sessionID escaped via SessionCommandSynthesizer's own
//  battle-tested shSafeToken -- reused, not duplicated, per that
//  function's own doc comment listing two prior grapheme-cluster
//  escaping bugs from earlier reimplementations) via the SAME injected
//  `commandRunner`/`LSPCommandRunner` seam every other operation on this
//  client already uses, with `ssh` resolved via the existing
//  `SSHBinaryResolverProtocol` (mirrors `SessionCommandSynthesizer
//  .remoteAttachCommand`'s own ssh resolution, and `installRemote(host:)`'s
//  own `payloadResolver` dependency-injection shape).
//
//  WHY NO -t: unlike `remoteAttachCommand` (which allocates a PTY for an
//  interactive ghostty pane), `kill` is a one-shot, non-interactive
//  remote command -- no PTY is needed, so `-t` is deliberately omitted.
//
//  WHY NO OUTER shSafeToken LAYER: unlike `remoteAttachCommand`, whose
//  entire synthesized string is embedded in ghostty's own LOCAL
//  `/bin/sh -c "exec <command>"` wrapping (requiring a second, outer
//  quoting layer for that local shell), `killRemote` invokes `ssh`
//  directly as a `Process` via `commandRunner.run(executable:arguments:)`
//  -- there is no local shell parsing this argv array at all, so only
//  the sessionID needs escaping, scoped for the REMOTE shell sshd invokes
//  to run the trailing command argument.
//
//  DESIGN NOTE on SessionDaemonClientProtocol.killRemote(host:sessionID:):
//  a NEW protocol requirement. Every existing SessionDaemonClientProtocol
//  fake across the suite (SessionReconnectCoordinatorTests,
//  SessionDaemonClientBoundedCancellationTests, etc.) must keep compiling
//  untouched, so the Green phase must add a default protocol extension
//  (a no-op) alongside the requirement -- mirroring `installRemote(host:)`'s
//  own identical precedent (SessionDaemonClient.swift) -- rather than a
//  bare protocol requirement that would force every existing fake in the
//  suite to grow a new override.
//
//  Held-out compile-RED file per this codebase's established convention
//  (see SessionRemoteInstallTests's header for the identical precedent
//  this mirrors): `killRemote(host:sessionID:)` does not exist anywhere
//  in the codebase yet -- neither on the protocol nor on the concrete
//  SessionDaemonClient, which also does not yet accept an `sshResolver`
//  dependency. Expected to FAIL TO COMPILE until the Green phase adds
//  both. That compile failure IS this file's RED evidence. Must be
//  excluded from the build while running the rest of the round's RED
//  suite and verified separately for its own specific compiler errors.
//
//  Coverage:
//  - killRemote(host:sessionID:) invokes the resolved ssh binary
//    (injected SSHBinaryResolverProtocol fake) as the executable, with
//    argv exactly ["--", host, "$HOME/.calyx/bin/calyx-session kill
//    '<sessionID>'"] -- no -t flag
//  - A sessionID containing a single quote is escaped via the same
//    single-quote-wrapping convention SessionCommandSynthesizer.shSafeToken
//    already uses elsewhere in this codebase (defense in depth; real
//    sessionIDs are ULIDs and never contain one in practice)
//  - No local calyx-session binary resolvable must NOT prevent
//    killRemote from running -- unlike the local kill(id:), a remote
//    kill only ever needs the ssh binary, never the local
//    calyx-session binary at all
//

import XCTest
@testable import Calyx

private struct FixedBinaryResolver: SessionBinaryResolverProtocol {
    let path: String?
    func resolve() -> String? { path }
}

private struct FakeSSHResolver: SSHBinaryResolverProtocol {
    let path: String
    func resolve() -> String { path }
}

/// Records every run(...) call; an actor (mirrors this suite's other
/// LSPCommandRunner-recording fakes, e.g. SessionRemoteInstallTests'
/// RecordingCommandRunner) so awaited calls can safely append to shared
/// state.
private actor RecordingCommandRunner: LSPCommandRunner {
    private(set) var recordedCalls: [(executable: String, arguments: [String])] = []

    func run(
        executable: String,
        arguments: [String],
        workingDirectory: URL?,
        environment: [String: String]?
    ) async throws -> CommandResult {
        recordedCalls.append((executable, arguments))
        return CommandResult(exitCode: 0, stdout: "", stderr: "")
    }

    func locate(_ executable: String) async -> URL? { nil }
}

final class SessionDaemonClientKillRemoteTests: XCTestCase {

    func test_killRemote_shellsSSHWithHostAndRemoteKillCommand_noPTYFlag() async {
        let runner = RecordingCommandRunner()
        let client = SessionDaemonClient(
            resolver: FixedBinaryResolver(path: "/opt/calyx-fixture/bin/calyx-session"),
            commandRunner: runner,
            sshResolver: FakeSSHResolver(path: "/opt/calyx-fixture/bin/ssh")
        )

        await client.killRemote(host: "devbox.example.com", sessionID: "01ARZ3NDEKTSV4RRFFQ69G5FAV")

        let recorded = await runner.recordedCalls
        XCTAssertEqual(recorded.count, 1, "killRemote must invoke the command runner exactly once")
        XCTAssertEqual(recorded[0].executable, "/opt/calyx-fixture/bin/ssh",
                       "killRemote must invoke the resolved ssh binary as the executable, never the local " +
                       "calyx-session binary")
        XCTAssertEqual(recorded[0].arguments, [
            "--", "devbox.example.com",
            "$HOME/.calyx/bin/calyx-session kill '01ARZ3NDEKTSV4RRFFQ69G5FAV'",
        ], "killRemote's argv must be -- then the host then the single remote-command-line word, with no " +
           "-t flag (a one-shot kill needs no PTY, unlike an interactive attach)")
    }

    func test_killRemote_sessionIDContainingSingleQuote_isEscaped() async {
        let runner = RecordingCommandRunner()
        let client = SessionDaemonClient(
            resolver: FixedBinaryResolver(path: "/opt/calyx-fixture/bin/calyx-session"),
            commandRunner: runner,
            sshResolver: FakeSSHResolver(path: "/opt/calyx-fixture/bin/ssh")
        )

        await client.killRemote(host: "devbox.example.com", sessionID: "01ARZ3'; touch pwned; '")

        let recorded = await runner.recordedCalls
        XCTAssertEqual(recorded.first?.arguments.last,
                       "$HOME/.calyx/bin/calyx-session kill '01ARZ3'\\''; touch pwned; '\\'''",
                       "A sessionID containing a single quote must be escaped via the same unconditional " +
                       "single-quote-wrapping convention SessionCommandSynthesizer.shSafeToken already uses " +
                       "for every other operation this codebase shells out to the remote host")
    }

    func test_killRemote_noLocalBinaryResolvable_stillInvokesSSH() async {
        let runner = RecordingCommandRunner()
        let client = SessionDaemonClient(
            resolver: FixedBinaryResolver(path: nil),
            commandRunner: runner,
            sshResolver: FakeSSHResolver(path: "/opt/calyx-fixture/bin/ssh")
        )

        await client.killRemote(host: "devbox.example.com", sessionID: "01ARZ3NDEKTSV4RRFFQ69G5FAV")

        let recorded = await runner.recordedCalls
        XCTAssertEqual(recorded.count, 1,
                       "Unlike the local kill(id:), which returns early without a resolvable local binary, " +
                       "killRemote only ever needs the ssh binary -- the local calyx-session binary's " +
                       "presence or absence is irrelevant to killing a session on the remote host")
    }
}
