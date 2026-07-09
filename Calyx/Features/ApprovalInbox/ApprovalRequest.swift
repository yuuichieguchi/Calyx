// ApprovalRequest.swift
// Calyx
//
// Cockpit approval-core data model: a pending gated action (e.g. an MCP
// tool call) waiting on a human decision from the approval inbox. See
// ApprovalInboxStore for the queueing/decision lifecycle and
// ApprovalPolicy for whether a given action requires approval at all.

import Foundation

struct ApprovalRequest: Identifiable, Sendable {
    enum Source: Sendable, Equatable {
        case mcpTool(name: String)
        /// A `PreToolUse` call intercepted from a non-MCP CLI agent hook
        /// (Claude Code / Codex) rather than Calyx's own MCP server --
        /// `kind` identifies the owning CLI (`AgentEntry.claudeCodeKind`
        /// / `AgentEntry.codexKind`); `toolName` and `summary` come from
        /// the decoded `AgentHookToolCall`.
        case agentHook(toolName: String, kind: String, summary: String)
    }

    let id: UUID
    let source: Source
    let targetSurfaceID: UUID?
    let payload: String
    let createdAt: Date
}

enum ApprovalDecision: Sendable, Equatable {
    case allowed
    case denied
    case expired
}

extension ApprovalRequest {
    /// The tool-name label `ApprovalBannerView` renders in its header.
    /// RAW, unescaped -- escaping untrusted text for display is
    /// `ControlCharacterDisplay`'s job, applied later in the view layer,
    /// not here. `.mcpTool` is just the tool's own name (today's
    /// semantics, unchanged); `.agentHook` combines the owning CLI's
    /// display label (`AgentEntry.displayName(forKind:)`) with the tool
    /// name, since an agent-hook call has no MCP tool name of its own.
    var displayToolName: String {
        switch source {
        case .mcpTool(let name):
            return name
        case .agentHook(let toolName, let kind, _):
            return "\(AgentEntry.displayName(forKind: kind)) · \(toolName)"
        }
    }

    /// The payload text `ApprovalBannerView` renders in its body. RAW,
    /// unescaped, same caveat as `displayToolName` above. `.mcpTool`
    /// reuses `payload` unchanged (today's semantics); `.agentHook` uses
    /// the hook call's own `summary` instead -- `payload` there is the
    /// full (and possibly large) `tool_input` JSON, not what's meant for
    /// display.
    var displayPayload: String {
        switch source {
        case .mcpTool:
            return payload
        case .agentHook(_, _, let summary):
            return summary
        }
    }
}
