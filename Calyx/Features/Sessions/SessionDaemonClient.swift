// SessionDaemonClient.swift
// Calyx
//
// Queries the calyx-session daemon's state for a given session ID.
// Needed because macOS never delivers a real exit code through
// `GHOSTTY_ACTION_SHOW_CHILD_EXITED` (`exit_code` is always 0 there —
// verified by spike; only `runtime_ms` is trustworthy), so "did the
// attach process lose its connection (reconnect) vs. did the session
// itself actually end (close the pane)" can only be answered by asking
// the daemon directly.

import Foundation

/// Result of asking the daemon about one session's current state.
enum SessionQueryResult: Sendable, Equatable {
    /// The session is still running; the attach process merely
    /// disconnected (e.g. the ghostty surface's process bridge was
    /// torn down without the daemon's child exiting) — reconnect.
    case running
    /// The session's child process actually exited with `code`.
    case exited(code: Int32)
    /// The daemon could not be reached at all (not running, socket
    /// gone, timed out). Treated as "assume reconnectable": `attach
    /// --create`'s idempotency means a retry either re-attaches to a
    /// session that's still alive on a since-recovered daemon, or
    /// transparently recreates it.
    case unreachable
}

/// Abstraction over the daemon query/kill operations so
/// `SessionReconnectCoordinator` can be tested with a fake, without
/// spawning a real `calyx-session` process.
protocol SessionDaemonClientProtocol: Sendable {
    func sessionState(id: String) async -> SessionQueryResult
    func kill(id: String) async
    /// The full ledger view (`ls --all --json`) -- every session the
    /// daemon has ever recorded, running or exited, with `meta`. Added
    /// for P4's `SessionBrowserModel`.
    func listAll() async -> [SessionInfo]
    /// Persists `key=value` into session `id`'s daemon-side meta map
    /// (`calyx-session meta set <id> <key>=<value>`). Added for P4's
    /// `AgentSessionMetaBridge`.
    func setMeta(id: String, key: String, value: String) async
    /// Deploys the daemon binary to `host` via the local bundled
    /// `calyx-session`'s own `remote-install` subcommand. Returns `nil`
    /// when the underlying run couldn't be attempted at all (e.g. no
    /// local binary resolvable). Added for P5's remote-install wiring.
    func installRemote(host: String) async -> CommandResult?
    /// Kills a REMOTE session by shelling `ssh -- <host>
    /// "$HOME/.calyx/bin/calyx-session kill '<sessionID>'"` -- the
    /// remote-host counterpart to `kill(id:)`, which only ever reaches
    /// the LOCAL daemon. Added for P5's close=kill routing fix
    /// (`CalyxWindowController.killSessionIfPersistent`).
    func killRemote(host: String, sessionID: String) async
    /// Toggles the daemon-wide on-disk history-persistence default
    /// (`calyx-session history on`/`off`, i.e.
    /// `ControlMsg::SetHistoryEnabled` -- see that message's own doc
    /// comment: a live, in-memory override, never persisted
    /// daemon-side). Added for P6's `HistoryPersistenceToggleCoordinator`
    /// and `AppDelegate.reassertHistoryPersistenceIfNeeded()`.
    func setHistoryEnabled(_ enabled: Bool) async
}

/// R14-B (r14-fix-spec.md): narrow `#if DEBUG` override hook for the
/// two bounded-timeout constants below, mirroring
/// `NotificationManager.shared`'s R6-F override and
/// `SessionSettings._testStore`'s suite-swap seam. `nil` (the default)
/// means "use the production value"; a test sets one or both to a
/// tiny, distinguishable value so it can assert the bound's plumbing
/// without waiting out the real 5s/15s. `nonisolated(unsafe)` is sound
/// because every production reader only consults it via the matching
/// computed property below, and every test that sets it resets it back
/// to `nil` in its own `tearDown()`.
#if DEBUG
enum SessionDaemonClientBoundTimeoutOverrides {
    nonisolated(unsafe) static var daemonQueryBoundTimeoutSeconds: UInt64?
    nonisolated(unsafe) static var sessionStateBoundTimeoutSeconds: UInt64?
}
#endif

