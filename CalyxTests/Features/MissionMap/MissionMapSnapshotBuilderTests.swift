//
//  MissionMapSnapshotBuilderTests.swift
//  CalyxTests
//
//  Pins MissionMapSnapshotBuilder.build(input:) -- the pure function that
//  turns one window's live state (panes, agent entries, subagent
//  children, pending approvals, IPC events, peer bindings, edited-file
//  records, git badges) into a MissionMapSnapshot (cards + edges +
//  groups).
//
//  Also pins MissionMapCwdAbbreviator.abbreviate(_:home:maxComponents:)
//  (kept in this file per the plan's own instruction), the pure cwd
//  label formatter cards use for their `cwdLabel`.
//
//  Coverage (snapshot builder):
//  - One card per pane
//  - A pane with no matching AgentEntry gets a nil `state`
//  - A pane's subagent children populate `children`
//  - unreadCount is carried from the entry
//  - A pending `.mcpTool` approval targeting a surface -> `.allowable`
//  - A pending `.agentQuestion` approval targeting a surface -> `.openOnly`
//  - An IPC event between two bound surfaces resolves to a `.ipc` edge
//  - An IPC event involving the app's own peer ID is excluded
//  - An IPC event whose peer has no surface binding is dropped
//  - A broadcast event expands into one edge per OTHER bound peer,
//    excluding the sender and the app peer
//  - An IPC event older than `ipcEdgeLifetime` is dropped
//  - A 30s-old IPC event still resolves to an edge under the real
//    `MissionMapView.ipcEdgeLifetime` (2 minutes)
//  - focusTarget follows AgentRowFocusTarget.resolve(source:surfaceID:
//    focusSurfaceID:) -- an explicit focusSurfaceID always wins over the
//    pane's own surfaceID
//  - cwd label abbreviation, via MissionMapCwdAbbreviator directly
//

import XCTest
@testable import Calyx

final class MissionMapSnapshotBuilderTests: XCTestCase {

    // MARK: - Helpers

    private func pane(
        surfaceID: UUID = UUID(), windowID: UUID = UUID(), groupID: UUID = UUID(),
        groupName: String = "Default", tabID: UUID = UUID(), tabTitle: String = "Shell",
        title: String? = nil, cwd: String? = "/Users/dev/project", isFocused: Bool = false,
        agentKind: String? = nil, calyxSessionID: String? = nil
    ) -> CockpitPaneInfo {
        CockpitPaneInfo(
            surfaceID: surfaceID, windowID: windowID, groupName: groupName, tabID: tabID,
            tabTitle: tabTitle, title: title, cwd: cwd, isFocused: isFocused,
            agentKind: agentKind, calyxSessionID: calyxSessionID
        )
    }

    private func entry(
        surfaceID: UUID, source: AgentSource = .hooks, state: AgentState = .working,
        unreadCount: Int = 0, focusSurfaceID: UUID? = nil
    ) -> AgentEntry {
        AgentEntry(
            surfaceID: surfaceID, sessionID: "session-1", source: source, state: state,
            cwd: "/Users/dev/project", kind: AgentEntry.claudeCodeKind, lastEventAt: Date(),
            unreadCount: unreadCount, focusSurfaceID: focusSurfaceID
        )
    }

    private func subagent(parentSurfaceID: UUID, agentID: String = "sub-1") -> SubagentEntry {
        SubagentEntry(
            parentSurfaceID: parentSurfaceID, agentID: agentID, agentType: "explore",
            state: .working, lastToolName: "Bash", lastToolSummary: "ls -la", startedAt: Date()
        )
    }

    private func mcpToolApproval(targetSurfaceID: UUID) -> ApprovalRequest {
        ApprovalRequest(
            id: UUID(), source: .mcpTool(name: "write_file"), targetSurfaceID: targetSurfaceID,
            payload: "", createdAt: Date()
        )
    }

