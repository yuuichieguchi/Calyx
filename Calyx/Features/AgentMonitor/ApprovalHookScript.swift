// ApprovalHookScript.swift
// Calyx
//
// The `calyx-approval-hook` shell script installed under
// `~/Library/Application Support/Calyx/bin/`, alongside
// `calyx-agent-hook` (see AgentHookScript.swift). Unlike
// calyx-agent-hook's fire-and-forget async POST to /agent-event, this
// script is invoked *synchronously* by a PreToolUse hook entry and its
// stdout becomes Claude Code's / Codex's actual permission decision --
// so its fail-safe behavior (never printing "allow", always exiting 0)
// is the single most safety-critical string invariant in this file.

import Foundation

enum ApprovalHookScript {

    /// The script's file name, also used by `ClaudeHooksConfigManager` /
    /// `CodexHooksConfigManager` to recognize its own `command` entries
    /// by path, alongside `AgentHookScript.fileName`.
    static let fileName = "calyx-approval-hook"

    /// Both `CALYX_SURFACE_ID` and `CALYX_SESSION_ID` unset means this
    /// pane wasn't launched by Calyx at all (e.g. a plain Terminal.app
    /// tab running `claude`) -- exit immediately, exactly like
    /// `AgentHookScript`'s identical guard, so those instances are
    /// unaffected. `agent-endpoint.json` is re-read on every invocation
    /// (rather than baked in at install time) so a server restart or
    /// token rotation never leaves the hook posting to a stale
    /// port/token.
    ///
    /// `$1` defaults `kind` to `claude-code` for the same reason as
    /// `AgentHookScript`: Claude Code's own hook `command` entries
    /// (installed by `ClaudeHooksConfigManager`) invoke this script with
    /// no arguments, while `CodexHooksConfigManager` installs Codex's
    /// entries as `"<scriptPath>" codex` to pass `codex` explicitly.
    ///
    /// The `X-Calyx-Surface-ID` header value is
    /// `${CALYX_SESSION_ID:-$CALYX_SURFACE_ID}`: a persistent-session
    /// pane's calyx-session ID survives ghostty surface re-creation
    /// (reconnect) while `CALYX_SURFACE_ID` does not, so `CALYX_SESSION_ID`
    /// is preferred whenever set, falling back to the ordinary
    /// `CALYX_SURFACE_ID` otherwise -- see `AgentHookScript`'s doc
    /// comment for the fuller rationale, which applies identically here.
    ///
    /// curl's `-m` deadline is `ApprovalHookTiming.curlTimeoutSeconds`
    /// (585s), derived by string interpolation rather than a separately
    /// hardcoded literal, so the nesting invariant `ApprovalHookTiming`
    /// documents -- Calyx's own server answers by 570s, strictly before
    /// curl gives up at 585s, strictly before the CLI's own hook-entry
    /// timeout kills the whole hook process at 600s -- can't silently
    /// drift out of sync with this script. `--fail` makes curl treat any
    /// non-2xx server response as a curl error too, so it's routed
    /// through `fail_safe()` rather than printed to the CLI as if it
    /// were a real permission decision.
    ///
    /// The curl exit code is then switched on:
    /// - `0` (success): the server's response body is printed verbatim
    ///   via `printf '%s'` -- never `echo`, which can mangle a body
    ///   starting with `-` or containing backslash escape sequences.
    /// - `7` (connection refused): silent, no output at all, and
    ///   crucially does NOT call `fail_safe()`. After Calyx crashes,
    ///   `agent-endpoint.json` is left behind pointing at a now-dead
    ///   port, so every subsequent tool call would otherwise land in
    ///   this branch -- calling `fail_safe()` there would force an
    ///   interactive "ask" prompt onto every tool call for as long as
    ///   Calyx stays down, including ones on the CLI's own allow-list.
    ///   Producing no output instead leaves the hook inert: the CLI
    ///   falls back to exactly the permission behavior it would have had
    ///   with no Calyx hook installed at all, rather than a stale
    ///   endpoint file silently degrading every tool call's UX.
    /// - anything else (timeout, DNS failure, a non-2xx response
    ///   rejected by `--fail`, etc.): `fail_safe()`, which prints the
    ///   exact `"ask"` `hookSpecificOutput` JSON literal when `kind` is
    ///   `claude-code` (nothing for any other kind) -- a lost connection
    ///   or unexpected failure must surface as an interactive approval
    ///   prompt, never a silent bypass, and must never fabricate
    ///   `"allow"`.
    ///
    /// Every exit path is `exit 0`: whatever curl did or didn't return,
    /// this script itself must never exit nonzero and break the user's
    /// hook chain.
    static let scriptBody: String = """
    #!/bin/sh
    #
    # calyx-approval-hook — synchronously forwards a PreToolUse hook's
    # stdin JSON to Calyx's local Agent Monitor IPC endpoint and prints
    # its response verbatim; the response body IS the CLI's permission
    # decision. Installed and removed by ClaudeHooksConfigManager /
    # CodexHooksConfigManager.

    if [ -z "$CALYX_SURFACE_ID" ] && [ -z "$CALYX_SESSION_ID" ]; then
        exit 0
    fi

    kind="${1:-claude-code}"

    endpoint_file="$HOME/Library/Application Support/Calyx/agent-endpoint.json"
    if [ ! -f "$endpoint_file" ]; then
        exit 0
    fi

    port=$(sed -n 's/.*"port"[[:space:]]*:[[:space:]]*\\([0-9]*\\).*/\\1/p' "$endpoint_file")
    token=$(sed -n 's/.*"token"[[:space:]]*:[[:space:]]*"\\([^"]*\\)".*/\\1/p' "$endpoint_file")

    if [ -z "$port" ] || [ -z "$token" ]; then
        exit 0
    fi

    fail_safe() {
        if [ "$kind" = "claude-code" ]; then
            printf '%s' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"Calyx approval inbox unavailable"}}'
        fi
    }

    response=$(curl -s -m \(ApprovalHookTiming.curlTimeoutSeconds) \\
        --fail \\
        -X POST \\
        -H "Authorization: Bearer $token" \\
        -H "X-Calyx-Surface-ID: ${CALYX_SESSION_ID:-$CALYX_SURFACE_ID}" \\
        -H "X-Calyx-Agent-Kind: $kind" \\
        -H "Content-Type: application/json" \\
        --data-binary @- \\
        "http://127.0.0.1:$port/approval-request")
    curl_exit=$?

    case "$curl_exit" in
        0) printf '%s' "$response" ;;
        7) exit 0 ;;
        *) fail_safe ;;
    esac

    exit 0
    """

    /// Installs the script into `toDirectory`, creating the directory if
    /// needed, and marks it executable (0755). Returns the script's
    /// absolute path. Mirrors `AgentHookScript.install(toDirectory:)`
    /// exactly.
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
