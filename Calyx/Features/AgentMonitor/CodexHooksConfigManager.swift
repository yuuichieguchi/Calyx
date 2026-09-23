// CodexHooksConfigManager.swift
// Calyx
//
// Manages a BEGIN/END-delimited managed block of `[[hooks.<Event>]]` TOML
// array-of-tables entries in `~/.codex/config.toml` for the
// calyx-agent-hook script — Codex's equivalent of
// ClaudeHooksConfigManager's `"hooks"` section in settings.json. Unlike
// Codex's `[mcp_servers.calyx-ipc]` section (a single upserted table,
// managed by `CodexConfigManager`), the 9 hook events each need their own
// `[[hooks.X]]` + `[[hooks.X.hooks]]` array-of-tables pair, and TOML has
// no syntax for replacing "our" entries within a user's own array without
// risking corruption of entries we don't own — so, like
// `HermesConfigManager`'s YAML block, the whole thing is wrapped in a
// single BEGIN/END comment span: appended at EOF on first install,
// rewritten at its own position after that (TOML has no
// "insert at top" primitive either — a leading array-of-tables would swallow
// any of the user's own un-headered root keys that follow it). Codex may insert
// its own tables between those comment markers (comments do not establish
// ownership in TOML); replacement therefore extracts every table that cannot
// be positively identified as one of Calyx's hook entries before removing the
// Calyx-owned definitions.

import Foundation

// MARK: - CodexHooksConfigError

enum CodexHooksConfigError: Error, LocalizedError {
    case invalidScriptPath

    var errorDescription: String? {
        switch self {
        case .invalidScriptPath:
            return "The script path contains a single quote, which cannot be safely embedded " +
                "in a TOML literal string"
        }
    }
}

// MARK: - CodexHooksConfigManager

struct CodexHooksConfigManager: Sendable {

    // MARK: - Constants

    /// The 9 Codex hook events Calyx installs a `[[hooks.X]]` entry for.
    /// SessionEnd is what settles an ended Codex session to `.done`;
    /// without it, a session's last event is `Stop`, which only reaches
    /// `.idle`.
    private static let targetEvents = [
        "SessionStart", "UserPromptSubmit", "PreToolUse",
        "PostToolUse", "PermissionRequest", "Stop", "SessionEnd",
        "SubagentStart", "SubagentStop",
    ]

    static let beginLine = "# BEGIN CALYX AGENT HOOKS (managed by Calyx, do not edit)"
    static let endLine = "# END CALYX AGENT HOOKS"

    /// The BEGIN/END marker editor shared with every other marker-block
    /// manager. Given `isCalyxGeneratedBlockLine` and `foreignTableBytes`,
    /// it owns the well-formed append/replace of the freshly built managed
    /// block, extracting any foreign TOML table found inside a removed
    /// block's span and self-healing an orphan BEGIN entirely on its own.
    private static let markerEditor = MarkerConfigDocumentEditor(
        beginLine: beginLine,
        endLine: endLine,
        isOwnBodyLine: { doc, index in isCalyxGeneratedBlockLine(lineString(doc, index)) },
        foreignBodyBytes: { doc, bodyLines in foreignTableBytes(in: doc, bodyLines: bodyLines) }
    )

    // MARK: - Public API

    /// Replaces Calyx's managed block in `configPath` with a freshly built
    /// one for `scriptPath`'s 9 target events plus `approvalScriptPath`'s
    /// extra synchronous `PermissionRequest` pair, preserving everything
    /// else in the file verbatim. An existing well-formed managed block is
    /// rewritten at its own position, never moved to EOF; with none
    /// present, any orphan marker self-heals first and the new block is
    /// appended at EOF. Idempotent: identical inputs on an already-current
    /// file produce byte-identical output, so the file is not rewritten.
    static func installHooks(scriptPath: String, approvalScriptPath: String, configPath: String? = nil) throws {
        guard !scriptPath.contains("'"), !approvalScriptPath.contains("'") else {
            // TOML literal strings (`'...'`) have no escape mechanism, and
            // `command = '"<scriptPath>" codex'` relies on one — a `'` in
            // either scriptPath would truncate the literal early and
            // corrupt the TOML.
            throw CodexHooksConfigError.invalidScriptPath
        }

        let path = configPath ?? defaultConfigPath
        let resolvedPath = try ConfigFileUtils.resolveConfigPath(path)
        let parentDir = (resolvedPath as NSString).deletingLastPathComponent

        guard ConfigFileUtils.directoryExists(at: parentDir) else {
            throw CodexConfigError.directoryNotFound
        }

        let freshBody = managedBlockBody(scriptPath: scriptPath, approvalScriptPath: approvalScriptPath)

        // mode: nil (leave the mode as-is): this hooks block carries no
        // secret. ~/.codex/config.toml is shared with CodexConfigManager's
        // `[mcp_servers.calyx-ipc]` table, which does carry the bearer
        // token and enforces 0600 on its own writes -- one file, two
        // policies, deliberately: whichever manager's write actually
        // contains the secret is the one that enforces the mode.
        try ConfigFileUtils.withExclusiveConfig(path: path) { current in
            // Rewrites the first managed block in place (lifting any
            // foreign TOML table found inside it to just before it, and
            // removing every further block) or, with none present,
            // self-heals any orphan marker and appends at EOF, so
            // reinstalling never duplicates or moves it.
            try markerEditor.upsertBlock(body: freshBody, in: current)
        }
    }