/// R14-A (r14-fix-spec.md): thread-safe bridge between
/// `withTaskCancellationHandler`'s `onCancel` closure and
/// `SessionDaemonClientProtocol.bounded(...)`'s own `operationTask`/
/// `timeoutTask`/`continuation`, mirroring `SystemCommandRunner`'s
/// `CancellationBridge`. Declared at file scope, generic over `T`,
/// because Swift does not allow a nested type inside a generic
/// function. `resume(with:)` is exactly-once, shared by all three
/// potential resumers (the operation arm, the timeout arm, and
/// `cancel(onTimeout:)`). `register(...)`'s return value tells the
/// caller whether the bridge was already cancelled by the time it ran,
/// mirroring that type's own already-cancelled-before-register
/// handling.
private final class SessionDaemonBoundedRaceBridge<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false
    private var isCancelled = false
    private var operationTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var continuation: CheckedContinuation<T, Never>?

    func register(
        continuation: CheckedContinuation<T, Never>,
        operationTask: Task<Void, Never>,
        timeoutTask: Task<Void, Never>
    ) -> Bool {
        lock.lock(); defer { lock.unlock() }
        self.continuation = continuation
        self.operationTask = operationTask
        self.timeoutTask = timeoutTask
        return isCancelled
    }

    @discardableResult
    func resume(with value: T) -> Bool {
        lock.lock()
        guard !resumed, let continuation else { lock.unlock(); return false }
        resumed = true
        self.continuation = nil
        lock.unlock()
        continuation.resume(returning: value)
        return true
    }

    func cancel(onTimeout: @Sendable () -> T) {
        lock.lock()
        isCancelled = true
        let opTask = operationTask
        let toTask = timeoutTask
        // R16-3 (r16-fix-spec.md): `register(...)` hasn't run yet when
        // `continuation` is still nil, so its own already-cancelled
        // branch (see `bounded(...)` below) is the one that will call
        // `onTimeout()`, not this method -- calling it here too would
        // invoke it twice (only the second call's result would actually
        // resume anything, since `resume(with:)` alone is exactly-once,
        // but `onTimeout()` itself is not idempotent to call). This
        // lock is the sole arbiter of which side runs first, making the
        // single call exactly-once by construction rather than documented.
        let hasRegistered = continuation != nil
        lock.unlock()
        opTask?.cancel()
        toTask?.cancel()
        guard hasRegistered else { return }
        resume(with: onTimeout())
    }
}

extension SessionDaemonClientProtocol {
    /// Default empty/no-op implementations, so fakes built before P4
    /// introduced `listAll()`/`setMeta(id:key:value:)` (e.g.
    /// `SessionReconnectCoordinatorTests`'s `FakeSessionDaemonClient`)
    /// keep conforming without modification. A fake that actually
    /// exercises P4 behavior (`SessionBrowserModelTests`,
    /// `AgentSessionMetaBridgeTests`) overrides these itself.
    func listAll() async -> [SessionInfo] { [] }
    func setMeta(id: String, key: String, value: String) async {}
    /// Default `nil`-returning implementation (mirrors `LSPCommandRunner`'s
    /// own default `installRun`-forwards-to-`run` precedent), so every
    /// existing `SessionDaemonClientProtocol` fake predating P5's
    /// `installRemote(host:)` keeps conforming without modification. A
    /// fake that actually exercises this behavior overrides it itself.
    func installRemote(host: String) async -> CommandResult? { nil }

    /// Default no-op implementation, mirroring `installRemote(host:)`'s
    /// own identical precedent right above, so every existing
    /// `SessionDaemonClientProtocol` fake predating P5's
    /// `killRemote(host:sessionID:)` keeps conforming without
    /// modification. A fake that actually exercises this behavior
    /// overrides it itself.
    func killRemote(host: String, sessionID: String) async {}

    /// Default no-op implementation, mirroring `installRemote(host:)`'s
    /// and `killRemote(host:sessionID:)`'s own identical precedent right
    /// above, so every existing `SessionDaemonClientProtocol` fake
    /// predating P6's `setHistoryEnabled(_:)` keeps conforming without
    /// modification. A fake that actually exercises this behavior
    /// overrides it itself.
    func setHistoryEnabled(_ enabled: Bool) async {}

