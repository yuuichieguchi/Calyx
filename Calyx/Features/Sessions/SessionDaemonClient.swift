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

    /// R10-C item 2 (r10-fix-spec.md): the single bound shared by every
    /// caller that must not await `listAll()` unbounded, originally
    /// `AppDelegate`'s agent-resume path alone
    /// (`listAllSessionsBounded`, R8-D item 1), now also
    /// `SessionBrowserModel.refresh()`, which used to await `listAll()`
    /// completely unbounded and freeze the whole session browser behind
    /// a hung `calyx-session` daemon.
    static var listAllBoundTimeoutSeconds: UInt64 { 5 }

    /// Races `listAll()` against `listAllBoundTimeoutSeconds`, degrading
    /// to `[]` if the daemon round-trip hasn't completed by then, so a
    /// hung daemon never blocks a caller indefinitely. Lifted from
    /// `AppDelegate`'s former private `listAllSessionsBounded` (R8-D
    /// item 1) into this shared default so `SessionBrowserModel
    /// .refresh()` and `AppDelegate.fetchSessionsForAgentResume()` share
    /// one bound and one implementation instead of the browser path
    /// omitting it entirely.
    ///
    /// Deliberately NOT a `TaskGroup` race: `withTaskGroup` always
    /// awaits every child task to completion before returning, even
    /// after `cancelAll()` (cancellation is cooperative; an
    /// unresponsive daemon's `listAll()`, awaiting a
    /// `CheckedContinuation` nobody ever resumes, never observes it),
    /// which would make the whole race hang exactly as long as the call
    /// it exists to bound. Instead, two independent, unstructured
    /// `Task`s race to resume `continuation` first, guarded by
    /// `resumed`; `@MainActor` isolation means both closures (each
    /// inherits this method's actor context, per `Task.init`'s
    /// `@_inheritActorContext`) can never execute concurrently with
    /// each other, mirroring `AppDelegate.applicationWillTerminate`'s
    /// identical `killsDrained` pattern, no lock needed.
    ///
    /// R10-C item 1 (r10-fix-spec.md): the winner cancels the loser (a
    /// beaten daemon task is cancelled, not merely abandoned; the
    /// subprocess layer may ignore it, but the signal is sent; a beaten
    /// timeout task is cancelled too), and the timeout arm re-checks
    /// `Task.isCancelled` before resuming, closing the
    /// `try?`-swallows-`CancellationError` hole the old, unguarded
    /// `Task.sleep` had (a cancelled sleep could still fall through to
    /// resume the continuation with a stale `[]` after the daemon task
    /// had already won).
    @MainActor
    func listAllBounded() async -> [SessionInfo] {
        await withCheckedContinuation { (continuation: CheckedContinuation<[SessionInfo], Never>) in
            var resumed = false
            var daemonTask: Task<Void, Never>?
            var timeoutTask: Task<Void, Never>?
            daemonTask = Task {
                let result = await listAll()
                guard !resumed else { return }
                resumed = true
                timeoutTask?.cancel()
                continuation.resume(returning: result)
            }
            timeoutTask = Task {
                try? await Task.sleep(nanoseconds: Self.listAllBoundTimeoutSeconds * 1_000_000_000)
                guard !Task.isCancelled, !resumed else { return }
                resumed = true
                daemonTask?.cancel()
                continuation.resume(returning: [])
            }
        }
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
    /// actually spawning a process) can ignore it.
    init(resolver: SessionBinaryResolverProtocol, commandRunner: LSPCommandRunner = SystemCommandRunner()) {
        self.binaryPath = resolver.resolve()
        self.commandRunner = commandRunner
    }

    func sessionState(id: String) async -> SessionQueryResult {
        guard let binaryPath else { return .unreachable }
        guard let result = try? await commandRunner.run(
            executable: binaryPath, arguments: ["ls", "--all", "--json"], workingDirectory: nil, environment: nil
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

    func kill(id: String) async {
        guard let binaryPath else { return }
        _ = try? await commandRunner.run(
            executable: binaryPath, arguments: ["kill", id], workingDirectory: nil, environment: nil
        )
    }

    /// Runs the same `ls --all --json` invocation `sessionState(id:)`
    /// above already does and decodes the result as `[SessionInfo]`,
    /// returning `[]` when the binary is unresolvable or the daemon is
    /// unreachable — mirroring that method's own degrade-gracefully
    /// contract.
    func listAll() async -> [SessionInfo] {
        guard let binaryPath else { return [] }
        guard let result = try? await commandRunner.run(
            executable: binaryPath, arguments: ["ls", "--all", "--json"], workingDirectory: nil, environment: nil
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
    /// offered next time.
    func setMeta(id: String, key: String, value: String) async {
        guard let binaryPath else { return }
        _ = try? await commandRunner.run(
            executable: binaryPath, arguments: ["meta", "set", id, "\(key)=\(value)"], workingDirectory: nil, environment: nil
        )
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
