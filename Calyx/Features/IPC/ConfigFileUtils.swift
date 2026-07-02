// ConfigFileUtils.swift
// Calyx

import CryptoKit
import Foundation

enum ConfigFileError: Error, LocalizedError, Sendable, Equatable {
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

    /// Upper bound on the number of symlink hops `resolveConfigPath`
    /// follows before giving up. Real dotfiles setups resolve in 1-2
    /// hops; this exists purely as a finite backstop against a
    /// self-referencing loop (see `resolveConfigPath`'s doc comment).
    static let maxSymlinkHops = 8

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

    /// Reads, parses, and backs up a JSON config file: resolves `path`
    /// (`resolveConfigPath`) before touching the filesystem, returns
    /// `[:]` when the resolved path doesn't exist yet (an empty starting
    /// config — there is nothing to back up), otherwise parses the
    /// file's JSON object and writes a `.bak` backup (0600) of the
    /// original bytes before returning. Shared by `ClaudeConfigManager`
    /// and `ClaudeHooksConfigManager` so the resolve / exists-check /
    /// read / parse / backup sequence, and its safety guarantees, exist
    /// in exactly one place. Propagates `resolveConfigPath`'s
    /// `.symlinkDetected` for an unresolvable chain — there is no
    /// separate symlink-rejection guard here, since a path this function
    /// returns from without throwing is, by `resolveConfigPath`'s own
    /// construction, never itself a symlink.
    static func readConfigWithBackup(path: String) throws -> [String: Any] {
        let resolvedPath = try resolveConfigPath(path)
        guard FileManager.default.fileExists(atPath: resolvedPath) else { return [:] }

        let data = try Data(contentsOf: URL(fileURLWithPath: resolvedPath))
        guard let parsed = try? JSONSerialization.jsonObject(with: data),
              let dict = parsed as? [String: Any] else {
            throw ConfigFileError.invalidJSON
        }

        let bakPath = resolvedPath + ".bak"
        try data.write(to: URL(fileURLWithPath: bakPath))
        chmod(bakPath, 0o600)

        return dict
    }

    /// Resolves `path` to the real file it should be read from / written
    /// to, following a chain of intermediate and final symlinks
    /// (dotfiles-style setups commonly symlink `~/.claude/settings.json`
    /// etc. to a managed repo) up to `maxSymlinkHops` hops.
    ///
    /// Each hop: if the current path isn't itself a symlink,
    /// `resolvingSymlinksInPath` is applied (to also resolve any
    /// symlinked intermediate directory components) and the result is
    /// returned — this covers both a plain file and a symlink chain that
    /// terminates at an existing file. Otherwise the symlink's
    /// destination is read directly (absolutized against the link's own
    /// directory if relative) and resolution continues from there — this
    /// is what makes a multi-hop *dangling* chain (link → link → not-yet-
    /// existing file) resolve all the way to the final destination
    /// instead of stopping at the first intermediate link, which would
    /// otherwise cause a write to land on — and replace — that
    /// intermediate symlink instead of creating the intended target file.
    ///
    /// Throws `ConfigFileError.symlinkDetected` if the chain revisits a
    /// path already seen (a self-referencing loop) or exceeds
    /// `maxSymlinkHops` without terminating — both cases mean the target
    /// this path should resolve to can't be determined, so proceeding
    /// with a read or write would be unsafe.
    static func resolveConfigPath(_ path: String) throws -> String {
        let fileManager = FileManager.default
        var current = (path as NSString).standardizingPath
        var visited: Set<String> = []

        for _ in 0..<maxSymlinkHops {
            guard isSymlink(at: current) else {
                return (current as NSString).resolvingSymlinksInPath
            }
            guard visited.insert(current).inserted else {
                throw ConfigFileError.symlinkDetected
            }
            guard let destination = try? fileManager.destinationOfSymbolicLink(atPath: current) else {
                return current
            }

            if (destination as NSString).isAbsolutePath {
                current = (destination as NSString).standardizingPath
            } else {
                let linkDirectory = (current as NSString).deletingLastPathComponent
                let resolvedLinkDirectory = (linkDirectory as NSString).resolvingSymlinksInPath
                current = ((resolvedLinkDirectory as NSString).appendingPathComponent(destination) as NSString).standardizingPath
            }
        }

        throw ConfigFileError.symlinkDetected
    }