    /// R10-C item 2 (r10-fix-spec.md): the single bound shared by every
    /// query-style caller that must not await `listAll()` unbounded,
    /// originally `AppDelegate`'s agent-resume path alone
    /// (`listAllSessionsBounded`, R8-D item 1), now also
    /// `SessionBrowserModel.refresh()`, which used to await `listAll()`
    /// completely unbounded and freeze the whole session browser behind
    /// a hung `calyx-session` daemon.
    ///
    /// R14-B (r14-fix-spec.md): renamed from `listAllBoundTimeoutSeconds`
    /// -- `sessionStateBounded(id:)` now has its own dedicated, longer
    /// `sessionStateBoundTimeoutSeconds` below, so this name describes
    /// only the low-consequence query callers that still share the
    /// original 5s value. Consults the `#if DEBUG`-only
    /// `SessionDaemonClientBoundTimeoutOverrides` seam first, so tests
    /// can assert the bound's plumbing with tiny, distinguishable
    /// values instead of waiting out the real 5s.
    static var daemonQueryBoundTimeoutSeconds: UInt64 {
        #if DEBUG
        if let override = SessionDaemonClientBoundTimeoutOverrides.daemonQueryBoundTimeoutSeconds {
            return override
        }
        #endif
        return 5
    }

    /// R14-B (r14-fix-spec.md): `sessionStateBounded(id:)` feeds
    /// `SessionReconnectCoordinator.childExited`'s reconnect decision --
    /// a 5-attempt-cap retry/backoff sequence (0/1/2/4/8s) -- so its
    /// bound must be generous enough to separate "daemon truly hung"
    /// from "daemon merely busy". The 5s `daemonQueryBoundTimeoutSeconds`
    /// value was tuned for the low-consequence session-browser poll
    /// `listAllBounded()` serves, not for this. Same `#if DEBUG`
    /// override seam as `daemonQueryBoundTimeoutSeconds` above.
    static var sessionStateBoundTimeoutSeconds: UInt64 {
        #if DEBUG
        if let override = SessionDaemonClientBoundTimeoutOverrides.sessionStateBoundTimeoutSeconds {
            return override
        }
        #endif
        return 15
    }

