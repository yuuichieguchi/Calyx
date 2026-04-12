// OpenCodeConfigManager.swift
// Calyx
//
// Manages reading/writing OpenCode's config files for the Calyx IPC MCP server.
//
// OpenCode uses two files under `~/.config/opencode/`:
// 1. `opencode.json`  — the MCP remote server entry (upsert `mcp.calyx-ipc`)
// 2. `AGENTS.md`      — Markdown injected into the LLM system prompt; we manage a
//                       delimiter-wrapped block that OpenCode sends to the model.
//
// Both files support bidirectional enable/disable with idempotent upsert.

import Foundation

// MARK: - OpenCodeConfigError

enum OpenCodeConfigError: Error, LocalizedError {
    case invalidJSON
    case symlinkDetected
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidJSON:
            return "The opencode.json file contains invalid JSON"
        case .symlinkDetected:
            return "An OpenCode config path is a symlink, which is not allowed for security reasons"
        case .writeFailed(let reason):
            return "Failed to write OpenCode config file: \(reason)"
        }
    }
}

// MARK: - OpenCodeConfigManager

struct OpenCodeConfigManager: Sendable {

    // MARK: - Constants

    private static let mcpKey = "mcp"
    private static let calyxIPCKey = "calyx-ipc"

    /// Relative filename (including leading slash) for `opencode.json` under the OpenCode config dir.
    private static let openCodeJSONFilename = "/opencode.json"

    /// Relative filename (including leading slash) for `AGENTS.md` under the OpenCode config dir.
    private static let agentsMDFilename = "/AGENTS.md"

    /// Common prefix shared by all BEGIN CALYX IPC markers (historical and current).
    /// Kept as a derived constant so `beginDelimiter` stays in sync with it.
    private static let beginAnchor = "<!-- BEGIN CALYX IPC"

    /// BEGIN delimiter for the Calyx IPC managed block in AGENTS.md.
    /// Must match the literal the tests search for.
    private static let beginDelimiter = beginAnchor + " (managed by Calyx, do not edit) -->"

    /// Regex that matches a full BEGIN line (`<!-- BEGIN CALYX IPC ... -->`), requiring
    /// the `-->` closing on the same line. This prevents `stripManagedBlocks` from
    /// anchoring on user prose that merely mentions `<!-- BEGIN CALYX IPC` mid-line.
    private static let beginLinePattern = #"<!--\s*BEGIN CALYX IPC[^\n]*?-->"#

    /// END delimiter for the Calyx IPC managed block in AGENTS.md.
    private static let endDelimiter = "<!-- END CALYX IPC -->"

    /// Managed-block body injected into AGENTS.md. This is MCPProtocol.instructions
    /// minus the browser-automation paragraph, formatted as Markdown.
    ///
    /// Note: kept as a stable constant so the canary substring
    /// `"call register_peer once"` remains present.
    private static let managedBlockBody = """
    ## Calyx IPC

    You are connected to Calyx IPC, enabling communication with other Claude Code instances in other terminal panes.

    Immediately after connecting, call register_peer once with a descriptive name based on your current task or working directory, and a role describing your function. Do not call register_peer again in the same session.

    After completing any significant task, call receive_messages to check for messages from other peers. When you receive messages, process them and respond via send_message.

    Use list_peers to discover other connected instances. Use broadcast for announcements relevant to all peers.
    """

    // MARK: - Public API

    /// Enables the Calyx IPC MCP entry in OpenCode's `opencode.json` and appends
    /// (or replaces) the managed block in `AGENTS.md`.
    ///
    /// Both files are written atomically under independent `flock`-based locks.
    /// Symlinks on either target path cause the entire operation to abort before
    /// any write happens — neither file is partially modified.
    static func enableIPC(port: Int, token: String, configDir: String? = nil) throws {
        let dir = configDir ?? defaultConfigDir
        let jsonPath = dir + Self.openCodeJSONFilename
        let agentsPath = dir + Self.agentsMDFilename

        // Preflight: reject symlinks on BOTH paths before touching either file.
        // This gives atomic-ish rejection: neither file is partially modified.
        guard !ConfigFileUtils.isSymlink(at: jsonPath) else {
            throw OpenCodeConfigError.symlinkDetected
        }
        guard !ConfigFileUtils.isSymlink(at: agentsPath) else {
            throw OpenCodeConfigError.symlinkDetected
        }

        try upsertOpenCodeJSON(port: port, token: token, path: jsonPath)
        try upsertAgentsMD(path: agentsPath)
    }

