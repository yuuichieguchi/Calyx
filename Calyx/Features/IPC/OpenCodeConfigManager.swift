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
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidJSON:
            return "The opencode.json file contains invalid JSON"
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
    /// The `/calyx-mcp` entry, beside `calyx-ipc`.
    private static let calyxMCPKey = "calyx-mcp"

    /// Relative filename (including leading slash) for `opencode.json` under the OpenCode config dir.
    private static let openCodeJSONFilename = "/opencode.json"

    /// Relative filename (including leading slash) for `AGENTS.md` under the OpenCode config dir.
    private static let agentsMDFilename = "/AGENTS.md"

    /// BEGIN delimiter for the Calyx IPC managed block in AGENTS.md.
    /// Must match the literal the tests search for.
    private static let beginDelimiter = "<!-- BEGIN CALYX IPC (managed by Calyx, do not edit) -->"

    /// END delimiter for the Calyx IPC managed block in AGENTS.md.
    private static let endDelimiter = "<!-- END CALYX IPC -->"

    /// Shared line-anchored editor for the AGENTS.md managed block: finds
    /// a well-formed BEGIN...END span by exact (whitespace-tolerant) line
    /// match, so user prose that merely mentions the marker text mid-line
    /// is never mistaken for a block boundary. AGENTS.md's body is fixed
    /// Markdown prose Calyx itself writes, with no structural shape (a
    /// YAML child key, a TOML sub-table) that can distinguish a user's own
    /// content from Calyx's once it ends up inside the span -- so unlike
    /// HermesConfigManager's and CodexHooksConfigManager's own marker
    /// editors, `foreignBodyBytes` is left `nil`: a well-formed BEGIN...END
    /// span is always Calyx's owned region in full, removed entirely
    /// regardless of whether its wording matches the body this Calyx
    /// version currently writes (older releases worded it differently).
    /// `isOwnBodyLine` only bounds the orphan-BEGIN (no matching END) self-
    /// heal scan, never a well-formed span.
    private static let agentsMDEditor = MarkerConfigDocumentEditor(
        beginLine: beginDelimiter,
        endLine: endDelimiter,
        isOwnBodyLine: { doc, index in isOwnAgentsMDOrphanBodyLine(doc, index) }
    )

    /// Bounds `agentsMDEditor`'s orphan-BEGIN self-heal scan above: whether
    /// `doc.lines[index]` still looks like part of Calyx's own generated
    /// block body. Judged by stable identifiers -- a blank line, or a line
    /// containing one of the Calyx IPC MCP tool names -- rather than exact
    /// wording, since `managedBlockBody`'s prose can change across Calyx
    /// releases while these tool names do not.
    private static func isOwnAgentsMDOrphanBodyLine(_ doc: LineDoc, _ index: Int) -> Bool {
        let line = String(decoding: doc.lineBytes(doc.lines[index]), as: UTF8.self)
        if line.isEmpty { return true }
        let ownIdentifiers = [
            "Calyx IPC", "register_peer", "receive_messages", "send_message", "list_peers", "broadcast",
        ]
        return ownIdentifiers.contains { line.contains($0) }
    }

    /// Managed-block body injected into AGENTS.md. This is the peer-messaging
    /// part of `MCPRouter.instructions` (the intro sentence, the
    /// register_peer paragraph, the receive_messages paragraph, and the
    /// list_peers/broadcast paragraph), formatted as Markdown.
    ///
    /// Note: kept as a stable constant so the canary substring
    /// `"call register_peer once"` remains present. The receive_messages
    /// once-only sentence is interpolated from `MCPRouter.
    /// receiveMessagesOnceNotice` rather than duplicated here verbatim,
    /// so this block and `MCPRouter`'s own instructions text can't drift
    /// out of sync.
    private static let managedBlockBody = """
    ## Calyx IPC

    You are connected to Calyx IPC, enabling communication with other Claude Code instances in other terminal panes.

    Immediately after connecting, call register_peer once with a descriptive name based on your current task or working directory, and a role describing your function. Do not call register_peer again in the same session.

    After completing any significant task, call receive_messages to check for messages from other peers. \(MCPRouter.receiveMessagesOnceNotice) — process and respond via send_message as soon as you receive it.

    Use list_peers to discover other connected instances. Use broadcast for announcements relevant to all peers.
    """

    // MARK: - Public API

    /// Enables the Calyx IPC MCP entry in OpenCode's `opencode.json` and appends
    /// (or replaces) the managed block in `AGENTS.md`.
    ///
    /// Both files are written atomically under independent `flock`-based locks.
    /// A symlinked target path is followed to its real file
    /// (`ConfigFileUtils.resolveConfigPath`) and written through, leaving the
    /// symlink itself intact — a dotfiles-managed OpenCode config root
    /// commonly symlinks these files elsewhere.
    ///
    /// Both resolved paths are preflight-checked for writability (their
    /// parent directory exists) before either file is touched: without
    /// this, a failure resolving/writing the *second* file (`AGENTS.md`)
    /// could leave `opencode.json` enabled while `AGENTS.md`'s managed
    /// block was never written, a partially-enabled state that's
    /// confusing to recover from.
    static func enableIPC(port: Int, token: String, configDir: String? = nil) throws {
        let dir = configDir ?? defaultConfigDir
        let jsonPath = try ConfigFileUtils.resolveConfigPath(dir + Self.openCodeJSONFilename)
        let agentsPath = try ConfigFileUtils.resolveConfigPath(dir + Self.agentsMDFilename)

        try preflightWritable(jsonPath)
        try preflightWritable(agentsPath)

        try upsertOpenCodeJSON(port: port, token: token, path: jsonPath)
        try upsertAgentsMD(path: agentsPath)
    }

    /// Disables the Calyx IPC entry by removing `mcp.calyx-ipc` from `opencode.json`
    /// and removing the managed block from `AGENTS.md`. Missing files are a no-op.
    static func disableIPC(configDir: String? = nil) throws {
        let dir = configDir ?? defaultConfigDir
        let jsonPath = try ConfigFileUtils.resolveConfigPath(dir + Self.openCodeJSONFilename)
        let agentsPath = try ConfigFileUtils.resolveConfigPath(dir + Self.agentsMDFilename)

        try removeFromOpenCodeJSON(path: jsonPath)
        try removeFromAgentsMD(path: agentsPath)
    }

    /// Returns whether the Calyx IPC MCP entry is present in `opencode.json`.
    /// Returns `false` if the file is missing, invalid, lacks the entry, or
    /// `configDir`'s symlink chain can't be resolved.
    /// Does not inspect AGENTS.md — authoritative truth is opencode.json.
    static func isIPCEnabled(configDir: String? = nil) -> Bool {
        let dir = configDir ?? defaultConfigDir
        guard let jsonPath = try? ConfigFileUtils.resolveConfigPath(dir + Self.openCodeJSONFilename) else {
            return false
        }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: jsonPath)) else { return false }
        return JSONConfigDocumentEditor.containsValue(at: [mcpKey, calyxIPCKey], in: data)
    }

    // MARK: - Private: Preflight

    /// Checks that `path`'s parent directory exists, so a subsequent
    /// `atomicWrite` there won't fail outright. Used by `enableIPC` to
    /// verify both `opencode.json` and `AGENTS.md`'s resolved paths
    /// before writing either — see `enableIPC`'s doc comment.
    private static func preflightWritable(_ path: String) throws {
        let parentDir = (path as NSString).deletingLastPathComponent
        guard ConfigFileUtils.directoryExists(at: parentDir) else {
            throw OpenCodeConfigError.writeFailed("parent directory does not exist: \(parentDir)")
        }
    }

    // MARK: - Private: opencode.json

    private static func upsertOpenCodeJSON(port: Int, token: String, path: String) throws {
        // Build the calyx-ipc entry fresh — no merge, guarantees stale header keys
        // are not retained across upserts.
        let calyxEntry: [String: Any] = [
            "type": "remote",
            "url": "http://127.0.0.1:\(port)/mcp",
            "headers": [
                "Authorization": "Bearer \(token)",
                "X-Calyx-Surface-ID": "{env:CALYX_SURFACE_ID}",
                "X-Calyx-Session-ID": "{env:CALYX_SESSION_ID}",
                "X-Calyx-Agent-Kind": AgentEntry.openCodeKind,
            ]
        ]
        // .sortedKeys: see ClaudeConfigManager.enableIPC's identical
        // comment -- without it this entry's bytes are not stable across
        // process launches, defeating withExclusiveConfig's no-write check.
        let entryData = try JSONSerialization.data(withJSONObject: calyxEntry, options: [.sortedKeys])
        // Same host, port and identity headers as calyx-ipc, plus the herdr
        // pane and socket headers `/calyx-mcp` resolves a herdr pane by.
        let calyxMCPEntry: [String: Any] = [
            "type": "remote",
            "url": "http://127.0.0.1:\(port)\(HTTPParser.calyxMCPPath)",
            "headers": [
                "Authorization": "Bearer \(token)",
                "X-Calyx-Surface-ID": "{env:CALYX_SURFACE_ID}",
                "X-Calyx-Session-ID": "{env:CALYX_SESSION_ID}",
                "X-Calyx-Agent-Kind": AgentEntry.openCodeKind,
                "X-Calyx-Herdr-Pane-ID": "{env:HERDR_PANE_ID}",
                "X-Calyx-Herdr-Socket-Path": "{env:HERDR_SOCKET_PATH}",
            ]
        ]
        let calyxMCPEntryData = try JSONSerialization.data(withJSONObject: calyxMCPEntry, options: [.sortedKeys])

        do {
            // 0600: these entries carry the bearer token.
            try ConfigFileUtils.withExclusiveConfig(path: path, mode: 0o600) { current in
                // A 0-byte file (a pre-created empty file) is treated the same
                // as an absent one: `JSONConfigDocumentEditor` already starts
                // a fresh `{}` for both `nil` and empty input.
                let withIPC = try JSONConfigDocumentEditor.setValue(entryData, at: [mcpKey, calyxIPCKey], in: current)
                return try JSONConfigDocumentEditor.setValue(calyxMCPEntryData, at: [mcpKey, calyxMCPKey], in: withIPC)
            }
        } catch ConfigFileError.invalidJSON {
            // Preserve this manager's own public error type for a
            // malformed root document: this call site's contract predates
            // the shared editor and is unrelated to it.
            throw OpenCodeConfigError.invalidJSON
        }
    }

    private static func removeFromOpenCodeJSON(path: String) throws {
        do {
            // mode: nil -- disable writes no secret, only removes the
            // entry that carried one, so it must preserve whatever mode
            // the user's file already has rather than forcing 0600 (that
            // mode belongs to upsertOpenCodeJSON, which writes the
            // token).
            try ConfigFileUtils.withExclusiveConfig(path: path) { current in
                // A 0-byte file has nothing to remove and is left exactly as it
                // was: `JSONConfigDocumentEditor.removeValue` passes empty
                // input straight through unchanged.
                let withoutIPC = try JSONConfigDocumentEditor.removeValue(at: [mcpKey, calyxIPCKey], in: current)
                return try JSONConfigDocumentEditor.removeValue(at: [mcpKey, calyxMCPKey], in: withoutIPC)
            }
        } catch ConfigFileError.invalidJSON {
            throw OpenCodeConfigError.invalidJSON
        }
    }

    // MARK: - Private: AGENTS.md

    private static func upsertAgentsMD(path: String) throws {
        // mode: nil (leave the mode as-is): AGENTS.md is a user-owned
        // prompt file with no secret in it.
        try ConfigFileUtils.withExclusiveConfig(path: path) { current in
            try agentsMDEditor.setBlock(body: managedBlockBody, in: current)
        }
    }

    private static func removeFromAgentsMD(path: String) throws {
        try ConfigFileUtils.withExclusiveConfig(path: path) { current in
            try agentsMDEditor.removeBlock(in: current)
        }
    }

    // MARK: - Private: Defaults

    private static var defaultConfigDir: String {
        AgentToolPaths.openCodeConfigDirectory
    }
}
