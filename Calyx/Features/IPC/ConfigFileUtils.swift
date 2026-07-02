// ConfigFileUtils.swift
// Calyx

import Foundation

enum ConfigFileError: Error, LocalizedError, Sendable {
    case symlinkDetected
    case invalidJSON
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .symlinkDetected:
            return "The config path is a symlink, which is not allowed for security reasons"
        case .invalidJSON:
            return "The config file contains invalid JSON"
        case .writeFailed(let reason):
            return "Failed to write config file: \(reason)"
        }
    }
}

struct ConfigFileUtils: Sendable {

    static func isSymlink(at path: String) -> Bool {
        var statBuf = stat()
        guard lstat(path, &statBuf) == 0 else { return false }
        return (statBuf.st_mode & S_IFMT) == S_IFLNK
    }

    /// Checks that a path exists and is a directory (not a file). Shared by
    /// every agent-tool config manager's "is this tool even installed"
    /// pre-check, so that check exists in exactly one place.
    static func directoryExists(at path: String) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
    }

    /// Reads, parses, and backs up a JSON config file: rejects a
    /// symlinked `path`, returns `[:]` when `path` doesn't exist yet (an
    /// empty starting config — there is nothing to back up), otherwise
    /// parses the file's JSON object and writes a `.bak` backup (0600) of
    /// the original bytes before returning. Shared by `ClaudeConfigManager`
    /// and `ClaudeHooksConfigManager` so the symlink-check / exists-check /
    /// read / parse / backup sequence, and its safety guarantees, exist in
    /// exactly one place.
    static func readConfigWithBackup(path: String) throws -> [String: Any] {
        guard !isSymlink(at: path) else {
            throw ConfigFileError.symlinkDetected
        }
        guard FileManager.default.fileExists(atPath: path) else { return [:] }

        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard let parsed = try? JSONSerialization.jsonObject(with: data),
              let dict = parsed as? [String: Any] else {
            throw ConfigFileError.invalidJSON
        }

        let bakPath = path + ".bak"
        try data.write(to: URL(fileURLWithPath: bakPath))
        chmod(bakPath, 0o600)

        return dict
    }

    static func atomicWrite(data: Data, to path: String, lockPath: String) throws {
        let lockFd = open(lockPath, O_WRONLY | O_CREAT, 0o600)
        guard lockFd >= 0 else {
            throw ConfigFileError.writeFailed("Cannot create lock file")
        }
        defer {
            flock(lockFd, LOCK_UN)
            close(lockFd)
        }

        guard flock(lockFd, LOCK_EX) == 0 else {
            throw ConfigFileError.writeFailed("Cannot acquire lock")
        }

        let tempPath = path + ".tmp"

        try data.write(to: URL(fileURLWithPath: tempPath))
        chmod(tempPath, 0o600)

        guard rename(tempPath, path) == 0 else {
            try? FileManager.default.removeItem(atPath: tempPath)
            throw ConfigFileError.writeFailed("Rename failed")
        }

        chmod(path, 0o600)
    }
}