    private func agentQuestionApproval(targetSurfaceID: UUID) -> ApprovalRequest {
        let prompt = AgentQuestionPrompt(
            questions: [
                AgentQuestionPrompt.Question(
                    text: "Which?", header: nil,
                    options: [AgentQuestionPrompt.Option(label: "a", description: nil, preview: nil)],
                    multiSelect: false
                ),
            ],
            originalToolInputJSON: Data()
        )
        return ApprovalRequest(
            id: UUID(), source: .agentQuestion(kind: AgentEntry.claudeCodeKind, prompt: prompt),
            targetSurfaceID: targetSurfaceID, payload: "", createdAt: Date()
        )
    }

    private func input(
        panes: [CockpitPaneInfo] = [], entries: [UUID: AgentEntry] = [:],
        children: [UUID: [SubagentEntry]] = [:], pendingApprovals: [ApprovalRequest] = [],
        ipcEvents: [IPCMessageEvent] = [], peerToSurface: [UUID: UUID] = [:],
        appPeerID: UUID? = nil, editedFiles: [AgentEditedFile] = [],
        git: [String: MissionMapGitBadge] = [:], now: Date = Date(),
        conflictWindow: TimeInterval = 300, ipcEdgeLifetime: TimeInterval = 30
    ) -> MissionMapInput {
        MissionMapInput(
            panes: panes, entries: entries, children: children, pendingApprovals: pendingApprovals,
            ipcEvents: ipcEvents, peerToSurface: peerToSurface, appPeerID: appPeerID,
            editedFiles: editedFiles, git: git, now: now, conflictWindow: conflictWindow,
            ipcEdgeLifetime: ipcEdgeLifetime
        )
    }

    // MARK: - Git badge cwd

    /// The git badge is looked up under the same cwd the label shows:
    /// the entry's cwd when it differs from the pane's.
    func test_build_gitBadge_keyedByEntryCwd_whenEntryCwdDiffersFromPaneCwd() {
        let surfaceID = UUID()
        let paneA = pane(surfaceID: surfaceID, cwd: "/Users/dev/pane-dir")
        var agent = entry(surfaceID: surfaceID)
        agent.cwd = "/Users/dev/entry-dir"
        let badge = MissionMapGitBadge(branch: "main", shortHash: "abc1234", changedFileCount: 2)

        let keyedByEntry = MissionMapSnapshotBuilder.build(input: input(
            panes: [paneA], entries: [surfaceID: agent], git: ["/Users/dev/entry-dir": badge]
        ))
        let keyedByPane = MissionMapSnapshotBuilder.build(input: input(
            panes: [paneA], entries: [surfaceID: agent], git: ["/Users/dev/pane-dir": badge]
        ))

        XCTAssertEqual(keyedByEntry.cards.first?.git, badge)
        XCTAssertNil(keyedByPane.cards.first?.git)
    }

    // MARK: - Cards

    func test_build_createsOneCardPerPane() {
        let paneA = pane()
        let paneB = pane()

        let snapshot = MissionMapSnapshotBuilder.build(input: input(panes: [paneA, paneB]))

        XCTAssertEqual(Set(snapshot.cards.map(\.id)), Set([paneA.surfaceID, paneB.surfaceID]))
    }

    func test_build_paneWithNoMatchingEntry_hasNilState() {
        let paneA = pane()

        let snapshot = MissionMapSnapshotBuilder.build(input: input(panes: [paneA], entries: [:]))

        XCTAssertEqual(snapshot.cards.first?.state, nil)
    }

    func test_build_paneWithMatchingEntry_carriesItsState() {
        let paneA = pane()
        let entryA = entry(surfaceID: paneA.surfaceID, state: .blocked)

        let snapshot = MissionMapSnapshotBuilder.build(
            input: input(panes: [paneA], entries: [paneA.surfaceID: entryA])
        )

        XCTAssertEqual(snapshot.cards.first?.state, .blocked)
    }

