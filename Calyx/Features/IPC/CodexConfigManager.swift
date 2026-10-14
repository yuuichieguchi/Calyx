// CodexConfigManager.swift
// Calyx
//
// Manages reading/writing ~/.codex/config.toml for the Calyx IPC MCP server.

import Foundation

// MARK: - CodexConfigError

enum CodexConfigError: Error, LocalizedError {
    case directoryNotFound

    var errorDescription: String? {
        switch self {
        case .directoryNotFound:
            return "The ~/.codex/ directory does not exist"
        }
    }
}

// MARK: - CodexConfigManager

struct CodexConfigManager: Sendable {

    // MARK: - Private

    private static let tableEditor = TOMLTableConfigDocumentEditor(tablePath: "mcp_servers.calyx-ipc")
    /// The `/calyx-mcp` table, beside `calyx-ipc`.
    private static let calyxMCPTableEditor = TOMLTableConfigDocumentEditor(tablePath: "mcp_servers.calyx-mcp")

    // MARK: - Public API

    /// `headersHelperPath` non-nil (the installed `calyx-mcp-headers`):
    /// both tables carry `http_headers_helper`
    /// (`MCPHeadersHelperScript.helperCommand(path:port:)`: quoted path
    /// plus port, so a session on an older port gets `{}`) and
    /// `http_headers` keeps only `X-Calyx-Agent-Kind`. V3-3: Codex reruns
    /// the helper once on a 401, and an explicit `Authorization` in
    /// `http_headers` would win over the helper, so it is left out.
    /// nil: today's baked-in `Authorization`, byte for byte.
    static func enableIPC(port: Int, token: String, headersHelperPath: String? = nil, configPath: String? = nil) throws {
        let path = configPath ?? defaultConfigPath
        let resolvedPath = try ConfigFileUtils.resolveConfigPath(path)
        let parentDir = (resolvedPath as NSString).deletingLastPathComponent

        // Parent directory must exist
        guard ConfigFileUtils.directoryExists(at: parentDir) else {
            throw CodexConfigError.directoryNotFound
        }

        // The table's body, beneath the synthesized `[mcp_servers.calyx-ipc]`
        // header `setTable` writes.
        //
        // `env_http_headers` tells Codex to read each header's value from
        // its own process environment rather than send a literal string.
        // Inside a persistent calyx-session pane, CALYX_SURFACE_ID does not
        // identify the pane (absent with a current session daemon, stale
        // with an older one still running), so `X-Calyx-Session-ID` carries
        // the identity that has to be sent instead; see
        // `CalyxMCPServer.resolveSurfaceID`'s doc comment for how the two
        // headers are resolved. Measured against real codex 0.148.0: when
        // CALYX_SESSION_ID is unset (an ordinary, non-persistent pane),
        // Codex omits that header entirely rather than sending an empty
        // value, so the surface header alone still resolves exactly as
        // before.
        let headerLines: String
        if let headersHelperPath {
            let command = MCPHeadersHelperScript.helperCommand(path: headersHelperPath, port: port)
                .replacingOccurrences(of: "\"", with: "\\\"")
            headerLines = """
            http_headers_helper = "\(command)"
            http_headers = { "X-Calyx-Agent-Kind" = "\(AgentEntry.codexKind)" }
            """
        } else {
            headerLines = """
            http_headers = { "Authorization" = "Bearer \(token)", "X-Calyx-Agent-Kind" = "\(AgentEntry.codexKind)" }
            """
        }

        let body = """
        url = "http://127.0.0.1:\(port)/mcp"
        \(headerLines)
        env_http_headers = { "X-Calyx-Surface-ID" = "CALYX_SURFACE_ID", "X-Calyx-Session-ID" = "CALYX_SESSION_ID" }
        """

        // Same host, port and headers as calyx-ipc, plus the herdr pane and
        // socket headers `/calyx-mcp` resolves a herdr pane by. Codex omits
        // an env header whose variable is unset.
        let calyxMCPBody = """
        url = "http://127.0.0.1:\(port)\(HTTPParser.calyxMCPPath)"
        \(headerLines)
        env_http_headers = { "X-Calyx-Surface-ID" = "CALYX_SURFACE_ID", "X-Calyx-Session-ID" = "CALYX_SESSION_ID", "X-Calyx-Herdr-Pane-ID" = "HERDR_PANE_ID", "X-Calyx-Herdr-Socket-Path" = "HERDR_SOCKET_PATH" }
        """

        // 0600: this table carries the bearer token (baked-in form; kept
        // for the helper form too). ~/.codex/config.toml
        // is shared with CodexHooksConfigManager's hooks block, which
        // carries no token and therefore leaves the file's mode alone
        // (mode: nil) -- one file, two policies, deliberately: whichever
        // manager's write actually contains the secret is the one that
        // enforces the mode.
        try ConfigFileUtils.withExclusiveConfig(path: path, mode: 0o600) { current in
            let withIPC = try tableEditor.setTable(body: body, in: current)
            return try calyxMCPTableEditor.setTable(body: calyxMCPBody, in: withIPC)
        }
    }

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

    /// Returns `false` (rather than throwing) when `configPath`'s symlink
    /// chain can't be resolved, or the file doesn't exist or can't be
    /// read — this is a read-only status check.
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

    private static var defaultConfigPath: String {
        AgentToolPaths.codexConfigDirectory + "/config.toml"
    }
}