    /// R12-B (r12-fix-spec.md): generalized race shape shared by every
    /// bounded daemon call. Races `operation()` against `timeoutSeconds`
    /// (default `daemonQueryBoundTimeoutSeconds`; R14-B lets
    /// `sessionStateBounded(id:)` pass its own dedicated, longer bound
    /// instead), resolving to `onTimeout()` if `operation()` hasn't
    /// completed by then, so a hung daemon never blocks a caller
    /// indefinitely. Originally `listAllBounded()`'s own implementation
    /// (lifted from `AppDelegate`'s former private
    /// `listAllSessionsBounded`, R8-D item 1); generalized here so
    /// `sessionStateBounded(id:)` (R12-B) shares the identical race
    /// shape instead of duplicating it.
    ///
    /// Deliberately NOT a `TaskGroup` race: `withTaskGroup` always
    /// awaits every child task to completion before returning, even
    /// after `cancelAll()` (cancellation is cooperative; an
    /// unresponsive daemon's call, awaiting a `CheckedContinuation`
    /// nobody ever resumes, never observes it), which would make the
    /// whole race hang exactly as long as the call it exists to bound.
    /// Instead, two independent, unstructured `Task`s race to resume
    /// `continuation` first, guarded by `SessionDaemonBoundedRaceBridge`;
    /// `@MainActor` isolation means both closures (each inherits this
    /// method's actor context, per `Task.init`'s `@_inheritActorContext`)
    /// can never execute concurrently with each other, mirroring
    /// `AppDelegate.applicationWillTerminate`'s identical `killsDrained`
    /// pattern.
    ///
    /// R10-C item 1 (r10-fix-spec.md): the winner cancels the loser (a
    /// beaten operation task is cancelled, not merely abandoned; the
    /// subprocess layer may ignore it, but the signal is sent; a beaten
    /// timeout task is cancelled too), and the timeout arm re-checks
    /// `Task.isCancelled` before resuming, closing the
    /// `try?`-swallows-`CancellationError` hole the old, unguarded
    /// `Task.sleep` had (a cancelled sleep could still fall through to
    /// resume the continuation with a stale value after the operation
    /// task had already won).
    ///
    /// R14-A (r14-fix-spec.md): the continuation await is now wrapped in
    /// `withTaskCancellationHandler`, whose handler cancels BOTH the
    /// operation and timeout arms and resumes promptly with `onTimeout()`
    /// -- before this fix, cancelling the CALLER's own Task did nothing:
    /// neither unstructured arm auto-cancels just because the caller's
    /// Task was cancelled, so the race rode out the full bound
    /// regardless. `SessionDaemonBoundedRaceBridge` (above) is the
    /// thread-safe hand-off between `onCancel` (which may run
    /// concurrently with, and on a different thread than, the two
    /// MainActor-isolated race arms) and those arms' own exactly-once
    /// resume discipline -- mirroring
    /// `SystemCommandRunner`'s own `CancellationBridge`.
    @MainActor
    private func bounded<T: Sendable>(
        operation: @escaping @Sendable () async -> T,
        onTimeout: @escaping @Sendable () -> T,
        timeoutSeconds: UInt64 = Self.daemonQueryBoundTimeoutSeconds
    ) async -> T {
        let bridge = SessionDaemonBoundedRaceBridge<T>()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
                var operationTask: Task<Void, Never>?
                var timeoutTask: Task<Void, Never>?
                operationTask = Task {
                    let result = await operation()
                    guard bridge.resume(with: result) else { return }
                    timeoutTask?.cancel()
                }
                timeoutTask = Task {
                    try? await Task.sleep(nanoseconds: timeoutSeconds * 1_000_000_000)
                    guard !Task.isCancelled else { return }
                    guard bridge.resume(with: onTimeout()) else { return }
                    operationTask?.cancel()
                }
                guard let opTask = operationTask, let toTask = timeoutTask else { return }
                if bridge.register(continuation: continuation, operationTask: opTask, timeoutTask: toTask) {
                    // Already cancelled by the time both arms were
                    // created and registered; cancel them and resume
                    // right away instead of waiting for either to
                    // notice on its own. R16-3 (r16-fix-spec.md): this
                    // branch is the sole `onTimeout()` caller for this
                    // race -- `bridge.cancel(onTimeout:)` skips its own
                    // call when it ran before `register(...)` did (see
                    // that method's own comment), so `onTimeout()` fires
                    // exactly once, not twice.
                    opTask.cancel()
                    toTask.cancel()
                    bridge.resume(with: onTimeout())
                }
            }
        } onCancel: {
            bridge.cancel(onTimeout: onTimeout)
        }
    }

    /// Races `listAll()` against `daemonQueryBoundTimeoutSeconds`,
    /// degrading to `[]` if the daemon round-trip hasn't completed by
    /// then, so a hung daemon never blocks a caller indefinitely.
    /// Shared by `SessionBrowserModel.refresh()` and
    /// `AppDelegate.fetchSessionsForAgentResume()`.
    @MainActor
    func listAllBounded() async -> [SessionInfo] {
        await bounded(operation: { await listAll() }, onTimeout: { [] })
    }

    /// R12-B (r12-fix-spec.md): `sessionState(id:)` used to await the
    /// underlying `commandRunner.run(...)` completely unbounded, so a
    /// hung `calyx-session` daemon could stall
    /// `SessionReconnectCoordinator.childExited`'s reconnect decision
    /// indefinitely -- exactly the failure mode `listAllBounded()`
    /// already fixed for the ledger listing alone. Read-only, so racing
    /// it against the timeout and cancelling the loser (mirroring
    /// `listAllBounded()`'s shape exactly) is safe. Degrades to
    /// `.unreachable` on timeout, which `SessionReconnectCoordinator`
    /// already treats as a retry/give-up input.
    ///
    /// R14-B (r14-fix-spec.md): threads its own dedicated, longer
    /// `sessionStateBoundTimeoutSeconds` into `bounded(timeout:)`
    /// instead of the general `daemonQueryBoundTimeoutSeconds` every
    /// other bounded call shares (see that constant's own doc comment
    /// for why).
    @MainActor
    func sessionStateBounded(id: String) async -> SessionQueryResult {
        await bounded(
            operation: { await sessionState(id: id) },
            onTimeout: { .unreachable },
            timeoutSeconds: Self.sessionStateBoundTimeoutSeconds
        )
    }
}

