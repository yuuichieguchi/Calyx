// ClaudeConfigManager.swift
// Calyx
//
// Manages reading/writing ~/.claude.json for the Calyx IPC MCP server.

import Foundation

// MARK: - ClaudeConfigError

enum ClaudeConfigError: Error, LocalizedError {
    case invalidJSON
    case symlinkDetected
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidJSON:
            return "The config file contains invalid JSON"
        case .symlinkDetected:
            return "The config path is a symlink, which is not allowed for security reasons"
        case .writeFailed(let reason):
            return "Failed to write config file: \(reason)"
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
        guard !isSymlink(at: path) else {
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

            config = dict
        } else {
            config = [:]
        }

        // Ensure mcpServers key exists
        var mcpServers = config[mcpServersKey] as? [String: Any] ?? [:]

        // Add/update calyx-ipc entry
        let calyxEntry: [String: Any] = [
            "type": "http",
            "url": "http://localhost:\(port)/mcp",
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
        try atomicWrite(data: outputData, to: path)
    }

    static func disableIPC(configPath: String? = nil) throws {
        let path = configPath ?? defaultConfigPath
        let fm = FileManager.default

        // No file → no-op
        guard fm.fileExists(atPath: path) else { return }

        // Security: reject symlinks
        guard !isSymlink(at: path) else {
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
        try atomicWrite(data: outputData, to: path)
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

    private static func isSymlink(at path: String) -> Bool {
        var statBuf = stat()
        guard lstat(path, &statBuf) == 0 else { return false }
        return (statBuf.st_mode & S_IFMT) == S_IFLNK
    }

    private static func atomicWrite(data: Data, to path: String) throws {
        let lockPath = path + ".lock"
        let lockFd = open(lockPath, O_WRONLY | O_CREAT, 0o600)
        guard lockFd >= 0 else {
            throw ClaudeConfigError.writeFailed("Cannot create lock file")
        }
        defer {
            flock(lockFd, LOCK_UN)
            close(lockFd)
        }

        guard flock(lockFd, LOCK_EX) == 0 else {
            throw ClaudeConfigError.writeFailed("Cannot acquire lock")
        }

        let tempPath = path + ".tmp"

        // Write to temp file
        try data.write(to: URL(fileURLWithPath: tempPath), options: .atomic)
        // Set permissions to 0600 (owner read/write only)
        chmod(tempPath, 0o600)

        // Rename (atomic on same filesystem)
        guard rename(tempPath, path) == 0 else {
            try? FileManager.default.removeItem(atPath: tempPath)
            throw ClaudeConfigError.writeFailed("Rename failed")
        }

        // Ensure final file has correct permissions
        chmod(path, 0o600)
    }
}