    /// Disables the Calyx IPC entry by removing `mcp.calyx-ipc` from `opencode.json`
    /// and removing the managed block from `AGENTS.md`. Missing files are a no-op.
    static func disableIPC(configDir: String? = nil) throws {
        let dir = configDir ?? defaultConfigDir
        let jsonPath = dir + Self.openCodeJSONFilename
        let agentsPath = dir + Self.agentsMDFilename

        // Preflight: reject symlinks on BOTH paths before touching either file.
        // Mirrors enableIPC's preflight for atomic-rejection contract consistency —
        // without this, if opencode.json is a regular file and AGENTS.md is a
        // symlink, disableIPC would modify opencode.json first and only throw
        // when it reached AGENTS.md, leaving the user in a half-modified state.
        if FileManager.default.fileExists(atPath: jsonPath),
           ConfigFileUtils.isSymlink(at: jsonPath) {
            throw OpenCodeConfigError.symlinkDetected
        }
        if FileManager.default.fileExists(atPath: agentsPath),
           ConfigFileUtils.isSymlink(at: agentsPath) {
            throw OpenCodeConfigError.symlinkDetected
        }

        try removeFromOpenCodeJSON(path: jsonPath)
        try removeFromAgentsMD(path: agentsPath)
    }

    /// Returns whether the Calyx IPC MCP entry is present in `opencode.json`.
    /// Returns `false` if the file is missing, invalid, or lacks the entry.
    /// Does not inspect AGENTS.md — authoritative truth is opencode.json.
    static func isIPCEnabled(configDir: String? = nil) -> Bool {
        let dir = configDir ?? defaultConfigDir
        let jsonPath = dir + Self.openCodeJSONFilename

        guard FileManager.default.fileExists(atPath: jsonPath),
              let data = try? Data(contentsOf: URL(fileURLWithPath: jsonPath)),
              let parsed = try? JSONSerialization.jsonObject(with: data),
              let config = parsed as? [String: Any],
              let mcp = config[mcpKey] as? [String: Any] else {
            return false
        }

        return mcp[calyxIPCKey] != nil
    }

    // MARK: - Private: opencode.json

    private static func upsertOpenCodeJSON(port: Int, token: String, path: String) throws {
        // Note: unlike ClaudeConfigManager, no .bak backup is created here.
        // We match CodexConfigManager's pattern — the atomic-write + .tmp flow
        // is considered sufficient for tool-config files of this size.
        let fm = FileManager.default
        var config: [String: Any]

        if fm.fileExists(atPath: path) {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))

