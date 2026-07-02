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
