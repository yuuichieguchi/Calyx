// ClaudeConfigManager.swift
// Calyx
//
// Manages reading/writing ~/.claude.json for the Calyx IPC MCP server.

import Foundation

// MARK: - ClaudeConfigManager

struct ClaudeConfigManager: Sendable {

    private static let mcpServersKey = "mcpServers"
    private static let calyxIPCKey = "calyx-ipc"

    // MARK: - Public API

    static func enableIPC(port: Int, token: String, configPath: String? = nil) throws {
        let path = configPath ?? defaultConfigPath

        var config = try ConfigFileUtils.readConfigWithBackup(path: path)

        // Ensure mcpServers key exists
        var mcpServers = config[mcpServersKey] as? [String: Any] ?? [:]

        // Add/update calyx-ipc entry.
        //
        // `X-Calyx-Surface-ID` (Round 4) carries the pane's surface ID via
        // Claude Code's own `${VAR}` header env-expansion, so
        // `CalyxMCPServer` can bind surface -> peer at MCP `initialize`
        // time even for a passive recipient that never calls a calyx-ipc
        // tool. Must be the `${CALYX_SURFACE_ID:-}` empty-default form: an
        // undefined variable with no default fails Claude Code's config
        // parse entirely, which would break every *other* terminal (one
        // with no `CALYX_SURFACE_ID` env, e.g. outside Calyx) too. An
        // empty header value is treated as "no binding" server-side, so
        // the empty default is always safe.
        let calyxEntry: [String: Any] = [
            "type": "http",
            "url": "http://127.0.0.1:\(port)/mcp",
            "headers": [
                "Authorization": "Bearer \(token)",
                "X-Calyx-Surface-ID": "${CALYX_SURFACE_ID:-}"
            ]
        ]
        mcpServers[calyxIPCKey] = calyxEntry
        config[mcpServersKey] = mcpServers

        // Serialize
        let outputData = try JSONSerialization.data(
            withJSONObject: config,
            options: [.prettyPrinted, .sortedKeys]
        )

        // Atomic write with file locking
        try ConfigFileUtils.atomicWrite(data: outputData, to: path)
    }

    static func disableIPC(configPath: String? = nil) throws {
        let path = configPath ?? defaultConfigPath

        var config = try ConfigFileUtils.readConfigWithBackup(path: path)

        // Remove calyx-ipc from mcpServers
        guard var mcpServers = config[mcpServersKey] as? [String: Any] else {
            // No mcpServers key → nothing to remove
            return
        }

        mcpServers.removeValue(forKey: calyxIPCKey)

        // If mcpServers is now empty, remove the key entirely
        if mcpServers.isEmpty {
            config.removeValue(forKey: mcpServersKey)
        } else {
            config[mcpServersKey] = mcpServers
        }

        // Serialize
        let outputData = try JSONSerialization.data(
            withJSONObject: config,
            options: [.prettyPrinted, .sortedKeys]
        )

        // Atomic write with file locking
        try ConfigFileUtils.atomicWrite(data: outputData, to: path)
    }

    /// Returns `false` (rather than throwing) when `configPath`'s symlink
    /// chain can't be resolved — this is a read-only status check, and
    /// every other unreadable/invalid-file case here already resolves to
    /// `false` the same way.
    static func isIPCEnabled(configPath: String? = nil) -> Bool {
        guard let path = try? ConfigFileUtils.resolveConfigPath(configPath ?? defaultConfigPath) else {
            return false
        }
        let fm = FileManager.default

        guard fm.fileExists(atPath: path) else { return false }

        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let parsed = try? JSONSerialization.jsonObject(with: data),
              let config = parsed as? [String: Any],
              let mcpServers = config[mcpServersKey] as? [String: Any] else {
            return false
        }

        return mcpServers[calyxIPCKey] != nil
    }

    // MARK: - Private

    private static var defaultConfigPath: String {
        NSHomeDirectory() + "/.claude.json"
    }

}