/// Production client: shells out to the bundled `calyx-session` binary
/// via `LSPCommandRunner` (the same `Process`-driving abstraction
/// `LSPInstaller` uses), rather than a bespoke `Process` invocation —
/// so `calyx-session` subprocess calls inherit `SystemCommandRunner`'s
/// already-tested SIGTERM-then-SIGKILL watchdog escalation instead of
/// reimplementing (and re-risking getting wrong) a second one here.
final class SessionDaemonClient: SessionDaemonClientProtocol, Sendable {

    /// Default instance. Production callers (`SessionReconnectCoordinator`'s
    /// wiring, `SessionSpawnPlanner`'s binary-path lookup) use this;
    /// tests build their own `SessionDaemonClient(resolver:)` or a fake
    /// `SessionDaemonClientProtocol` instead.
    static let shared = SessionDaemonClient(resolver: SessionBinaryResolver())

    private let binaryPath: String?
    private let commandRunner: LSPCommandRunner
    /// The `["--runtime-dir", "<root>/.calyx/run"]` pair every
    /// `commandRunner.run(...)` call below prepends before its own
    /// subcommand arguments, so `ls`/`kill`/`meta` ask the same daemon
    /// socket directory `SessionCommandSynthesizer`'s synthesized attach
    /// command spawns the daemon into for the same `rootResolver` (see
    /// `SessionRootResolver.swift`'s header comment). The Rust CLI's
    /// global `--runtime-dir` flag (`calyx-session/crates/cli/src/cli.rs:15-16`,
    /// `global = true`) is what each of these three subcommands actually
    /// consults to find the daemon's socket (`main.rs`'s dispatch passes
    /// only `runtime_dir` through to each; `commands/mod.rs`'s
    /// `resolve_runtime_dir`/`socket_path`). `--state-dir` is
    /// deliberately never part of this: `state_dir` is resolved once,
    /// daemon-internally, inside the already-running daemon process
    /// itself (`commands/mod.rs:74`'s `default_home_subdir`), so none of
    /// `ls`/`kill`/`meta` ever need it as a client-side argument -- with
    /// no override (the default, real production use), this resolves to
    /// `<real $HOME>/.calyx/run`, identical to the Rust CLI's own
    /// default, so this is behaviorally invisible for normal users.
    private let runtimeDirArgument: [String]

    /// Resolves the bundled resources `installRemote(host:)` needs
    /// (cross-compiled Linux musl payloads, bundled terminfo entry).
    /// See `SessionRemotePayloadResolver`'s own doc comment for the
    /// bundle layout.
    private let payloadResolver: SessionRemotePayloadResolverProtocol

    /// Resolves the system `ssh` binary `killRemote(host:sessionID:)`
    /// execs directly, mirroring `SessionCommandSynthesizer
    /// .remoteAttachCommand`'s own identical `SSHBinaryResolverProtocol`
    /// dependency.
    private let sshResolver: SSHBinaryResolverProtocol

    /// Exposes the resolved binary path for tests
    /// (`SessionBinaryResolverTests`) that need to confirm this client
    /// and `SessionSpawnPlanner`, given the same injected
    /// `SessionBinaryResolverProtocol` instance, agree on the same
    /// path.
    var resolvedBinaryPath: String? { binaryPath }

