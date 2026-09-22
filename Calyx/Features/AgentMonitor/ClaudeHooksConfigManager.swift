// ClaudeHooksConfigManager.swift
// Calyx
//
// Manages the "hooks" section of ~/.claude/settings.json for the
// calyx-agent-hook lifecycle hook. Mirrors ClaudeConfigManager's API shape
// and file-safety guarantees (symlink rejection, atomic write): both
// entry points go through `ConfigFileUtils.withExclusiveConfig` and edit
// only Calyx's own array elements via `JSONConfigDocumentEditor`, leaving
// co-located user hooks and unrelated top-level keys byte-identical.

import Foundation

struct ClaudeHooksConfigManager: Sendable {

    /// The 10 hook events Calyx installs a command entry for, and the
    /// `matcher` each uses (`nil` means no `"matcher"` key is written —
    /// Claude Code treats an absent matcher as "always run").
    ///
    /// `PermissionRequest` is a tool-approval-prompt hook,
    /// subscribed here with matcher `"*"` — unified with `PreToolUse`/
    /// `PostToolUse` rather than left without a matcher — and installed
    /// alongside `Notification`("permission_prompt") rather than in place
    /// of it: `Notification`'s firing can lag the actual on-screen dialog
    /// by several seconds, while `PermissionRequest` fires in sync with
    /// the dialog appearing, so subscribing to it lets the Agents sidebar
    /// flip a row to `.blocked` immediately instead of waiting out that
    /// delay. `AgentRegistry`'s server-side mapping of `PermissionRequest`
    /// to `.blocked` (unconditional, no message-substring check — unlike
    /// `Notification`) is already implemented; this only wires up
    /// `calyx-agent-hook`'s subscription so the hook actually fires.
    private static let targetEvents: [(name: String, matcher: String?)] = [
        ("SessionStart", nil),
        ("UserPromptSubmit", nil),
        ("PreToolUse", "*"),
        ("PostToolUse", "*"),
        ("Notification", "permission_prompt"),
        ("Stop", nil),
        ("SessionEnd", nil),
        ("PermissionRequest", "*"),
        ("SubagentStart", "*"),
        ("SubagentStop", "*"),
    ]

    // MARK: - Public API

    /// Merges Calyx's 10 hook entries into `configPath`'s `"hooks"` section,
    /// preserving the user's own existing hook entries and unrelated
    /// top-level keys. Idempotent: re-running replaces Calyx's own prior
    /// entries rather than duplicating them.
    ///
    /// `PermissionRequest` alone gets a second Calyx-owned command entry:
    /// the same-shaped async monitor entry every other event gets
    /// (`scriptPath`) plus a synchronous approval entry
    /// (`approvalScriptPath`, no `"async"` key, timeout
    /// `ApprovalHookTiming.hookEntryTimeoutSeconds`) that blocks the tool
    /// call until Calyx's own `/approval-request` long-poll resolves.
    /// `PreToolUse` carries only the monitor entry, since it fires for
    /// every tool call regardless of whether it needs approval, unlike
    /// `PermissionRequest`, which fires only once the CLI has already
    /// decided it needs to show a confirmation prompt. Every event other
    /// than `PermissionRequest` gets exactly one entry.
    static func installHooks(scriptPath: String, approvalScriptPath: String, configPath: String? = nil) throws {
        let path = configPath ?? defaultConfigPath

        // mode: nil (leave the mode as-is): ~/.claude/settings.json is a
        // user-owned file and this write carries no secret.
        try ConfigFileUtils.withExclusiveConfig(path: path) { current in
            var bytes = current
            for target in targetEvents {
                guard eventShapeIsRecognized(target.name, in: bytes) else { continue }

                let entries = commandEntries(
                    scriptPath: scriptPath, approvalScriptPath: approvalScriptPath, eventName: target.name
                )
                let newGroup = commandGroup(entries: entries, matcher: target.matcher)

                // Already installed, unchanged: skip the remove+append
                // round trip entirely, so a no-op reinstall leaves this
                // event's position in "hooks" (and every byte of the
                // file) untouched, matching every other unchanged event
                // -- `withExclusiveConfig` only skips the write when the
                // WHOLE document comes back byte-identical.
                guard !ownGroupAlreadyInstalled(newGroup, eventName: target.name, in: bytes) else { continue }

                bytes = try removingOwnEntriesFromEventGroups(target.name, in: bytes)
                // .sortedKeys: see ClaudeConfigManager.enableIPC's identical
                // comment -- without it this group's bytes are not stable
                // across process launches, defeating withExclusiveConfig's
                // no-write check.
                let groupData = try JSONSerialization.data(withJSONObject: newGroup, options: [.sortedKeys])
                bytes = try JSONConfigDocumentEditor.appendArrayElement(
                    groupData, at: ["hooks", target.name], in: bytes
                )
            }
            return bytes
        }
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

        try ConfigFileUtils.withExclusiveConfig(path: path) { current in
            guard let current, !current.isEmpty else { return current }
            // An actual JSON parse failure (corrupt file) throws, matching
            // installHooks -- both entry points against the same corrupt
            // file must agree, and a config the user can't get any signal
            // about being unreadable is a config they can never fix. A
            // well-formed document that merely lacks a "hooks" object (or
            // has no dict root) is the ordinary "nothing installed here"
            // case, not a parse failure, so it falls through to the no-op
            // return below instead. `decodedValue` throws
            // `ConfigFileError.invalidJSON` for the former case and
            // returns `nil` for an absent "hooks" key, both handled here
            // exactly as the prior whole-document `JSONSerialization`
            // parse did.
            guard let hooks = try JSONConfigDocumentEditor.decodedValue(at: [.key("hooks")], in: current) as? [String: Any] else {
                return current
            }

            var bytes: Data? = current
            for eventName in hooks.keys {
                guard hooks[eventName] is [[String: Any]] else { continue }
                bytes = try removingOwnEntriesFromEventGroups(eventName, in: bytes)
            }
            return bytes
        }
    }

