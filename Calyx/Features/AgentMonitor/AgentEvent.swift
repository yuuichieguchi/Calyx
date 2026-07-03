// AgentEvent.swift
// Calyx
//
// Data model for AI agent lifecycle state (AgentEntry) and the decoded form
// of a Claude Code hook's stdin JSON payload (AgentEvent).

import Foundation

// MARK: - AgentState

enum AgentState: Sendable, Equatable {
    case blocked, working, done, idle
}

// MARK: - AgentSource

enum AgentSource: Sendable, Equatable {
    case hooks, titleHeuristic
}

// MARK: - AgentEntry

struct AgentEntry: Identifiable, Sendable, Equatable {
    var id: UUID { surfaceID }
    let surfaceID: UUID
    var sessionID: String?
    var source: AgentSource
    var state: AgentState
    var cwd: String?
    /// Identifies which agent CLI this entry belongs to. Always
    /// `"claude-code"` in v1 (the only integration `AgentRegistry` wires
    /// up); Phase 2 adds `"codex"` / `"opencode"` alongside their own
    /// hook/plugin sources.
    var kind: String
    var lastEventAt: Date
    /// Count of unread IPC messages waiting for the peer bound to this
    /// surface, kept in sync by `AgentRegistry.updateInbox` /
    /// `syncInboxCounts` from `IPCStore`'s current inbox count.
    var unreadCount: Int = 0
}

extension AgentEntry {
    /// Human-readable label for `kind`, shown as the row's secondary
    /// line in `AgentStatusView`.
    static func displayName(forKind kind: String) -> String {
        switch kind {
        case Self.claudeCodeKind: return "Claude Code"
        case Self.codexKind: return "Codex"
        case Self.openCodeKind: return "OpenCode"
        default: return kind
        }
    }
}

extension AgentEntry {
    /// `kind` constants for the three agent CLIs `AgentRegistry` produces
    /// entries for: `AgentHookScript`'s `$1` argv default for Claude Code,
    /// `CodexHooksConfigManager`'s installed `command` argument for Codex,
    /// and `OpenCodePluginManager`'s `X-Calyx-Agent-Kind` header for
    /// OpenCode all resolve to one of these three.
    static let claudeCodeKind = "claude-code"
    static let codexKind = "codex"
    /// Keep in sync with the `"opencode"` literal in
    /// `OpenCodePluginManager.scriptBody`'s `X-Calyx-Agent-Kind` header —
    /// that value lives in a JS string embedded in a Swift string constant,
    /// so it can't reference this constant directly.
    static let openCodeKind = "opencode"
}

// MARK: - AgentEvent

/// Decoded form of a Claude Code hook's stdin JSON payload
/// (`hook_event_name` / `session_id` / `cwd` / `message`, snake_case).
struct AgentEvent: Sendable, Equatable {
    let hookEventName: String
    let sessionID: String?
    let cwd: String?
    let message: String?
    /// For a `PreToolUse` event whose `tool_name` is one of Calyx's own
    /// `mcp__calyx-ipc__*` tools, this surface's own peer ID (extracted
    /// from `tool_input.from` for `send_message`/`broadcast`, or
    /// `tool_input.peer_id` for `receive_messages`) — or,
    /// for a `PostToolUse` event whose `tool_name` is
    /// `mcp__calyx-ipc__register_peer`, the peer ID the server just
    /// generated for this surface (`tool_response.peerId`) — used by
    /// `AgentRegistry` to learn the surface-to-peer binding that drives
    /// unread-message badges. Registering the binding right at
    /// `register_peer` itself (rather than waiting for this surface's
    /// first `send_message`/`receive_messages`/etc. call) means an
    /// unread message sent to it immediately after registration still
    /// lights up the badge. `nil` for every other event / tool
    /// (including `list_peers`, which carries no self-identifying peer
    /// ID field).
    ///
    /// `var`, not `let`: a stored property needs `var` for Swift to
    /// include it as an overridable (rather than permanently
    /// default-only) parameter in the synthesized memberwise
    /// initializer — see SE-0242. Every mutation in practice still goes
    /// through `decode(from:)`'s single construction site.
    var ipcSelfPeerID: String? = nil

    /// Decodes a hook's stdin JSON payload. `hook_event_name` is mandatory;
    /// all other fields are optional. Unknown fields are tolerated.
    static func decode(from data: Data) -> AgentEvent? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hookEventName = object["hook_event_name"] as? String else {
            return nil
        }
        return AgentEvent(
            hookEventName: hookEventName,
            sessionID: object["session_id"] as? String,
            cwd: object["cwd"] as? String,
            message: object["message"] as? String,
            ipcSelfPeerID: extractIPCSelfPeerID(hookEventName: hookEventName, object: object)
        )
    }

    /// `tool_name`s whose self peer ID is carried in `tool_input.from`
    /// (the sender identifies itself when originating a message).
    private static let fromKeyToolNames: Set<String> = [
        "mcp__calyx-ipc__send_message", "mcp__calyx-ipc__broadcast",
    ]

    /// `tool_name`s whose self peer ID is carried in `tool_input.peer_id`
    /// (the caller identifies itself when reading its own inbox).
    private static let peerIDKeyToolNames: Set<String> = [
        "mcp__calyx-ipc__receive_messages",
    ]

    /// The one `tool_name` whose self peer ID is learned from its
    /// `PostToolUse` response (`tool_response.peerId`) rather than from
    /// `PreToolUse`'s `tool_input` — `register_peer` is the only
    /// `calyx-ipc` tool call that doesn't already know its own peer ID
    /// going in; the server generates it, so it's only available once
    /// the call has returned.
    private static let registerPeerToolName = "mcp__calyx-ipc__register_peer"

    private static func extractIPCSelfPeerID(hookEventName: String, object: [String: Any]) -> String? {
        guard let toolName = object["tool_name"] as? String else { return nil }

        if hookEventName == "PreToolUse", let toolInput = object["tool_input"] as? [String: Any] {
            if fromKeyToolNames.contains(toolName) {
                return toolInput["from"] as? String
            }
            if peerIDKeyToolNames.contains(toolName) {
                return toolInput["peer_id"] as? String
            }
        }

        if hookEventName == "PostToolUse", toolName == registerPeerToolName,
           let toolResponse = object["tool_response"] as? [String: Any] {
            return toolResponse["peerId"] as? String
        }

        return nil
    }
}
