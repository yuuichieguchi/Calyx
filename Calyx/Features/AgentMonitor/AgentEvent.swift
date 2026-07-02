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
}

extension AgentEntry {
    /// Human-readable label for `kind`, shown as the row's secondary
    /// line in `AgentStatusView`.
    static func displayName(forKind kind: String) -> String {
        switch kind {
        case "claude-code": return "Claude Code"
        default: return kind
        }
    }
}

// MARK: - AgentEvent

/// Decoded form of a Claude Code hook's stdin JSON payload
/// (`hook_event_name` / `session_id` / `cwd` / `message`, snake_case).
struct AgentEvent: Sendable, Equatable {
    let hookEventName: String
    let sessionID: String?
    let cwd: String?
    let message: String?

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
            message: object["message"] as? String
        )
    }
}