    func test_build_paneWithSubagentChildren_populatesChildCards() {
        let paneA = pane()
        let entryA = entry(surfaceID: paneA.surfaceID)
        let child = subagent(parentSurfaceID: paneA.surfaceID)

        let snapshot = MissionMapSnapshotBuilder.build(
            input: input(
                panes: [paneA], entries: [paneA.surfaceID: entryA],
                children: [paneA.surfaceID: [child]]
            )
        )

        XCTAssertEqual(snapshot.cards.first?.children.count, 1)
        XCTAssertEqual(snapshot.cards.first?.children.first?.id, child.agentID)
    }

    func test_build_unreadCount_carriedFromEntry() {
        let paneA = pane()
        let entryA = entry(surfaceID: paneA.surfaceID, unreadCount: 3)

        let snapshot = MissionMapSnapshotBuilder.build(
            input: input(panes: [paneA], entries: [paneA.surfaceID: entryA])
        )

        XCTAssertEqual(snapshot.cards.first?.unreadCount, 3)
    }

    // MARK: - Approvals

    func test_build_pendingMCPToolApproval_producesAllowable() {
        let paneA = pane()
        let approval = mcpToolApproval(targetSurfaceID: paneA.surfaceID)

        let snapshot = MissionMapSnapshotBuilder.build(
            input: input(panes: [paneA], pendingApprovals: [approval])
        )

        XCTAssertEqual(snapshot.cards.first?.approval, .allowable(approval.id))
    }

    func test_build_pendingAgentQuestionApproval_producesOpenOnly() {
        let paneA = pane()
        let approval = agentQuestionApproval(targetSurfaceID: paneA.surfaceID)

        let snapshot = MissionMapSnapshotBuilder.build(
            input: input(panes: [paneA], pendingApprovals: [approval])
        )

        XCTAssertEqual(snapshot.cards.first?.approval, .openOnly(approval.id))
    }

    func test_build_noApprovalForSurface_leavesApprovalNil() {
        let paneA = pane()

        let snapshot = MissionMapSnapshotBuilder.build(input: input(panes: [paneA]))

        XCTAssertNil(snapshot.cards.first?.approval)
    }

    // MARK: - IPC edges

    func test_build_ipcEvent_betweenTwoBoundSurfaces_resolvesToEdge() {
        let paneA = pane()
        let paneB = pane()
        let peerA = UUID()
        let peerB = UUID()
        let now = Date()
        let message = IPCMessageEvent(
            id: UUID(), from: peerA, to: peerB, content: "hi", sentAt: now, isBroadcast: false
        )

        let snapshot = MissionMapSnapshotBuilder.build(
            input: input(
                panes: [paneA, paneB], ipcEvents: [message],
                peerToSurface: [peerA: paneA.surfaceID, peerB: paneB.surfaceID],
                now: now, ipcEdgeLifetime: 30
            )
        )

        let ipcEdges = snapshot.edges.filter {
            if case .ipc = $0.kind { return true }
            return false
        }
        XCTAssertEqual(ipcEdges.count, 1)
        XCTAssertEqual(ipcEdges.first?.from, paneA.surfaceID)
        XCTAssertEqual(ipcEdges.first?.to, paneB.surfaceID)
    }

    func test_build_ipcEvent_involvingAppPeer_isExcluded() {
        let paneA = pane()
        let appPeer = UUID()
        let peerA = UUID()
        let now = Date()
        let message = IPCMessageEvent(
            id: UUID(), from: peerA, to: appPeer, content: "hi", sentAt: now, isBroadcast: false
        )

        let snapshot = MissionMapSnapshotBuilder.build(
            input: input(
                panes: [paneA], ipcEvents: [message],
                peerToSurface: [peerA: paneA.surfaceID, appPeer: UUID()],
                appPeerID: appPeer, now: now, ipcEdgeLifetime: 30
            )
        )

        XCTAssertTrue(snapshot.edges.isEmpty, "An edge touching the app's own peer must be excluded")
    }