    /// Builds a client whose binary path comes from `resolver`, shared
    /// with whatever `SessionSpawnPlanner.plan(for:resolver:)` call site
    /// injects the same resolver instance into — see
    /// `SessionBinaryResolver.swift`'s header comment. `commandRunner`
    /// defaults to the real `SystemCommandRunner`; tests that don't
    /// need this seam (e.g. `SessionBinaryResolverTests`, which only
    /// asserts on `resolvedBinaryPath`/`.unreachable` without ever
    /// actually spawning a process) can ignore it. `rootResolver`
    /// defaults to `SessionRootResolver()` (real production use); see
    /// `runtimeDirArgument`'s doc comment for why every query prepends
    /// its resolved value as `--runtime-dir`.
    init(
        resolver: SessionBinaryResolverProtocol,
        commandRunner: LSPCommandRunner = SystemCommandRunner(),
        rootResolver: SessionRootResolverProtocol = SessionRootResolver(),
        payloadResolver: SessionRemotePayloadResolverProtocol = SessionRemotePayloadResolver(),
        sshResolver: SSHBinaryResolverProtocol = SSHBinaryResolver()
    ) {
        self.binaryPath = resolver.resolve()
        self.commandRunner = commandRunner
        self.runtimeDirArgument = ["--runtime-dir", rootResolver.resolve() + "/.calyx/run"]
        self.payloadResolver = payloadResolver
        self.sshResolver = sshResolver
    }

    func sessionState(id: String) async -> SessionQueryResult {
        guard let binaryPath else { return .unreachable }
        guard let result = try? await commandRunner.run(
            executable: binaryPath, arguments: runtimeDirArgument + ["ls", "--all", "--json"], workingDirectory: nil, environment: nil
        ), result.exitCode == 0 else {
            return .unreachable
        }
        guard let sessions = try? JSONDecoder().decode([SessionInfo].self, from: Data(result.stdout.utf8)) else {
            return .unreachable
        }
        guard let match = sessions.first(where: { $0.id == id }) else {
            // `--all` (ControlMsg::ListAll) is the full ledger view —
            // running and exited sessions both — so an id absent even
            // from this is not merely "exited and dropped from the
            // live registry" (that's what plain `ls` without `--all`
            // would show); it means the id never existed or has been
            // pruned from the ledger entirely. Approximated as exited
            // with an unknown code — `SessionReconnectCoordinator` only
            // branches on the `.exited` case itself, never on the code.
            return .exited(code: 0)
        }
        switch match.state {
        case .running: return .running
        case .exited(let code): return .exited(code: code)
        }
    }

    /// Deliberately NOT bounded (R12-B sweep addendum, r12-fix-spec.md):
    /// with R12-A's SIGTERM-on-cancel now reaching the actual
    /// `calyx-session kill` subprocess, racing it against a timeout and
    /// cancelling the loser could terminate it mid-IPC-write, silently
    /// losing the kill -- worse than a slow-but-eventually-completed
    /// one. Keeps its unbounded complete-or-watchdog semantics;
    /// `SessionKillTracker`'s 2s quit-drain already abandons (without
    /// cancelling) rather than needing a bounded wrapper here.
    ///
    /// R14-C (r14-fix-spec.md): the same R12-A SIGTERM-on-cancel fix
    /// also newly exposed this write to the CALLER's own ambient Task
    /// cancellation -- with no internal race arm shielding it (unlike
    /// `listAllBounded()`/`sessionStateBounded(id:)`), `commandRunner
    /// .run(...)` used to await directly in the caller's own Task, so
    /// cancelling that Task reached straight through to the subprocess
    /// mid-write, silently losing the kill. Now structurally shielded:
    /// the run call is wrapped in an inner unstructured `Task` (the same
    /// pattern `LSPInstaller.runPrerequisiteDeduped` uses) whose
    /// cancellation is never inherited from its creating context, so
    /// ambient cancellation of any future caller's Task can no longer
    /// reach it.
    func kill(id: String) async {
        guard let binaryPath else { return }
        let commandRunner = self.commandRunner
        let runtimeDirArgument = self.runtimeDirArgument
        await Task {
            _ = try? await commandRunner.run(
                executable: binaryPath, arguments: runtimeDirArgument + ["kill", id], workingDirectory: nil, environment: nil
            )
        }.value
    }

    /// Runs the same `ls --all --json` invocation `sessionState(id:)`
    /// above already does and decodes the result as `[SessionInfo]`,
    /// returning `[]` when the binary is unresolvable or the daemon is
    /// unreachable — mirroring that method's own degrade-gracefully
    /// contract.
    func listAll() async -> [SessionInfo] {
        guard let binaryPath else { return [] }
        guard let result = try? await commandRunner.run(
            executable: binaryPath, arguments: runtimeDirArgument + ["ls", "--all", "--json"], workingDirectory: nil, environment: nil
        ), result.exitCode == 0 else {
            return []
        }
        guard let sessions = try? JSONDecoder().decode([SessionInfo].self, from: Data(result.stdout.utf8)) else {
            return []
        }
        return sessions
    }

