// AgentEndpointFile.swift
// Calyx
//
// Writes/removes `agent-endpoint.json` (port, token, the two HMAC
// blocks of the server's `IPCWakeProofKey`, and the writing process's
// liveness identifier `pid`/`pidStart`) so the hook scripts can
// always reach the current IPC server, even after a restart or token
// rotation, and `calyx-ipc-wake-hook` can verify that a wake answer came
// from that server.

import Foundation

enum AgentEndpointFile {

    private static let fileName = "agent-endpoint.json"

    /// `calyx-bearer-token`: the bare token, written beside
    /// agent-endpoint.json by `write` and removed with it by `remove`.
    /// Grok >= 1.0.52 reads it on every request through
    /// `bearer_token_file` (C-D17), so a renewed token reaches Grok
    /// without a config rewrite. Like the endpoint file it persists across
    /// Cmd-Q (C-D13 residual): nothing removes it at quit. `calyx-mcp-headers`
    /// does NOT read it; it reads the endpoint file so the liveness check
    /// in `shellResolution` applies before the token is sent.
    static let bearerFileName = "calyx-bearer-token"

    /// `<directory>/calyx-bearer-token`.
    static func bearerFilePath(directory: String) -> String {
        (directory as NSString).appendingPathComponent(bearerFileName)
    }

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
    /// `write(port:token:wakeProofKey:liveness:directory:)`'s own path.
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

    /// The JavaScript `liveEndpoint(endpoint)` guard shared by the OpenCode
    /// plugin (`OpenCodePluginManager.scriptBody`, Bun) and the pi extension
    /// (`PiExtensionManager.scriptBody`, TypeScript), so the two cannot
    /// drift (spec Feature C, G1; C-D7). Plain JavaScript, valid in both.
    ///
    /// Threat model: the bearer goes only to the Calyx process that wrote
    /// agent-endpoint.json. `process.kill(pid, 0)` rejects a dead pid
    /// (ESRCH) and another user's (EPERM); `ps -o lstart=` under
    /// `TZ=UTC LC_ALL=C`, whitespace collapsed, must equal `pidStart`,
    /// which rules out a reused pid. C-D7: a verified (pid, pidStart) pair
    /// is cached in `verifiedPid`/`verifiedPidStart` for the host
    /// process's lifetime, after which only `process.kill(pid, 0)` is
    /// re-checked. Residual: another process reusing the pid with the same
    /// `pidStart` text, which needs the pid counter to wrap within it.
    ///
    /// The caller must import `spawnSync` from `node:child_process` and
    /// interpolate this at a six-space indentation inside its literal:
    /// the first line carries no indentation of its own and every later
    /// line carries two spaces, matching the enclosing function body.
    static let javascriptLiveEndpoint: String = """
    // Liveness check (spec Feature C, G1): the token goes only to the
      // Calyx process that wrote agent-endpoint.json. process.kill(pid, 0)
      // throws ESRCH for a dead pid and EPERM for another user's; the start
      // time from `ps -o lstart=` (UTC, C locale, whitespace collapsed, the
      // same normalisation Calyx wrote pidStart with) rules out a reused pid.
      // A verified (pid, pidStart) pair is cached for this process's lifetime
      // and afterwards only process.kill(pid, 0) is re-checked: the residual
      // is the pid being reused by another process with the same pidStart
      // text, which needs the pid counter to wrap around within it.
      let verifiedPid = null;
      let verifiedPidStart = null;

      function liveEndpoint(endpoint) {
        const pid = endpoint["pid"];
        const pidStart = endpoint["pidStart"];
        if (typeof pid !== "number" || typeof pidStart !== "string" || !pidStart) {
          return false;
        }
        try {
          process.kill(pid, 0);
        } catch {
          return false;
        }
        if (pid === verifiedPid && pidStart === verifiedPidStart) {
          return true;
        }
        const ps = spawnSync("ps", ["-p", String(pid), "-o", "lstart="], {
          env: { ...process.env, TZ: "UTC", LC_ALL: "C" },
          encoding: "utf8",
        });
        const liveStart = String(ps.stdout ?? "").split(/\\s+/).filter(Boolean).join(" ");
        if (liveStart !== pidStart) {
          return false;
        }
        verifiedPid = pid;
        verifiedPidStart = pidStart;
        return true;
      }
    """

    struct Endpoint: Sendable, Equatable {
        let port: Int
        let token: String
    }

