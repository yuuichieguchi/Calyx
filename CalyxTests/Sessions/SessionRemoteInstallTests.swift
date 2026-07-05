//
//  SessionRemoteInstallTests.swift
//  CalyxTests
//
//  TDD Red phase, P5 (remote sessions), RED5 cycle (remote UI wiring),
//  contract R3: remote-install invocation plumbing on the Swift side --
//  turning (host, bundled resource paths) into the calyx-session CLI's
//  own `remote-install` argv (calyx-session/crates/cli/src/commands/remote_install.rs,
//  already green: positional host, --payload-x86-64/--payload-aarch64/
//  --host-binary/--terminfo), then actually running it through this
//  codebase's established `LSPCommandRunner` seam.
//
//  BUNDLE LAYOUT (verified in project.yml's "Bundle Remote Session
//  Binaries"/"Bundle Session Daemon"/"Copy Ghostty Resources"
//  postBuildScripts, and Resources/ on disk):
//    - Resources/session-remote/<x86_64|aarch64>/calyx-session -- the
//      cross-compiled Linux musl payloads (cycle 4)
//    - Resources/bin/calyx-session -- the LOCAL calyx-session binary,
//      already resolved by SessionBinaryResolver. Serves DOUBLE duty
//      here: it is both the executable this plumbing invokes AND the
//      --host-binary payload (a Darwin arm64 remote is bit-for-bit the
//      same target this Mac itself builds -- remote_install.rs's
//      PayloadKind::HostBinary mapping)
//    - Resources/terminfo/78/xterm-ghostty -- the bundled ghostty
//      terminfo entry ("78" is 'x' hashed by ncurses' first-letter
//      convention, matching the CLI's own REMOTE_TERMINFO_DIR
//      "$HOME/.terminfo/x" layout)
//
//  Held-out compile-RED file per this codebase's established convention:
//  RemoteInstallArgvBuilder, SessionRemotePayloadResolverProtocol,
//  SessionDaemonClientProtocol.installRemote(host:), and
//  SessionBrowserModel.installRemote(host:) do not exist anywhere in
//  the codebase yet. Expected to FAIL TO COMPILE until the Green phase
//  adds them.
//
//  DESIGN NOTE on SessionDaemonClientProtocol.installRemote(host:): this
//  is a NEW protocol requirement. Every existing SessionDaemonClientProtocol
//  fake across the suite (SessionReconnectCoordinatorTests,
//  SessionDaemonClientBoundedCancellationTests, etc.) must keep
//  compiling untouched, so the Green phase must add a default protocol
//  extension (returning nil) alongside the requirement -- mirroring
//  LSPCommandRunner's own default installRun-forwards-to-run precedent
//  (LSPInstaller.swift) -- rather than a bare protocol requirement that
//  would force every existing fake in the suite to grow a new override.
//
//  Coverage:
//  - RemoteInstallArgvBuilder.buildArgv(...) is a pure function: host
//    positional after the remote-install subcommand name; each of
//    --payload-x86-64/--payload-aarch64/--host-binary/--terminfo is
//    included only when its path is non-nil, omitted entirely
//    otherwise (never duplicating the CLI's own MissingPayload
//    fail-fast validation locally)
//  - SessionDaemonClient.installRemote(host:) (reusing its existing
//    resolver/commandRunner fields, plus a new payloadResolver
//    dependency) runs the LOCAL bundled binary as the executable, with
//    --host-binary pointing at that SAME path
//  - No local binary resolvable -> installRemote returns nil without
//    ever invoking the command runner (no local shell layer to run
//    remote-install through at all)
//  - Missing bundled cross-compiled payloads/terminfo -> their flags
//    are simply omitted from the built argv
//  - SessionBrowserModel.installRemote(host:) forwards to its injected
//    daemonClient's own installRemote(host:) and returns its result --
//    mirrors kill(_:)'s existing injectable-client pattern
//    (SessionBrowserModelTests, P4)
//

import XCTest
@testable import Calyx

private struct FixedBinaryResolver: SessionBinaryResolverProtocol {
    let path: String?
    func resolve() -> String? { path }
}

private struct FakePayloadResolver: SessionRemotePayloadResolverProtocol {
    var x86_64Path: String?
    var aarch64Path: String?
    var terminfoPathValue: String?

