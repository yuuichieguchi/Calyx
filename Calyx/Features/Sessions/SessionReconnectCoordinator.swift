// SessionReconnectCoordinator.swift
// Calyx
//
// Decides what to do when a persistent-session surface's
// `GHOSTTY_ACTION_SHOW_CHILD_EXITED` fires: query the daemon for the
// session's actual state (see `SessionDaemonClient`'s header comment for
// why macOS's exit code can't be trusted) and either close the pane
// (the session really ended) or reconnect (the attach process merely
// disconnected).
//
// Attempt tracking is keyed by sessionID rather than surfaceID so it
// survives a reconnect's surface swap (`SessionSurfaceMap
// .replaceSurface`); consecutive `.running`/`.unreachable` decisions
// are capped at `maxReconnectAttempts`, closing the pane instead of
// retrying forever once exceeded; and the gate for whether a surface is
// managed at all is "does `surfaceMap` have a session for this
// surface", not the global `SessionSettings.persistentSessionsEnabled`
// toggle — a surface already tracked must keep being managed even if
// the user turns off "start new panes as persistent" afterward (that
// toggle only affects `SessionSpawnPlanner`'s decision for *new*
// surfaces).

import Foundation

enum SessionReconnectDecision: Sendable, Equatable {
    /// The session actually ended — close the pane normally.
    case closePane
    /// Re-run `calyx-session attach --create` for `sessionID`. `attempt`
    /// is the 1-based count of consecutive reconnect attempts for this
    /// sessionID, for the caller to compute a backoff delay from.
    case reconnect(sessionID: String, attempt: Int)
}

@MainActor
final class SessionReconnectCoordinator {

    /// After this many consecutive `.running`/`.unreachable` reconnect
    /// decisions for the same sessionID with no intervening
    /// `markEstablished(sessionID:)`, give up and close the pane
    /// instead of retrying forever.
    static let maxReconnectAttempts = 5

    private let daemonClient: SessionDaemonClientProtocol
    /// Resolves which calyx-session a surface belongs to. Tests inject
    /// a fresh instance for isolation instead of mutating the shared
    /// singleton.
    private let surfaceMap: SessionSurfaceMap
    private let onDecision: (UUID, SessionReconnectDecision) -> Void

    /// Consecutive reconnect-attempt count keyed by sessionID (not
    /// surfaceID): a reconnect replaces the surface, so tracking by
    /// surfaceID would silently reset backoff on every single
    /// reconnect instead of accumulating across them. Reset by
    /// `markEstablished(sessionID:)` / `markClosed(sessionID:)`.
    private(set) var attemptCounts: [String: Int] = [:]

    /// Surfaces with a `childExited` call currently awaiting the
    /// daemon's reply. Guards against two overlapping
    /// `GHOSTTY_ACTION_SHOW_CHILD_EXITED` events for the same surface
    /// (e.g. a flapping daemon connection) racing each other into two
    /// separate attempt-count increments / decisions for what is really
    /// one disconnect.
    private var inFlightSurfaceIDs: Set<UUID> = []

    init(
        daemonClient: SessionDaemonClientProtocol,
        surfaceMap: SessionSurfaceMap,
        onDecision: @escaping (UUID, SessionReconnectDecision) -> Void
    ) {
        self.daemonClient = daemonClient
        self.surfaceMap = surfaceMap
        self.onDecision = onDecision
    }

    /// Gated solely on `surfaceMap.sessionID(for: surfaceID) != nil` —
    /// a surface already tracked as a persistent session must keep
    /// being managed for reconnect purposes regardless of
    /// `SessionSettings.persistentSessionsEnabled`, which only affects
    /// `SessionSpawnPlanner`'s decision for *new* surfaces.
    func childExited(surfaceID: UUID) async {
        guard let sessionID = surfaceMap.sessionID(for: surfaceID) else { return }
        guard !inFlightSurfaceIDs.contains(surfaceID) else { return }
        inFlightSurfaceIDs.insert(surfaceID)
        defer { inFlightSurfaceIDs.remove(surfaceID) }

        switch await daemonClient.sessionState(id: sessionID) {
        case .exited:
            attemptCounts[sessionID] = nil
            onDecision(surfaceID, .closePane)
        case .running, .unreachable:
            let attempt = (attemptCounts[sessionID] ?? 0) + 1
            guard attempt <= Self.maxReconnectAttempts else {
                attemptCounts[sessionID] = nil
                onDecision(surfaceID, .closePane)
                return
            }
            attemptCounts[sessionID] = attempt
            onDecision(surfaceID, .reconnect(sessionID: sessionID, attempt: attempt))
        }
    }

    /// Resets `attemptCounts[sessionID]` once a reconnect attempt is
    /// confirmed to have succeeded (the pane is live again), so a
    /// later, unrelated disconnect starts backing off from attempt 1
    /// again instead of continuing a stale count. Takes `sessionID`
    /// directly rather than a surfaceID: by the time a reconnect
    /// succeeds, the OLD surfaceID has already been replaced in
    /// `surfaceMap` (`replaceSurface`), so resolving through it here
    /// would resolve a mapping that no longer points anywhere.
    func markEstablished(sessionID: String) {
        attemptCounts[sessionID] = nil
    }

    /// Drops `sessionID`'s attempt count when the user explicitly kills
    /// the session (`SessionCloseKillPolicy.shouldKill` decided `true`)
    /// rather than waiting for a reconnect/cap decision to clear it —
    /// otherwise a stale entry for a now-dead sessionID would linger in
    /// `attemptCounts` indefinitely.
    func markClosed(sessionID: String) {
        attemptCounts[sessionID] = nil
    }
}