    /// The `/bin/sh` text that resolves agent-endpoint.json and checks
    /// that its writer is alive (spec Feature C, J1/J2): the endpoint
    /// file path (`CALYX_ENDPOINT_FILE`, else `shellFallbackPath`), its
    /// presence, `port`/`token` (both non-empty), then `pid`/`pidStart`
    /// (both present), `kill -0 "$pid"` and the normalised
    /// `TZ=UTC LC_ALL=C ps -p "$pid" -o lstart=` equal to `pidStart`.
    /// Falling through leaves `endpoint_file`, `port`, `token`, `pid` and
    /// `pid_start` set. Never writes stdout and ends only through
    /// `exit 0`, so a caller that prints its own failure output (slice
    /// 4's `calyx-mcp-headers`) can reuse it. Runs `set --`, which
    /// clobbers the positional parameters: read `$1` before it.
    /// Interpolated by `AgentHookScriptPrologue.body`.
    static let shellResolution: String = """
    # CALYX_ENDPOINT_FILE is injected by GhosttySurfaceController alongside
    # CALYX_SURFACE_ID, scoped to wherever this Calyx process actually
    # wrote agent-endpoint.json (a --calyx-path-root scratch directory
    # under test, the real Application Support directory otherwise). The
    # literal fallback covers a pane launched before that injection
    # existed, or a shell that stripped the variable.
    endpoint_file="${CALYX_ENDPOINT_FILE:-\(AgentEndpointFile.shellFallbackPath)}"
    if [ ! -f "$endpoint_file" ]; then
        exit 0
    fi

    port=$(sed -n 's/.*"port"[[:space:]]*:[[:space:]]*\\([0-9]*\\).*/\\1/p' "$endpoint_file")
    token=$(sed -n 's/.*"token"[[:space:]]*:[[:space:]]*"\\([^"]*\\)".*/\\1/p' "$endpoint_file")

    if [ -z "$port" ] || [ -z "$token" ]; then
        exit 0
    fi

    # Liveness check (spec Feature C, G1): send the token only to the
    # Calyx process that wrote this file. `kill -0` fails for a dead pid
    # and for another user's pid (EPERM); the start time rules out a
    # reused pid. `ps -o lstart=` under TZ=UTC LC_ALL=C prints the same
    # text EndpointLiveness wrote, modulo whitespace, which word
    # splitting into `set --` and `$*` collapses. `set --` clobbers $1,
    # so `kind` was read before this, in AgentHookScriptPrologue.guards.
    pid=$(sed -n 's/.*"pid"[[:space:]]*:[[:space:]]*\\([0-9]*\\).*/\\1/p' "$endpoint_file")
    pid_start=$(sed -n 's/.*"pidStart"[[:space:]]*:[[:space:]]*"\\([^"]*\\)".*/\\1/p' "$endpoint_file")
    if [ -z "$pid" ] || [ -z "$pid_start" ]; then
        exit 0
    fi
    if ! kill -0 "$pid" 2>/dev/null; then
        exit 0
    fi
    set -- $(TZ=UTC LC_ALL=C ps -p "$pid" -o lstart=)
    if [ "$*" != "$pid_start" ]; then
        exit 0
    fi
    """

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

    /// Writes `agent-endpoint.json` (0600) to `directory` with `port`,
    /// `token`, and `wakeProofInner`/`wakeProofOuter`: the
    /// `innerBlockHex`/`outerBlockHex` of `wakeProofKey`, never the key
    /// itself. The blocks are read only by `calyx-ipc-wake-hook`
    /// (`IPCWakeHookScript`), which checks with them that a
    /// `POST /ipc-wake` 200 answer carries a proof made with the running
    /// server's key; `read` and every other reader ignore them. Uses
    /// `ConfigFileUtils.atomicWrite` (temp file + rename) rather than a
    /// direct `Data.write` so a reader, any hook script invoked
    /// concurrently from every active pane, never observes a
    /// partially-written file.
    ///
    /// Also writes `liveness` as `pid` (number) and `pidStart` (string),
    /// six keys in all: every sender checks them before sending the
    /// token (spec Feature C, J1/J2; see `shellResolution` and
    /// `EndpointLiveness`). `read` ignores them.
    ///
    /// Writes `bearerFilePath(directory:)` FIRST: the token bytes only (no
    /// trailing newline), atomically, 0600 (`atomicWrite`'s fixed mode).
    /// Only then is agent-endpoint.json written. A bearer-file failure
    /// therefore throws before anything is published, leaving any existing
    /// agent-endpoint.json untouched, so `finishStart`'s catch/log
    /// describes the on-disk state accurately. The only remaining window
    /// is "bearer new, endpoint old": Grok then sends the new token to the
    /// new server, which is correct.
    static func write(
        port: Int, token: String, wakeProofKey: IPCWakeProofKey, liveness: EndpointLiveness, directory: String
    ) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: directory) {
            try fm.createDirectory(atPath: directory, withIntermediateDirectories: true)
        }
        let dict: [String: Any] = [
            "port": port,
            "token": token,
            "wakeProofInner": wakeProofKey.innerBlockHex,
            "wakeProofOuter": wakeProofKey.outerBlockHex,
            "pid": Int(liveness.pid),
            "pidStart": liveness.startText,
        ]
        let data = try JSONSerialization.data(withJSONObject: dict)
        let filePath = (directory as NSString).appendingPathComponent(fileName)
        try ConfigFileUtils.atomicWrite(data: Data(token.utf8), to: bearerFilePath(directory: directory))
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
    ///
    /// `calyx-bearer-token` is removed exactly when agent-endpoint.json
    /// is, and left alone otherwise.
    static func remove(directory: String, port: Int, token: String) {
        guard !token.isEmpty else { return }
        let filePath = (directory as NSString).appendingPathComponent(fileName)
        var removedEndpointFile = false
        // 0600: Calyx owns this file outright and it carries the bearer
        // token (see `write(port:token:wakeProofKey:liveness:directory:)` above).
        try? ConfigFileUtils.withExclusiveConfig(path: filePath, mode: 0o600, restoreModeOnNoWrite: true) { current in
            guard let current else { return current }
            guard let onDisk = decode(current), onDisk.port == port, onDisk.token == token
            else { return current }
            removedEndpointFile = true
            return nil
        }
        guard removedEndpointFile else { return }
        try? FileManager.default.removeItem(atPath: bearerFilePath(directory: directory))
    }
}
