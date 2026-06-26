// ClaudeConfigManager.swift
// Calyx
//
// Manages reading/writing ~/.claude.json for the Calyx IPC MCP server.

import Foundation

// MARK: - ClaudeConfigError

enum ClaudeConfigError: Error, LocalizedError {
    case invalidJSON
    case symlinkDetected

    var errorDescription: String? {
        switch self {
        case .invalidJSON:
            return "The config file contains invalid JSON"
        case .symlinkDetected:
            return "The config path is a symlink, which is not allowed for security reasons"
        }
    }
}

// MARK: - ClaudeConfigManager

struct ClaudeConfigManager: Sendable {

    private static let mcpServersKey = "mcpServers"
    private static let calyxIPCKey = "calyx-ipc"

    // MARK: - Public API

    static func enableIPC(port: Int, token: String, configPath: String? = nil) throws {
        let path = configPath ?? defaultConfigPath

        // Security: reject symlinks
        guard !ConfigFileUtils.isSymlink(at: path) else {
            throw ClaudeConfigError.symlinkDetected
        }

        let fm = FileManager.default
        var config: [String: Any]

        if fm.fileExists(atPath: path) {
            // Read existing content
            let data = try Data(contentsOf: URL(fileURLWithPath: path))

            // Parse JSON
            guard let parsed = try? JSONSerialization.jsonObject(with: data),
                  let dict = parsed as? [String: Any] else {
                throw ClaudeConfigError.invalidJSON
            }

            // Create backup with the original content
            let bakPath = path + ".bak"
            try data.write(to: URL(fileURLWithPath: bakPath))
            chmod(bakPath, 0o600)

            config = dict
        } else {
            config = [:]
        }

        // Ensure mcpServers key exists
        var mcpServers = config[mcpServersKey] as? [String: Any] ?? [:]

        // Add/update calyx-ipc entry
        let calyxEntry: [String: Any] = [
            "type": "http",
            "url": "http://127.0.0.1:\(port)/mcp",
            "headers": [
                "Authorization": "Bearer \(token)"
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
        try ConfigFileUtils.atomicWrite(data: outputData, to: path, lockPath: path + ".lock")
    }

    static func disableIPC(configPath: String? = nil) throws {
        let path = configPath ?? defaultConfigPath
        let fm = FileManager.default

        // No file → no-op
        guard fm.fileExists(atPath: path) else { return }

        // Security: reject symlinks
        guard !ConfigFileUtils.isSymlink(at: path) else {
            throw ClaudeConfigError.symlinkDetected
        }

        let data = try Data(contentsOf: URL(fileURLWithPath: path))

        guard let parsed = try? JSONSerialization.jsonObject(with: data),
              var config = parsed as? [String: Any] else {
            throw ClaudeConfigError.invalidJSON
        }

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
        try ConfigFileUtils.atomicWrite(data: outputData, to: path, lockPath: path + ".lock")
    }

    static func isIPCEnabled(configPath: String? = nil) -> Bool {
        let path = configPath ?? defaultConfigPath
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
