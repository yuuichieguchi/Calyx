// MissionMapSnapshotBuilder.swift
// Calyx
//
// Turns one window's live state into the MissionMapSnapshot its map
// draws. Pure: every input arrives through MissionMapInput, so the
// view can call this from `body` (where reading the registries keeps
// @Observable tracking alive) and tests can pin every rule directly.

import Foundation

enum MissionMapSnapshotBuilder {

    /// How many trailing cwd components a card's cwd label keeps.
    static let cwdLabelComponents = 2

    static func build(input: MissionMapInput) -> MissionMapSnapshot {
        let groups = makeGroups(from: input.panes)
        let cards = input.panes.map { makeCard(for: $0, input: input) }
        let cardIDs = Set(cards.map(\.id))
        let edges = ipcEdges(input: input, cardIDs: cardIDs) + conflictEdges(input: input, cardIDs: cardIDs)
        return MissionMapSnapshot(cards: cards, edges: edges, groups: groups)
    }

    // MARK: - Groups

    /// One group per distinct `groupName`, in first-appearance order.
    /// `CockpitPaneInfo` carries a group's name but not its ID, so the
    /// ID is derived from the name (`MissionMapStableID`): stable across
    /// rebuilds, which is all the layout and the views key on.
    private static func makeGroups(from panes: [CockpitPaneInfo]) -> [MissionMapGroup] {
        var seen: Set<String> = []
        var groups: [MissionMapGroup] = []
        for pane in panes where seen.insert(pane.groupName).inserted {
            groups.append(MissionMapGroup(id: groupID(forName: pane.groupName), name: pane.groupName))
        }
        return groups
    }

    private static func groupID(forName name: String) -> UUID {
        MissionMapStableID.make("group:\(name)")
    }

    // MARK: - Cards

    /// The one cwd a card stands for: the agent entry's own cwd when it
    /// has a non-empty one (as in the sidebar,
    /// `AgentRowDisplay.cwdLabel(entryCwd:...)`), otherwise the pane's.
    /// Both the cwd label and the git badge lookup use it, and
    /// `CalyxWindowController.showMissionMap()` feeds
    /// `MissionMapGitPoller` the same cwds, so a badge is always polled
    /// for the directory the card names.
    static func resolvedCwd(entryCwd: String?, paneCwd: String?) -> String? {
        entryCwd.flatMap { $0.isEmpty ? nil : $0 } ?? paneCwd
    }

    private static func makeCard(for pane: CockpitPaneInfo, input: MissionMapInput) -> MissionMapCard {
        let entry = input.entries[pane.surfaceID]
        let kind = entry?.kind ?? pane.agentKind
        let cwd = resolvedCwd(entryCwd: entry?.cwd, paneCwd: pane.cwd)
        return MissionMapCard(
            id: pane.surfaceID,
            groupID: groupID(forName: pane.groupName),
            groupName: pane.groupName,
            tabID: pane.tabID,
            kindLabel: kind.map(AgentEntry.displayName(forKind:)),
            paneTitle: AgentRowDisplay.primaryLabel(title: pane.title),
            cwdLabel: MissionMapCwdAbbreviator.abbreviate(
                cwd, home: input.homeDirectory, maxComponents: cwdLabelComponents
            ),
            state: entry?.state,
            toolLine: AgentRowDisplay.toolLine(toolName: entry?.currentToolName, toolSummary: entry?.currentToolSummary),
            children: (input.children[pane.surfaceID] ?? []).map {
                MissionMapChildCard(
                    id: $0.agentID, agentType: $0.agentType, state: $0.state,
                    toolLine: AgentRowDisplay.toolLine(toolName: $0.lastToolName, toolSummary: $0.lastToolSummary)
                )
            },
            unreadCount: entry?.unreadCount ?? 0,
            approval: approval(for: pane.surfaceID, in: input.pendingApprovals),
            git: cwd.flatMap { input.git[$0] },
            // A pane with no agent row is still a real pane: its own
            // surface is the target, exactly as for a `.hooks` row.
            focusTarget: entry.map {
                AgentRowFocusTarget.resolve(source: $0.source, surfaceID: $0.surfaceID, focusSurfaceID: $0.focusSurfaceID)
            } ?? pane.surfaceID
        )
    }

    /// The oldest pending request targeting `surfaceID` -- the one the
    /// agent has been waiting on longest.
    private static func approval(for surfaceID: UUID, in pending: [ApprovalRequest]) -> MissionMapApproval? {
        let oldest = pending
            .filter { $0.targetSurfaceID == surfaceID }
            .min { $0.createdAt < $1.createdAt }
        guard let oldest else { return nil }
        switch oldest.source {
        case .mcpTool, .agentHook:
            return .allowable(oldest.id)
        case .agentQuestion, .mcpApp:
            // A question needs one of its options chosen, and an MCP App
            // consent names a link or message the human must read before
            // agreeing: neither is a blind yes, so both open the panel.
            return .openOnly(oldest.id)
        }
    }

    // MARK: - IPC Edges

    /// One line per message still within `ipcEdgeLifetime`, between the
    /// panes its peers are bound to. A message is dropped when either
    /// end is Calyx's own app peer, is bound to no pane, or is bound to
    /// a pane outside this window; a broadcast (whose own `to` is just
    /// its first recipient) instead draws one line to every other bound
    /// pane in this window.
    private static func ipcEdges(input: MissionMapInput, cardIDs: Set<UUID>) -> [MissionMapEdge] {
        var edges: [MissionMapEdge] = []
        for event in input.ipcEvents where input.now.timeIntervalSince(event.sentAt) <= input.ipcEdgeLifetime {
            guard event.from != input.appPeerID,
                  let fromSurface = input.peerToSurface[event.from], cardIDs.contains(fromSurface)
            else { continue }

            if event.isBroadcast {
                let recipients = input.peerToSurface
                    .filter { peer, surface in
                        peer != event.from && peer != input.appPeerID
                            && surface != fromSurface && cardIDs.contains(surface)
                    }
                    .sorted { $0.key.uuidString < $1.key.uuidString }
                for (peer, surface) in recipients {
                    edges.append(MissionMapEdge(
                        id: MissionMapStableID.make("ipc:\(event.id.uuidString):\(peer.uuidString)"),
                        from: fromSurface, to: surface, kind: .ipc(event)
                    ))
                }
            } else {
                guard event.to != input.appPeerID,
                      let toSurface = input.peerToSurface[event.to], cardIDs.contains(toSurface),
                      toSurface != fromSurface
                else { continue }
                edges.append(MissionMapEdge(id: event.id, from: fromSurface, to: toSurface, kind: .ipc(event)))
            }
        }
        return edges
    }

    // MARK: - Conflict Edges

    private static func conflictEdges(input: MissionMapInput, cardIDs: Set<UUID>) -> [MissionMapEdge] {
        MissionMapConflictDetector
            .conflicts(in: input.editedFiles, now: input.now, window: input.conflictWindow)
            .filter { cardIDs.contains($0.surfaceA) && cardIDs.contains($0.surfaceB) }
            .map { conflict in
                MissionMapEdge(
                    id: MissionMapStableID.make(
                        "conflict:\(conflict.surfaceA.uuidString):\(conflict.surfaceB.uuidString):\(conflict.file)"
                    ),
                    from: conflict.surfaceA, to: conflict.surfaceB,
                    kind: .conflict(file: (conflict.file as NSString).lastPathComponent, fullPath: conflict.file)
                )
            }
    }
}
