// GrokHooksConfigManager.swift
// Calyx
//
// Manages `~/.grok/hooks/calyx.json`, a Grok hook file Grok auto-loads
// and always trusts (global hooks under `~/.grok/hooks/` need no
// folder-trust grant). Grok merges every `.json` file in that directory,
// so this one is entirely Calyx's own: install is a plain whole-file
// overwrite and remove is a plain delete, like
// `OpenCodePluginManager`'s plugin file, rather than
// `CodexHooksConfigManager`'s BEGIN/END managed block inside a config
// the CLI also writes to.
//
// `PreToolUse` carries two handlers: the fire-and-forget
// `calyx-agent-hook` state ping, and the synchronous
// `calyx-approval-hook` gate whose stdout becomes Grok's own decision.
// Grok has no `PermissionRequest` event, so `PreToolUse` (its one
// blocking event) is where the approval gate has to live. The entry
// carries no matcher and fires for every tool call in every permission
// mode; which of those Calyx actually holds for a human is decided
// server-side from the payload's own `permissionMode`
// (`ApprovalHookEvent.gateIsSoleAuthority`), which is why the hook
// script forwards stdin verbatim and carries no branch of its own.
//
// The approval entry states an explicit `timeout`. Grok's default hook
// timeout is 5 seconds; only `Stop` and `SubagentStop` default to 600.
// A gate that blocks while a human decides would otherwise be killed at
// 5 seconds and fail open, so the value is interpolated from
// `ApprovalHookTiming.hookEntryTimeoutSeconds` rather than written as a
// literal, keeping the nesting invariant that type documents (server
// answers by 570s, curl gives up at 585s, the CLI kills the hook at
// 600s) impossible to drift out of sync with.

import Foundation

// MARK: - GrokHooksConfigError

enum GrokHooksConfigError: Error, LocalizedError {
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .writeFailed(let reason):
            return "Failed to write Grok hooks file: \(reason)"
        }
    }
}

// MARK: - GrokHooksConfigManager

struct GrokHooksConfigManager: Sendable {

    // MARK: - Constants

    /// Calyx's own file inside `~/.grok/hooks/`. Grok merges every
    /// `.json` file in that directory, so a dedicated name keeps Calyx's
    /// entries from ever colliding with a user's own hook file.
    static let fileName = "calyx.json"

    // MARK: - Public API

    /// Writes the Calyx-owned hook file at `configPath`, creating its
    /// parent directory when absent, replacing any previous contents
    /// wholesale. `AgentHooksCoordinator.installGrok` already gates this
    /// call on the Grok config root existing, so this function does not
    /// repeat that check.
    ///
    /// Every handler is invoked with an explicit `grok` argument:
    /// `"<scriptPath>" grok` for the state pings, `"<approvalScriptPath>"
    /// grok` for the approval gate. The event keys are `SessionStart`,
    /// `UserPromptSubmit`, `PreToolUse`, `PostToolUse`,
    /// `PostToolUseFailure`, `Stop`, `StopFailure`, `StopCancelled`,
    /// `SessionEnd`, `Notification`, `SubagentStart`, and `SubagentStop`.
    ///
    /// `PreToolUse` carries both handlers, the agent hook first: Grok
    /// runs handlers in config order until one returns `deny`, so the
    /// state ping must not sit behind a gate that can block for minutes.
    ///
    /// `Notification` carries `matcher: "permission_prompt"`, the only
    /// notification type that fires while a permission UI is actually
    /// waiting. `Stop` carries an explicit `timeout` of 10: Grok defaults
    /// `Stop` and `SubagentStop` to 600 seconds because they are gates
    /// commonly used to run builds, and this handler is a fire-and-forget
    /// local POST sitting on the turn's critical path. Every other state
    /// ping takes Grok's 5-second observe default.
    static func installHooks(
        scriptPath: String, approvalScriptPath: String, configPath: String? = nil
    ) throws {
        let path = try ConfigFileUtils.resolveConfigPath(configPath ?? defaultConfigPath)
        let hooksDirectory = (path as NSString).deletingLastPathComponent

        if !FileManager.default.fileExists(atPath: hooksDirectory) {
            try FileManager.default.createDirectory(
                atPath: hooksDirectory, withIntermediateDirectories: true
            )
        }

        let agentCommand = command(scriptPath: scriptPath)
        var hooks: [String: Any] = [:]
        for event in statePingEvents {
            hooks[event.key] = [group(handlers: [handler(command: agentCommand, timeout: event.timeout)])]
        }
        hooks[ApprovalHookEvent.grokRegistrationName] = [group(handlers: [
            handler(command: agentCommand, timeout: nil),
            handler(
                command: command(scriptPath: approvalScriptPath),
                timeout: ApprovalHookTiming.hookEntryTimeoutSeconds
            ),
        ])]
        hooks[notificationEventKey] = [group(
            handlers: [handler(command: agentCommand, timeout: nil)],
            matcher: permissionPromptMatcher
        )]

        guard let data = try? JSONSerialization.data(
            withJSONObject: ["hooks": hooks], options: [.prettyPrinted, .sortedKeys]
        ) else {
            throw GrokHooksConfigError.writeFailed("JSON encoding failed")
        }
        // 0600: Calyx owns this file outright.
        try ConfigFileUtils.withExclusiveConfig(path: path, mode: 0o600, restoreModeOnNoWrite: true) { _ in data }
    }