    func test_build_ipcEvent_unresolvedPeer_isDropped() {
        let paneA = pane()
        let peerA = UUID()
        let unresolvedPeer = UUID()
        let now = Date()
        let message = IPCMessageEvent(
            id: UUID(), from: peerA, to: unresolvedPeer, content: "hi", sentAt: now, isBroadcast: false
        )

        let snapshot = MissionMapSnapshotBuilder.build(
            input: input(
                panes: [paneA], ipcEvents: [message], peerToSurface: [peerA: paneA.surfaceID],
                now: now, ipcEdgeLifetime: 30
            )
        )

        XCTAssertTrue(snapshot.edges.isEmpty, "An event whose recipient peer has no surface binding must be dropped")
    }

    /// A broadcast expands into one edge per OTHER bound peer (excluding
    /// the sender and the app peer), regardless of the event's own `to`
    /// field.
    func test_build_broadcastEvent_expandsToOneEdgePerOtherBoundPeer() {
        let paneSender = pane()
        let paneB = pane()
        let paneC = pane()
        let peerSender = UUID()
        let peerB = UUID()
        let peerC = UUID()
        let appPeer = UUID()
        let now = Date()
        let broadcast = IPCMessageEvent(
            id: UUID(), from: peerSender, to: UUID(), content: "hello all", sentAt: now, isBroadcast: true
        )

        let snapshot = MissionMapSnapshotBuilder.build(
            input: input(
                panes: [paneSender, paneB, paneC], ipcEvents: [broadcast],
                peerToSurface: [
                    peerSender: paneSender.surfaceID, peerB: paneB.surfaceID, peerC: paneC.surfaceID,
                    appPeer: UUID(),
                ],
                appPeerID: appPeer, now: now, ipcEdgeLifetime: 30
            )
        )

        let ipcEdges = snapshot.edges.filter {
            if case .ipc = $0.kind { return true }
            return false
        }
        XCTAssertEqual(ipcEdges.count, 2, "One edge per recipient (B and C), excluding the sender and app peer")
        XCTAssertEqual(Set(ipcEdges.map(\.to)), Set([paneB.surfaceID, paneC.surfaceID]))
        XCTAssertTrue(ipcEdges.allSatisfy { $0.from == paneSender.surfaceID })
    }

    func test_build_expiredIpcEvent_isDropped() {
        let paneA = pane()
        let paneB = pane()
        let peerA = UUID()
        let peerB = UUID()
        let now = Date()
        let staleMessage = IPCMessageEvent(
            id: UUID(), from: peerA, to: peerB, content: "old", sentAt: now.addingTimeInterval(-60),
            isBroadcast: false
        )

        let snapshot = MissionMapSnapshotBuilder.build(
            input: input(
                panes: [paneA, paneB], ipcEvents: [staleMessage],
                peerToSurface: [peerA: paneA.surfaceID, peerB: paneB.surfaceID],
                now: now, ipcEdgeLifetime: 30
            )
        )

        XCTAssertTrue(snapshot.edges.isEmpty, "An IPC event older than ipcEdgeLifetime must be dropped")
    }

    /// Reproduces the user's own flow: two Claude Code panes, both bound
    /// to peers, one `send_message` 30 seconds ago -- well past the old
    /// 6-second `MissionMapView.ipcEdgeLifetime`, but still comfortably
    /// inside the real one (`MissionMapView.ipcEdgeLifetime`, 120s) a
    /// human opening the map a few seconds after switching windows would
    /// actually see. Pins the production constant directly (not a
    /// test-local literal), so a future lifetime regression fails here
    /// too, not just in `test_build_expiredIpcEvent_isDropped`'s own
    /// shorter, test-local window.
    func test_build_sendMessage30SecondsAgo_stillProducesOneIPCEdge() {
        let paneA = pane()
        let paneB = pane()
        let peerA = UUID()
        let peerB = UUID()
        let now = Date()
        let message = IPCMessageEvent(
            id: UUID(), from: peerA, to: peerB, content: "hi", sentAt: now.addingTimeInterval(-30),
            isBroadcast: false
        )

        let snapshot = MissionMapSnapshotBuilder.build(
            input: input(
                panes: [paneA, paneB], ipcEvents: [message],
                peerToSurface: [peerA: paneA.surfaceID, peerB: paneB.surfaceID],
                now: now, ipcEdgeLifetime: MissionMapView.ipcEdgeLifetime
            )
        )

        let ipcEdges = snapshot.edges.filter {
            if case .ipc = $0.kind { return true }
            return false
        }
        XCTAssertEqual(ipcEdges.count, 1, "A 30s-old message must still draw its pulse line under the real lifetime")
    }