    /// Removes only Calyx's managed block from `configPath`, leaving the
    /// rest of the file untouched. A no-op when the file doesn't exist, or
    /// exists but has no managed block (including: doesn't rewrite the
    /// file in that case, so its modification time is left alone).
    /// Self-heals an orphan BEGIN marker (no matching END) rather than
    /// throwing, and preserves any foreign TOML table found inside a
    /// removed block's span in place of it -- both entirely `markerEditor`'s
    /// own responsibility (see its doc comments), given `isOwnBodyLine`
    /// and `foreignBodyBytes` above.
    static func removeHooks(configPath: String? = nil) throws {
        let path = configPath ?? defaultConfigPath

        // mode: nil, same policy/reasoning as installHooks above: this
        // block carries no token, so this call never touches the file's
        // mode.
        try ConfigFileUtils.withExclusiveConfig(path: path) { current in
            try markerEditor.removeBlock(in: current)
        }
    }

    /// Whether Calyx's managed block (its BEGIN marker, well-formed or
    /// orphan) is present. Returns `false` (rather than throwing) when
    /// `configPath`'s symlink chain can't be resolved — this is a
    /// read-only status check, and every other unreadable-file case here
    /// already resolves to `false` the same way.
    static func areHooksInstalled(configPath: String? = nil) -> Bool {
        guard let path = try? ConfigFileUtils.resolveConfigPath(configPath ?? defaultConfigPath),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            return false
        }
        return markerEditor.containsBlock(in: data)
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

    /// `PermissionRequest`'s extra synchronous approval entry -- a second
    /// `[[hooks.PermissionRequest]]` pair alongside the one `hookEntry`
    /// already writes for it, POSTing through `calyx-approval-hook`
    /// instead of `calyx-agent-hook`, with a timeout of
    /// `ApprovalHookTiming.hookEntryTimeoutSeconds` (600) rather than the
    /// monitor entries' fire-and-forget `5`. Nested under
    /// `PermissionRequest` rather than `PreToolUse`: `PermissionRequest`
    /// fires only once Codex has already decided it needs to show a
    /// confirmation prompt, unlike `PreToolUse`, which fires for every
    /// tool call regardless of whether it needs approval.
    private static func approvalHookEntry(approvalScriptPath: String) -> String {
        """
        [[hooks.\(ApprovalHookEvent.name)]]
        [[hooks.\(ApprovalHookEvent.name).hooks]]
        type = "command"
        command = '"\(approvalScriptPath)" \(AgentEntry.codexKind)'
        timeout = \(ApprovalHookTiming.hookEntryTimeoutSeconds)
        """
    }

    /// The managed block's body (everything between the BEGIN and END
    /// lines, which `MarkerConfigDocumentEditor.upsertBlock` supplies
    /// itself).
    private static func managedBlockBody(scriptPath: String, approvalScriptPath: String) -> String {
        let eventEntries = targetEvents.map { hookEntry(eventName: $0, scriptPath: scriptPath) }
        return (eventEntries + [approvalHookEntry(approvalScriptPath: approvalScriptPath)]).joined(separator: "\n")
    }

    // MARK: - Private: Managed Block Removal

    /// Decodes a single line's own content bytes (excluding its EOL) as a
    /// `String`. Always safe against CRLF: `LineDoc` already separated the
    /// terminator out, so the decoded string never contains a `\r\n` pair
    /// whose grapheme-cluster collapse could defeat a `String`-level check.
    private static func lineString(_ doc: LineDoc, _ index: Int) -> String {
        String(decoding: doc.lineBytes(doc.lines[index]), as: UTF8.self)
    }

