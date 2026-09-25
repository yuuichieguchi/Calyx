// MissionMapFixture.swift
// Calyx
//
// A fabricated Mission Map snapshot shared by the render fixture unit
// test and the UI-test-only live map seam (`--uitesting-mission-map-fixture`,
// see `MissionMapView`). Band A: 4 cards (3 per row at width 1000, so a4
// wraps to row 2; a2 has two subagents and is taller). Band B: 2 cards.
// Edges, in this order: an adjacent round trip a1<->a2 (a1->a2 carrying
// three messages sent 0.4 s apart, so its one line shows three pulse
// dots), a cross-row a2->a4, a cross-band a4->b1, and a conflict a1-a3.

import Foundation

struct MissionMapFixture: Sendable {
    let snapshot: MissionMapSnapshot
    /// The cards by fixture name: "a1"..."a4", "b1", "b2".
    let cards: [String: MissionMapCard]

    /// UI TEST ONLY. With `--uitesting`, this launch argument makes the
    /// live Mission Map show `make(now:)` instead of the window's panes,
    /// with the a1->a2 line pre-selected, so a UI test can capture the
    /// popover over real Liquid Glass.
    static let uiTestLaunchArgument = "--uitesting-mission-map-fixture"

    /// Whether this process was launched by a UI test with
    /// `uiTestLaunchArgument`.
    static var isUITestLaunch: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("--uitesting") && arguments.contains(uiTestLaunchArgument)
    }

    /// The a1->a2 edge: the fixture's first edge.
    var selectedEdgeID: UUID { snapshot.edges[0].id }

    static func make(now: Date) -> MissionMapFixture {
        let groupA = UUID()
        let groupB = UUID()
        let groups = [
            MissionMapGroup(id: groupA, name: "Band A"),
            MissionMapGroup(id: groupB, name: "Band B"),
        ]
        func card(
            groupID: UUID, groupName: String, title: String, state: AgentState = .working,
            toolLine: String? = nil, children: [MissionMapChildCard] = []
        ) -> MissionMapCard {
            let id = UUID()
            return MissionMapCard(
                id: id, groupID: groupID, groupName: groupName, tabID: UUID(), kindLabel: "Claude Code",
                paneTitle: title, cwdLabel: "~/projects/app", state: state, toolLine: toolLine,
                children: children, unreadCount: 0, approval: nil, git: nil, focusTarget: id
            )
        }
        let a1 = card(groupID: groupA, groupName: "Band A", title: "API server", toolLine: "Edit: main.swift")
        let a2 = card(
            groupID: groupA, groupName: "Band A", title: "Refactor router",
            children: [
                MissionMapChildCard(id: "child-1", agentType: "Explore", state: .working, toolLine: "Grep: route"),
                MissionMapChildCard(id: "child-2", agentType: "Plan", state: .idle, toolLine: nil),
            ]
        )
        let a3 = card(groupID: groupA, groupName: "Band A", title: "Docs", state: .idle, toolLine: "Edit: main.swift")
        let a4 = card(groupID: groupA, groupName: "Band A", title: "Test runner", toolLine: "Bash: swift test")
        let b1 = card(groupID: groupB, groupName: "Band B", title: "Release notes", state: .idle)
        let b2 = card(groupID: groupB, groupName: "Band B", title: "Shell", state: .idle)
        let cards = [a1, a2, a3, a4, b1, b2]

        func message(_ content: String, secondsAgo: TimeInterval = 0) -> IPCMessageEvent {
            IPCMessageEvent(
                id: UUID(), from: UUID(), to: UUID(), content: content,
                sentAt: now.addingTimeInterval(-secondsAgo), isBroadcast: false
            )
        }
        let pings = [message("ping 3"), message("ping 2", secondsAgo: 0.4), message("ping 1", secondsAgo: 0.8)]
        let edges = [
            MissionMapEdge(id: UUID(), from: a1.id, to: a2.id, kind: .ipc(messages: pings)),
            MissionMapEdge(id: UUID(), from: a2.id, to: a1.id, kind: .ipc(messages: [message("pong")])),
            MissionMapEdge(id: UUID(), from: a2.id, to: a4.id, kind: .ipc(messages: [message("cross-row")])),
            MissionMapEdge(id: UUID(), from: a4.id, to: b1.id, kind: .ipc(messages: [message("cross-band")])),
            MissionMapEdge(
                id: UUID(), from: a1.id, to: a3.id,
                kind: .conflict(file: "main.swift", fullPath: "/projects/app/main.swift")
            ),
        ]
        return MissionMapFixture(
            snapshot: MissionMapSnapshot(cards: cards, edges: edges, groups: groups),
            cards: ["a1": a1, "a2": a2, "a3": a3, "a4": a4, "b1": b1, "b2": b2]
        )
    }
}
