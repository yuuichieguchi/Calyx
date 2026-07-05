// AgentSessionMetaBridge.swift
// Calyx
//
// Bridges an agent CLI hook event's self-reported session ID
// (`AgentEvent.sessionID`) into the calyx-session daemon's per-session
// meta map, so a later reattach (`SessionResumePlanner`) can look it
// up and offer to resume the same CLI conversation.
// `CalyxMCPServer.routeAgentEvent` is meant to route every hook event
// through exactly one call to `recordAgentSession(surfaceID:agentKind
// :agentSessionID:)` below — see that method's doc comment.
//
import Foundation

@MainActor
final class AgentSessionMetaBridge {

    private let daemonClient: SessionDaemonClientProtocol
    private let surfaceMap: SessionSurfaceMap

    init(
        daemonClient: SessionDaemonClientProtocol = SessionDaemonClient.shared,
        surfaceMap: SessionSurfaceMap = .shared
    ) {
        self.daemonClient = daemonClient
        self.surfaceMap = surfaceMap
    }

    /// Records `agentSessionID` (the agent CLI's own session
    /// identifier, e.g. Claude Code's `session_id`) against the
    /// calyx-session tracking `surfaceID`, under
    /// `SessionResumePlanner.encodeMetaKey(kind: agentKind)`. A no-op
    /// when `surfaceID` has no tracked calyx-session (an ordinary,
    /// non-persistent pane) — there is nothing to attach this meta to.
    func recordAgentSession(surfaceID: UUID, agentKind: String, agentSessionID: String) async {
        guard let sessionID = surfaceMap.sessionID(for: surfaceID) else { return }
        await daemonClient.setMeta(
            id: sessionID,
            key: SessionResumePlanner.encodeMetaKey(kind: agentKind),
            value: agentSessionID
        )
    }
}