    /// Extracts every complete foreign TOML table chunk from `bodyLines`
    /// (the line-index range strictly between the BEGIN and END markers, or
    /// between BEGIN and the last recognized orphan-body line). A chunk is
    /// Calyx-owned only when an exact `[[hooks.<Event>]]` / `[[hooks.<Event>.hooks]]`
    /// pair is present and the child chunk's command references one of
    /// Calyx's installed hook scripts. Everything else is external state,
    /// even when Codex happened to serialize it between our BEGIN/END
    /// comments, and is returned byte-for-byte in its original order and
    /// spacing, including whatever blank lines the user's own content had,
    /// with each returned line's own original EOL attached: this must
    /// never trim blank lines off content that isn't Calyx's own.
    private static func foreignTableBytes(in doc: LineDoc, bodyLines: Range<Int>) -> [UInt8] {
        let headerIndices = bodyLines.filter {
            let trimmed = lineString(doc, $0).trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix("[") && trimmed.hasSuffix("]")
        }
        // A body with no table header anywhere gives this function no
        // anchor to identify Calyx's own content by, so the whole body
        // is foreign -- the same rule
        // HermesConfigManager.foreignBodyBytes applies to a span with no
        // recognizable calyx-ipc line.
        guard let firstHeader = headerIndices.first else {
            return rangeBytes(doc, bodyLines)
        }

        struct TableChunk {
            let header: String
            let lineRange: Range<Int>
        }

        let chunks: [TableChunk] = headerIndices.enumerated().map { offset, start in
            let end = offset + 1 < headerIndices.count ? headerIndices[offset + 1] : bodyLines.upperBound
            return TableChunk(
                header: lineString(doc, start).trimmingCharacters(in: .whitespaces),
                lineRange: start..<end
            )
        }

        var ownedChunkIndices: Set<Int> = []
        for index in chunks.indices.dropLast() {
            guard let event = calyxHookEvent(fromParentHeader: chunks[index].header),
                  chunks[index + 1].header == "[[hooks.\(event).hooks]]",
                  chunkReferencesCalyxHookScript(doc, chunks[index + 1].lineRange) else {
                continue
            }
            ownedChunkIndices.insert(index)
            ownedChunkIndices.insert(index + 1)
        }

        // Any line between the body's start and the first table header
        // belongs to no chunk (`chunks` only starts at `firstHeader`) --
        // there is no table header to identify it by either, so it is
        // preserved verbatim in its original position, ahead of every
        // chunk.
        var result: [UInt8] = rangeBytes(doc, bodyLines.lowerBound..<firstHeader)
        for (index, chunk) in chunks.enumerated() where !ownedChunkIndices.contains(index) {
            result.append(contentsOf: rangeBytes(doc, chunk.lineRange))
        }
        return result
    }

    /// Concatenates `range`'s lines verbatim, each with its own original
    /// EOL attached.
    private static func rangeBytes(_ doc: LineDoc, _ range: Range<Int>) -> [UInt8] {
        var result: [UInt8] = []
        for lineIndex in range {
            result.append(contentsOf: doc.bytes[doc.lines[lineIndex].contentRange])
            result.append(contentsOf: doc.bytes[doc.lines[lineIndex].eolRange])
        }
        return result
    }

    private static func calyxHookEvent(fromParentHeader header: String) -> String? {
        targetEvents.first { header == "[[hooks.\($0)]]" }
    }

    private static func chunkReferencesCalyxHookScript(_ doc: LineDoc, _ lineRange: Range<Int>) -> Bool {
        lineRange.contains { lineIndex in
            let trimmed = lineString(doc, lineIndex).trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix("command")
                && (trimmed.contains(AgentHookScript.fileName)
                    || trimmed.contains(ApprovalHookScript.fileName))
        }
    }

    /// Whether `line` looks like part of Calyx's own generated managed-block
    /// body, for `markerEditor`'s orphan-BEGIN self-heal: a
    /// blank line, a `#` comment, a `[[hooks.*]]` array-of-tables header, or
    /// a `type` / `command` (only when its value references
    /// `AgentHookScript.fileName` or `ApprovalHookScript.fileName`, i.e.
    /// it's plausibly one of Calyx's own command entries, not unrelated
    /// user TOML that happens to have a `command` key) / `timeout` key
    /// line.
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
        if trimmed.hasPrefix("command"),
           trimmed.contains(AgentHookScript.fileName) || trimmed.contains(ApprovalHookScript.fileName) {
            return true
        }
        return false
    }

    // MARK: - Private: Config Path

    private static var defaultConfigPath: String {
        AgentToolPaths.codexConfigDirectory + "/config.toml"
    }
}
