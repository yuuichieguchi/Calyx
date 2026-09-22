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
    /// path already seen (a self-referencing loop), exceeds
    /// `maxSymlinkHops` without terminating, or a symlink's own
    /// destination can't be read (e.g. a permissions error) — all three
    /// cases mean the target this path should resolve to can't be
    /// determined, so proceeding with a read or write would be unsafe.
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
                throw ConfigFileError.symlinkDetected
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
    static func atomicWrite(data: Data, to path: String, lockTimeout: TimeInterval = 10) throws {
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

        try acquireLock(lockFd, timeout: lockTimeout)

        // 0600: every current caller of atomicWrite (AgentEndpointFile.write)
        // writes a file Calyx owns outright and that carries the bearer
        // token, so this is unconditional rather than a parameter.
        try writeAtomically(data: data, toResolvedPath: resolvedPath, mode: 0o600)
    }

    /// Unlocked write body shared by `atomicWrite` and `withExclusiveConfig`.
    /// Writes to a `<resolvedPath>.tmp` sibling and renames it into place,
    /// exactly as `atomicWrite` did inline before this was extracted. Never
    /// call this without already holding the resolved path's lock — it does
    /// no locking of its own.
    ///
    /// `mode == nil` means "do not set or change the mode": the temp file
    /// is left at whatever `Data.write(to:)` gave it (the process umask
    /// applied to the default 0666), and the rename carries that mode
    /// straight through onto `resolvedPath`. This is this primitive's own
    /// general contract, not necessarily what either current caller
    /// exercises: `atomicWrite` always passes an explicit `0o600`, and
    /// `withExclusiveConfig` always resolves `mode` to a concrete value
    /// before calling this (the existing file's stat'd mode, or `0o600`
    /// for a file that doesn't exist yet, see its own doc comment), so
    /// `mode == nil` currently only reaches here if a future caller
    /// chooses to pass it.
    /// A non-nil `mode` is applied to the temp file before the rename
    /// (so a reader can never observe a wrong-mode window) and, redundantly,
    /// to the resolved path after; both `chmod` calls' results are checked,
    /// since a caller that requested a specific mode (most commonly because
    /// Calyx just wrote a secret into the file) must find out if that mode
    /// was not actually applied rather than silently publish the file at
    /// whatever mode the umask produced.
    private static func writeAtomically(data: Data, toResolvedPath resolvedPath: String, mode: mode_t?) throws {
        let tempPath = resolvedPath + ".tmp"
        // Recorded before this function touches `tempPath` at all, so a
        // failure below cleans up only the `.tmp` THIS write created,
        // never one that was already sitting there before this attempt.
        let tempPathExistedBefore = FileManager.default.fileExists(atPath: tempPath)

        do {
            try data.write(to: URL(fileURLWithPath: tempPath))
        } catch {
            cleanupTempIfNewlyCreated(tempPath, existedBefore: tempPathExistedBefore)
            throw error
        }
        if let mode {
            guard chmod(tempPath, mode) == 0 else {
                cleanupTempIfNewlyCreated(tempPath, existedBefore: tempPathExistedBefore)
                throw ConfigFileError.writeFailed("Cannot set file mode")
            }
        }

        guard rename(tempPath, resolvedPath) == 0 else {
            cleanupTempIfNewlyCreated(tempPath, existedBefore: tempPathExistedBefore)
            throw ConfigFileError.writeFailed("Rename failed")
        }

        if let mode {
            guard chmod(resolvedPath, mode) == 0 else {
                throw ConfigFileError.writeFailed("Cannot set file mode")
            }
        }
    }

    /// Removes `tempPath` only when this write created it. Shared by
    /// `writeAtomically`'s three failure paths (the write itself, the
    /// pre-rename `chmod`, the `rename`) so the same decision is made
    /// identically at each.
    private static func cleanupTempIfNewlyCreated(_ tempPath: String, existedBefore: Bool) {
        guard !existedBefore else { return }
        try? FileManager.default.removeItem(atPath: tempPath)
    }

    /// Reads, transforms, and writes back `path` under a single exclusive
    /// lock, so a caller's read-modify-write sequence can no longer race
    /// another caller's: `atomicWrite` alone only locks the write, leaving
    /// the read and the in-memory modification outside the lock.
    ///
    /// `path` is resolved (`resolveConfigPath`) exactly once, and that same
    /// resolved path is used for the read, the write, and the delete alike
    /// — a caller reading a raw, unresolved path while this writes to the
    /// resolved one is exactly the symlink divergence this closes.
    ///
    /// `transform` receives `nil` when the resolved path doesn't exist, and
    /// otherwise its current bytes. Returning `nil` deletes the resolved
    /// path (a no-op if it's already absent); returning the same bytes that
    /// went in (including `nil` in, `nil` out) writes no bytes at all, so
    /// the file's mtime is left untouched. For a caller that passes
    /// `restoreModeOnNoWrite: true` (a file Calyx owns outright), the
    /// guarantee on this identical-content path is "the file holds these
    /// bytes AND has this mode", not just the bytes, so an existing file
    /// whose mode has drifted from `mode` (e.g. `chmod`ed behind this
    /// API's back) is still brought back to `mode` via a bare `chmod` with
    /// no write. This matters concretely for a hook script or shell
    /// integration file: it's what lets reinstalling repair a lost
    /// executable/readable bit without needing different content to force
    /// a rewrite. For every other caller (the default, `false`), ordinary
    /// content edits to a file Calyx does not own outright must never
    /// narrow or widen the user's own permission bits, so this identical-
    /// content path leaves the mode alone entirely. `transform` throwing
    /// leaves the file byte-for-byte and mode-for-mode unchanged and still
    /// releases the lock.
    ///
    /// Never creates `path`'s parent directory. Several callers
    /// (`CodexConfigManager`, `GrokConfigManager`,
    /// `OpenCodeConfigManager.preflightWritable`) deliberately refuse to
    /// write when their tool's config directory doesn't exist yet, since
    /// that directory's absence means the tool itself isn't installed and
    /// Calyx must not create it on the user's behalf. A shared primitive
    /// that created the directory would silently defeat all of them.
    ///
    /// Writes no `.bak` — there is nothing to compensate for, since this
    /// function's write is non-destructive by construction (the caller's
    /// `transform` is the only place content is derived from the old
    /// bytes).
    ///
    /// `mode` is the permission bits applied to the temp file before the
    /// rename (and, redundantly, to the resolved path after — see
    /// `writeAtomically`). Defaults to `nil`: "do not set or change the
    /// mode, leave whatever is there". A file Calyx does not own outright
    /// (a user's own dotfile Calyx merely edits a region of) must keep
    /// whatever mode the user gave it, so only a caller that (a) owns the
    /// whole file, or (b) is writing a secret (the bearer token) into an
    /// otherwise user-owned file, passes an explicit `mode`. When `mode`
    /// is `nil` and an existing file's content is actually being
    /// rewritten, this function preserves that file's current mode across
    /// the write (stats it before building the temp file, then applies
    /// that mode to the temp file) rather than letting the temp file's own
    /// umask-derived mode carry through the rename — ordinary content
    /// edits must never narrow or widen a user's own permission bits.
    /// A brand-new file created with `mode: nil` has no prior mode to
    /// preserve, so it falls back to `0o600` rather than the umask's
    /// default (typically 0644, world-readable): "preserve the existing
    /// mode" has no meaning for a file that didn't exist, and every config
    /// `atomicWrite` has always created was 0600, not whatever the umask
    /// happened to produce.
    ///
    /// `restoreModeOnNoWrite` controls whether `mode` is also asserted on
    /// the no-write path (`transform` returns bytes identical to what went
    /// in, including `nil` in / `nil` out). Defaults to `false`. This must
    /// stay `false` for every file where `mode` is non-`nil` only because
    /// Calyx is writing a secret into an otherwise user-owned file (case
    /// (b) above): the mode there governs Calyx's own written content, not
    /// the file as a whole, and a no-op transform (the entry Calyx looks
    /// for isn't present) must never narrow or widen that file's mode --
    /// it is not Calyx's file to have an opinion about. Pass `true` only
    /// from a caller that owns the entire file outright (case (a)): there,
    /// repairing a drifted mode with no content change is the intended
    /// "reinstall repairs a lost executable/readable bit" behavior this
    /// function's main doc comment describes.
    /// `lockTimeout` bounds how long this call will wait to acquire the
    /// resolved path's lock before giving up (`ConfigFileError
    /// .writeFailed`) rather than blocking indefinitely -- see
    /// `acquireLock`'s own doc comment for why an unbounded wait is
    /// unsafe here specifically: `AgentEndpointFile.remove` routes
    /// through this function and is reachable from `@MainActor`
    /// (`CalyxMCPServer.stop()` / `LiveIPCServerControl.stop()`). Lock
    /// acquisition polls on the calling thread, 50ms at a time, up to
    /// `lockTimeout`, so on that path the worst case is up to
    /// `lockTimeout` of unresponsive UI followed by a failure that
    /// `AgentEndpointFile.remove` swallows via `try?`, not an indefinite
    /// freeze. The only contender for this lock file is another Calyx
    /// instance writing the same file for a few milliseconds, so in
    /// practice a single poll acquires it.
    static func withExclusiveConfig(
        path: String, mode: mode_t? = nil, restoreModeOnNoWrite: Bool = false, lockTimeout: TimeInterval = 10,
        _ transform: (Data?) throws -> Data?
    ) throws {
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

        try acquireLock(lockFd, timeout: lockTimeout)

        let fileManager = FileManager.default
        let exists = fileManager.fileExists(atPath: resolvedPath)
        let input: Data? = exists ? try Data(contentsOf: URL(fileURLWithPath: resolvedPath)) : nil

        let output = try transform(input)

        guard output != input else {
            // Bytes are unchanged (including nil in, nil out), so no write
            // is needed. Only bring an existing file's mode back to `mode`
            // if it has drifted when `restoreModeOnNoWrite` says this
            // caller owns the whole file -- see this parameter's doc
            // comment above for why a user-owned file must never have its
            // mode asserted on a no-op transform.
            if exists, restoreModeOnNoWrite {
                try restoreModeIfNeeded(mode, atPath: resolvedPath)
            }
            return
        }

        guard let output else {
            guard exists else { return }
            try fileManager.removeItem(atPath: resolvedPath)
            return
        }

        // `mode == nil` on a file that already exists means "preserve
        // whatever mode it currently has" (see this function's doc
        // comment) -- captured here, before the temp file is written, so
        // the rename carries the original mode through rather than the
        // temp file's own umask-derived one. `mode == nil` on a file that
        // does NOT yet exist has no prior mode to preserve, so it falls
        // back to 0600, matching every config `atomicWrite` has always
        // created: "preserve the user's existing mode" has no meaning for
        // a file Calyx is creating from nothing, and leaving a brand-new
        // config at the umask's default (typically 0644, world-readable)
        // is not a mode any config file's creation should default to.
        let effectiveMode: mode_t?
        if let mode {
            effectiveMode = mode
        } else if exists {
            var statBuf = stat()
            guard stat(resolvedPath, &statBuf) == 0 else {
                throw ConfigFileError.writeFailed("Cannot stat file to preserve its mode")
            }
            effectiveMode = statBuf.st_mode & ~S_IFMT
        } else {
            effectiveMode = 0o600
        }

        try writeAtomically(data: output, toResolvedPath: resolvedPath, mode: effectiveMode)
    }

    /// Brings `path`'s permission bits to `mode` if they've drifted,
    /// without touching its bytes or mtime: `chmod` alone, never a
    /// write. Only called from the `withExclusiveConfig` no-write path,
    /// under the caller's already-held lock. `mode == nil` means Calyx
    /// has no opinion on this file's mode, so there is nothing to
    /// restore. Reads the current mode via `stat`, masked to the
    /// permission bits `S_IFMT` excludes, so a mismatch in the file's
    /// type bits (which `chmod` couldn't change anyway) can never
    /// trigger a spurious `chmod` call.
    private static func restoreModeIfNeeded(_ mode: mode_t?, atPath path: String) throws {
        guard let mode else { return }
        var statBuf = stat()
        guard stat(path, &statBuf) == 0 else {
            throw ConfigFileError.writeFailed("Cannot stat file to check mode")
        }
        let currentMode = statBuf.st_mode & ~S_IFMT
        guard currentMode != mode else { return }
        guard chmod(path, mode) == 0 else {
            throw ConfigFileError.writeFailed("Cannot restore file mode")
        }
    }

    /// Acquires `fd`'s exclusive `flock`, retrying a non-blocking attempt
    /// (`LOCK_EX | LOCK_NB`) every 50ms until either it succeeds or
    /// `timeout` elapses, throwing `ConfigFileError.writeFailed` in the
    /// latter case rather than blocking on `flock(LOCK_EX)` forever.
    /// A blocking `flock` here is safe only as long as every holder of
    /// this same lock file always releases it in bounded time; nothing
    /// in this codebase can guarantee that of another process, so an
    /// unbounded wait risks holding this call's caller -- including a
    /// queued `IPCActivationChain` operation, whose `runningOperation`
    /// stays non-nil and keeps the Settings row disabled for as long as
    /// the wait continues -- hostage to a lock some other process never
    /// releases. A bounded wait instead surfaces a failure the chain can
    /// record and recover from.
    /// Any `flock` failure other than `EWOULDBLOCK` (the expected result
    /// of the lock genuinely being held elsewhere) is treated as
    /// unretryable and thrown immediately.
    private static func acquireLock(_ fd: Int32, timeout: TimeInterval) throws {
        let pollInterval: useconds_t = 50_000
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if flock(fd, LOCK_EX | LOCK_NB) == 0 { return }
            guard errno == EWOULDBLOCK else {
                throw ConfigFileError.writeFailed("Cannot acquire lock")
            }
            guard Date() < deadline else {
                throw ConfigFileError.writeFailed("Cannot acquire lock")
            }
            usleep(pollInterval)
        }
    }

    /// Maps `resolvedPath` to a stable lock-file path inside Calyx's own
    /// `AppSupportDirectory.locksPath` directory (created on first use),
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
        let locksDir = AppSupportDirectory.locksPath
        if !FileManager.default.fileExists(atPath: locksDir) {
            try FileManager.default.createDirectory(atPath: locksDir, withIntermediateDirectories: true)
        }
        let digest = SHA256.hash(data: Data(resolvedPath.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return (locksDir as NSString).appendingPathComponent(hex + ".lock")
    }
}