    func payloadPath(forArch arch: String) -> String? {
        switch arch {
        case "x86_64": return x86_64Path
        case "aarch64": return aarch64Path
        default: return nil
        }
    }

    func terminfoPath() -> String? { terminfoPathValue }
}

/// Records every run(...) call; an actor (mirrors LSPInstaller's own
/// MockCommandRunner / SessionDaemonClientRuntimeDirArgsTests'
/// RecordingCommandRunner) so awaited calls can safely append to
/// shared state.
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

/// Minimal SessionDaemonClientProtocol fake recording installRemote(host:)
/// calls -- a process-boundary stand-in for the browser-model-level
/// forwarding test, no real daemon or subprocess involved. A local
/// duplicate of SessionBrowserModelTests' FakeBrowserDaemonClient shape
/// (this codebase's established per-file fixture-duplication
/// convention), narrowed to only what this file's tests need.
private final class FakeInstallRemoteDaemonClient: SessionDaemonClientProtocol, @unchecked Sendable {
    var installRemoteResult: CommandResult?
    private(set) var installRemoteHosts: [String] = []

    func sessionState(id: String) async -> SessionQueryResult { .unreachable }
    func kill(id: String) async {}
    func listAll() async -> [SessionInfo] { [] }
    func setMeta(id: String, key: String, value: String) async {}

    func installRemote(host: String) async -> CommandResult? {
        installRemoteHosts.append(host)
        return installRemoteResult
    }
}

// MARK: - R3a: pure argv builder

final class RemoteInstallArgvBuilderTests: XCTestCase {

    func test_buildArgv_startsWithRemoteInstallSubcommandAndHostPositional() {
        let argv = RemoteInstallArgvBuilder.buildArgv(
            host: "devbox", payloadX86_64Path: nil, payloadAarch64Path: nil, hostBinaryPath: nil, terminfoPath: nil
        )

        XCTAssertEqual(argv, ["remote-install", "devbox"])
    }

    func test_buildArgv_includesEveryFlagWhenEveryPathIsGiven() {
        let argv = RemoteInstallArgvBuilder.buildArgv(
            host: "devbox",
            payloadX86_64Path: "/bundle/session-remote/x86_64/calyx-session",
            payloadAarch64Path: "/bundle/session-remote/aarch64/calyx-session",
            hostBinaryPath: "/bundle/bin/calyx-session",
            terminfoPath: "/bundle/terminfo/78/xterm-ghostty"
        )

        XCTAssertEqual(argv, [
            "remote-install", "devbox",
            "--payload-x86-64", "/bundle/session-remote/x86_64/calyx-session",
            "--payload-aarch64", "/bundle/session-remote/aarch64/calyx-session",
            "--host-binary", "/bundle/bin/calyx-session",
            "--terminfo", "/bundle/terminfo/78/xterm-ghostty",
        ])
    }

    func test_buildArgv_omitsPayloadX86_64FlagWhenPathIsNil() {
        let argv = RemoteInstallArgvBuilder.buildArgv(
            host: "devbox", payloadX86_64Path: nil, payloadAarch64Path: "/p/aarch64", hostBinaryPath: nil, terminfoPath: nil
        )

        XCTAssertEqual(argv, ["remote-install", "devbox", "--payload-aarch64", "/p/aarch64"])
    }

    func test_buildArgv_omitsEveryFlagWhenNoBundledPayloadsAvailable() {
        let argv = RemoteInstallArgvBuilder.buildArgv(
            host: "devbox", payloadX86_64Path: nil, payloadAarch64Path: nil, hostBinaryPath: nil, terminfoPath: nil
        )

        XCTAssertEqual(argv, ["remote-install", "devbox"],
                       "Missing bundled payloads must omit their flags entirely -- the CLI itself " +
                       "fail-fasts with its own exact-flag-name MissingPayload error (remote_install.rs), " +
                       "which this builder must never duplicate locally")
    }
}

// MARK: - R3b: SessionDaemonClient.installRemote(host:) wiring

final class SessionDaemonClientInstallRemoteTests: XCTestCase {