    /// Shells out to `meta set <id> <key>=<value>` exactly like
    /// `kill(id:)` above, ignoring the result the same way — a failed
    /// meta write is not user-visible, it just means resume won't be
    /// offered next time. Left unbounded (R12-B sweep addendum,
    /// r12-fix-spec.md): a WRITE, so bounding it would need an
    /// abandon-style wrapper that resumes the caller without cancelling
    /// the write arm (cancelling mid-write risks the same silent loss
    /// `kill(id:)`'s doc comment describes); this fire-and-forget
    /// background call already never blocks a user-visible flow, so the
    /// simplest acceptable choice is leaving it as-is.
    ///
    /// R14-C (r14-fix-spec.md): shielded from the caller's own ambient
    /// Task cancellation the same structural way `kill(id:)` now is
    /// (see its doc comment) -- an inner unstructured `Task` around
    /// `commandRunner.run(...)` that ambient cancellation can never
    /// reach.
    func setMeta(id: String, key: String, value: String) async {
        guard let binaryPath else { return }
        let commandRunner = self.commandRunner
        let runtimeDirArgument = self.runtimeDirArgument
        await Task {
            _ = try? await commandRunner.run(
                executable: binaryPath, arguments: runtimeDirArgument + ["meta", "set", id, "\(key)=\(value)"], workingDirectory: nil, environment: nil
            )
        }.value
    }

    /// Deploys the daemon to `host` by running the LOCAL bundled
    /// `calyx-session` binary's own `remote-install` subcommand, with
    /// `--host-binary` pointing at that SAME local path -- a Darwin
    /// arm64 remote reuses this Mac's own build bit-for-bit
    /// (remote_install.rs's `PayloadKind::HostBinary` mapping). Returns
    /// `nil` without ever invoking the command runner when no local
    /// binary is resolvable -- there is no executable to run
    /// remote-install with at all.
    ///
    /// Shielded from the caller's own ambient Task cancellation the
    /// same structural way `kill(id:)`/`setMeta(id:key:value:)` are: an
    /// inner unstructured `Task` around `commandRunner.run(...)` that
    /// ambient cancellation can never reach -- this is a WRITE (deploys
    /// a binary to the remote host), so cancelling mid-run risks the
    /// same silent-loss failure mode those methods' own doc comments
    /// describe.
    func installRemote(host: String) async -> CommandResult? {
        guard let binaryPath else { return nil }
        let commandRunner = self.commandRunner
        let argv = RemoteInstallArgvBuilder.buildArgv(
            host: host,
            payloadX86_64Path: payloadResolver.payloadPath(forArch: "x86_64"),
            payloadAarch64Path: payloadResolver.payloadPath(forArch: "aarch64"),
            hostBinaryPath: binaryPath,
            terminfoPath: payloadResolver.terminfoPath()
        )
        return await Task {
            try? await commandRunner.run(
                executable: binaryPath, arguments: argv, workingDirectory: nil, environment: nil
            )
        }.value
    }

    /// Kills a REMOTE session by shelling `ssh -- <host>
    /// "$HOME/.calyx/bin/calyx-session kill '<sessionID>'"`, with `ssh`
    /// resolved via the same `sshResolver` dependency
    /// `SessionCommandSynthesizer.remoteAttachCommand` uses. Invoked as
    /// argv directly through `commandRunner.run(executable:arguments:)`
    /// (no local shell parses this array at all), so only `sessionID`
    /// needs escaping -- via `SessionCommandSynthesizer`'s own
    /// `shSafeToken`, reused rather than duplicated -- scoped for the
    /// REMOTE shell `sshd` invokes to run the trailing command argument.
    ///
    /// NO `-t`: unlike `remoteAttachCommand` (an interactive ghostty
    /// pane needing a PTY), `kill` is a one-shot, non-interactive
    /// command.
    ///
    /// Never gated on `binaryPath`: unlike the local `kill(id:)`, which
    /// returns early without a resolvable local binary, a remote kill
    /// only ever needs the `ssh` binary -- the local calyx-session
    /// binary's presence or absence is irrelevant to killing a session
    /// on the remote host.
    ///
    /// Shielded from the caller's own ambient Task cancellation the same
    /// structural way `kill(id:)` is (see that method's own doc
    /// comment): an inner unstructured `Task` around `commandRunner
    /// .run(...)` that ambient cancellation can never reach.
    func killRemote(host: String, sessionID: String) async {
        let commandRunner = self.commandRunner
        let sshPath = sshResolver.resolve()
        let remoteCommand = "$HOME/.calyx/bin/calyx-session kill \(SessionCommandSynthesizer.shSafeToken(sessionID))"
        await Task {
            _ = try? await commandRunner.run(
                executable: sshPath, arguments: ["--", host, remoteCommand], workingDirectory: nil, environment: nil
            )
        }.value
    }

