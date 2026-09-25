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
    case hooks, mcpConnection, titleHeuristic
    /// A row sourced from an external agent runtime (herdr) rather than
    /// Calyx's own hooks/title-heuristic pipeline. Stored in
    /// `AgentRegistry.externalEntries`, a separate store from `entries`
    /// -- see that property's doc comment.
    case external
}

extension AgentSource {
    /// Whether a row from this source carries evidence the agent
    /// reports about itself, rather than evidence Calyx inferred by
    /// watching the pane. Only a self-reporting row can be aged out by
    /// the staleness sweep or settled by a pane-exit signal: an
    /// inferred row has no reliable last-event time and retires itself
    /// through its own miss-streak bookkeeping instead. `.external`
    /// rows are self-reported too, but they live in a separate store
    /// the resolver never sees.
    var isSelfReported: Bool {
        switch self {
        case .hooks, .mcpConnection, .external: return true
        case .titleHeuristic: return false
        }
    }
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
    /// surface, kept in sync by `AgentRegistry.syncInboxCounts` from
    /// `IPCStore`'s current inbox count.
    var unreadCount: Int = 0
    /// The Calyx surface (if any) an `.external` entry's row should
    /// focus when clicked -- an external entry's own `surfaceID` is not
    /// necessarily a Calyx `SurfaceRegistry` UUID, so this is a
    /// separate, optional pointer to a Calyx-hosted surface that
    /// represents the same agent (if one exists). `nil` for every
    /// Native (`.hooks`/`.mcpConnection`/`.titleHeuristic`) entries, whose
    /// own `surfaceID` already IS the surface to focus. Defaulted so every
    /// existing call site
    /// is unaffected.
    var focusSurfaceID: UUID? = nil
    /// The tool the agent's own (parent, never subagent) turn most
    /// recently started, from its `PreToolUse` event's `toolName`, and
    /// that call's `AgentEvent.toolSummary`. Kept through `PostToolUse`
    /// (the call finished, but it is still the last thing the turn did)
    /// and cleared by `Stop` / `SessionEnd` / `UserPromptSubmit`, after
    /// which no tool call is in flight -- see
    /// `AgentResolution.withCurrentTool(from:)`. Mission Map's card shows
    /// these as its tool line. Defaulted so every existing call site is
    /// unaffected.
    var currentToolName: String? = nil
    var currentToolSummary: String? = nil
}

