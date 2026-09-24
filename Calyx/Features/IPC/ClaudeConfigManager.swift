// ClaudeConfigManager.swift
// Calyx
//
// Manages reading/writing ~/.claude.json for the Calyx IPC MCP server.

import Foundation

// MARK: - ClaudeConfigManager

struct ClaudeConfigManager: Sendable {

    private static let mcpServersKey = "mcpServers"
    private static let calyxIPCKey = "calyx-ipc"
    /// The `/calyx-mcp` entry: the tools of the MCP servers configured in
    /// Calyx, re-published, approved separately from `calyx-ipc`.
    private static let calyxMCPKey = "calyx-mcp"

    // MARK: - Public API

    static func enableIPC(port: Int, token: String, configPath: String? = nil) throws {
        let path = configPath ?? defaultConfigPath

        // Claude Code expands `${VAR}` header values from its own process
        // environment. Inside a persistent calyx-session pane,
        // CALYX_SURFACE_ID does not identify the pane (absent with a
        // current session daemon, stale with an older one still running),
        // so `X-Calyx-Session-ID` carries the identity that has to be sent
        // instead; see `CalyxMCPServer.resolveSurfaceID`'s doc comment for
        // how the two headers are resolved.
        //
        // Both must be the `${VAR:-}` empty-default form: an undefined
        // variable with no default fails Claude Code's config parse
        // entirely, which would break every *other* terminal (one with no
        // such env var, e.g. outside Calyx) too. An empty header value is
        // treated as "no binding" server-side, so the empty default is
        // always safe.
        let calyxEntry: [String: Any] = [
            "type": "http",
            "url": "http://127.0.0.1:\(port)/mcp",
            "headers": [
                "Authorization": "Bearer \(token)",
                "X-Calyx-Surface-ID": "${CALYX_SURFACE_ID:-}",
                "X-Calyx-Session-ID": "${CALYX_SESSION_ID:-}"
            ]
        ]
        // .sortedKeys: JSONSerialization on a Swift Dictionary otherwise
        // emits keys in an order seeded per process launch, so without it
        // this entry's own bytes would differ across launches even when
        // its content doesn't -- defeating withExclusiveConfig's
        // input-equals-output no-write check on every restart.
        let entryData = try JSONSerialization.data(withJSONObject: calyxEntry, options: [.sortedKeys])

        // Same host, port and identity headers as calyx-ipc, plus the herdr
        // pane and socket headers `/calyx-mcp` resolves a herdr pane by.
        // `${HERDR_SOCKET_PATH:-}` is empty unless the user set it; the
        // server then looks the pane up under herdr's default socket.
        let calyxMCPEntry: [String: Any] = [
            "type": "http",
            "url": "http://127.0.0.1:\(port)\(HTTPParser.calyxMCPPath)",
            "headers": [
                "Authorization": "Bearer \(token)",
                "X-Calyx-Surface-ID": "${CALYX_SURFACE_ID:-}",
                "X-Calyx-Session-ID": "${CALYX_SESSION_ID:-}",
                "X-Calyx-Herdr-Pane-ID": "${HERDR_PANE_ID:-}",
                "X-Calyx-Herdr-Socket-Path": "${HERDR_SOCKET_PATH:-}"
            ]
        ]
        let calyxMCPEntryData = try JSONSerialization.data(withJSONObject: calyxMCPEntry, options: [.sortedKeys])

        // 0600: these entries carry the bearer token, so ~/.claude.json's
        // mode is enforced rather than left as-is.
        try ConfigFileUtils.withExclusiveConfig(path: path, mode: 0o600) { current in
            let withIPC = try JSONConfigDocumentEditor.setValue(entryData, at: [mcpServersKey, calyxIPCKey], in: current)
            return try JSONConfigDocumentEditor.setValue(calyxMCPEntryData, at: [mcpServersKey, calyxMCPKey], in: withIPC)
        }
    }

    static func disableIPC(configPath: String? = nil) throws {
        let path = configPath ?? defaultConfigPath

        // mode: nil -- disable writes no secret, only removes one, so it
        // must preserve whatever mode the user's file already has rather
        // than forcing 0600 (that mode belongs to enableIPC, which
        // writes the token).
        try ConfigFileUtils.withExclusiveConfig(path: path) { current in
            let withoutIPC = try JSONConfigDocumentEditor.removeValue(at: [mcpServersKey, calyxIPCKey], in: current)
            return try JSONConfigDocumentEditor.removeValue(at: [mcpServersKey, calyxMCPKey], in: withoutIPC)
        }
    }

    /// Returns `false` (rather than throwing) when `configPath`'s symlink
    /// chain can't be resolved — this is a read-only status check, and
    /// every other unreadable/invalid-file case here already resolves to
    /// `false` the same way.
    static func isIPCEnabled(configPath: String? = nil) -> Bool {
        guard let path = try? ConfigFileUtils.resolveConfigPath(configPath ?? defaultConfigPath) else {
            return false
        }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return false }
        return JSONConfigDocumentEditor.containsValue(at: [mcpServersKey, calyxIPCKey], in: data)
    }

    // MARK: - Private

    private static var defaultConfigPath: String {
        AgentToolPaths.claudeConfigPath
    }

}