    /// Shells `history on`/`history off`, mirroring `kill(id:)`'s and
    /// `setMeta(id:key:value:)`'s own `--runtime-dir`-prefixed argv
    /// shape exactly, with a nil environment (the session root travels
    /// via `--runtime-dir`, not an env override).
    ///
    /// A WRITE, so shielded from the caller's own ambient Task
    /// cancellation the same structural way `kill(id:)` is (see that
    /// method's own R14-C doc comment): an inner unstructured `Task`
    /// around `commandRunner.run(...)` that ambient cancellation can
    /// never reach -- an in-flight toggle write must run to completion
    /// even if the caller's Task is cancelled mid-flight.
    func setHistoryEnabled(_ enabled: Bool) async {
        guard let binaryPath else { return }
        let commandRunner = self.commandRunner
        let runtimeDirArgument = self.runtimeDirArgument
        let subcommand = enabled ? "on" : "off"
        await Task {
            _ = try? await commandRunner.run(
                executable: binaryPath, arguments: runtimeDirArgument + ["history", subcommand], workingDirectory: nil, environment: nil
            )
        }.value
    }
}

/// Mirrors `proto::SessionInfo` (the CLI's `ls --json` / `ls --all
/// --json` output — see `calyx-session/crates/proto/src/control.rs`).
/// Originally a `private` `id`/`state`-only `SessionInfoJSON`
/// (everything else `Decodable` simply ignored); extended for P4 to
/// carry every field `SessionBrowserModel` needs (`name`, `cwd`,
/// `createdAtMs`, `attachedClients`, `pid`, `meta`) and un-privated so
/// `SessionDaemonClient.listAll()` and the session-browser layer can
/// share one decoder.
struct SessionInfo: Decodable, Equatable, Sendable {
    let id: String
    let name: String?
    let cwd: String?
    let state: SessionLifecycleState
    let createdAtMs: UInt64
    let attachedClients: UInt32
    let pid: UInt32
    let meta: [String: String]

    enum CodingKeys: String, CodingKey {
        case id, name, cwd, state
        case createdAtMs = "created_at_ms"
        case attachedClients = "attached_clients"
        case pid, meta
    }
}

/// Mirrors `proto::SessionState`'s serde default (externally tagged)
/// representation: the unit variant `Running` encodes as the bare
/// string `"Running"`; the struct variant `Exited { code }` encodes as
/// `{"Exited": {"code": N}}`. Renamed from the former `private
/// SessionStateJSON` (P4) to `SessionLifecycleState` — not
/// `SessionState`, which already names an unrelated LSP-layer type in
/// `LSPSession.swift` — and un-privated so `SessionInfo.state` can be
/// inspected outside this file (e.g. `SessionBrowserModel`'s orphan
/// detection, which only considers `.running` sessions).
enum SessionLifecycleState: Decodable, Equatable, Sendable {
    case running
    case exited(code: Int32)

    private enum CodingKeys: String, CodingKey {
        case exited = "Exited"
    }

    private struct ExitedPayload: Decodable {
        let code: Int32
    }

    init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(),
           let tag = try? single.decode(String.self), tag == "Running" {
            self = .running
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let payload = try container.decode(ExitedPayload.self, forKey: .exited)
        self = .exited(code: payload.code)
    }
}
