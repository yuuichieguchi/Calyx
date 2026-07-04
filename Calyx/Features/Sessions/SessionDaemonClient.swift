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
        guard let sessions = try? JSONDecoder().decode([SessionInfoJSON].self, from: Data(result.stdout.utf8)) else {
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
}

/// Mirrors `proto::SessionInfo`'s `id`/`state` fields (the CLI's
/// `ls --json` output — see `calyx-session/crates/proto/src/control.rs`).
/// Only the fields `SessionDaemonClient` actually consumes are
/// declared; the JSON also carries `name`/`cwd`/`created_at_ms`/
/// `attached_clients`/`pid`/`meta`, which `Decodable` simply ignores.
private struct SessionInfoJSON: Decodable {
    let id: String
    let state: SessionStateJSON
}

/// Mirrors `proto::SessionState`'s serde default (externally tagged)
/// representation: the unit variant `Running` encodes as the bare
/// string `"Running"`; the struct variant `Exited { code }` encodes as
/// `{"Exited": {"code": N}}`.
private enum SessionStateJSON: Decodable {
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