    /// Whether Calyx's own command entry is present for at least one of the
    /// 10 target events. Returns `false` (rather than throwing) when
    /// `configPath`'s symlink chain can't be resolved — this is a
    /// read-only status check, and every other unreadable/invalid-file
    /// case here already resolves to `false` the same way.
    static func areHooksInstalled(configPath: String? = nil) -> Bool {
        guard let path = try? ConfigFileUtils.resolveConfigPath(configPath ?? defaultConfigPath) else {
            return false
        }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return false }

        return targetEvents.contains { target in
            JSONConfigDocumentEditor.containsArrayElement(
                at: [.key("hooks"), .key(target.name)], in: data, where: isOwnGroup
            )
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

    /// The synchronous approval entry: no `"async"` key at all (its
    /// stdout is the actual permission decision, so it must block), and
    /// a timeout of `ApprovalHookTiming.hookEntryTimeoutSeconds` (600) —
    /// the outermost deadline in the approval hook chain (see
    /// `ApprovalHookTiming`'s doc comment).
    private static func approvalCommandEntry(approvalScriptPath: String) -> [String: Any] {
        [
            "type": "command",
            "command": "\"\(approvalScriptPath)\"",
            "timeout": ApprovalHookTiming.hookEntryTimeoutSeconds,
        ]
    }

    /// The Calyx-owned command entries for one target event:
    /// `PermissionRequest` gets both the async monitor entry and the
    /// synchronous approval entry; every other event gets only the
    /// monitor entry.
    private static func commandEntries(
        scriptPath: String, approvalScriptPath: String, eventName: String
    ) -> [[String: Any]] {
        guard eventName == ApprovalHookEvent.name else {
            return [commandEntry(scriptPath: scriptPath)]
        }
        return [commandEntry(scriptPath: scriptPath), approvalCommandEntry(approvalScriptPath: approvalScriptPath)]
    }

    /// Builds the matcher-group Calyx installs for one target event:
    /// `{"matcher": <matcher>, "hooks": <entries>}`, omitting the
    /// `"matcher"` key entirely when `matcher` is `nil`.
    private static func commandGroup(entries: [[String: Any]], matcher: String?) -> [String: Any] {
        var group: [String: Any] = ["hooks": entries]
        if let matcher {
            group["matcher"] = matcher
        }
        return group
    }

    /// A matcher-group touches Calyx's own region when its nested
    /// `"hooks"` array contains at least one of Calyx's own command
    /// entries. Every group `commandGroup` builds is entirely its own,
    /// but a hand-edited or pre-L1 config can also hold a group where a
    /// Calyx entry sits alongside a user's own -- `removingOwnEntries
    /// FromEventGroups` handles that mixed case by rebuilding the group
    /// with only the survivors.
    private static func isOwnGroup(_ value: Any) -> Bool {
        guard let group = value as? [String: Any],
              let entries = group["hooks"] as? [[String: Any]] else {
            return false
        }
        return entries.contains { isOwnCommandEntry($0) }
    }

    /// Removes Calyx's own command entries from every group of
    /// `eventName`'s array in `bytes`, in place. Each group touching
    /// Calyx's region is addressed all the way down to its own nested
    /// `"hooks"` array (`.element(where: isOwnGroup)` locates the group,
    /// `.key("hooks")` its nested entries), so a group that also holds a
    /// user's own (foreign) entry keeps that entry with its original key
    /// order and array position -- nothing is removed and re-appended. A
    /// group whose nested `"hooks"` array becomes empty (nothing but
    /// Calyx's own entries) is removed from `eventName`'s array as a
    /// whole, cascading upward through the event key and the `"hooks"`
    /// key exactly as `removeValue` does for a plain JSON key path.
    private static func removingOwnEntriesFromEventGroups(_ eventName: String, in bytes: Data?) throws -> Data? {
        try JSONConfigDocumentEditor.removeArrayElements(
            at: [.key("hooks"), .key(eventName), .element(where: isOwnGroup), .key("hooks")],
            in: bytes,
            where: { ($0 as? [String: Any]).map(isOwnCommandEntry) ?? false }
        )
    }

    /// Whether `eventName`'s array in `bytes` already contains exactly
    /// `newGroup` as its sole Calyx-owned group -- the common no-op
    /// resync case, where nothing needs to change for this event at all.
    /// Anything else (no own group yet, more than one, an own group
    /// mixed with a foreign one, or different content) answers `false`
    /// and falls through to the ordinary remove-then-append path.
    private static func ownGroupAlreadyInstalled(_ newGroup: [String: Any], eventName: String, in bytes: Data?) -> Bool {
        guard let groups = (try? JSONConfigDocumentEditor.decodedValue(at: [.key("hooks"), .key(eventName)], in: bytes)) as? [[String: Any]],
              groups.count == 1,
              isOwnGroup(groups[0])
        else {
            return false
        }
        return jsonValuesEqual(groups[0], newGroup)
    }

    /// Structural equality over decoded JSON values (`[String: Any]`,
    /// `[Any]`, and JSON scalars), used instead of comparing
    /// `JSONSerialization`-encoded bytes: those bytes are not guaranteed
    /// to come out in the same key order across two independent encoding
    /// calls, but the *values* they'd encode are exactly what needs
    /// comparing here.
    private static func jsonValuesEqual(_ lhs: Any, _ rhs: Any) -> Bool {
        switch (lhs, rhs) {
        case let (l as [String: Any], r as [String: Any]):
            guard l.count == r.count else { return false }
            return l.allSatisfy { key, value in
                guard let other = r[key] else { return false }
                return jsonValuesEqual(value, other)
            }
        case let (l as [Any], r as [Any]):
            guard l.count == r.count else { return false }
            return zip(l, r).allSatisfy { jsonValuesEqual($0, $1) }
        default:
            return (lhs as? NSObject) == (rhs as? NSObject)
        }
    }

    /// Whether `eventName`'s existing value in `bytes`'s `"hooks"` section
    /// is one Calyx recognizes well enough to edit: absent (nothing to
    /// remove, safe to install into), or an array of objects. Any other
    /// existing shape (hand-edited, or a future hooks format) is left
    /// completely alone -- read-only, since this only inspects `bytes`
    /// to decide whether to call the editor at all.
    private static func eventShapeIsRecognized(_ eventName: String, in bytes: Data?) -> Bool {
        guard let bytes, !bytes.isEmpty else { return true }
        guard JSONConfigDocumentEditor.containsValue(at: ["hooks", eventName], in: bytes) else { return true }
        let existing = try? JSONConfigDocumentEditor.decodedValue(at: [.key("hooks"), .key(eventName)], in: bytes)
        return existing is [[String: Any]]
    }

    /// A command entry is Calyx's own when its `command` path's last
    /// component is `calyx-agent-hook` or `calyx-approval-hook` —
    /// independent of the surrounding quoting and of the directory it
    /// was installed into.
    private static let ownScriptFileNames: Set<String> = [AgentHookScript.fileName, ApprovalHookScript.fileName]

    private static func isOwnCommandEntry(_ entry: [String: Any]) -> Bool {
        guard entry["type"] as? String == "command",
              let command = entry["command"] as? String else {
            return false
        }
        var path = command
        if path.hasPrefix("\""), path.hasSuffix("\""), path.count >= 2 {
            path = String(path.dropFirst().dropLast())
        }
        return ownScriptFileNames.contains((path as NSString).lastPathComponent)
    }

    // MARK: - Private: Config Path

    private static var defaultConfigPath: String {
        AgentToolPaths.claudeSettingsPath
    }
}