    // MARK: - focusTarget

    func test_build_focusTarget_explicitFocusSurfaceID_winsOverPaneSurfaceID() {
        let paneA = pane()
        let otherSurface = UUID()
        let entryA = entry(surfaceID: paneA.surfaceID, source: .external, focusSurfaceID: otherSurface)

        let snapshot = MissionMapSnapshotBuilder.build(
            input: input(panes: [paneA], entries: [paneA.surfaceID: entryA])
        )

        XCTAssertEqual(snapshot.cards.first?.focusTarget, otherSurface)
    }

    func test_build_focusTarget_noFocusSurfaceID_fallsBackToPaneSurfaceID() {
        let paneA = pane()
        let entryA = entry(surfaceID: paneA.surfaceID, source: .hooks, focusSurfaceID: nil)

        let snapshot = MissionMapSnapshotBuilder.build(
            input: input(panes: [paneA], entries: [paneA.surfaceID: entryA])
        )

        XCTAssertEqual(snapshot.cards.first?.focusTarget, paneA.surfaceID)
    }

    // MARK: - MissionMapCwdAbbreviator

    func test_abbreviate_nilPath_returnsNA() {
        XCTAssertEqual(MissionMapCwdAbbreviator.abbreviate(nil, home: "/Users/dev", maxComponents: 2), "N/A")
    }

    func test_abbreviate_emptyPath_returnsNA() {
        XCTAssertEqual(MissionMapCwdAbbreviator.abbreviate("", home: "/Users/dev", maxComponents: 2), "N/A")
    }

    /// Under home, with the remaining path no longer than maxComponents:
    /// no truncation ellipsis, just the "~/" prefix.
    func test_abbreviate_underHome_shortPath_prefixesWithTilde_noTruncation() {
        let result = MissionMapCwdAbbreviator.abbreviate(
            "/Users/dev/project", home: "/Users/dev", maxComponents: 2
        )

        XCTAssertEqual(result, "~/project")
    }

    /// Under home, with more remaining components than maxComponents:
    /// keeps only the LAST maxComponents, with a "…" marker for the
    /// elided prefix.
    func test_abbreviate_underHome_longPath_keepsLastComponentsWithEllipsis() {
        let result = MissionMapCwdAbbreviator.abbreviate(
            "/Users/dev/workspace/calyx/Sources/App", home: "/Users/dev", maxComponents: 2
        )

        XCTAssertEqual(result, "~/…/Sources/App")
    }

    /// Not under home, path longer than maxComponents: same "…" +
    /// last-N-components shape, without a leading "~".
    func test_abbreviate_notUnderHome_longPath_keepsLastComponentsWithEllipsis() {
        let result = MissionMapCwdAbbreviator.abbreviate(
            "/var/tmp/build/output/artifacts", home: "/Users/dev", maxComponents: 2
        )

        XCTAssertEqual(result, "…/output/artifacts")
    }

    /// Not under home, path no longer than maxComponents: returned as-is.
    func test_abbreviate_notUnderHome_shortPath_returnsUnchanged() {
        let result = MissionMapCwdAbbreviator.abbreviate("/var/tmp", home: "/Users/dev", maxComponents: 2)

        XCTAssertEqual(result, "/var/tmp")
    }
}
