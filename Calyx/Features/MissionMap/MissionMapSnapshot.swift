// MissionMapSnapshot.swift
// Calyx
//
// The value types Mission Map renders: one immutable snapshot of a
// window's panes (cards), the lines between them (edges), and the tab
// groups the cards are banded by. `MissionMapSnapshotBuilder` produces
// it from live state; the views only ever read it, so everything here
// is a plain Sendable value with no SwiftUI dependency.

import CryptoKit
import Foundation

// MARK: - Snapshot

struct MissionMapSnapshot: Sendable, Equatable {
    /// One per pane, in window order: groups, then tabs, then split
    /// leaves.
    let cards: [MissionMapCard]
    let edges: [MissionMapEdge]
    /// The tab groups `cards` belong to, in window order.
    let groups: [MissionMapGroup]
}

struct MissionMapGroup: Identifiable, Sendable, Equatable {
    let id: UUID
    let name: String
}

// MARK: - Card

struct MissionMapCard: Identifiable, Sendable, Equatable {
    /// The pane's surface ID.
    let id: UUID
    let groupID: UUID
    let groupName: String
    let tabID: UUID
    /// The agent CLI's display name, or `nil` for a pane no agent has
    /// reported from.
    let kindLabel: String?
    let paneTitle: String
    let cwdLabel: String
    /// `nil` for a pane with no agent row: the card draws dimmed.
    let state: AgentState?
    /// "Tool: summary" for the agent's current tool call, if any.
    let toolLine: String?
    let children: [MissionMapChildCard]
    let unreadCount: Int
    let approval: MissionMapApproval?
    let git: MissionMapGitBadge?
    /// The surface a click focuses, or `nil` when nothing resolvable is
    /// behind the card (`AgentRowFocusTarget.resolve`'s own `nil`).
    let focusTarget: UUID?
}

/// One subagent row inside its parent's card.
struct MissionMapChildCard: Identifiable, Sendable, Equatable {
    /// The child's `SubagentEntry.agentID`.
    let id: String
    let agentType: String?
    let state: AgentState
    let toolLine: String?
}

/// A pending approval targeting a card's pane.
enum MissionMapApproval: Sendable, Equatable {
    /// A yes/no request the card can answer inline with its Allow button.
    case allowable(UUID)
    /// A request whose answer needs the approval panel itself (a question
    /// with options, or a consent prompt whose content must be read), so
    /// the card only offers to open it there.
    case openOnly(UUID)

    var requestID: UUID {
        switch self {
        case .allowable(let id), .openOnly(let id): return id
        }
    }
}

/// A pane's repository state, keyed by the pane's cwd in
/// `MissionMapGitPoller.badges`.
struct MissionMapGitBadge: Sendable, Equatable {
    /// `nil` on a detached HEAD.
    let branch: String?
    /// `nil` in a repository with no commit yet.
    let shortHash: String?
    /// Distinct paths `git status` reports, counted the same way
    /// `GitRepoChanges.changedFileCount` does.
    let changedFileCount: Int
}

// MARK: - Edge

struct MissionMapEdge: Identifiable, Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        /// An IPC message from `from`'s peer to `to`'s peer.
        case ipc(IPCMessageEvent)
        /// Both panes recently wrote `fullPath`; `file` is its last path
        /// component, the label drawn on the line.
        case conflict(file: String, fullPath: String)
    }

    let id: UUID
    /// Surface IDs of the two cards the line connects.
    let from: UUID
    let to: UUID
    let kind: Kind
}

// MARK: - Input

/// Everything `MissionMapSnapshotBuilder.build(input:)` reads, gathered
/// by the caller in one pass so the builder stays pure.
struct MissionMapInput: Sendable {
    /// The window's panes, in window order.
    let panes: [CockpitPaneInfo]
    /// Agent rows keyed by the pane surface they describe.
    let entries: [UUID: AgentEntry]
    /// Subagent children keyed by their parent's surface.
    let children: [UUID: [SubagentEntry]]
    let pendingApprovals: [ApprovalRequest]
    let ipcEvents: [IPCMessageEvent]
    /// `AgentRegistry.peerToSurfaceMap`.
    let peerToSurface: [UUID: UUID]
    /// `CalyxMCPServer.appPeerID`: Calyx's own peer, whose traffic is not
    /// agent-to-agent and is never drawn.
    let appPeerID: UUID?
    let editedFiles: [AgentEditedFile]
    /// Keyed by pane cwd.
    let git: [String: MissionMapGitBadge]
    let now: Date
    /// How far back an edit still counts toward a conflict line.
    let conflictWindow: TimeInterval
    /// How long an IPC line stays on screen after its message was sent.
    let ipcEdgeLifetime: TimeInterval
    /// The home directory cwd labels abbreviate to `~`. Injectable so
    /// the builder never reads process state its caller did not pass in.
    var homeDirectory: String = NSHomeDirectory()
}

// MARK: - Stable IDs

/// Deterministic UUIDs for snapshot identities that have no UUID of
/// their own (a tab group known only by name, one recipient's line of a
/// broadcast, a conflict pair). A fresh `UUID()` per build would give
/// the same line or group a new identity on every redraw, restarting its
/// animation and breaking selection. Same SHA-256 prefix construction as
/// `HerdrStableID`, under a Mission Map namespace.
enum MissionMapStableID {
    static func make(_ key: String) -> UUID {
        let digest = SHA256.hash(data: Data("calyx-mission-map:\(key)".utf8))
        let bytes = Array(digest.prefix(16))
        let raw: uuid_t = (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        )
        return UUID(uuid: raw)
    }
}
