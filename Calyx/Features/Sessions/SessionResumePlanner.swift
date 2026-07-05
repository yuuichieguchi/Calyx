// SessionResumePlanner.swift
// Calyx
//
// Decides whether/how to resume an agent CLI's conversation inside a
// reattached persistent-session pane. Consumes the agent CLI's own
// session identifier (`agentSessionID`) once `AgentSessionMetaBridge`
// has recorded it into the daemon's per-session meta map under this
// type's own key convention (`encodeMetaKey(kind:)`), keyed by one of
// `AgentEntry`'s `kind` constants (`"claude-code"` etc).
//
// Pure function group — no I/O, no actor isolation required, same
// shape as `SessionCommandSynthesizer`.
//
// Green-phase implementation: pure string formatting only, no I/O.

import Foundation

enum SessionResumePlanner {

    /// Meta-key namespace prefix: a resumable agent session is stored
    /// under `"agent.<kind>"` (e.g. `"agent.claude-code"`), where
    /// `<kind>` matches one of `AgentEntry`'s `kind` constants.
    private static let metaKeyPrefix = "agent."

    /// The daemon meta key an agent session of `kind` is stored under.
    static func encodeMetaKey(kind: String) -> String {
        metaKeyPrefix + kind
    }

    /// The reverse of `encodeMetaKey(kind:)`: extracts `kind` back out
    /// of a meta key, or `nil` if `key` doesn't carry the
    /// `metaKeyPrefix` namespace (or the remainder after it is empty).
    static func decodeMetaKey(_ key: String) -> String? {
        guard key.hasPrefix(metaKeyPrefix) else { return nil }
        let kind = String(key.dropFirst(metaKeyPrefix.count))
        return kind.isEmpty ? nil : kind
    }

    /// The shell command that resumes `agentKind`'s CLI conversation
    /// `agentSessionID`, or `nil` when `agentKind` isn't a resumable
    /// agent CLI, or `agentSessionID` is empty/invalid.
    static func resumeCommand(agentKind: String, agentSessionID: String) -> String? {
        guard !agentSessionID.isEmpty else { return nil }
        switch agentKind {
        case AgentEntry.claudeCodeKind:
            return "claude --resume \(agentSessionID)"
        default:
            // Other agent kinds (e.g. Codex) have no known resume
            // invocation yet — future work, not this phase.
            return nil
        }
    }

    /// The literal text to inject as a reattached persistent-session
    /// pane's initial input once `resumeCommand` resolves: with no
    /// trailing newline in "propose" mode (the user presses Return
    /// themselves), or with one in "auto-execute" mode
    /// (`SessionSettings.agentResumeAutoExecute`).
    static func initialInput(agentKind: String, agentSessionID: String, autoExecute: Bool) -> String? {
        guard let command = resumeCommand(agentKind: agentKind, agentSessionID: agentSessionID) else {
            return nil
        }
        return autoExecute ? command + "\n" : command
    }
}