extension AgentEntry {
    /// Human-readable label for `kind`, shown as the row's secondary
    /// line in `AgentStatusView`.
    static func displayName(forKind kind: String) -> String {
        switch kind {
        case Self.claudeCodeKind: return "Claude Code"
        case Self.codexKind: return "Codex"
        case Self.openCodeKind: return "OpenCode"
        case Self.hermesKind: return "Hermes Agent"
        case Self.grokKind: return "Grok"
        // pi's product name is lowercase.
        case Self.piKind: return "pi"
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
    static let hermesKind = "hermes"
    /// Grok's `kind`: `GrokHooksConfigManager`'s installed `command`
    /// argument and `GrokConfigManager`'s `X-Calyx-Agent-Kind` header
    /// both resolve to this.
    static let grokKind = "grok"
    /// pi's `kind`. Keep in sync with the `"pi"` literal in
    /// `PiExtensionManager.scriptBody`'s `X-Calyx-Agent-Kind` header:
    /// that value lives in a TypeScript string embedded in a Swift string
    /// constant, so it cannot reference this constant directly.
    static let piKind = "pi"
}

// MARK: - AgentEvent

/// Decoded form of a Claude Code hook's stdin JSON payload
/// (`hook_event_name` / `session_id` / `cwd` / `message`, snake_case), or
/// of Grok's camelCase equivalent normalized onto the same field and
/// event-name vocabulary -- see `decode(from:)`.
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

    /// The child agent's own identity for an event fired inside a
    /// subagent -- claude-code's `agent_id` (present on every hook event
    /// fired inside a subagent, including `PreToolUse`/`PostToolUse`),
    /// Grok's own child `sessionId` (Grok has no `agent_id` field at all;
    /// see `decodeGrokShaped`), or Codex's `agent_id` (present only on
    /// `SubagentStart`/`SubagentStop`, per Codex's own docs that its
    /// other subagent hooks reuse the parent session's id). `nil` for
    /// every main-thread event. `isSubagentEvent` is `agentID != nil` and
    /// nothing else -- see that property's doc comment for why
    /// `agentType` must never be folded into the predicate.
    var agentID: String? = nil
    /// The child agent's type name (claude-code's `agent_type`, Grok's
    /// `subagentType`). Also present, WITHOUT `agentID`, on a claude-code
    /// main-thread event whose session was started with `claude --agent
    /// foo` -- so `agentType` alone never means "this is a subagent
    /// event".
    var agentType: String? = nil
    /// The tool name a `PreToolUse`/`PostToolUse` event names, mirrored
    /// here (independent of `ipcSelfPeerID`'s own tool-name matching) so
    /// `SubagentRegistry` can show a child row's most recently used tool
    /// without re-parsing the raw payload.
    var toolName: String? = nil
    /// The tool-specific human-readable string derived from a
    /// `PreToolUse`/`PostToolUse` event's tool-input object (the command
    /// for a shell tool, the file path for a file tool, the URL for a
    /// fetch, the object's own arguments as readable `key: value` pairs
    /// for anything else --
    /// `AgentToolSummary.derive(toolName:toolInput:fallback:)`, the same
    /// derivation the approval banner uses), rendered as one line and
    /// capped at `AgentToolSummary.maxSummaryLength` visible characters
    /// by `AgentToolSummary.singleLineSummary(_:)`: every run of
    /// whitespace collapses to a single space, so a heredoc command
    /// still reads on the row's one line. `nil` when the payload
    /// carries no tool-input object, or the derivation yields an empty
    /// string -- never an empty string, which a row would render as a
    /// bare separator.
    var toolSummary: String? = nil
    /// The file paths a `PreToolUse` event's tool call is about to
    /// write (`AgentEditedFileExtractor.paths(toolName:toolInput:)`),
    /// which `AgentRegistry.handleHookEvent` records into
    /// `AgentEditedFileLog` for Mission Map's conflict lines. Always
    /// empty for every other event: a `PostToolUse` names a call that
    /// already ran, so recording it would only duplicate the edit its
    /// own `PreToolUse` already recorded.
    var editedFilePaths: [String] = []

    /// Whether this event fired inside a subagent rather than the main
    /// thread. The ONLY subagent predicate in the codebase: `agentType`
    /// alone is not sufficient, because claude-code also sets it (without
    /// `agentID`) on a main-thread event whose session was started with
    /// `claude --agent foo` -- folding `agentType` into this check would
    /// permanently freeze that session's parent row, since every one of
    /// its events would then read as a child's.
    var isSubagentEvent: Bool { agentID != nil }

    /// Decodes a hook's stdin JSON payload. `hook_event_name` is mandatory;
    /// all other fields are optional. Unknown fields are tolerated.
    ///
    /// A payload that names no `hook_event_name` at all but does name
    /// `hookEventName` is Grok's envelope and goes through
    /// `decodeGrokShaped` instead: Grok spells every key in camelCase and
    /// every event value in snake_case, and a `/bin/sh` hook script cannot
    /// rewrite JSON, so the normalization happens here. A payload carrying
    /// both keys is a Claude Code / Codex payload and stays on the
    /// snake_case path, which reads no camelCase alias of any field.
    static func decode(from data: Data) -> AgentEvent? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if object["hook_event_name"] == nil, object["hookEventName"] != nil {
            return decodeGrokShaped(object: object)
        }
        guard let hookEventName = object["hook_event_name"] as? String else {
            return nil
        }
        return AgentEvent(
            hookEventName: hookEventName,
            sessionID: object["session_id"] as? String,
            cwd: object["cwd"] as? String,
            message: object["message"] as? String,
            ipcSelfPeerID: extractIPCSelfPeerID(hookEventName: hookEventName, object: object),
            agentID: object["agent_id"] as? String,
            agentType: object["agent_type"] as? String,
            toolName: object["tool_name"] as? String,
            toolSummary: toolSummary(toolName: object["tool_name"] as? String, toolInput: object["tool_input"]),
            editedFilePaths: editedFilePaths(
                hookEventName: hookEventName,
                toolName: object["tool_name"] as? String,
                toolInput: object["tool_input"]
            )
        )
    }

    /// The single-line, capped, empty-mapped-to-nil summary for one
    /// event's tool name and raw tool-input value. `toolInput` is passed
    /// in as `Any?` so both envelopes supply their own key spelling
    /// (`tool_input` / `toolInput`) and share every other rule.
    private static func toolSummary(toolName: String?, toolInput: Any?) -> String? {
        guard let toolName, let toolInput = toolInput as? [String: Any] else { return nil }
        let derived = AgentToolSummary.derive(
            toolName: toolName, toolInput: toolInput,
            fallback: AgentToolSummary.readableArguments(toolInput)
        )
        let line = AgentToolSummary.singleLineSummary(derived)
        return line.isEmpty ? nil : line
    }

    /// `AgentEditedFileExtractor.paths` for a `PreToolUse` event, `[]`
    /// for every other event. `hookEventName` is the already-normalized
    /// name, so Grok's `pre_tool_use` qualifies through the same check.
    private static func editedFilePaths(hookEventName: String, toolName: String?, toolInput: Any?) -> [String] {
        guard hookEventName == "PreToolUse", let toolName, let toolInput = toolInput as? [String: Any] else {
            return []
        }
        return AgentEditedFileExtractor.paths(toolName: toolName, toolInput: toolInput)
    }

