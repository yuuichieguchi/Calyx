// ClaudeHooksConfigManager.swift
// Calyx
//
// Manages the "hooks" section of ~/.claude/settings.json for the
// calyx-agent-hook lifecycle hook. Mirrors ClaudeConfigManager's API shape
// and file-safety guarantees (symlink rejection, .bak backup, atomic
// write) via the same shared `ConfigFileUtils.readConfigWithBackup`.

import Foundation

struct ClaudeHooksConfigManager: Sendable {

    /// The 7 hook events Calyx installs a command entry for, and the
    /// `matcher` each uses (`nil` means no `"matcher"` key is written —
    /// Claude Code treats an absent matcher as "always run").
    private static let targetEvents: [(name: String, matcher: String?)] = [
        ("SessionStart", nil),
        ("UserPromptSubmit", nil),
        ("PreToolUse", "*"),
        ("PostToolUse", "*"),
        ("Notification", "permission_prompt"),
        ("Stop", nil),
        ("SessionEnd", nil),
    ]

    // MARK: - Public API

    /// Merges Calyx's 7 hook entries into `configPath`'s `"hooks"` section,
    /// preserving the user's own existing hook entries and unrelated
    /// top-level keys. Idempotent: re-running replaces Calyx's own prior
    /// entries rather than duplicating them.
    static func installHooks(scriptPath: String, configPath: String? = nil) throws {
        let path = configPath ?? defaultConfigPath

        var config = try ConfigFileUtils.readConfigWithBackup(path: path)

        var hooks = config["hooks"] as? [String: Any] ?? [:]

        for target in targetEvents {
            let newGroup = commandGroup(scriptPath: scriptPath, matcher: target.matcher)

            guard let existingValue = hooks[target.name] else {
                hooks[target.name] = [newGroup]
                continue
            }
            guard let groups = existingValue as? [[String: Any]] else {
                // The existing value for this event has a shape Calyx
                // doesn't recognize (hand-edited, or a future hooks
                // format) — skip installing Calyx's own entry for this
                // event rather than silently discarding whatever the
                // user has there. `hooks[target.name]` is left as-is.
                continue
            }

            let deduped = removingOwnCommandEntries(from: groups)
            hooks[target.name] = deduped + [newGroup]
        }

        config["hooks"] = hooks

        let outputData = try JSONSerialization.data(
            withJSONObject: config,
            options: [.prettyPrinted, .sortedKeys]
        )
        try ConfigFileUtils.atomicWrite(data: outputData, to: path)
    }

    /// Removes only Calyx's own command entries (identified by the
    /// `calyx-agent-hook` command path) from `configPath`'s `"hooks"`
    /// section, leaving co-located user hooks and unrelated top-level keys
    /// untouched. A no-op when the file doesn't exist. An event whose
    /// group list becomes empty as a result has its key removed entirely
    /// (no dangling `"EventName": []`), and the `"hooks"` key itself is
    /// removed when every event under it became empty — mirroring
    /// `ClaudeConfigManager.disableIPC`'s `mcpServers`-key cleanup.
    static func removeHooks(configPath: String? = nil) throws {
        let path = configPath ?? defaultConfigPath

        var config = try ConfigFileUtils.readConfigWithBackup(path: path)

        guard var hooks = config["hooks"] as? [String: Any] else { return }

        for eventName in hooks.keys {
            guard let groups = hooks[eventName] as? [[String: Any]] else { continue }
            let filtered = removingOwnCommandEntries(from: groups)
            if filtered.isEmpty {
                hooks.removeValue(forKey: eventName)
            } else {
                hooks[eventName] = filtered
            }
        }

        if hooks.isEmpty {
            config.removeValue(forKey: "hooks")
        } else {
            config["hooks"] = hooks
        }

        let outputData = try JSONSerialization.data(
            withJSONObject: config,
            options: [.prettyPrinted, .sortedKeys]
        )
        try ConfigFileUtils.atomicWrite(data: outputData, to: path)
    }

    /// Whether Calyx's own command entry is present for at least one of the
    /// 7 target events. Returns `false` (rather than throwing) when
    /// `configPath`'s symlink chain can't be resolved — this is a
    /// read-only status check, and every other unreadable/invalid-file
    /// case here already resolves to `false` the same way.
    static func areHooksInstalled(configPath: String? = nil) -> Bool {
        guard let path = try? ConfigFileUtils.resolveConfigPath(configPath ?? defaultConfigPath) else {
            return false
        }
        let fm = FileManager.default

        guard fm.fileExists(atPath: path) else { return false }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let parsed = try? JSONSerialization.jsonObject(with: data),
              let config = parsed as? [String: Any],
              let hooks = config["hooks"] as? [String: Any] else {
            return false
        }

        return targetEvents.contains { target in
            let groups = (hooks[target.name] as? [[String: Any]]) ?? []
            return groups.contains { group in
                let entries = (group["hooks"] as? [[String: Any]]) ?? []
                return entries.contains { isOwnCommandEntry($0) }
            }
        }
    }

    // MARK: - Private: Entry Construction / Identification

    private static func commandEntry(scriptPath: String) -> [String: Any] {
        [
            "type": "command",
            "command": "\"\(scriptPath)\"",
            "timeout": 5,
            "async": true,
        ]
    }

    /// Builds the matcher-group Calyx installs for one target event:
    /// `{"matcher": <matcher>, "hooks": [<commandEntry>]}`, omitting the
    /// `"matcher"` key entirely when `matcher` is `nil`.
    private static func commandGroup(scriptPath: String, matcher: String?) -> [String: Any] {
        var group: [String: Any] = ["hooks": [commandEntry(scriptPath: scriptPath)]]
        if let matcher {
            group["matcher"] = matcher
        }
        return group
    }

    /// Removes Calyx's own command entries from every group in `groups`,
    /// dropping any group that becomes empty as a result (so reinstalling
    /// or disabling doesn't leave empty `{"hooks": []}` groups behind).
    /// Groups containing surviving (user-owned) entries are kept as-is.
    private static func removingOwnCommandEntries(from groups: [[String: Any]]) -> [[String: Any]] {
        groups.compactMap { group -> [String: Any]? in
            guard let innerHooks = group["hooks"] as? [[String: Any]] else { return group }
            let filtered = innerHooks.filter { !isOwnCommandEntry($0) }
            guard filtered.count != innerHooks.count else { return group }
            guard !filtered.isEmpty else { return nil }
            var updated = group
            updated["hooks"] = filtered
            return updated
        }
    }

    /// A command entry is Calyx's own when its `command` path's last
    /// component is `calyx-agent-hook` — independent of the surrounding
    /// quoting and of the directory it was installed into.
    private static func isOwnCommandEntry(_ entry: [String: Any]) -> Bool {
        guard entry["type"] as? String == "command",
              let command = entry["command"] as? String else {
            return false
        }
        var path = command
        if path.hasPrefix("\""), path.hasSuffix("\""), path.count >= 2 {
            path = String(path.dropFirst().dropLast())
        }
        return (path as NSString).lastPathComponent == AgentHookScript.fileName
    }

    // MARK: - Private: Config Path

    private static var defaultConfigPath: String {
        NSHomeDirectory() + "/.claude/settings.json"
    }
}
