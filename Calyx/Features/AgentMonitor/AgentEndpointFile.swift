// AgentEndpointFile.swift
// Calyx
//
// Writes/removes `agent-endpoint.json` (port + token) so the
// calyx-agent-hook script can always reach the current IPC server, even
// after a restart or token rotation.

import Foundation

enum AgentEndpointFile {

    private static let fileName = "agent-endpoint.json"

    /// Default directory: `~/Library/Application Support/Calyx`.
    static var defaultDirectory: String {
        AppSupportDirectory.path
    }

    /// The path this process actually writes/reads `agent-endpoint.json`
    /// at: `defaultDirectory`/`fileName`, already reflecting
    /// `CalyxPathRoot.testRoot` via `defaultDirectory`. This is what
    /// `GhosttySurfaceController` injects as `CALYX_ENDPOINT_FILE`, so a
    /// pane's environment always names the exact file this process wrote
    /// (or would write), not a rebuilt string a caller could drift from
    /// `write(port:token:directory:)`'s own path.
    static var path: String {
        (defaultDirectory as NSString).appendingPathComponent(fileName)
    }

    /// Path suffix, relative to a user's home directory, of the file
    /// every generated script falls back to when `CALYX_ENDPOINT_FILE`
    /// is unset -- production's own `defaultDirectory`/`fileName`, but
    /// expressed as a literal a generated script can embed and resolve
    /// against ITS OWN runtime `$HOME`, since that script runs in an
    /// arbitrary end user's shell, not this process. Single source for
    /// the literal `AgentHookScript`, `ApprovalHookScript`,
    /// `OpenCodePluginManager`, `PiExtensionManager`, and
    /// `ShellIntegrationInstaller`'s zsh/fish bodies each interpolate,
    /// via `shellFallbackPath`/`javascriptFallbackPathExpression` below,
    /// rather than each carrying its own copy of the string.
    private static let homeRelativePath = "Library/Application Support/Calyx/\(fileName)"

    /// `homeRelativePath`, spelled as a POSIX shell literal
    /// (`$HOME`-relative) for embedding in a `sh`/`zsh`/`fish` generated
    /// script body's fallback expression.
    static let shellFallbackPath = "$HOME/" + homeRelativePath

    /// `homeRelativePath`, spelled as a backtick-quoted JavaScript
    /// template-literal expression (`process.env.HOME`-relative) for
    /// embedding in a Node/Bun generated script body's fallback
    /// expression.
    static let javascriptFallbackPathExpression = "`${process.env.HOME}/" + homeRelativePath + "`"

    struct Endpoint: Sendable, Equatable {
        let port: Int
        let token: String
    }

    /// Reads and decodes `agent-endpoint.json` from `directory`, without
    /// taking `ConfigFileUtils`'s exclusive lock -- a stale-by-one-write
    /// read here is fine, since the only use is "is there a port/token to
    /// reuse", not a read-modify-write. Returns `nil` for every failure
    /// mode (file absent, unreadable, not valid JSON, missing either
    /// key), and never logs: an absent or malformed file is a normal,
    /// expected state (first launch, or after a clean `remove()`), not an
    /// error worth surfacing.
    static func read(directory: String) -> Endpoint? {
        let filePath = (directory as NSString).appendingPathComponent(fileName)
        guard let data = FileManager.default.contents(atPath: filePath) else { return nil }
        return decode(data)
    }

    private static func decode(_ data: Data) -> Endpoint? {
        guard let parsed = try? JSONSerialization.jsonObject(with: data),
              let json = parsed as? [String: Any],
              let port = json["port"] as? Int,
              let token = json["token"] as? String
        else { return nil }
        return Endpoint(port: port, token: token)
    }

    /// Writes `agent-endpoint.json` (0600) to `directory` with the given
    /// `port` and `token`. Uses `ConfigFileUtils.atomicWrite` (temp file +
    /// rename) rather than a direct `Data.write` so a reader — the
    /// `calyx-agent-hook` script, invoked concurrently from every active
    /// pane's hooks — never observes a partially-written file.
    static func write(port: Int, token: String, directory: String) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: directory) {
            try fm.createDirectory(atPath: directory, withIntermediateDirectories: true)
        }
        let dict: [String: Any] = ["port": port, "token": token]
        let data = try JSONSerialization.data(withJSONObject: dict)
        let filePath = (directory as NSString).appendingPathComponent(fileName)
        try ConfigFileUtils.atomicWrite(data: data, to: filePath)
    }

    /// Removes `agent-endpoint.json` from `directory`, but only when the
    /// file on disk was published by the caller: its decoded `port` and
    /// `token` must both equal the ones passed in. A `token` of `""`
    /// (the value `CalyxMCPServer.token` holds before `start()` is ever
    /// called) is treated as an unconditional mismatch, so a server that
    /// never started can never delete a file it never wrote, even if its
    /// `port` (also defaulted, to `0`) happens to coincide with the
    /// value on disk. The file is left untouched if it is absent,
    /// unreadable, not valid JSON, or missing either key.
    ///
    /// If two Calyx instances run at once, whichever started later
    /// overwrites the file with its own port+token: the earlier
    /// instance is unreachable from that write onward, before either
    /// instance's `stop()` ever runs, because every hook invocation
    /// reads this one shared file fresh. Once the later instance's own
    /// `stop()` then matches and deletes the file, hook traffic from
    /// every pane of BOTH instances goes inert. This is left unresolved
    /// on purpose: `~/.claude.json`'s MCP server config, the hook
    /// script's install location, and calyx-session are each already a
    /// single shared resource across all running instances, so
    /// self-healing only this file would imply a multi-instance story
    /// that does not exist.
    static func remove(directory: String, port: Int, token: String) {
        guard !token.isEmpty else { return }
        let filePath = (directory as NSString).appendingPathComponent(fileName)
        // 0600: Calyx owns this file outright and it carries the bearer
        // token (see `write(port:token:directory:)` above).
        try? ConfigFileUtils.withExclusiveConfig(path: filePath, mode: 0o600, restoreModeOnNoWrite: true) { current in
            guard let current else { return current }
            guard let onDisk = decode(current), onDisk.port == port, onDisk.token == token
            else { return current }
            return nil
        }
    }
}