            // Treat an empty file as an empty object (allows a pre-created empty file).
            if data.isEmpty {
                config = [:]
            } else {
                guard let parsed = try? JSONSerialization.jsonObject(with: data),
                      let dict = parsed as? [String: Any] else {
                    // Invalid JSON: throw WITHOUT overwriting the file.
                    throw OpenCodeConfigError.invalidJSON
                }
                config = dict
            }
        } else {
            config = [:]
        }

        // Build the calyx-ipc entry fresh — no merge, guarantees stale header keys
        // are not retained across upserts.
        let calyxEntry: [String: Any] = [
            "type": "remote",
            "url": "http://localhost:\(port)/mcp",
            "headers": [
                "Authorization": "Bearer \(token)"
            ]
        ]

        var mcp = config[mcpKey] as? [String: Any] ?? [:]
        mcp[calyxIPCKey] = calyxEntry
        config[mcpKey] = mcp

        let outputData = try JSONSerialization.data(
            withJSONObject: config,
            options: [.prettyPrinted, .sortedKeys]
        )

        try ConfigFileUtils.atomicWrite(
            data: outputData,
            to: path,
            lockPath: path + ".lock"
        )
    }

    private static func removeFromOpenCodeJSON(path: String) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else { return }

        guard !ConfigFileUtils.isSymlink(at: path) else {
            throw OpenCodeConfigError.symlinkDetected
        }

        let data = try Data(contentsOf: URL(fileURLWithPath: path))

        // Empty file → nothing to do.
        guard !data.isEmpty else { return }

        guard let parsed = try? JSONSerialization.jsonObject(with: data),
              var config = parsed as? [String: Any] else {
            throw OpenCodeConfigError.invalidJSON
        }

        guard var mcp = config[mcpKey] as? [String: Any] else {
            // No mcp key → nothing to remove.
            return
        }

        mcp.removeValue(forKey: calyxIPCKey)

        // If mcp is now empty, drop the key entirely (parity with ClaudeConfigManager).
        if mcp.isEmpty {
            config.removeValue(forKey: mcpKey)
        } else {
            config[mcpKey] = mcp
        }

        let outputData = try JSONSerialization.data(
            withJSONObject: config,
            options: [.prettyPrinted, .sortedKeys]
        )

        try ConfigFileUtils.atomicWrite(
            data: outputData,
            to: path,
            lockPath: path + ".lock"
        )
    }

    // MARK: - Private: AGENTS.md

    private static func upsertAgentsMD(path: String) throws {
        let fm = FileManager.default

        let existing: String
        if fm.fileExists(atPath: path) {
            existing = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        } else {
            existing = ""
        }

        // Strip any previous managed block(s), then append a fresh one.
        // This guarantees idempotency: exactly one managed block afterwards,
        // regardless of how many stale ones were present.
        let cleaned = stripManagedBlocks(from: existing)

        let freshBlock = beginDelimiter + "\n" + managedBlockBody + "\n" + endDelimiter + "\n"

        var output = cleaned
        if !output.isEmpty {
            // Ensure a blank line separates user content from the managed block.
            if !output.hasSuffix("\n") {
                output += "\n"
            }
            if !output.hasSuffix("\n\n") {
                output += "\n"
            }
        }
        output += freshBlock

        guard let data = output.data(using: .utf8) else {
            throw OpenCodeConfigError.writeFailed("UTF-8 encoding failed")
        }

        try ConfigFileUtils.atomicWrite(
            data: data,
            to: path,
            lockPath: path + ".lock"
        )
    }

    private static func removeFromAgentsMD(path: String) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else { return }

        guard !ConfigFileUtils.isSymlink(at: path) else {
            throw OpenCodeConfigError.symlinkDetected
        }

        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            // Unreadable → treat as no-op (consistent with CodexConfigManager).
            return
        }

        let cleaned = stripManagedBlocks(from: content)

        // Only write if content actually changed, to avoid gratuitous timestamp churn.
        guard cleaned != content else { return }

        guard let data = cleaned.data(using: .utf8) else {
            throw OpenCodeConfigError.writeFailed("UTF-8 encoding failed")
        }

        try ConfigFileUtils.atomicWrite(
            data: data,
            to: path,
            lockPath: path + ".lock"
        )
    }

    /// Removes all `BEGIN CALYX IPC` ... `END CALYX IPC` managed blocks from a string.
    ///
    /// Matches by searching for a full BEGIN line (via `beginLinePattern`), then the
    /// next occurrence of `endDelimiter` following it. The regex requires the `-->`
    /// comment terminator on the same line as `BEGIN CALYX IPC`, so user prose that
    /// merely mentions `<!-- BEGIN CALYX IPC` mid-line is NOT treated as a block
    /// start. The search is still robust to legacy BEGIN markers that have additional
    /// trailing label text before the `-->`, e.g.
    /// `<!-- BEGIN CALYX IPC (managed by Calyx, do not edit) -->`.
    ///
    /// Preserves all content outside the removed blocks exactly, including user
    /// content both before and after the block.
    private static func stripManagedBlocks(from content: String) -> String {
        let endAnchor = endDelimiter

        var result = content

        // Match a complete BEGIN line (regex, not plain prefix), so a bare
        // mid-line mention of `<!-- BEGIN CALYX IPC` in user prose cannot
        // anchor a false-positive managed-block span.
        while let beginRange = result.range(
            of: Self.beginLinePattern,
            options: .regularExpression
        ) {
            // Find end delimiter AFTER the BEGIN marker.
            guard let endRange = result.range(of: endAnchor, range: beginRange.upperBound..<result.endIndex) else {
                // Unterminated managed block — bail out to avoid removing user content.
                break
            }

            // Extend removal forward past a trailing newline (if any) so we don't
            // leave an orphan blank line where the block used to be.
            var removeUpperBound = endRange.upperBound
            if removeUpperBound < result.endIndex,
               result[removeUpperBound] == "\n" {
                removeUpperBound = result.index(after: removeUpperBound)
            }

            // Extend removal backward over a leading blank-line separator if one
            // exists immediately before the BEGIN marker — keeps removal symmetric
            // with the insertion (which adds a blank line before the block).
            var removeLowerBound = beginRange.lowerBound
            if removeLowerBound > result.startIndex {
                let prevIndex = result.index(before: removeLowerBound)
                if result[prevIndex] == "\n" {
                    // Only eat ONE newline so user content separators stay intact.
                    removeLowerBound = prevIndex
                }
            }

            result.removeSubrange(removeLowerBound..<removeUpperBound)
        }

        return result
    }

    // MARK: - Private: Defaults

    private static var defaultConfigDir: String {
        NSHomeDirectory() + "/.config/opencode"
    }
}
