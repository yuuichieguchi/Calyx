// GrokConfigManager.swift
// Calyx
//
// Manages reading/writing ~/.grok/config.toml for the Calyx IPC MCP
// server. Grok's MCP client config is TOML, like Codex's, but its
// remote-server headers live in a `[mcp_servers.<name>.headers]`
// sub-table rather than Codex's inline `http_headers` / `env_http_headers`
// keys, and Grok expands `${VAR}` / `${VAR:-default}` inside every
// `[mcp_servers.*]` string field at load time, so the surface and
// session identities are interpolated from the environment directly
// instead of through a separate env-header mapping table.

import Foundation

// MARK: - GrokConfigError

enum GrokConfigError: Error, LocalizedError {
    case directoryNotFound

    var errorDescription: String? {
        switch self {
        case .directoryNotFound:
            return "The ~/.grok/ directory does not exist"
        }
    }
}

// MARK: - GrokConfigManager

struct GrokConfigManager: Sendable {

    // MARK: - Private

    private static let tableEditor = TOMLTableConfigDocumentEditor(tablePath: "mcp_servers.calyx-ipc")
    /// The `/calyx-mcp` table, beside `calyx-ipc`.
    private static let calyxMCPTableEditor = TOMLTableConfigDocumentEditor(tablePath: "mcp_servers.calyx-mcp")

    // MARK: - Public API

    /// Replaces any existing `[mcp_servers.calyx-ipc]` entry (its
    /// `[mcp_servers.calyx-ipc.headers]` sub-table included) with a
    /// freshly built one for `port`/`token`, preserving everything else
    /// in the file verbatim.
    ///
    /// The replacement is keyed on the section header alone, with no
    /// Calyx ownership marker: a `[mcp_servers.calyx-ipc]` entry a user
    /// (or an earlier experiment) wrote by hand is adopted and rewritten
    /// into the managed shape rather than duplicated. The entry name is
    /// Calyx's own, so nothing else can legitimately own it.
    ///
    /// Throws `.directoryNotFound` when `configPath`'s parent directory
    /// does not exist: Grok not being installed must never make Calyx
    /// create `~/.grok` on the user's behalf.
    static func enableIPC(port: Int, token: String, configPath: String? = nil) throws {
        let path = configPath ?? defaultConfigPath
        let resolvedPath = try ConfigFileUtils.resolveConfigPath(path)
        let parentDir = (resolvedPath as NSString).deletingLastPathComponent

        guard ConfigFileUtils.directoryExists(at: parentDir) else {
            throw GrokConfigError.directoryNotFound
        }

        let body = """
        url = "http://127.0.0.1:\(port)/mcp"

        [mcp_servers.calyx-ipc.headers]
        Authorization = "Bearer \(token)"
        X-Calyx-Agent-Kind = "\(AgentEntry.grokKind)"
        X-Calyx-Session-ID = "${CALYX_SESSION_ID:-}"
        X-Calyx-Surface-ID = "${CALYX_SURFACE_ID:-}"
        """

        // Same host, port and headers as calyx-ipc, plus the herdr pane and
        // socket headers `/calyx-mcp` resolves a herdr pane by.
        let calyxMCPBody = """
        url = "http://127.0.0.1:\(port)\(HTTPParser.calyxMCPPath)"

        [mcp_servers.calyx-mcp.headers]
        Authorization = "Bearer \(token)"
        X-Calyx-Agent-Kind = "\(AgentEntry.grokKind)"
        X-Calyx-Session-ID = "${CALYX_SESSION_ID:-}"
        X-Calyx-Surface-ID = "${CALYX_SURFACE_ID:-}"
        X-Calyx-Herdr-Pane-ID = "${HERDR_PANE_ID:-}"
        X-Calyx-Herdr-Socket-Path = "${HERDR_SOCKET_PATH:-}"
        """

        // 0600: both tables' headers sub-tables carry the bearer token.
        try ConfigFileUtils.withExclusiveConfig(path: path, mode: 0o600) { current in
            let withIPC = try tableEditor.setTable(body: body, in: current)
            return try calyxMCPTableEditor.setTable(body: calyxMCPBody, in: withIPC)
        }
    }

    /// Removes every `[mcp_servers.calyx-ipc]` entry (sub-tables
    /// included) from `configPath`, leaving the rest of the file
    /// untouched. A no-op when the file does not exist, or carries no
    /// such entry.
    static func disableIPC(configPath: String? = nil) throws {
        let path = configPath ?? defaultConfigPath
        // mode: nil -- disable writes no secret, only removes the table
        // that carried one, so it must preserve whatever mode the
        // user's file already has rather than forcing 0600 (that mode
        // belongs to enableIPC, which writes the token).
        try ConfigFileUtils.withExclusiveConfig(path: path) { current in
            let withoutIPC = try tableEditor.removeTable(in: current)
            return try calyxMCPTableEditor.removeTable(in: withoutIPC)
        }
    }

    /// Whether a `[mcp_servers.calyx-ipc]` section header is present.
    /// Returns `false` rather than throwing for an unresolvable symlink
    /// chain, matching `CodexConfigManager.isIPCEnabled`.
    static func isIPCEnabled(configPath: String? = nil) -> Bool {
        guard let path = try? ConfigFileUtils.resolveConfigPath(configPath ?? defaultConfigPath) else {
            return false
        }

        guard FileManager.default.fileExists(atPath: path),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            return false
        }

        return tableEditor.containsTable(in: data)
    }

    // MARK: - Private

    static var defaultConfigPath: String {
        AgentToolPaths.grokConfigDirectory + "/config.toml"
    }
}