    /// Atomically writes `data` to `path`: resolves `path`
    /// (`resolveConfigPath`) first so the write lands on a symlink's real
    /// target rather than replacing the symlink itself (`rename(2)`
    /// replaces whatever is at its destination argument, symlink or not,
    /// without following it), then locks (`lockFilePath(forResolvedPath:)`),
    /// writes to a `<resolved>.tmp` sibling, and renames it into place.
    ///
    /// The lock file is deliberately never unlinked. Deleting a
    /// `flock`-based lock file after use is the classic unsafe "dotlock"
    /// pattern: the lock file identifies a *lock*, not a *path* — once
    /// unlinked, a third process racing to open the (now-recreated) path
    /// gets a brand-new, unrelated inode, so it and whichever process was
    /// already holding the original inode's lock both believe they hold
    /// "the" lock while actually holding independent locks on two
    /// different inodes, silently voiding the exclusion the lock exists
    /// to provide. An earlier version of this function did unlink the
    /// lock file (to avoid it becoming a tracked-changes artifact in a
    /// dotfiles repo the resolved config lives in) — `lockFilePath`
    /// achieves that same goal safely, by placing the lock file outside
    /// the resolved config's own directory entirely, where letting it
    /// persist forever has no git-hygiene downside.
    static func atomicWrite(data: Data, to path: String) throws {
        let resolvedPath = try resolveConfigPath(path)
        let lockPath = try lockFilePath(forResolvedPath: resolvedPath)

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

        let tempPath = resolvedPath + ".tmp"

        try data.write(to: URL(fileURLWithPath: tempPath))
        chmod(tempPath, 0o600)

        guard rename(tempPath, resolvedPath) == 0 else {
            try? FileManager.default.removeItem(atPath: tempPath)
            throw ConfigFileError.writeFailed("Rename failed")
        }

        chmod(resolvedPath, 0o600)
    }

    /// Maps `resolvedPath` to a stable lock-file path inside Calyx's own
    /// `<AppSupportDirectory>/locks/` directory (created on first use),
    /// rather than a sibling of `resolvedPath` itself — see
    /// `atomicWrite`'s doc comment for why the lock file lives outside
    /// the resolved config's own directory and is never deleted.
    ///
    /// The lock file's name is a SHA-256 hex digest of `resolvedPath`:
    /// every process/thread writing to the same resolved path computes
    /// the identical name and therefore contends on the identical inode
    /// (unlike `String.hashValue`, which is randomized per process
    /// launch and would defect this). A hash collision between two
    /// *different* resolved paths is cryptographically negligible, and
    /// even in that theoretical case the failure mode is fail-safe, not
    /// fail-dangerous: the two unrelated config files would merely
    /// serialize their writes against each other, never corrupt one
    /// another.
    ///
    /// Not `private`: exposed at `internal` visibility so tests can
    /// locate a given resolved path's lock file directly (to verify it
    /// persists, and that concurrent `atomicWrite` calls against the same
    /// resolved path actually block on it) without duplicating this
    /// hashing logic.
    static func lockFilePath(forResolvedPath resolvedPath: String) throws -> String {
        let locksDir = (AppSupportDirectory.path as NSString).appendingPathComponent("locks")
        if !FileManager.default.fileExists(atPath: locksDir) {
            try FileManager.default.createDirectory(atPath: locksDir, withIntermediateDirectories: true)
        }
        let digest = SHA256.hash(data: Data(resolvedPath.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return (locksDir as NSString).appendingPathComponent(hex + ".lock")
    }
}