    func test_installRemote_runsLocalBinaryWithBuiltArgv() async {
        let runner = RecordingCommandRunner()
        let client = SessionDaemonClient(
            resolver: FixedBinaryResolver(path: "/opt/calyx-fixture/bin/calyx-session"),
            commandRunner: runner,
            payloadResolver: FakePayloadResolver(
                x86_64Path: "/bundle/session-remote/x86_64/calyx-session",
                aarch64Path: "/bundle/session-remote/aarch64/calyx-session",
                terminfoPathValue: "/bundle/terminfo/78/xterm-ghostty"
            )
        )

        _ = await client.installRemote(host: "devbox.example.com")

        let recorded = await runner.recordedCalls
        XCTAssertEqual(recorded.count, 1, "installRemote(host:) must run the command exactly once")
        XCTAssertEqual(recorded[0].executable, "/opt/calyx-fixture/bin/calyx-session",
                       "installRemote must invoke the LOCAL bundled calyx-session binary as the executable")
        XCTAssertEqual(recorded[0].arguments, [
            "remote-install", "devbox.example.com",
            "--payload-x86-64", "/bundle/session-remote/x86_64/calyx-session",
            "--payload-aarch64", "/bundle/session-remote/aarch64/calyx-session",
            "--host-binary", "/opt/calyx-fixture/bin/calyx-session",
            "--terminfo", "/bundle/terminfo/78/xterm-ghostty",
        ], "The --host-binary flag must point at the SAME local binary path used as the executable -- a " +
           "Darwin arm64 remote reuses this Mac's own build bit-for-bit, per remote_install.rs's " +
           "PayloadKind::HostBinary mapping")
    }

    func test_installRemote_noLocalBinaryResolvable_returnsNilWithoutRunningAnything() async {
        let runner = RecordingCommandRunner()
        let client = SessionDaemonClient(
            resolver: FixedBinaryResolver(path: nil),
            commandRunner: runner,
            payloadResolver: FakePayloadResolver()
        )

        let result = await client.installRemote(host: "devbox.example.com")

        XCTAssertNil(result, "With no local calyx-session binary resolvable, installRemote must return " +
                     "nil -- there is no executable to run remote-install with at all")
        let recorded = await runner.recordedCalls
        XCTAssertTrue(recorded.isEmpty, "The command runner must never be invoked when no local binary " +
                     "is resolvable")
    }

    func test_installRemote_missingBundledPayloads_omitsTheirFlags() async {
        let runner = RecordingCommandRunner()
        let client = SessionDaemonClient(
            resolver: FixedBinaryResolver(path: "/opt/calyx-fixture/bin/calyx-session"),
            commandRunner: runner,
            payloadResolver: FakePayloadResolver() // every payload/terminfo path nil
        )

        _ = await client.installRemote(host: "devbox.example.com")

        let recorded = await runner.recordedCalls
        XCTAssertEqual(recorded.first?.arguments, [
            "remote-install", "devbox.example.com",
            "--host-binary", "/opt/calyx-fixture/bin/calyx-session",
        ], "With no cross-compiled Linux payloads or terminfo entry bundled, only --host-binary (this " +
           "Mac's own binary, always available since it's what's running) should be passed")
    }
}

// MARK: - R3c: SessionBrowserModel.installRemote(host:) forwarding

final class SessionBrowserModelInstallRemoteTests: XCTestCase {

    @MainActor
    func test_installRemote_forwardsToInjectedDaemonClient_andReturnsItsResult() async {
        let daemonClient = FakeInstallRemoteDaemonClient()
        daemonClient.installRemoteResult = CommandResult(exitCode: 0, stdout: "installed", stderr: "")
        let model = SessionBrowserModel(daemonClient: daemonClient, surfaceMap: SessionSurfaceMap())

        let result = await model.installRemote(host: "devbox.example.com")

        XCTAssertEqual(daemonClient.installRemoteHosts, ["devbox.example.com"],
                       "installRemote(host:) must forward to the injected daemonClient's own " +
                       "installRemote(host:), mirroring kill(_:)'s existing injectable-client pattern")
        XCTAssertEqual(result, CommandResult(exitCode: 0, stdout: "installed", stderr: ""),
                       "installRemote(host:) must return exactly what the injected daemonClient produced")
    }
}
