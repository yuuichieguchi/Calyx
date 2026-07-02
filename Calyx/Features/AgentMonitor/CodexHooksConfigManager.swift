// CodexHooksConfigManager.swift
// Calyx
//
// Manages a BEGIN/END-delimited managed block of `[[hooks.<Event>]]` TOML
// array-of-tables entries in `~/.codex/config.toml` for the
// calyx-agent-hook script — Codex's equivalent of
// ClaudeHooksConfigManager's `"hooks"` section in settings.json. Unlike
// Codex's `[mcp_servers.calyx-ipc]` section (a single upserted table,
// managed by `CodexConfigManager`), the 6 hook events each need their own
// `[[hooks.X]]` + `[[hooks.X.hooks]]` array-of-tables pair, and TOML has
// no syntax for replacing "our" entries within a user's own array without
// risking corruption of entries we don't own — so, like
// `HermesConfigManager`'s YAML block, the whole thing is wrapped in a
// single BEGIN/END comment span that's always appended at EOF (TOML has no
// "insert at top" primitive either — a leading array-of-tables would swallow
// any of the user's own un-headered root keys that follow it) and replaced
// wholesale on reinstall.

import Foundation

// MARK: - CodexHooksConfigError

enum CodexHooksConfigError: Error, LocalizedError {
    case invalidScriptPath
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidScriptPath:
            return "The script path contains a single quote, which cannot be safely embedded " +
                "in a TOML literal string"
        case .writeFailed(let reason):
            return "Failed to write Codex config file: \(reason)"
        }
    }
}

// MARK: - CodexHooksConfigManager

struct CodexHooksConfigManager: Sendable {

    // MARK: - Constants

    /// The 6 Codex hook events Calyx installs a `[[hooks.X]]` entry for.
    /// Codex has no `SessionEnd` hook (see the Phase 2 plan's "risks"
    /// section), so a Codex session ending only reaches `.idle` (via
    /// `Stop`), never `.done`.
    private static let targetEvents = [
        "SessionStart", "UserPromptSubmit", "PreToolUse",
        "PostToolUse", "PermissionRequest", "Stop",
    ]

    static let beginLine = "# BEGIN CALYX AGENT HOOKS (managed by Calyx, do not edit)"
    static let endLine = "# END CALYX AGENT HOOKS"

    // MARK: - Public API

    /// Replaces Calyx's managed block in `configPath` with a freshly built
    /// one for `scriptPath`'s 6 target events, preserving everything else
    /// in the file verbatim. Idempotent: re-running strips the prior
    /// managed block (wherever it is) before appending the new one at EOF,
    /// rather than duplicating it.
    static func installHooks(scriptPath: String, configPath: String? = nil) throws {
        guard !scriptPath.contains("'") else {
            // TOML literal strings (`'...'`) have no escape mechanism, and
            // `command = '"<scriptPath>" codex'` relies on one — a `'` in
            // scriptPath would truncate the literal early and corrupt the
            // TOML.
            throw CodexHooksConfigError.invalidScriptPath
        }

        let path = try ConfigFileUtils.resolveConfigPath(configPath ?? defaultConfigPath)
        let parentDir = (path as NSString).deletingLastPathComponent

        guard ConfigFileUtils.directoryExists(at: parentDir) else {
            throw CodexConfigError.directoryNotFound
        }

        let content: String
        if FileManager.default.fileExists(atPath: path) {
            content = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        } else {
            content = ""
        }
        let normalized = content.replacingOccurrences(of: "\r\n", with: "\n")

        // Strips any existing managed block first (self-healing an orphan
        // BEGIN, if present) so reinstalling never duplicates it.
        let (stripped, _) = removingManagedBlock(from: normalized)

        var result = stripped
        if !result.isEmpty {
            if !result.hasSuffix("\n") { result += "\n" }
            if !result.hasSuffix("\n\n") { result += "\n" }
        }
        result += managedBlock(scriptPath: scriptPath) + "\n"

        guard let data = result.data(using: .utf8) else {
            throw CodexHooksConfigError.writeFailed("UTF-8 encoding failed")
        }
        try ConfigFileUtils.atomicWrite(data: data, to: path)
    }

    /// Removes only Calyx's managed block from `configPath`, leaving the
    /// rest of the file untouched. A no-op when the file doesn't exist, or
    /// exists but has no managed block (including: doesn't rewrite the
    /// file in that case, so its modification time is left alone).
    /// Self-heals an orphan BEGIN marker (no matching END) rather than
    /// throwing — see `removingManagedBlock`'s doc comment.
    static func removeHooks(configPath: String? = nil) throws {
        let path = try ConfigFileUtils.resolveConfigPath(configPath ?? defaultConfigPath)

        guard FileManager.default.fileExists(atPath: path) else { return }

        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        let normalized = content.replacingOccurrences(of: "\r\n", with: "\n")

        let (stripped, hadBlock) = removingManagedBlock(from: normalized)
        guard hadBlock else { return }

        guard let data = stripped.data(using: .utf8) else {
            throw CodexHooksConfigError.writeFailed("UTF-8 encoding failed")
        }
        try ConfigFileUtils.atomicWrite(data: data, to: path)
    }