    /// Grok's `stop` `reason` for a genuine turn end. Grok fires an extra
    /// observe-only `stop` at session teardown with `channel_closed` or
    /// `shutdown`; treating those as turn ends would roll a
    /// `SessionEnd`-settled `.done` row back to `.idle`.
    private static let grokTurnEndReason = "end_turn"

    /// The one `notificationType` that fires while a permission UI is
    /// actually waiting. The accompanying `message` is display text that
    /// changes between releases, so the type is what gets matched.
    private static let grokPermissionNotificationType = "permission_prompt"

    /// Decodes Grok's camelCase envelope. `hookEventName` is the only
    /// field Grok guarantees; everything else is optional.
    ///
    /// An event carrying a non-empty `subagentType` happened inside a
    /// child agent. Grok has no `agent_id` field, so `agentID` is derived
    /// from `subagentId` when present, falling back to `sessionId`. Grok
    /// names the child differently depending on which event fires:
    /// `subagent_start` carries the PARENT's `sessionId` and names the
    /// child only through `subagentId`, while every other child-scoped
    /// event (`pre_tool_use`, `post_tool_use`, `session_end`, etc.)
    /// carries the CHILD's own `sessionId` and no `subagentId` at all.
    /// Preferring `subagentId` when it is present yields one stable key,
    /// the child's own session id, across every event of that child's
    /// life -- without the fallback, `subagent_start` would key the
    /// child on the parent's session id instead, and no later event
    /// would ever match that key. `sessionID` / `cwd` are still stripped
    /// from the shared field either way: recording a child's session ID
    /// into the pane's resume meta would make a later reattach offer
    /// `grok --resume <child>`. The structural guard against a child
    /// event touching the host pane's row is `AgentEvent.isSubagentEvent`,
    /// checked in `AgentStateResolver.resolveHookRow`, so the event name
    /// is mapped through the same `grokEventName` table every other
    /// event uses -- `SubagentRegistry` needs a mapped name to derive the
    /// child's own state.
    ///
    /// A non-empty `subagentType` with neither `subagentId` nor
    /// `sessionId` carries no usable identity for the child, so the event
    /// name is left unmapped (as it always was) and nothing acts on it.
    ///
    /// No `ipcSelfPeerID` is extracted here: Grok binds its peer through
    /// the MCP `initialize` surface header rather than through tool
    /// arguments.
    private static func decodeGrokShaped(object: [String: Any]) -> AgentEvent? {
        guard let rawEventName = object["hookEventName"] as? String else { return nil }

        let rawSubagentType = object["subagentType"] as? String
        let subagentType = (rawSubagentType?.isEmpty == false) ? rawSubagentType : nil
        let agentID = subagentType != nil
            ? (object["subagentId"] as? String ?? object["sessionId"] as? String)
            : nil
        let hasIdentity = subagentType != nil && agentID != nil

        let mappedEventName = hasIdentity || subagentType == nil
            ? grokEventName(rawEventName, object: object) : rawEventName
        return AgentEvent(
            hookEventName: mappedEventName,
            sessionID: subagentType != nil ? nil : object["sessionId"] as? String,
            cwd: subagentType != nil ? nil : object["cwd"] as? String,
            message: object["message"] as? String,
            ipcSelfPeerID: nil,
            agentID: agentID,
            agentType: subagentType,
            toolName: object["toolName"] as? String,
            toolSummary: toolSummary(toolName: object["toolName"] as? String, toolInput: object["toolInput"]),
            editedFilePaths: editedFilePaths(
                hookEventName: mappedEventName,
                toolName: object["toolName"] as? String,
                toolInput: object["toolInput"]
            )
        )
    }

    /// Maps a Grok event value onto the event vocabulary
    /// `AgentStateResolver.resultingState` reads. An unmapped name is passed
    /// through verbatim so the registry ignores it rather than the
    /// decoder inventing a state change.
    private static func grokEventName(_ rawEventName: String, object: [String: Any]) -> String {
        switch rawEventName {
        case "session_start":
            return "SessionStart"
        case "user_prompt_submit":
            return "UserPromptSubmit"
        case "pre_tool_use":
            return "PreToolUse"
        case "post_tool_use", "post_tool_use_failure":
            // A failed tool call still means the turn is running.
            return "PostToolUse"
        case "stop":
            guard let reason = object["reason"] as? String else { return "Stop" }
            return reason == grokTurnEndReason ? "Stop" : rawEventName
        case "stop_failure", "stop_cancelled":
            // Either runs instead of `stop` when a turn ends on an API
            // error or without completing: the turn is over either way.
            return "Stop"
        case "session_end":
            return "SessionEnd"
        case "subagent_start":
            return "SubagentStart"
        case "subagent_stop", "subagent_end":
            // subagent_end is documented as an alias of subagent_stop.
            return "SubagentStop"
        case "notification":
            return (object["notificationType"] as? String) == grokPermissionNotificationType
                ? "PermissionRequest" : "Notification"
        default:
            return rawEventName
        }
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
