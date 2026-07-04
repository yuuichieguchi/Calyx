// SessionSurfaceMap.swift
// Calyx
//
// Bidirectional registry between a calyx-session ID (ULID string,
// stable across reconnect) and the ghostty surface UUID currently
// attached to it (unstable — a reconnect creates a fresh surface).
// `CalyxMCPServer` consults this to resolve `/agent-event` requests that
// carry a session ID (rather than a raw surface UUID) in
// `X-Calyx-Surface-ID`.

import Foundation

@MainActor
final class SessionSurfaceMap {

    static let shared = SessionSurfaceMap()

    private var surfaceBySessionID: [String: UUID] = [:]
    private var sessionIDBySurface: [UUID: String] = [:]

    init() {}

    /// Records both directions (sessionID -> surfaceID and surfaceID ->
    /// sessionID). Registering a second surface under the same
    /// `sessionID` overwrites the first and clears that prior surface's
    /// reverse entry (double registration replaces, it does not
    /// accumulate).
    func register(sessionID: String, surfaceID: UUID) {
        if let priorSurfaceID = surfaceBySessionID[sessionID] {
            sessionIDBySurface.removeValue(forKey: priorSurfaceID)
        }
        surfaceBySessionID[sessionID] = surfaceID
        sessionIDBySurface[surfaceID] = sessionID
    }

    func surfaceID(for sessionID: String) -> UUID? {
        surfaceBySessionID[sessionID]
    }

    func sessionID(for surfaceID: UUID) -> String? {
        sessionIDBySurface[surfaceID]
    }

    /// Removes both directions of the mapping for `sessionID`.
    func unregister(sessionID: String) {
        guard let surfaceID = surfaceBySessionID.removeValue(forKey: sessionID) else { return }
        sessionIDBySurface.removeValue(forKey: surfaceID)
    }

    /// Re-points `sessionID`'s registration from `old` to `new` in one
    /// step (the reconnect case: a fresh surface replaces the one whose
    /// child just exited).
    func replaceSurface(old: UUID, new: UUID) {
        guard let sessionID = sessionIDBySurface.removeValue(forKey: old) else { return }
        surfaceBySessionID[sessionID] = new
        sessionIDBySurface[new] = sessionID
    }
}