    /// Whether Calyx's managed block (its BEGIN marker) is present.
    /// Returns `false` (rather than throwing) when `configPath`'s
    /// symlink chain can't be resolved — this is a read-only status
    /// check, and every other unreadable-file case here already resolves
    /// to `false` the same way.
    static func areHooksInstalled(configPath: String? = nil) -> Bool {
        guard let path = try? ConfigFileUtils.resolveConfigPath(configPath ?? defaultConfigPath) else {
            return false
        }

        guard FileManager.default.fileExists(atPath: path),
              let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            return false
        }
        let normalized = content.replacingOccurrences(of: "\r\n", with: "\n")
        return normalized.components(separatedBy: "\n").contains(beginLine)
    }

    // MARK: - Private: Managed Block Construction

    /// One event's `[[hooks.X]]` + `[[hooks.X.hooks]]` array-of-tables
    /// pair. `command` is a TOML literal string (`'...'`, single-quoted)
    /// so the embedded double quotes around `scriptPath` need no escaping
    /// — literal strings take no escapes at all, which is exactly why a
    /// `'` in `scriptPath` is rejected up front in `installHooks`.
    private static func hookEntry(eventName: String, scriptPath: String) -> String {
        """
        [[hooks.\(eventName)]]
        [[hooks.\(eventName).hooks]]
        type = "command"
        command = '"\(scriptPath)" \(AgentEntry.codexKind)'
        timeout = 5
        """
    }

    private static func managedBlock(scriptPath: String) -> String {
        let eventEntries = targetEvents.map { hookEntry(eventName: $0, scriptPath: scriptPath) }
        return ([beginLine] + eventEntries + [endLine]).joined(separator: "\n")
    }

    // MARK: - Private: Managed Block Removal

    /// Removes Calyx's managed block (BEGIN line through END line
    /// inclusive, plus one immediately-preceding blank line if present) from
    /// `content`. Returns the resulting content and whether a block was
    /// found and removed.
    ///
    /// Self-heals an orphan BEGIN marker (no matching END — e.g. left by a
    /// crash mid-write, or a file hand-edited after a prior install)
    /// instead of throwing, following `HermesConfigManager.enableIPC`'s
    /// precedent of stripping malformed managed-block remnants rather than
    /// requiring manual file surgery: it removes the BEGIN line plus every
    /// immediately-following line that still looks like part of Calyx's own
    /// generated block body (`isCalyxGeneratedBlockLine`), stopping at the
    /// first line that doesn't. Real user content past that point — even
    /// directly abutting the orphan block with no blank-line separator — is
    /// left untouched rather than guessed at.
    private static func removingManagedBlock(from content: String) -> (result: String, hadBlock: Bool) {
        var lines = content.components(separatedBy: "\n")

        guard let beginIndex = lines.firstIndex(of: beginLine) else {
            return (content, false)
        }

        let removeEnd: Int
        if let endIndex = lines[(beginIndex + 1)...].firstIndex(of: endLine) {
            removeEnd = endIndex
        } else {
            var lastRecognized = beginIndex
            var scanIndex = beginIndex + 1
            while scanIndex < lines.count, isCalyxGeneratedBlockLine(lines[scanIndex]) {
                lastRecognized = scanIndex
                scanIndex += 1
            }
            removeEnd = lastRecognized
        }

        var removeStart = beginIndex
        if removeStart > 0, lines[removeStart - 1].isEmpty {
            removeStart -= 1
        }
        lines.removeSubrange(removeStart...removeEnd)
        return (lines.joined(separator: "\n"), true)
    }

    /// Whether `line` looks like part of Calyx's own generated managed-block
    /// body, for the orphan-BEGIN self-heal in `removingManagedBlock`: a
    /// blank line, a `#` comment, a `[[hooks.*]]` array-of-tables header, or
    /// a `type` / `command` (only when its value references
    /// `AgentHookScript.fileName`, i.e. it's plausibly one of Calyx's own
    /// command entries, not unrelated user TOML that happens to have a
    /// `command` key) / `timeout` key line.
    private static func isCalyxGeneratedBlockLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return true }
        if trimmed.hasPrefix("#") { return true }
        if trimmed.range(of: #"^\[\[hooks\.[^\[\]]+\]\]$"#, options: .regularExpression) != nil {
            return true
        }
        if trimmed == "type = \"command\"" { return true }
        if trimmed.range(of: #"^timeout\s*=\s*\d+$"#, options: .regularExpression) != nil {
            return true
        }
        if trimmed.hasPrefix("command"), trimmed.contains(AgentHookScript.fileName) {
            return true
        }
        return false
    }

    // MARK: - Private: Config Path

    private static var defaultConfigPath: String {
        AgentToolPaths.codexConfigDirectory + "/config.toml"
    }
}
