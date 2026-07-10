// AgentHookPermissionResponse.swift
// Calyx
//
// The PreToolUse hook stdout body Calyx writes back to a CLI agent to
// carry a human's approval decision into that CLI's own permission
// gate -- shape and field names follow Claude Code's own hook-response
// contract (`hookSpecificOutput.permissionDecision`), which Codex also
// understands for allow/deny; Codex has no "ask" analog, so an expired
// decision there produces no body at all.
//
// FAIL-SAFE CONTRACT: `body(kind:decision:)` returns `nil` for any
// `kind` other than `AgentEntry.claudeCodeKind` / `AgentEntry.codexKind`.
// Calyx must never inject a permission decision into a CLI hook
// protocol it doesn't recognize -- guessing at an unknown CLI's own
// stdout shape risks either silently authorizing a dangerous action or
// corrupting that CLI's own parsing of its hook's output.

import Foundation

enum AgentHookPermissionResponse {

    /// Builds the JSON body for a CLI agent's PreToolUse hook stdout,
    /// encoding `decision` in that CLI's own `permissionDecision` shape.
    /// `nil` for any `kind` other than `claude-code`/`codex` (see this
    /// file's header), and also for `codex` + `.expired` (no "ask"
    /// analog there).
    static func body(kind: String, decision: ApprovalDecision) -> Data? {
        switch kind {
        case AgentEntry.claudeCodeKind:
            return encode(permissionDecision: claudePermissionDecision(for: decision))
        case AgentEntry.codexKind:
            guard let permissionDecision = codexPermissionDecision(for: decision) else { return nil }
            return encode(permissionDecision: permissionDecision)
        default:
            return nil
        }
    }

    private static func claudePermissionDecision(for decision: ApprovalDecision) -> String {
        switch decision {
        case .allowed: return "allow"
        case .denied: return "deny"
        case .expired: return "ask"
        }
    }

    private static func codexPermissionDecision(for decision: ApprovalDecision) -> String? {
        switch decision {
        case .allowed: return "allow"
        case .denied: return "deny"
        case .expired: return nil
        }
    }

    private static func encode(permissionDecision: String) -> Data? {
        let object: [String: Any] = [
            "hookSpecificOutput": [
                "hookEventName": "PreToolUse",
                "permissionDecision": permissionDecision,
                "permissionDecisionReason": permissionDecisionReason(for: permissionDecision),
            ],
        ]
        return try? JSONSerialization.data(withJSONObject: object)
    }

    /// A short, non-empty, human-readable reason surfaced by the CLI
    /// alongside its permission decision.
    private static func permissionDecisionReason(for permissionDecision: String) -> String {
        switch permissionDecision {
        case "allow": return "Approved from the Calyx approval inbox."
        case "deny": return "Denied from the Calyx approval inbox."
        default: return "The approval request expired without a response."
        }
    }
}