    /// Deletes the Calyx-owned hook file. A no-op when it does not
    /// exist. Resolves a symlinked path and removes the real target, so
    /// a dotfiles-managed hooks directory keeps its link rather than
    /// losing it while the installed file survives.
    static func removeHooks(configPath: String? = nil) throws {
        let path = configPath ?? defaultConfigPath
        try ConfigFileUtils.withExclusiveConfig(path: path) { _ in nil }
    }

    /// Whether the Calyx-owned hook file exists and names
    /// `AgentHookScript.fileName` in at least one handler command. A file
    /// at Calyx's own path naming no Calyx script is somebody else's, so
    /// a launch-time resync must not treat it as an install and overwrite
    /// it.
    static func areHooksInstalled(configPath: String? = nil) -> Bool {
        guard let path = try? ConfigFileUtils.resolveConfigPath(configPath ?? defaultConfigPath),
              let data = FileManager.default.contents(atPath: path),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = root["hooks"] as? [String: Any] else {
            return false
        }
        return hooks.values.contains { event in
            guard let groups = event as? [[String: Any]] else { return false }
            return groups.contains { group in
                guard let handlers = group["hooks"] as? [[String: Any]] else { return false }
                return handlers.contains {
                    ($0["command"] as? String)?.contains(AgentHookScript.fileName) == true
                }
            }
        }
    }

    // MARK: - Private: Hook File Construction

    /// One event key per state ping, with the `timeout` that key states
    /// explicitly. Grok's hook default is 5 seconds, ample for a loopback
    /// POST, so only `Stop` and `SubagentStop` override it: Grok defaults
    /// both to 600 seconds because those gates commonly run builds (or,
    /// for `SubagentStop`, simply take a while), and this handler is a
    /// fire-and-forget POST sitting on the turn's (or the child's own
    /// exit) critical path.
    private static let statePingEvents: [(key: String, timeout: Int?)] = [
        ("SessionStart", nil),
        ("UserPromptSubmit", nil),
        ("PostToolUse", nil),
        ("PostToolUseFailure", nil),
        ("Stop", 10),
        ("StopFailure", nil),
        ("StopCancelled", nil),
        ("SessionEnd", nil),
        ("SubagentStart", nil),
        ("SubagentStop", 10),
    ]

    private static let notificationEventKey = "Notification"

    /// `Notification`'s matcher tests the notification type.
    /// `permission_prompt` is the only type that fires while a permission
    /// UI is actually waiting; an unfiltered `Notification` would fire on
    /// `idle_prompt` and `task_complete` too and paint the row blocked
    /// when nothing is waiting.
    private static let permissionPromptMatcher = "permission_prompt"

    /// `"<scriptPath>" grok`: the path is double-quoted because the real
    /// install directory contains a space, and the explicit kind argument
    /// is what keeps the script from defaulting to claude-code.
    private static func command(scriptPath: String) -> String {
        "\"\(scriptPath)\" \(AgentEntry.grokKind)"
    }

    private static func handler(command: String, timeout: Int?) -> [String: Any] {
        var handler: [String: Any] = ["type": "command", "command": command]
        if let timeout {
            handler["timeout"] = timeout
        }
        return handler
    }

    /// A matcher group. An omitted `matcher` matches everything; one on
    /// `Stop` or `UserPromptSubmit` is ignored with a warning, and one on
    /// a tool event would silently drop fires the row depends on.
    private static func group(handlers: [[String: Any]], matcher: String? = nil) -> [String: Any] {
        var group: [String: Any] = ["hooks": handlers]
        if let matcher {
            group["matcher"] = matcher
        }
        return group
    }

    // MARK: - Config Path

    static var defaultConfigPath: String {
        AgentToolPaths.grokConfigDirectory + "/hooks/" + fileName
    }
}
