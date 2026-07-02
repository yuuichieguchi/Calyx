// AgentHookScript.swift
// Calyx
//
// The `calyx-agent-hook` shell script installed under
// `~/Library/Application Support/Calyx/bin/`. Forwards a Claude Code hook's
// stdin JSON to the local Calyx IPC server's /agent-event endpoint.

import Foundation

enum AgentHookScript {

    /// The script's file name, also used by `ClaudeHooksConfigManager` to
    /// recognize its own `command` entries by path.
    static let fileName = "calyx-agent-hook"

    /// Default install directory: `~/Library/Application Support/Calyx/bin`.
    static var defaultInstallDirectory: String {
        (AgentEndpointFile.defaultDirectory as NSString).appendingPathComponent("bin")
    }

    /// `CALYX_SURFACE_ID` unset means this pane wasn't launched by Calyx
    /// (e.g. a plain Terminal.app tab running `claude`) — exit
    /// immediately so those instances are unaffected. `agent-endpoint.json`
    /// is re-read on every invocation (rather than baked in at install
    /// time) so a server restart or token rotation never leaves the hook
    /// posting to a stale port/token. Every exit path is `exit 0`: a
    /// failed or unreachable POST must never break the user's hook chain.
    static let scriptBody: String = """
    #!/bin/sh
    #
    # calyx-agent-hook — forwards a Claude Code hook's stdin JSON to
    # Calyx's local Agent Monitor IPC endpoint. Installed and removed by
    # ClaudeHooksConfigManager.

    if [ -z "$CALYX_SURFACE_ID" ]; then
        exit 0
    fi

    endpoint_file="$HOME/Library/Application Support/Calyx/agent-endpoint.json"
    if [ ! -f "$endpoint_file" ]; then
        exit 0
    fi

    port=$(sed -n 's/.*"port"[[:space:]]*:[[:space:]]*\\([0-9]*\\).*/\\1/p' "$endpoint_file")
    token=$(sed -n 's/.*"token"[[:space:]]*:[[:space:]]*"\\([^"]*\\)".*/\\1/p' "$endpoint_file")

    if [ -z "$port" ] || [ -z "$token" ]; then
        exit 0
    fi

    curl -s -m 2 \\
        -X POST \\
        -H "Authorization: Bearer $token" \\
        -H "X-Calyx-Surface-ID: $CALYX_SURFACE_ID" \\
        -H "Content-Type: application/json" \\
        --data-binary @- \\
        "http://127.0.0.1:$port/agent-event" > /dev/null 2>&1

    exit 0
    """

    /// Installs the script into `toDirectory`, creating the directory if
    /// needed, and marks it executable (0755). Returns the script's
    /// absolute path.
    static func install(toDirectory directory: String) throws -> String {
        let fm = FileManager.default
        if !fm.fileExists(atPath: directory) {
            try fm.createDirectory(atPath: directory, withIntermediateDirectories: true)
        }
        let scriptPath = (directory as NSString).appendingPathComponent(fileName)
        try scriptBody.write(toFile: scriptPath, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath)
        return scriptPath
    }
}
